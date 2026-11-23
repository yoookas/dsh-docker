#!/bin/sh
# 构建期执行：安装 Go 工具链（官方 tarball 解压到 /usr/local/go）。
#
# 上游 devtools 变体不含 Go（见上游 .build-variants 的 apt 列表），所以这里自己装。
# 版本由 Dockerfile 的 ARG GO_VERSION 指定，升级只改那一行。
set -eu

GO_VERSION="${GO_VERSION:-1.26.11}"

log() { printf '[install-go] %s\n' "$*"; }

# ── 架构映射：uname -m → Go 官方文件名后缀 ─────────────────────────────
case "$(uname -m)" in
  x86_64|amd64)        goarch=amd64 ;;
  aarch64|arm64)       goarch=arm64 ;;
  armv6l|armv6)        goarch=armv6l ;;
  armv7l|armv7|armv8l) goarch=armv6l ;;   # 官方只发 armv6l，它在 ARMv7 上能跑
  i386|i486|i586|i686) goarch=386 ;;
  *)
    echo "[install-go] 错误：Go 官方没有提供 $(uname -m) 的 linux 包" >&2
    exit 1
    ;;
esac

archive="go${GO_VERSION}.linux-${goarch}.tar.gz"
url="https://go.dev/dl/${archive}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

log "下载 ${url}"
# 包有 ~70 MB，弱网下连接重置很常见；--retry-all-errors 才会重试这类错误
if ! curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
     --connect-timeout 15 --max-time 900 -o "${tmp}/${archive}" "$url"; then
  echo "[install-go] 错误：下载失败" >&2
  exit 1
fi

# ── 用官方下载清单里的 sha256 校验（清单取不到就跳过，镜像不依赖它）────
expected="$(curl -fsSL --connect-timeout 15 --max-time 60 \
  'https://go.dev/dl/?mode=json&include=all' 2>/dev/null \
  | tr -d '[:space:]' \
  | sed 's/{/\n{/g' \
  | grep -F "\"filename\":\"${archive}\"" \
  | sed -n 's/.*"sha256":"\([0-9a-fA-F]\{64\}\)".*/\1/p' \
  | head -n 1)"
if [ -n "$expected" ]; then
  actual="$(sha256sum "${tmp}/${archive}" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    echo "[install-go] 错误：sha256 不一致" >&2
    echo "  期望：$expected" >&2
    echo "  实际：$actual" >&2
    exit 1
  fi
  log 'sha256 校验通过'
else
  log '警告：取不到官方清单，跳过 sha256 校验'
fi

# ── 解压到 /usr/local/go 并软链进 PATH ─────────────────────────────────
log '解压到 /usr/local/go'
rm -rf /usr/local/go
tar -xzf "${tmp}/${archive}" -C /usr/local || { echo '[install-go] 错误：解压失败' >&2; exit 1; }
ln -sf /usr/local/go/bin/go /usr/local/bin/go
ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

version="$(go version)"
case "$version" in
  *"go${GO_VERSION} "*) log "安装完成：${version}" ;;
  *)
    echo "[install-go] 错误：安装后版本不符：${version}" >&2
    exit 1
    ;;
esac
