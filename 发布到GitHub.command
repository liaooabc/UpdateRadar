#!/bin/bash
# 双击这个文件：把源码推到 GitHub，并把 dist 里最新的 DMG 传到 Releases。
# 第一次用之前，只需要把账号信息填进配置文件（脚本会帮你打开它）。
set -uo pipefail
cd "$(dirname "$0")"

CFG_DIR="${HOME}/.config/更新雷达"
CFG="${CFG_DIR}/github.cfg"
DMG="dist/更新雷达-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)-arm64.dmg"

say() { echo "$1"; }

# ── 0. 配置 ──────────────────────────────────────────────
if [ ! -f "${CFG}" ]; then
    mkdir -p "${CFG_DIR}"
    cat > "${CFG}" <<'EOF'
# 填两行，保存关掉窗口，再双击一次「发布到GitHub.command」
OWNER=你的GitHub用户名
REPO=UpdateRadar
# 令牌不用写在这个文件里：脚本会把它存进 macOS 钥匙串
#   （服务 github.com，账号 x-access-token），remote 地址里也不会带令牌
# 生成令牌：GitHub → 右上角头像 → Settings → Developer settings
#      → Personal access tokens → Fine-grained tokens → Generate new token
#      勾 Repository access: All repositories（或只选这一个仓库）
#      Permissions 里给 Contents: Read and write、Releases 也给 Read and write
EOF
    chmod 600 "${CFG}"
    open -e "${CFG}"
    say "小星：第一次用，先把账号信息填一下。"
    say "我已经打开配置文件了：${CFG}"
    say "把 OWNER 改成你的 GitHub 用户名（REPO 想叫别的也可以改），保存后关窗口，再双击我一次。"
    say "令牌这次不用填了，第二次双击时我会问你要一次，拿到就存进钥匙串。"
    echo; read -n 1 -s -r -p "按任意键关闭"
    exit 0
fi

set -a
# shellcheck disable=SC1090
. "${CFG}"
set +a
TOKEN_CFG="${TOKEN:-}"     # 老配置里可能还留着 TOKEN=，下面会把它搬进钥匙串再抹掉

if [ "${OWNER:-}" = "你的GitHub用户名" ] || [ -z "${OWNER:-}" ] || [ -z "${REPO:-}" ]; then
    open -e "${CFG}"
    say "配置还没填完：OWNER / REPO 两行都要有值。已经帮你打开文件了。"
    echo; read -n 1 -s -r -p "按任意键关闭"
    exit 1
fi

# ── 0.5 令牌：只走钥匙串，不进任何文件 ──────────────────────
KC_SERVICE="github.com"
KC_ACCOUNT="x-access-token"

kc_get() {  # 从登录钥匙串取令牌（走 git 官方 helper，不触发钥匙串弹窗）
    printf 'protocol=https\nhost=%s\nusername=%s\n\n' "${KC_SERVICE}" "${KC_ACCOUNT}" \
        | git credential-osxkeychain get 2>/dev/null | sed -n 's/^password=//p'
}

kc_put() {  # 把令牌写进登录钥匙串
    [ -n "${1:-}" ] || return 1
    printf 'protocol=https\nhost=%s\nusername=%s\npassword=%s\n\n' \
        "${KC_SERVICE}" "${KC_ACCOUNT}" "$1" | git credential-osxkeychain store
}

TOKEN="$(kc_get)"
if [ -z "${TOKEN}" ]; then
    if [ -n "${TOKEN_CFG}" ] && [ "${TOKEN_CFG}" != "粘贴令牌在这里" ]; then
        TOKEN="${TOKEN_CFG}"
        say "把配置文件里的令牌搬进钥匙串（配置里不再保留明文）"
        if kc_put "${TOKEN}"; then
            sed -i '' -E 's|^TOKEN=.*|# TOKEN 已存进 macOS 钥匙串（服务 github.com、账号 x-access-token），这里不用再填|' "${CFG}" \
                && say "  已把配置里的 TOKEN 那行注释掉"
        fi
    else
        say "第一次用：把 GitHub 令牌粘进来（输入时不显示），只会存进钥匙串。"
        printf '  令牌：'
        read -r -s TOKEN; echo
    fi
    if [ -z "${TOKEN}" ]; then
        say "没拿到令牌，先退出了。"
        echo; read -n 1 -s -r -p "按任意键关闭"; exit 1
    fi
    kc_put "${TOKEN}" || { say "写钥匙串失败，先退出了。"; echo; read -n 1 -s -r -p "按任意键关闭"; exit 1; }
    say "  令牌已存进钥匙串（服务 github.com，账号 x-access-token），以后不用再输入。"
else
    say "令牌已从钥匙串读取。"
fi

VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
TAG="v${VER}"
API="https://api.github.com/repos/${OWNER}/${REPO}"

say "小星：准备把 ${VER} 发到 GitHub（${OWNER}/${REPO}）。"
echo

# ── 1. 源码推上去 ─────────────────────────────────────────
say "▸ 1/3 推送源码"
git remote remove origin >/dev/null 2>&1 || true
# 令牌不进 URL：URL 只带用户名，密码由钥匙串里的凭据提供
git config credential.helper osxkeychain
git remote add origin "https://x-access-token@github.com/${OWNER}/${REPO}.git"
git branch -M main >/dev/null 2>&1 || true
git add -A >/dev/null 2>&1
git -c user.name="${OWNER}" -c user.email="${OWNER}@users.noreply.github.com" \
    commit -qm "更新雷达 ${VER}" >/dev/null 2>&1 || true
if git push -u origin main >/tmp/radar-push.log 2>&1; then
    say "  源码已推送：https://github.com/${OWNER}/${REPO}"
else
    # 源码可以用 GitHub Desktop 那个 Push 顶上，这里不拦着，接着发安装包
    say "  ⚠ 源码没推上去（不影响发安装包）。"
    say "    想推源码就用 GitHub Desktop 点一下 Publish/Push，或者检查令牌有没有 Contents 写权限。"
    sed -n '1,3p' /tmp/radar-push.log | sed 's/^/    /'
fi

# ── 1.5 先确认安装包在不在（别先建了空的 Release 再发现没包） ──
if [ ! -f "${DMG}" ]; then
    say "找不到 ${DMG}"
    say "先双击「发版.command」打一个包，再回来发布。"
    echo; read -n 1 -s -r -p "按任意键关闭"; exit 1
fi

# ── 2. 建 Release ────────────────────────────────────────
say "▸ 2/3 创建 Release ${TAG}"
# 更新说明：改仓库根目录的「发布说明.md」就行（写多短都没关系）。
# 没有这个文件时只写一行标题，不会再把上一版的长文案贴上去。
# 注意：body 里有多行中文，**不能**用 shell 传参给 python3（会丢转义、生成非法 JSON），
# 所以把发布说明写进临时文件，让 python 直接读文件。
BODY_FILE="$(mktemp)"
if [ -f "发布说明.md" ]; then
    cat "发布说明.md" > "${BODY_FILE}"
else
    printf '## 更新雷达 %s（Apple 芯片）\n' "${VER}" > "${BODY_FILE}"
fi
JSON_FILE="$(mktemp)"
python3 - "${TAG}" "${VER}" "${BODY_FILE}" "${JSON_FILE}" <<'PY'
import json, sys
tag, ver, body_file, out_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(body_file, encoding="utf-8") as f:
    body = f.read()
with open(out_file, "w", encoding="utf-8") as f:
    json.dump({"tag_name": tag, "name": f"更新雷达 {ver}", "body": body,
               "draft": False, "prerelease": False}, f, ensure_ascii=False)
PY
RESP=$(curl -sS -X POST "${API}/releases" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    --data-binary @"${JSON_FILE}")
rm -f "${BODY_FILE}" "${JSON_FILE}"

RESP_FILE="$(mktemp)"
printf '%s' "${RESP}" > "${RESP_FILE}"
UP=$(python3 - "${RESP_FILE}" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    print(""); raise SystemExit
print(d.get("upload_url", "").split("{")[0])
PY
)
rm -f "${RESP_FILE}"
if [ -z "${UP}" ]; then
    say "  创建 Release 失败，GitHub 的原话："
    echo "${RESP}" | head -5 | sed 's/^/    /'
    say "  如果提示 already_exists，说明这个版本号已经发过了 —— 先双击「发版.command」升版本号。"
    echo; read -n 1 -s -r -p "按任意键关闭"; exit 1
fi

# ── 3. 传安装包 ──────────────────────────────────────────
say "▸ 3/3 上传安装包"
ASSET="UpdateRadar-${VER}-arm64.dmg"
curl -sS -X POST "${UP}?name=${ASSET}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"${DMG}" -o /tmp/radar-upload.json
curl -sS -X POST "${UP}?name=${ASSET}.sha256" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"${DMG}.sha256" -o /dev/null

if grep -q '"browser_download_url"' /tmp/radar-upload.json; then
    URL=$(python3 -c "import json;print(json.load(open('/tmp/radar-upload.json'))['browser_download_url'])")
    echo
    say "搞定 ✅"
    say "  发布页：https://github.com/${OWNER}/${REPO}/releases/tag/${TAG}"
    say "  直链：${URL}"
    say "  （别人点直链就能下，不用登录）"
    printf '%s' "${URL}" | pbcopy
    say "  下载直链已复制到剪贴板，写文章直接粘。"
else
    say "  上传好像失败了，GitHub 的原话："
    head -5 /tmp/radar-upload.json | sed 's/^/    /'
fi
echo; read -n 1 -s -r -p "按任意键关闭"
