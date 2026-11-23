# dsh

![Build](https://github.com/yoookas/dsh-docker/actions/workflows/build-ssh-image.yml/badge.svg)
![Release](https://img.shields.io/github/v/release/yoookas/dsh-docker?include_prereleases&label=release)
![License](https://img.shields.io/github/license/yoookas/dsh-docker)

A derivative of [`smanx/deepseek-harness`](https://hub.docker.com/r/smanx/deepseek-harness/tags):
adds **OpenSSH Server**, **gh** and a **Go 1.26.11** toolchain on top of the `devtools-<version>`
variant, with the root password injected from an environment variable.

Every hour the repo checks upstream, and on a new version it builds, smoke-tests and publishes
a tarball to GitHub Releases (tags mirror upstream).

## Quick start

Deployment is [Docker Compose](examples/docker-compose.yml); the `dsh-data` / `workspaces` / `ssh` / `go`
directories are created automatically.

```bash
# 1. Load the image tarball (pick your arch: arm64 / amd64)
curl -LO https://github.com/yoookas/dsh-docker/releases/download/devtools-0.2.2-rc.5/dsh-devtools-0.2.2-rc.5-linux-arm64.tar.gz
docker load -i dsh-devtools-0.2.2-rc.5-linux-arm64.tar.gz

# 2. Prepare compose + env
cp examples/docker-compose.yml .
cp examples/.env.example .env
vi .env                     # at least set SSH_ROOT_PASSWORD

# 3. Start
docker compose up -d

# 4. Access
#   Web:  http://<host>:3080/
#   SSH:  ssh -p 44222 root@<host>
```

Upgrading: `docker load` the new tarball, then `docker compose up -d --force-recreate`
(a plain `restart` does not swap the image).

## Mounts

| Host | Container | Purpose |
| --- | --- | --- |
| `./dsh-data` | `/root/.dsh` | sessions / config (upstream convention) |
| `./workspaces` | `/root/workspaces` | workspace; add `/root/workspaces` in the Web UI |
| `./ssh` | `/etc/ssh` | host keys + sshd config; generated on first start, fingerprint stays stable |
| `./go` | `/root/go` | `GOPATH`: Go module cache + `go install` binaries; survives container recreation |

## Bundled tools

The upstream devtools variant ships git / vim / python3 / pnpm / uv / build-essential and friends (see
upstream `.build-variants` — **no Go**); this image adds:

| Tool | Version | Notes |
| --- | --- | --- |
| `go` / `gofmt` | `1.26.11` (`ARG GO_VERSION`, one line to bump) | added here: official tarball into `/usr/local/go`, symlinked onto `PATH` |
| `sshd` | distro repo | added here: OpenSSH Server, root login via password or public key |
| `gh` | latest stable at build time | added here: GitHub CLI, authenticated with `GH_TOKEN` |
| `tini` | distro repo | added here: PID 1, reaps orphans |

The build downloads the official tarball (~70 MB), verifies it against the sha256 in go.dev's download
manifest, and asserts `go version` afterwards; a failed download or checksum fails the build. Bumping Go
is a single `ARG GO_VERSION` change in the Dockerfile.

`go install` binaries land in `/root/go/bin` (on `PATH`); compose mounts `./go` at `/root/go`, so the
module cache and those binaries survive container recreation.

## Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `SSH_ROOT_PASSWORD` | – | root password; `SSH_ROOT_PASSWORD_FILE` or a Docker secret also works |
| `SSH_AUTHORIZED_KEYS` | – | root public keys; pair with `SSH_PASSWORD_AUTHENTICATION=no` |
| `SSH_PORT` | `22` | sshd port inside the container |
| `SSH_ENABLED` | `true` | `false` = no sshd |
| `GH_TOKEN` | – | token for the bundled `gh` |

Upstream variables (`PROXY_USERNAME`, `PROXY_PASSWORD`, `DSH_PORT`, …) keep working.

## How it works

1. Hourly: pick the highest `devtools-<version>` tag and use its manifest digest as the fingerprint.
2. Same fingerprint ⇒ skip; otherwise pull upstream and rebuild (failed builds don't update state).
3. Image = upstream + `openssh-server` + `gh` + `tini` + the official Go toolchain; the entrypoint starts sshd, then execs upstream.
4. Smoke test runs a real container: password login works, user is root, wrong password is rejected, zombies are reaped.
5. Export `tar.gz` + `SHA256SUMS.txt` → publish a Release (tag mirrors upstream, `-rc` ⇒ pre-release).

## Notes

- Root password login is allowed by default; private networks only.
- Passwords and tokens passed as env vars are visible in `docker inspect`; use `SSH_ROOT_PASSWORD_FILE` when that matters.
- The image is ~800 MB (514 MB upstream + ~15 MB for gh/openssh/tini + ~265 MB unpacked Go toolchain; the CI size report prints the actual numbers). The release `.tar.gz` is a second copy you can delete after `docker load`.

## Credits

- Application: [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
- Base image: [smanx/deepseek-harness-docker](https://github.com/smanx/deepseek-harness-docker)

## License

[MIT](LICENSE)
