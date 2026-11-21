#!/bin/sh
# 构建期执行：在上游镜像里安装并预配置 OpenSSH Server。
# 兼容 apt（Debian/Ubuntu）、apk（Alpine）、dnf（Fedora/RHEL 系）。
set -eu

log() { printf '[install-openssh] %s\n' "$*"; }

log "开始安装 OpenSSH Server ..."

# 阻止包管理器在构建期尝试启动服务（容器里没有 init），装完再删掉
POLICY_CREATED=0
if [ ! -e /usr/sbin/policy-rc.d ]; then
  printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
  chmod +x /usr/sbin/policy-rc.d
  POLICY_CREATED=1
fi

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  # 上游 devtools 变体已经带 openssh-client，有就不重复装
  set -- openssh-server openssh-sftp-server
  if ! command -v ssh >/dev/null 2>&1; then
    set -- "$@" openssh-client
  fi
  # tini：容器 1 号进程的回收器（见 Dockerfile 末尾说明）
  apt-get install -y --no-install-recommends "$@" tini
  apt-get clean
  rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb
  SFTP_CANDIDATES="/usr/lib/openssh/sftp-server /usr/libexec/openssh/sftp-server /usr/lib/ssh/sftp-server"
elif command -v apk >/dev/null 2>&1; then
  apk add --no-cache openssh-server openssh-client tini
  SFTP_CANDIDATES="/usr/lib/ssh/sftp-server /usr/libexec/sftp-server /usr/lib/openssh/sftp-server"
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y openssh-server openssh-clients tini
  dnf clean all
  SFTP_CANDIDATES="/usr/libexec/openssh/sftp-server /usr/libexec/sftp-server"
elif command -v microdnf >/dev/null 2>&1; then
  microdnf install -y openssh-server openssh-clients tini
  microdnf clean all
  SFTP_CANDIDATES="/usr/libexec/openssh/sftp-server /usr/libexec/sftp-server"
else
  echo "[install-openssh] 错误：未识别包管理器，无法安装 openssh-server" >&2
  exit 1
fi

if [ "$POLICY_CREATED" = "1" ]; then
  rm -f /usr/sbin/policy-rc.d
fi

# ── sshd 特权分离用户（部分精简镜像的 postinst 会跳过创建）──────────────
if ! id sshd >/dev/null 2>&1; then
  log "创建 sshd 系统用户"
  if command -v adduser >/dev/null 2>&1; then
    adduser --system --group --no-create-home --home /run/sshd \
      --shell /usr/sbin/nologin sshd >/dev/null 2>&1 || true
  fi
  if ! id sshd >/dev/null 2>&1 && command -v useradd >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /run/sshd \
      --shell /usr/sbin/nologin sshd >/dev/null 2>&1 || true
  fi
fi

# ── 运行期必需目录 ─────────────────────────────────────────────────────
mkdir -p /run/sshd /etc/ssh/sshd_config.d /root/.ssh
chmod 0755 /run/sshd
chmod 0700 /root/.ssh

# ── 确保主配置 Include 了 sshd_config.d（运行期配置写在这里，优先级最高）──
if [ -f /etc/ssh/sshd_config ] \
   && ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
  log "主配置缺少 Include，补到文件开头"
  printf 'Include /etc/ssh/sshd_config.d/*.conf\n' | cat - /etc/ssh/sshd_config \
    > /etc/ssh/sshd_config.new
  mv /etc/ssh/sshd_config.new /etc/ssh/sshd_config
fi

# ── sftp 子系统二进制路径（仅在主配置没有定义 Subsystem 时才用到）──────
SFTP_SERVER=""
for candidate in $SFTP_CANDIDATES; do
  if [ -x "$candidate" ]; then
    SFTP_SERVER="$candidate"
    break
  fi
done
if [ -n "$SFTP_SERVER" ]; then
  printf '%s\n' "$SFTP_SERVER" > /etc/dsh-sftp-server
  log "sftp 子系统：$SFTP_SERVER"
else
  log "警告：未找到 sftp-server，SFTP 功能不可用（SSH shell 仍可正常使用）"
fi

# ── 备份 moduli：这是数据文件（不是配置），重新生成要几分钟，缺了会退化 ──
if [ -f /etc/ssh/moduli ]; then
  mkdir -p /usr/share/dsh-ssh
  cp /etc/ssh/moduli /usr/share/dsh-ssh/moduli
  log '已备份 /etc/ssh/moduli'
fi

# ── 校验配置（必须在删除主机密钥之前：sshd -t 需要至少一把主机密钥）────
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  ssh-keygen -A >/dev/null 2>&1 || true
fi
if ! sshd -t 2>/tmp/sshd-test.log; then
  echo "[install-openssh] 错误：sshd 配置校验失败" >&2
  cat /tmp/sshd-test.log >&2
  exit 1
fi
rm -f /tmp/sshd-test.log

# ── 删除构建期生成的主机密钥：每个容器首启时重新生成，避免全镜像统一指纹 ──
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub

# ── SSH 登录后自动进入 /app（可用 SSH_AUTO_CD= 关闭）───────────────────
cat > /etc/profile.d/99-dsh-workdir.sh <<'EOF'
# 由 dsh 镜像提供：SSH 登录后自动 cd 到工作目录
if [ -z "${SSH_AUTO_CD:-}" ] && [ -d /app ]; then
  cd /app || true
fi
EOF
chmod 0644 /etc/profile.d/99-dsh-workdir.sh

log "OpenSSH Server 安装完成：$(ssh -V 2>&1 | head -n 1 || true)"
