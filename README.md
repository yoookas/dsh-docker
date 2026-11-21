# dsh

![Build](https://github.com/yoookas/dsh-docker/actions/workflows/build-ssh-image.yml/badge.svg)
![Release](https://img.shields.io/github/v/release/yoookas/dsh-docker?include_prereleases&label=release)
![License](https://img.shields.io/github/license/yoookas/dsh-docker)

[`smanx/deepseek-harness`](https://hub.docker.com/r/smanx/deepseek-harness/tags) 的衍生镜像：
在 `devtools-<版本>` 变体上加装 **OpenSSH Server** 和 **gh**，root 密码由环境变量指定。

仓库每小时检查上游是否更新，有新版本就自动构建、冒烟测试，导出 `tar.gz` 发到 Release（tag 与上游一致）。

## 快速开始

```bash
# 1. 下载并加载（arm64 机器换成 -linux-arm64）
curl -LO https://github.com/yoookas/dsh-docker/releases/download/devtools-0.2.2-rc.5/dsh-devtools-0.2.2-rc.5-linux-amd64.tar.gz
docker load -i dsh-devtools-0.2.2-rc.5-linux-amd64.tar.gz

# 2. 启动
docker run -d --name dsh \
  -p 3080:3080 -p 2222:22 \
  -e SSH_ROOT_PASSWORD='换成你的密码' \
  -v dsh-data:/root/.dsh \
  dsh:devtools-0.2.2-rc.5

# 3. 访问
#   Web: http://127.0.0.1:3080/
#   SSH: ssh -p 2222 root@127.0.0.1
```

也提供了 compose 示例：[`examples/docker-compose.yml`](examples/docker-compose.yml)。

### 目录挂载

| 宿主机 | 容器内 | 内容 |
| --- | --- | --- |
| `./dsh-data` | `/root/.dsh` | 会话 / 配置（上游约定） |
| `./ssh` | `/etc/ssh` | 主机密钥 + sshd 配置；挂上后重建容器指纹不变 |
| `./workspaces` | `/root/workspaces` | 工作区，Web UI 里把 `/root/workspaces` 添加为工作区 |

`/etc/ssh` 首次挂载为空时会自动生成 `sshd_config` 和主机密钥，不需要手动准备；之后配置就固定下来了。

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `SSH_ROOT_PASSWORD` | – | root 密码，启动时写入 |
| `SSH_ROOT_PASSWORD_FILE` | – | 从文件读密码（Docker secret） |
| `SSH_AUTHORIZED_KEYS` | – | root 的公钥（多行用 `\n`） |
| `SSH_PORT` | `22` | 容器内 sshd 端口 |
| `SSH_PERMIT_ROOT_LOGIN` | `yes` | 可改 `prohibit-password` |
| `SSH_ENABLED` | `true` | `false` 时不启动 sshd |
| `DSH_APP_ENABLED` | `true` | `false` 时只开 SSH，不跑 DSH |
| `GH_TOKEN` | – | 给容器内的 `gh` 用 |

上游变量（`DSH_PORT`、`PROXY_USERNAME` 等）照常生效。

## 工作原理

1. 每小时拉一次上游 tag 列表，在 `devtools-<版本>` 里挑最高版本，取 manifest 摘要当指纹。
2. 指纹与 `state/upstream.json` 一致就跳过；不一致才 `docker pull` 上游镜像并重建（构建失败不写状态，下一小时重试）。
3. 构建：上游镜像 + `openssh-server` + `gh` + `tini`；`tini` 做 1 号进程回收僵尸，入口脚本先起 sshd，再 exec 上游命令。
4. 冒烟：真起容器、真用密码 SSH 登录、断言身份是 root、错误密码被拒。
5. 导出 `tar.gz` + `SHA256SUMS.txt` → 发布 Release（tag 与上游一致，`-rc` 自动标 pre-release）。

## 仓库配置

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `PLATFORMS` | 本仓库为 `linux/amd64,linux/arm64` | 构建哪些架构 |
| `UPSTREAM_TRACK` | `version` | `version` 跟版本号，`tag` 跟固定 tag |
| `UPSTREAM_TAG_PREFIX` | `devtools` | 版本模式的前缀，`none` 表示纯版本号 |
| `UPSTREAM_TAG` | `devtools-latest` | `UPSTREAM_TRACK=tag` 时用 |

手动重建：Actions → **Build SSH image** → Run workflow → 勾 `force`。

## 镜像体积

镜像约 **530 MB**，其中上游 devtools 变体 514 MB，本镜像只多约 15 MB（主要是 `gh` 42 MB 与 `openssh-server` 5.8 MB 两层）。

注意：在后面的层里 `rm` 文件**不会**让镜像变小（数据仍留在下层），所以清理只影响容器内可见文件，tar 包大小基本不变（531 MB）。

Release 里的 `.tar.gz` 是**另一份拷贝**（527 MB，内容已压缩，gzip 几乎压不动）——`docker load` 完就可以删掉；重复导入新版本时，旧的同名镜像会变成 `<none>` 悬空镜像，记得 `docker image prune -f`。

## 已知问题：`fork of unprivileged child failed`

**症状**：容器跑一段时间后日志被同一条错误刷满，SSH 全部连不上；`docker exec` 里能看到大量 `<defunct>`。

**原因**：上游把 `node` 跑成 PID 1，它不调用 `waitpid(-1)`。sshd 每条「完成握手并走完认证」的连接都会遗留一个
privsep 子进程，退出后成为永久僵尸、占 1 个 PID。累积到 `pids.max`（常见 4537）后 `fork()` 返回 EAGAIN，
每条连接打印一行日志，直到重启容器。实测：**1 条连接 = 1 个僵尸**；被爆破时 4.5 小时撞线，
只有 dsh-go 长期连接也要约 5 天。

**修复**：镜像用 `tini` 作 1 号进程，孤儿进程即时回收。

```dockerfile
ENTRYPOINT ["tini", "-g", "--", "/usr/local/bin/dsh-entrypoint.sh"]
```

**自查**：

```bash
docker exec dsh cat /proc/1/comm                                                     # tini
docker exec dsh sh -c 'grep -lE "^State:[[:space:]]+Z" /proc/[0-9]*/status | wc -l'  # 0
docker exec dsh cat /sys/fs/cgroup/pids.current                                      # 不随时间增长
```

> 这里只解决「僵尸吃光 PID」。连接量本身（爆破、客户端反复重连）不在镜像职责内，
> 公网场景建议改公钥登录（`SSH_AUTHORIZED_KEYS` + `SSH_PASSWORD_AUTHENTICATION=no`）或在转发层限源。

## 注意

- 允许 root 密码登录，只建议内网使用；更稳妥的是 `SSH_AUTHORIZED_KEYS` + `SSH_PASSWORD_AUTHENTICATION=no`。
- 密码走环境变量，`docker inspect` 可见；敏感场景用 `SSH_ROOT_PASSWORD_FILE`。
- 主机密钥在容器首启时生成，不随镜像分发。

## 致谢

- 应用：[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
- 基础镜像：[smanx/deepseek-harness-docker](https://github.com/smanx/deepseek-harness-docker)

## License

[MIT](LICENSE)
