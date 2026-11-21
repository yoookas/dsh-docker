#!/usr/bin/env bash
# 构建后冒烟测试：
#   1. 镜像内 sshd 配置语法合法；
#   2. 内置工具齐全（gh / git / dsh / node / sshd / chpasswd / tini）；
#   3. 只开 SSH 的容器（DSH_APP_ENABLED=false）：
#      用 SSH_ROOT_PASSWORD 注入的密码能登录、登录用户是 root、错误密码被拒；
#   4. 默认容器（SSH + DSH）能起来并保持运行（DSH 依赖外部配置，失败只警告不阻断）；
#   5. 空的 /etc/ssh 绑定挂载（模拟 compose 里的 ./ssh）也能自动补齐并登录；
#   6. 1 号进程是 tini，且 20 次认证失败不会留下僵尸进程。
#
# 用法：bash scripts/smoke-test.sh <image:tag>   [SMOKE_PORT=2222 可指定端口]
set -euo pipefail

IMAGE="${1:?用法: smoke-test.sh <image:tag>}"
PASSWORD="${SMOKE_PASSWORD:-Smoke-Test-Pass-123}"
CONTAINER="dsh-smoke-$$"
PORT=""
FAILED=0

log()  { printf '[smoke] %s\n' "$*"; }
warn() { printf '[smoke][警告] %s\n' "$*" >&2; }

dump_container() {
  [ -n "${CONTAINER:-}" ] || return 0
  echo '----- docker inspect -----' >&2
  docker inspect -f 'status={{.State.Status}} exit={{.State.ExitCode}}' "$CONTAINER" >&2 2>&1 || true
  echo '----- docker logs (tail 80) -----' >&2
  docker logs --tail 80 "$CONTAINER" >&2 2>&1 || true
}

on_exit() {
  local rc=$?
  printf '[smoke] EXIT rc=%s\n' "$rc" >&2
  if [ "$FAILED" = '1' ] || [ "$rc" -ne 0 ]; then
    dump_container
  fi
  # SMOKE_KEEP=1 时保留容器，便于在后续步骤继续抓日志
  if [ "${SMOKE_KEEP:-0}" != '1' ]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap on_exit EXIT

fail() {
  FAILED=1
  printf '[smoke][失败] %s\n' "$*" >&2
  exit 1
}

log "镜像：$IMAGE"

log '1/6 校验 sshd 配置'
# 镜像里不保留主机密钥（每个容器首启才生成），所以先造一把再 -t
docker run --rm --entrypoint sh "$IMAGE" -c 'ssh-keygen -A >/dev/null 2>&1 && sshd -t' \
  || fail 'sshd -t 校验失败'

log '2/6 校验镜像内置工具'
docker run --rm --entrypoint sh "$IMAGE" -c '
  set -e
  for bin in gh git node dsh ssh sshd ssh-keygen chpasswd tini; do
    command -v "$bin" >/dev/null 2>&1 || { echo "缺少命令：$bin"; exit 1; }
  done
  echo "gh      $(gh --version 2>/dev/null | head -n 1)"
  echo "git     $(git --version)"
  echo "node    $(node -v)"
  echo "dsh     $(dsh --version 2>/dev/null | head -n 1 || echo ok)"
' || fail '镜像内置工具检查失败'

start_container() { # $1 = 阶段名，其余为额外 docker run 参数
  local phase=$1
  shift
  CONTAINER="dsh-smoke-${phase}-$$"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

  if [ -n "${SMOKE_PORT:-}" ]; then
    docker run -d --name "$CONTAINER" \
      -e SSH_ROOT_PASSWORD="$PASSWORD" \
      -p "127.0.0.1:${SMOKE_PORT}:22" "$@" "$IMAGE" >/dev/null || fail '容器启动失败'
    PORT="$SMOKE_PORT"
  else
    docker run -d --name "$CONTAINER" \
      -e SSH_ROOT_PASSWORD="$PASSWORD" \
      -p "127.0.0.1::22" "$@" "$IMAGE" >/dev/null || fail '容器启动失败'
    PORT="$(docker port "$CONTAINER" 22/tcp | head -n 1 | sed 's/.*://')"
    [ -n "$PORT" ] || fail '无法获取容器映射的 SSH 端口'
  fi
  log "容器 SSH 端口：${PORT}"
}

container_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = 'true' ]
}

wait_port() { # 最多 90 秒
  local i
  for i in $(seq 1 90); do
    # 注意：连接在子 shell 里完成，fd 3 随子 shell 退出自动关闭。
    # 这里绝不能用 `exec 3>&- 2>/dev/null`，那会把整个脚本的 stderr 永久指向 /dev/null。
    if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then
      return 0
    fi
    if ! container_running; then
      printf '[smoke]   第 %d 秒：容器已退出\n' "$i" >&2
      return 1
    fi
    if [ $((i % 5)) -eq 0 ]; then
      printf '[smoke]   等待中 %d/90 ...\n' "$i" >&2
    fi
    sleep 1
  done
  return 1
}

# 注意：必须在拿到 PORT 之后才能拼参数，否则 -p 会是个空串（Bad port ''）
build_ssh_opts() {
  SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
            -o ConnectTimeout=10 -o PreferredAuthentications=password
            -o PubkeyAuthentication=no -p "$PORT")
}

try_login() { # 返回 0 表示登录成功
  local i out rc
  for i in $(seq 1 10); do
    set +e
    out="$(sshpass -p "$PASSWORD" ssh "${SSH_OPTS[@]}" root@127.0.0.1 'id -un; echo SMOKE_OK' 2>&1)"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      printf '%s\n' "$out"
      return 0
    fi
    printf '[smoke]   第 %d 次登录失败（rc=%d）：%s\n' "$i" "$rc" "$(printf '%s' "$out" | tail -n 2 | tr '\n' ' ')" >&2
    sleep 2
  done
  return 1
}

log '3/6 SSH 容器：密码登录 / root 身份 / 错误密码'
start_container ssh -e DSH_APP_ENABLED=false
build_ssh_opts

log '等待 SSH 端口就绪 ...'
wait_port || fail "SSH 端口 ${PORT} 未在 90 秒内就绪或容器已退出"

if ! command -v sshpass >/dev/null 2>&1; then
  warn '未安装 sshpass，跳过登录断言（CI 中会安装）'
else
  OUTPUT="$(try_login)" || fail '密码登录失败'

  grep -qx 'root' <<<"$OUTPUT" || fail '登录用户不是 root'
  grep -q 'SMOKE_OK' <<<"$OUTPUT" || fail '远端命令未执行'
  log '密码登录成功，身份为 root'

  set +e
  sshpass -p 'definitely-wrong-password' ssh "${SSH_OPTS[@]}" root@127.0.0.1 'true' >/dev/null 2>&1
  RC=$?
  set -e
  [ "$RC" -ne 0 ] || fail '错误密码竟然登录成功了'
  log "错误密码按预期被拒绝（ssh 退出码 $RC）"
fi

container_running || fail 'SSH 容器已退出'

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
CONTAINER=""

log '4/6 默认容器：SSH + DSH 能同时起来'
start_container full
sleep 8
if container_running; then
  log '默认容器运行正常（SSH + DSH）'
else
  warn '默认容器 8 秒内退出（DSH 依赖外部配置，非致命）：'
  docker logs --tail 40 "$CONTAINER" >&2 2>&1 || true
fi
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
CONTAINER=""

log '5/6 空 /etc/ssh（模拟 compose 首次挂载 ./ssh）'
start_container bind -e DSH_APP_ENABLED=false --tmpfs /etc/ssh
build_ssh_opts
wait_port || fail "绑定挂载空 /etc/ssh 后 SSH 端口未就绪（默认配置没恢复成功？）"
if command -v sshpass >/dev/null 2>&1; then
  OUTPUT="$(try_login)" || fail '绑定挂载空 /etc/ssh 后无法登录'
  grep -qx 'root' <<<"$OUTPUT" || fail '绑定挂载场景登录用户不是 root'
  log '空 /etc/ssh 能自动生成配置并登录'
fi
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
CONTAINER=""

log '6/6 僵尸进程回收（1 号进程必须是 tini）'
start_container reap -e DSH_APP_ENABLED=false
build_ssh_opts
wait_port || fail '僵尸回收测试：SSH 端口未就绪'

# 上游把 node 跑成 PID 1，不回收孤儿进程；僵尸累积到 pids.max 后 SSH 全断。
init_comm="$(docker exec "$CONTAINER" cat /proc/1/comm 2>/dev/null | tr -dc '[:print:]')"
[ "$init_comm" = 'tini' ] || fail "1 号进程是 '${init_comm:-未知}' 而不是 tini：孤儿进程会累积成僵尸"
log '1 号进程是 tini'

# 注意：裸 TCP 连接不会遗留子进程（实测 40 次 = 0 僵尸），必须用真实认证失败
# 才能复现（20 次 = 20 个僵尸），否则这个断言是假阴性。
if command -v sshpass >/dev/null 2>&1; then
  SSH_OPTS_FAIL=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
                 -o PreferredAuthentications=password -o PubkeyAuthentication=no
                 -o NumberOfPasswordPrompts=1 -o ConnectTimeout=10 -p "$PORT")
  for _ in $(seq 1 20); do
    sshpass -p 'definitely-wrong-password' ssh "${SSH_OPTS_FAIL[@]}" root@127.0.0.1 true \
      >/dev/null 2>&1 || true
  done
  sleep 3
else
  warn '未安装 sshpass，无法制造认证失败，跳过僵尸数量断言（CI 中会安装）'
fi

# 用 /proc 统计僵尸（不依赖 ps 是否存在于镜像里）
zombie_count() {
  docker exec "$CONTAINER" sh -c \
    'grep -lE "^State:[[:space:]]+Z" /proc/[0-9]*/status 2>/dev/null | wc -l' 2>/dev/null \
    | tr -dc '0-9'
}
ZOMBIES="$(zombie_count)"; ZOMBIES="${ZOMBIES:-99}"
log "20 次认证失败后残留僵尸进程：${ZOMBIES} 个"
if command -v sshpass >/dev/null 2>&1; then
  # 没有 tini 时这里会是 ~20 个，且永久不消失；阈值 2 足够区分
  [ "$ZOMBIES" -le 2 ] || fail "残留 ${ZOMBIES} 个僵尸进程（tini 没起到回收作用）"
else
  log '（未做 sshpass 断言，仅记录僵尸数）'
fi

PIDS_NOW="$(docker exec "$CONTAINER" cat /sys/fs/cgroup/pids.current 2>/dev/null | tr -dc '0-9')"
log "pids.current=${PIDS_NOW:-未知}"

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
CONTAINER=""

log '全部通过 ✅'
