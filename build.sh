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

echo "▸ 清理"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ 编译（约 1-2 分钟）"
DEVELOPER_DIR="$CLT_DEV" swiftc -O -whole-module-optimization \
    -target arm64-apple-macosx15.0 \
    -o "$APP/Contents/MacOS/UpdateRadar" \
    "$SRC"/*.swift

echo "▸ 图标（日间 + 夜间）"
ICON_BIN="$BUILD/make_icon"
if [ ! -x "$ICON_BIN" ] || [ "$ROOT/tools/make_icon.swift" -nt "$ICON_BIN" ]; then
    DEVELOPER_DIR="$CLT_DEV" swiftc -O -target arm64-apple-macosx15.0 -o "$ICON_BIN" "$ROOT/tools/make_icon.swift"
fi
# 单张成品图（给 .icns 兜底用）
"$ICON_BIN" art "$BUILD/icon_art_1024.png" 1024

ICON_PKG="$BUILD/AppIcon.icon"
rm -rf "$ICON_PKG"; mkdir -p "$ICON_PKG/Assets"
"$ICON_BIN" bleed "$ICON_PKG/Assets/art.png" 1024
cat > "$ICON_PKG/icon.json" <<'JSON'
{
  "groups" : [
    { "layers" : [ { "image-name" : "art.png", "name" : "art" } ] }
  ],
  "supported-platforms" : { "squares" : ["macOS"] }
}
JSON

mkdir -p "$BUILD/actool-out"
if DEVELOPER_DIR="$XCODE_DEV" xcrun actool --compile "$BUILD/actool-out" \
     --platform macosx --minimum-deployment-target 15.0 \
     --app-icon AppIcon --output-partial-info-plist "$BUILD/icon-partial.plist" \
     "$ICON_PKG" >/dev/null 2>"$BUILD/actool.log"; then
    cp "$BUILD/actool-out/Assets.car" "$APP/Contents/Resources/Assets.car"
    cp "$BUILD/actool-out/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    echo "  .icon 已编译 → Assets.car（含 Aqua / DarkAqua 两套）"
else
    echo "  ⚠ actool 失败，退回单套 .icns"
    sed -n '1,6p' "$BUILD/actool.log"
    ICONSET="$BUILD/AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for s in 16 32 64 128 256 512; do
        sips -z $s $s "$BUILD/icon_art_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        d=$((s*2))
        sips -z $d $d "$BUILD/icon_art_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    cp "$BUILD/icon_art_1024.png" "$ICONSET/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
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
