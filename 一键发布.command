#!/bin/bash
# 双击这个：升版本号 → 编译打包 → 推源码 → 传安装包到 GitHub Releases
# 相当于「发版.command」+「发布到GitHub.command」连在一起跑。
set -uo pipefail
cd "$(dirname "$0")"

echo "小星：一键发布。先打包（大概两三分钟，别关窗口），好了自动传 GitHub。"
echo

if ! printf '\n' | ./发版.command; then
    echo
    echo "打包这一步失败了，先别发布。把上面的报错截给我看。"
    echo; read -n 1 -s -r -p "按任意键关闭"
    exit 1
fi

echo
if ! printf '\n' | ./发布到GitHub.command; then
    echo
    echo "上传这一步失败了，把上面的报错截给我看。"
    echo; read -n 1 -s -r -p "按任意键关闭"
    exit 1
fi

echo
echo "全部完成 ✅ 下载页和直链在上面，直链已经在剪贴板里。"
echo; read -n 1 -s -r -p "按任意键关闭"
