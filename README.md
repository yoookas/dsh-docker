# dsh

![Build](https://github.com/yoookas/dsh-docker/actions/workflows/build-ssh-image.yml/badge.svg)
![Release](https://img.shields.io/github/v/release/yoookas/dsh-docker?include_prereleases&label=release)
![License](https://img.shields.io/github/license/yoookas/dsh-docker)

[`smanx/deepseek-harness`](https://hub.docker.com/r/smanx/deepseek-harness/tags) 的衍生镜像：
在 `devtools-<版本>` 变体上加装 **OpenSSH Server** 和 **gh**，root 密码由环境变量指定。

仓库每小时检查上游更新，有新版本就自动构建、冒烟测试，打包发到 Release（tag 与上游一致）。

## 快速开始

部署方式是 [Docker Compose](examples/docker-compose.yml)，三个目录（`dsh-data` / `workspaces` / `ssh`）会自动创建。

```bash
# 1. 加载镜像包（按架构二选一：arm64 / amd64）
curl -LO https://github.com/yoookas/dsh-docker/releases/download/devtools-0.2.2-rc.5/dsh-devtools-0.2.2-rc.5-linux-arm64.tar.gz
docker load -i dsh-devtools-0.2.2-rc.5-linux-arm64.tar.gz

# 2. 准备 compose 和环境变量
cp examples/docker-compose.yml .
cp examples/.env.example .env
vi .env                     # 至少填 SSH_ROOT_PASSWORD

# 3. 启动
docker compose up -d

# 4. 访问
#   Web:  http://<host>:3080/
#   SSH:  ssh -p 44222 root@<host>
```

升级到新版本：`docker load` 新包后执行 `docker compose up -d --force-recreate`——`restart` 不会替换镜像。

## 挂载

| 宿主机 | 容器内 | 内容 |
| --- | --- | --- |
| `./dsh-data` | `/root/.dsh` | 会话 / 配置（上游约定） |
| `./workspaces` | `/root/workspaces` | 工作区，Web UI 里添加 `/root/workspaces` |
| `./ssh` | `/etc/ssh` | 主机密钥 + sshd 配置；空目录首次启动自动生成，之后指纹固定 |

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `SSH_ROOT_PASSWORD` | – | root 密码；也支持 `SSH_ROOT_PASSWORD_FILE` 或 Docker secret |
| `SSH_AUTHORIZED_KEYS` | – | root 公钥，建议配合 `SSH_PASSWORD_AUTHENTICATION=no` |
| `SSH_PORT` | `22` | 容器内 sshd 端口 |
| `SSH_ENABLED` | `true` | `false` 时不启动 sshd |
| `GH_TOKEN` | – | 容器内 `gh` 用的 token |

上游变量（`PROXY_USERNAME`、`PROXY_PASSWORD`、`DSH_PORT` 等）照常生效。

## 工作原理

1. 每小时查上游 `devtools-<版本>` 的最高 tag，取 manifest 摘要当指纹。
2. 指纹没变就跳过；变了才拉上游镜像重建（构建失败不写状态，下一小时重试）。
3. 镜像 = 上游 + `openssh-server` + `gh` + `tini`；入口脚本先起 sshd，再 exec 上游命令。
4. 冒烟测试真起容器：密码登录成功、身份是 root、错误密码被拒、僵尸进程被回收。
5. 导出 `tar.gz` + `SHA256SUMS.txt` → 发布 Release（tag 与上游一致，`-rc` 自动标 pre-release）。

## 已知问题：`fork of unprivileged child failed`

**症状**：容器跑一段时间后日志被这条错误刷满，SSH 基本不可用，`docker exec` 里能看到大量 `<defunct>`。

**原因**：上游把 `node` 跑成 PID 1，它不回收孤儿进程。sshd 每条完成认证的连接都会遗留一个 privsep 子进程，
退出后成为永久僵尸、占 1 个 PID；累积到 `pids.max` 后 `fork()` 返回 EAGAIN。实测 **1 条连接 = 1 个僵尸**。

**修复**：镜像用 `tini` 作 1 号进程，孤儿进程即时回收。自查：

```bash
docker exec dsh cat /proc/1/comm                                                     # tini
docker exec dsh sh -c 'grep -lE "^State:[[:space:]]+Z" /proc/[0-9]*/status | wc -l'  # 0
```

> 这里只解决僵尸累积。连接量本身（爆破、客户端反复重连）不在镜像职责内：公网场景建议
> `SSH_AUTHORIZED_KEYS` + `SSH_PASSWORD_AUTHENTICATION=no`，或在转发层限制来源。

## 注意

- 默认允许 root 密码登录，只建议内网使用。
- 密码和 token 走环境变量时 `docker inspect` 可见；敏感场景用 `SSH_ROOT_PASSWORD_FILE`。
- 镜像约 530 MB（上游 devtools 514 MB + gh/openssh/tini 约 15 MB）；Release 里的 `.tar.gz` 是另一份拷贝，`docker load` 完可以删。

## 致谢

- 应用：[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
- 基础镜像：[smanx/deepseek-harness-docker](https://github.com/smanx/deepseek-harness-docker)

## License

[MIT](LICENSE)
