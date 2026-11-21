# syntax=docker/dockerfile:1.7
#
# dsh
# ────────────────────
# 在官方第三方镜像 smanx/deepseek-harness 之上加装 OpenSSH Server，
# root 密码由环境变量 SSH_ROOT_PASSWORD 在容器启动时注入（不打进镜像层）。
#
# 跟踪的上游变体：devtools-<版本>（自带 git/vim/python3/pnpm/uv 等，适合 SSH 进去干活）
#
# 上游镜像事实（2026-11 核对）：
#   * 基础镜像 node:24-slim（Debian 12 bookworm）
#   * WORKDIR /app，ENTRYPOINT ["/app/entrypoint.sh"]，默认监听 3080
#   * 以 root 运行
# 因此这里可以直接 apt-get 安装 openssh-server，并用 entrypoint 包裹上游入口。
#
# 本地构建：
#   bash scripts/gen-launcher.sh smanx/deepseek-harness:devtools-latest docker/upstream-launch.sh
#   docker build -f docker/Dockerfile -t dsh:local .

ARG BASE_IMAGE=smanx/deepseek-harness:devtools-latest

FROM ${BASE_IMAGE}

# 重新声明，供 LABEL / ENV 使用
ARG BASE_IMAGE
ARG SOURCE_URL=unknown
ARG BUILD_REVISION=dev
ARG BUILD_DATE=unknown
ARG UPSTREAM_VERSION=unknown

LABEL org.opencontainers.image.title="dsh" \
      org.opencontainers.image.description="DeepSeek Harness + OpenSSH Server；root 密码通过环境变量 SSH_ROOT_PASSWORD 注入" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" \
      org.opencontainers.image.revision="${BUILD_REVISION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.version="${UPSTREAM_VERSION}" \
      org.opencontainers.image.licenses="MIT" \
      io.github.dsh.base-image="${BASE_IMAGE}"

# 上游若将来改成非 root，这里强制回到 root，否则装不了包也起不了 sshd
USER root

# ── 1. 安装 OpenSSH Server + tini（apt / apk / dnf 自适应）──────────────
# tini 是容器 1 号进程：上游把 node 跑成 PID 1，不回收孤儿进程。sshd 每次连接
# 都会 fork 出 privsep 子进程，连接异常中断时子进程被遗留，退出后变成永久
# 僵尸；累积到 pids.max 后新连接全部 fork 失败，日志被
# "fork of unprivileged child failed" 刷屏。详见 README「已知问题」。
COPY docker/install-openssh.sh /usr/local/bin/dsh-install-openssh.sh
RUN chmod 0755 /usr/local/bin/dsh-install-openssh.sh \
 && /usr/local/bin/dsh-install-openssh.sh

# ── 2. GitHub CLI（gh）：devtools 变体自带 git/curl，这里补上 gh ─────────
COPY docker/install-gh.sh /usr/local/bin/dsh-install-gh.sh
RUN chmod 0755 /usr/local/bin/dsh-install-gh.sh \
 && /usr/local/bin/dsh-install-gh.sh

# ── 3. 启动脚本 / 健康检查 / 上游入口桥接 ──────────────────────────────
COPY docker/entrypoint.sh /usr/local/bin/dsh-entrypoint.sh
COPY docker/healthcheck.sh /usr/local/bin/dsh-healthcheck.sh
COPY docker/upstream-launch.sh /usr/local/bin/dsh-upstream-launch.sh
RUN chmod 0755 /usr/local/bin/dsh-entrypoint.sh \
                /usr/local/bin/dsh-healthcheck.sh \
                /usr/local/bin/dsh-upstream-launch.sh

# ── 4. 清理构建期残留（apt 缓存 / 文档 / man）──────────────────────────
# 这些文件运行期用不到，但会让镜像白白大几十 MB
RUN rm -rf /var/lib/apt/lists/* \
           /var/cache/apt/archives/*.deb \
           /var/cache/debconf/*.dat-old \
           /usr/share/doc/* \
           /usr/share/man/* \
           /tmp/* \
           /var/tmp/* 2>/dev/null || true

# ── 5. 运行参数默认值（均可在 docker run -e 覆盖）──────────────────────
ENV SSH_ENABLED=true \
    SSH_PORT=22 \
    SSH_LISTEN_ADDRESS=0.0.0.0 \
    SSH_PERMIT_ROOT_LOGIN=yes \
    SSH_PASSWORD_AUTHENTICATION=auto \
    DSH_APP_ENABLED=true

# 22 = sshd；3080 由上游 EXPOSE 声明并自动继承
EXPOSE 22

# 上游 WORKDIR 为 /app，这里显式声明一次，保证 SSH 登录后与容器内目录一致
WORKDIR /app

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD ["/usr/local/bin/dsh-healthcheck.sh"]

# 注意：设置 ENTRYPOINT 会重置继承来的 CMD，因此上游的启动命令
# 由 /usr/local/bin/dsh-upstream-launch.sh 在构建期捕获并保存（见 scripts/gen-launcher.sh）。
#
# tini 做 1 号进程：回收被 reparent 过来的孤儿进程（sshd 的 privsep 子进程），
# 否则僵尸会累积到 pids.max，最终所有新连接 fork 失败。用 PATH 解析，兼容
# 各发行版的安装路径（Debian /usr/bin、Alpine /sbin）。
ENTRYPOINT ["tini", "-g", "--", "/usr/local/bin/dsh-entrypoint.sh"]
