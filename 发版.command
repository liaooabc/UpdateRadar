#!/bin/bash
# 双击这个文件就能发新版：自动把版本号 +1，然后打包出新的 DMG
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"

echo "小星：开始打包，大概需要两三分钟，别关窗口。"
echo

# 版本号 1.0.0 → 1.0.1
CUR=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
NEW=$(echo "$CUR" | awk -F. '{print $1"."$2"."$3+1}')
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((BUILD + 1))" Info.plist
echo "版本号：$CUR → $NEW"
echo

LOG="$(mktemp)"
if ! ./package.sh >"$LOG" 2>&1; then
    echo "打包失败了。下面是最关键的一行，复制给我看："
    echo "--------"
    grep -i "error" "$LOG" | head -5 || tail -20 "$LOG"
    echo "--------"
    echo "（完整日志在 ${LOG}）"
    read -n 1 -s -r -p "按任意键关闭"
    exit 1
fi

DMG=$(ls -t dist/*.dmg | head -1)
echo "搞定。新的安装包："
echo "  $DMG"
echo
echo "接下来：双击打开它 → 把「更新雷达」拖进 Applications → 就能发给别人了。"
open "$(dirname "$DMG")"
echo
read -n 1 -s -r -p "按任意键关闭窗口"
