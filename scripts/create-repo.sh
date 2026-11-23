#!/usr/bin/env bash
# 用 GitHub REST API 一键创建仓库并推送当前目录（本机没有 gh 也能用）。
#
# 用法：
#   GITHUB_TOKEN=ghp_xxx bash scripts/create-repo.sh
#   GITHUB_TOKEN=ghp_xxx REPO_NAME=my-dsh VISIBILITY=private bash scripts/create-repo.sh
#
# Token 至少需要 repo（经典）或 Contents: Read and write + Workflows: Read and write（细粒度）。
set -euo pipefail

: "${GITHUB_TOKEN:?请设置 GITHUB_TOKEN 环境变量}"

REPO_NAME="${REPO_NAME:-dsh}"
VISIBILITY="${VISIBILITY:-public}"
DESCRIPTION="${DESCRIPTION:-每小时跟踪 smanx/deepseek-harness，自动构建带 OpenSSH 的镜像并发布到 Release}"

log() { printf '\033[36m[create-repo]\033[0m %s\n' "$*"; }

api() {
  curl -sS -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' "$@"
}

# ── 1. 确认账号 ────────────────────────────────────────────────────────
USER_JSON="$(api https://api.github.com/user)"
OWNER="${GITHUB_OWNER:-$(jq -r '.login // empty' <<<"$USER_JSON")}"
[ -n "$OWNER" ] || { echo "无法确定 GitHub 账号，token 可能无效" >&2; exit 1; }
log "账号：${OWNER}"

OWNER_TYPE="$(api "https://api.github.com/users/${OWNER}" | jq -r '.type // "User"')"
if [ "$OWNER_TYPE" = "Organization" ]; then
  CREATE_URL="https://api.github.com/orgs/${OWNER}/repos"
else
  CREATE_URL="https://api.github.com/user/repos"
fi

# ── 2. 创建仓库（已存在则复用）──────────────────────────────────────────
PRIVATE=false
[ "$VISIBILITY" = "private" ] && PRIVATE=true

PAYLOAD="$(jq -n --arg name "$REPO_NAME" --arg desc "$DESCRIPTION" --argjson priv "$PRIVATE" \
  '{name:$name, description:$desc, private:$priv, has_issues:true, has_wiki:false, has_projects:false, auto_init:false}')"

HTTP="$(curl -sS -o /tmp/create-repo.json -w '%{http_code}' \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H 'Accept: application/vnd.github+json' \
  -X POST "$CREATE_URL" -d "$PAYLOAD")"

case "$HTTP" in
  201) log "已创建仓库 ${OWNER}/${REPO_NAME}" ;;
  422)
    if api "https://api.github.com/repos/${OWNER}/${REPO_NAME}" | jq -e '.id' >/dev/null 2>&1; then
      log "仓库 ${OWNER}/${REPO_NAME} 已存在，直接推送"
    else
      cat /tmp/create-repo.json >&2
      exit 1
    fi
    ;;
  *)
    echo "创建仓库失败（HTTP $HTTP）：" >&2
    cat /tmp/create-repo.json >&2
    exit 1
    ;;
esac
rm -f /tmp/create-repo.json

# ── 3. 允许 Actions 写入（新仓库默认只读，否则回写状态/发布 Release 会失败）──
HTTP="$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H 'Accept: application/vnd.github+json' \
  -X PUT "https://api.github.com/repos/${OWNER}/${REPO_NAME}/actions/permissions/workflow" \
  -d '{"default_workflow_permissions":"write","can_approve_pull_request_reviews":false}')"
if [ "$HTTP" = "204" ]; then
  log "已把 Actions 默认权限设为 read/write"
else
  log "警告：设置 Actions 权限失败（HTTP $HTTP），请到 Settings → Actions → General 手动改为 Read and write"
fi

# ── 4. 初始化 git 并推送 ───────────────────────────────────────────────
cd "$(dirname "$0")/.."

if [ ! -d .git ]; then
  git init -q -b main
fi
git add -A
if git diff --cached --quiet; then
  log '没有需要提交的改动'
else
  git -c user.name="${GIT_AUTHOR_NAME:-dsh bot}" \
      -c user.email="${GIT_AUTHOR_EMAIL:-bot@users.noreply.local}" \
      commit -q -m "feat: 初始化 dsh（每小时跟踪上游并发布 SSH 镜像）"
  log '已创建初始提交'
fi

REMOTE_URL="https://github.com/${OWNER}/${REPO_NAME}.git"
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$REMOTE_URL"
else
  git remote add origin "$REMOTE_URL"
fi

log '推送 main 分支 ...'
git push "https://x-access-token:${GITHUB_TOKEN}@github.com/${OWNER}/${REPO_NAME}.git" HEAD:main --force-with-lease 2>&1 | tail -n 3

log '完成 ✅'
cat <<EOF

仓库地址：https://github.com/${OWNER}/${REPO_NAME}
Actions ：https://github.com/${OWNER}/${REPO_NAME}/actions/workflows/build-release.yml

下一步：
  1. 打开上面的 Actions 页面，点 "Run workflow" 立即跑一次（首次会直接构建并发布 Release）；
  2. 想固定跟踪某个 tag，可在 Settings → Variables 里加 UPSTREAM_TAG；
  3. 想构建 arm64，把变量 PLATFORMS 设为 linux/amd64,linux/arm64。
EOF
