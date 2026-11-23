# dsh

![Build](https://github.com/yoookas/dsh-docker/actions/workflows/build-ssh-image.yml/badge.svg)
![Release](https://img.shields.io/github/v/release/yoookas/dsh-docker?include_prereleases&label=release)
![License](https://img.shields.io/github/license/yoookas/dsh-docker)

[`smanx/deepseek-harness`](https://hub.docker.com/r/smanx/deepseek-harness/tags) 的衍生镜像：
在 `devtools-<版本>` 变体上加装 **OpenSSH Server**、**gh** 和 **Go 1.26.11**，root 密码由环境变量指定。

仓库每小时检查上游更新，有新版本就自动构建、冒烟测试，打包发到 Release（tag 与上游一致）。

## 快速开始

部署方式是 [Docker Compose](examples/docker-compose.yml)，四个目录（`dsh-data` / `workspaces` / `ssh` / `go`）会自动创建。

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
| `./go` | `/root/go` | `GOPATH`：Go 模块缓存 + `go install` 的二进制，重建容器后不用重新下载依赖 |

## 内置工具

上游 devtools 变体自带 git / vim / python3 / pnpm / uv / build-essential 等（见上游的
`.build-variants`，其中**没有 Go**），本镜像另外补上：

| 工具 | 版本 | 说明 |
| --- | --- | --- |
| `go` / `gofmt` | `1.26.11`（`ARG GO_VERSION`，一行可升） | 本镜像新装：官方 tarball 解压到 `/usr/local/go`，软链进 `PATH` |
| `sshd` | 发行版仓库 | 本镜像新装：OpenSSH Server，root 密码或公钥登录 |
| `gh` | 安装时的最新稳定版 | 本镜像新装：GitHub CLI，用 `GH_TOKEN` 认证 |
| `tini` | 发行版仓库 | 本镜像新装：1 号进程，回收孤儿进程 |

构建时下载官方 tarball（约 70 MB）并用 go.dev 清单里的 sha256 校验，装完执行 `go version` 断言版本；
装不上或校验不过就让构建失败。升级 Go 只改 Dockerfile 里的 `ARG GO_VERSION`。

`go install` 的二进制落在 `/root/go/bin`（已在 `PATH`）；compose 里把 `./go` 挂到 `/root/go`，
容器重建后模块缓存和这些二进制都还在。

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
3. 镜像 = 上游 + `openssh-server` + `gh` + `tini` + 官方 Go 工具链；入口脚本先起 sshd，再 exec 上游命令。
4. 冒烟测试真起容器：密码登录成功、身份是 root、错误密码被拒、僵尸进程被回收。
5. 导出 `tar.gz` + `SHA256SUMS.txt` → 发布 Release（tag 与上游一致，`-rc` 自动标 pre-release）。

## 注意

- 默认允许 root 密码登录，只建议内网使用。
- 密码和 token 走环境变量时 `docker inspect` 可见；敏感场景用 `SSH_ROOT_PASSWORD_FILE`。
- 镜像约 594 MB（上游 devtools 514 MB + gh/openssh/tini 约 15 MB + Go 工具链约 80 MB；CI 的「镜像体积报表」会打印实际值）。Release 里的 `.tar.gz` 是另一份拷贝，`docker load` 完可以删。

## 致谢

- 应用：[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
- 基础镜像：[smanx/deepseek-harness-docker](https://github.com/smanx/deepseek-harness-docker)

## License

[MIT](LICENSE)
