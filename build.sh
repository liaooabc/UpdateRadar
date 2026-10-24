#!/bin/bash
# 更新雷达 构建脚本：编译 → 生成日夜图标资源 → 打包 .app → 临时签名
set -euo pipefail
# 这台机器装过 Xcode.app 但没同意许可：swiftc 用 Command Line Tools，
# actool（编译资源目录）只有 Xcode 里那份能用。
export CLT_DEV=/Library/Developer/CommandLineTools
export XCODE_DEV=/Applications/Xcode.app
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src"
BUILD="$ROOT/build"
APP="$BUILD/更新雷达.app"

echo "▸ 并发自检（Swift 6 迁移债，看这个数就行）"
CONC_LOG="$(mktemp)"
if DEVELOPER_DIR="$CLT_DEV" swiftc -typecheck -strict-concurrency=complete \
     -target arm64-apple-macosx15.0 "$SRC"/*.swift >"$CONC_LOG" 2>&1; then
    CONC_N=$(grep -oE "static property '[^']+'" "$CONC_LOG" | sort -u | wc -l | tr -d ' ')
    if [ "${CONC_N}" -eq 0 ]; then
        echo "  0 条，Swift 6 可以直接迁"
    else
        echo "  ${CONC_N} 条（不影响 Swift 5 编译，但 Swift 6 语言模式下会变成错误）："
        grep -oE "static property '[^']+'" "$CONC_LOG" | sort -u | sed 's/^/    /'
    fi
else
    echo "  自检没编过，跳过（真正的编译在下一步，报错会打在那里）"
fi
rm -f "$CONC_LOG"

echo "▸ 清理"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ 编译（约 1-2 分钟）"
DEVELOPER_DIR="$CLT_DEV" swiftc -O -whole-module-optimization \
    -target arm64-apple-macosx15.0 \
    -o "$APP/Contents/MacOS/UpdateRadar" \
    "$SRC"/*.swift

echo "▸ 图标（Icon Composer 图层包：底板 / 圆盘 / 光环 / 箭头，白天 + 暗夜）"
ICON_DOC="$ROOT/Resources/AppIcon.icon"      # 设计源文件（8 个 SVG + icon.json，可再用 Icon Composer 打开改）
ICON_PKG="$BUILD/AppIcon.icon"               # actool 只认这个位置，换路径会静默不产出
ICON_BIN="$BUILD/make_icon"                  # 兜底：万一 .icon 编不出来，用代码现画一套

build_icon_bin() {
    if [ ! -x "$ICON_BIN" ] || [ "$ROOT/tools/make_icon.swift" -nt "$ICON_BIN" ]; then
        DEVELOPER_DIR="$CLT_DEV" swiftc -O -target arm64-apple-macosx15.0 -o "$ICON_BIN" "$ROOT/tools/make_icon.swift"
    fi
}

# 兜底方案：单套 .icns（没有图层、不跟明暗切换，只在 actool 失败时用）
fallback_icns() {
    echo "  ⚠ 退回单套 .icns（不带明暗切换）"
    build_icon_bin
    "$ICON_BIN" art "$BUILD/icon_art_1024.png" 1024 dark
    ICONSET="$BUILD/AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for s in 16 32 64 128 256 512; do
        sips -z $s $s "$BUILD/icon_art_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        d=$((s*2))
        sips -z $d $d "$BUILD/icon_art_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    cp "$BUILD/icon_art_1024.png" "$ICONSET/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
}

if [ -f "$ICON_DOC/icon.json" ]; then
    rm -rf "$ICON_PKG"
    cp -R "$ICON_DOC" "$ICON_PKG"

    # actool 的输出目录放在 /tmp：直接在「文稿」下的 build/ 里写 Assets.car 时，
    # 它内部的 BOMStorageCompact 会报 "rename failed Operation not permitted"（沙箱/ACL 的锅），
    # 结果只留下一个半成品和 tmp.XXXX。先把产物写进临时目录，再拷回来。
    ACTOOL_OUT="$(mktemp -d)/actool-out"
    mkdir -p "$ACTOOL_OUT"
    # 一次 actool 编两个 catalog：AppIcon.icon（Dock 图标，明暗双模）+ Assets.xcassets
    # （菜单栏那张模板图）。两个必须编进同一个 Assets.car，NSImage(named:) 才找得到。
    MENUBAR_CATALOG="$ROOT/Resources/Assets.xcassets"
    if DEVELOPER_DIR="$XCODE_DEV" xcrun actool --compile "$ACTOOL_OUT" \
         --platform macosx --minimum-deployment-target 26.0 \
         --app-icon AppIcon --output-partial-info-plist "$BUILD/icon-partial.plist" \
         "$ICON_PKG" "$MENUBAR_CATALOG" >/dev/null 2>"$BUILD/actool.log"; then
        cp "$ACTOOL_OUT/Assets.car" "$APP/Contents/Resources/Assets.car"
        cp "$ACTOOL_OUT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
        # 自查：白天 / 暗夜两套图层的 LayerOpacity 必须正好互换，否则等于没做明暗
        LAYERS=$(xcrun assetutil --info "$APP/Contents/Resources/Assets.car" 2>/dev/null \
                 | grep -c '"AssetType" : "Vector"' || true)
        echo "  .icon 已编译 → Assets.car（矢量图层条目：${LAYERS}，含 Aqua / DarkAqua / Tinted 三套）"
    else
        sed -n '1,8p' "$BUILD/actool.log"
        fallback_icns
    fi
else
    echo "  没找到 Resources/AppIcon.icon，用 make_icon.swift 现画"
    fallback_icns
fi

echo "▸ 资源（Homebrew Cask 名称表）"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/Resources/cask-map.json" "$APP/Contents/Resources/cask-map.json"

echo "▸ Info.plist"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ 临时签名"
codesign --force --deep --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /'

echo "▸ 完成：$APP"
du -sh "$APP"
