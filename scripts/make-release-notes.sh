#!/usr/bin/env bash
# 生成 GitHub Release 说明（markdown，输出到 stdout）。
#
# 需要的环境变量（均有默认值）：
#   RELEASE_TAG     本次发布 tag（与上游对齐）
#   UPSTREAM_TAG    上游镜像 tag
#   UPSTREAM_REPO   上游镜像仓库
#   UPSTREAM_DIGEST 上游 manifest 摘要
#   PLATFORMS       构建平台列表
#   GITHUB_REPOSITORY / IMAGE_NAME / ASSET_DIR
set -euo pipefail

RELEASE_TAG="${RELEASE_TAG:?缺少 RELEASE_TAG}"
UPSTREAM_TAG="${UPSTREAM_TAG:-devtools-latest}"
UPSTREAM_REPO="${UPSTREAM_REPO:-smanx/deepseek-harness}"
UPSTREAM_DIGEST="${UPSTREAM_DIGEST:-unknown}"
PLATFORMS="${PLATFORMS:-linux/amd64}"
IMAGE_NAME="${IMAGE_NAME:-dsh}"
REPO_SLUG="${GITHUB_REPOSITORY:-yoookas/dsh-docker}"
ASSET_DIR="${ASSET_DIR:-dist}"
BUILT_AT="$(date -u '+%Y-%m-%d %H:%M UTC')"

assets_table() {
  local f size
  shopt -s nullglob
  for f in "$ASSET_DIR"/*.tar.gz; do
    size="$(du -h "$f" | cut -f1)"
    # shellcheck disable=SC2016  # 这里的反引号是 markdown 语法，不是命令替换
    printf '| `%s` | %s |\n' "$(basename "$f")" "$size"
  done
  shopt -u nullglob
}

cat <<EOF
## ${IMAGE_NAME} \`${RELEASE_TAG}\`

在上游 \`${UPSTREAM_REPO}:${UPSTREAM_TAG}\` 基础上加装 **OpenSSH Server**、**gh**，并把上游自带的 Go 接进 \`PATH\`，root 密码由环境变量注入。

| 文件 | 大小 |
| --- | --- |
$(assets_table)

校验：\`sha256sum -c SHA256SUMS.txt\`

### 部署

\`\`\`bash
# 1. 加载镜像（按架构二选一：linux-arm64 / linux-amd64）
docker load -i ${IMAGE_NAME}-${RELEASE_TAG}-linux-arm64.tar.gz

# 2. 用仓库 examples/ 下的 compose 与 .env 模板
cp examples/docker-compose.yml .
cp examples/.env.example .env      # 至少填 SSH_ROOT_PASSWORD

# 3. 启动
docker compose up -d
\`\`\`

Web \`:3080\` · SSH \`:44222\` · 环境变量与挂载说明见 [README](https://github.com/${REPO_SLUG}#环境变量)

---

上游 \`${UPSTREAM_REPO}:${UPSTREAM_TAG}\` · 摘要 \`${UPSTREAM_DIGEST}\` · 构建于 ${BUILT_AT}（${PLATFORMS}）
EOF
