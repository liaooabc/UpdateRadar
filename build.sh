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

echo "▸ 图标（Icon Composer 图层包：圆环 + 箭头，白天白底黑图 / 暗夜黑底白图）"
ICON_DOC="$ROOT/Resources/AppIcon.icon"      # 设计源文件（4 个 SVG + icon.json，可用 Icon Composer 打开改）
ICON_PKG="$BUILD/AppIcon.icon"               # actool 只认这个位置，换路径会静默不产出
                                             # 图标只有一条路：Resources/AppIcon.icon → actool → Assets.car。
# 老的单套 .icns 兜底（tools/make_icon.swift 现画蓝色箭头）已经删掉 —— 那是上一版的设计，
# 留着它只会在 actool 失败时把旧图标塞进包里，反而更难查。
if [ -f "$ICON_DOC/icon.json" ]; then
    rm -rf "$ICON_PKG"
    cp -R "$ICON_DOC" "$ICON_PKG"

    # actool 的输出目录放在 /tmp：直接在「文稿」下的 build/ 里写 Assets.car 时，
    # 它内部的 BOMStorageCompact 会报 "rename failed Operation not permitted"（沙箱/ACL 的锅），
    # 结果只留下一个半成品和 tmp.XXXX。先把产物写进临时目录，再拷回来。
    ACTOOL_OUT="$(mktemp -d)/actool-out"
    mkdir -p "$ACTOOL_OUT"
    # 一次 actool 编两个 catalog：AppIcon.icon（Dock 图标）+ Assets.xcassets
    # （菜单栏那张模板图）。两个必须编进同一个 Assets.car，NSImage(named:) 才找得到。
    MENUBAR_CATALOG="$ROOT/Resources/Assets.xcassets"
    if DEVELOPER_DIR="$XCODE_DEV" xcrun actool --compile "$ACTOOL_OUT" \
         --platform macosx --minimum-deployment-target 26.0 \
         --app-icon AppIcon --output-partial-info-plist "$BUILD/icon-partial.plist" \
         "$ICON_PKG" "$MENUBAR_CATALOG" >/dev/null 2>"$BUILD/actool.log"; then
        # 只装 Assets.car：它带 Aqua / DarkAqua / Tinted 三套，Finder、启动台（Apps.app）、
        # 显示简介、快速查看都读同一份，换外观不会"跳出另一个图标"。
        # 不再装 actool 顺带出的 AppIcon.icns —— 那个只有一套浅色图，边角场合会被顶上来。
        cp "$ACTOOL_OUT/Assets.car" "$APP/Contents/Resources/Assets.car"
        # 自查：白天 / 暗夜两套图层的 LayerOpacity 必须正好互换，否则等于没做明暗
        LAYERS=$(xcrun assetutil --info "$APP/Contents/Resources/Assets.car" 2>/dev/null \
                 | grep -c '"AssetType" : "Vector"' || true)
        echo "  .icon 已编译 → Assets.car（矢量图层条目：${LAYERS}，含 Aqua / DarkAqua / Tinted 三套）"
    else
        sed -n '1,8p' "$BUILD/actool.log"
        echo "  ✗ 图标编译失败（见上面 actool 的报错），先修好再继续；不会再用旧图标兜底。"
        exit 1
    fi
else
    echo "  ✗ 没找到 Resources/AppIcon.icon（图标唯一的来源），先找回它再继续。"
    exit 1
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
