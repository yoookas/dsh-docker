# dsh

![Build](https://github.com/yoookas/dsh-docker/actions/workflows/build-ssh-image.yml/badge.svg)
![Release](https://img.shields.io/github/v/release/yoookas/dsh-docker?include_prereleases&label=release)
![License](https://img.shields.io/github/license/yoookas/dsh-docker)

A derived image of [`smanx/deepseek-harness`](https://hub.docker.com/r/smanx/deepseek-harness/tags):
the `devtools-<version>` variant plus **OpenSSH Server** and **gh**, with the root password supplied at runtime.

An hourly job watches upstream, rebuilds on new versions, smoke-tests the result, and publishes `tar.gz` images
to GitHub Releases (release tags mirror upstream).

## Quick start

```bash
# 1. download and load (use -linux-arm64 on ARM)
curl -LO https://github.com/yoookas/dsh-docker/releases/download/devtools-0.2.2-rc.5/dsh-devtools-0.2.2-rc.5-linux-amd64.tar.gz
docker load -i dsh-devtools-0.2.2-rc.5-linux-amd64.tar.gz

# 2. run
docker run -d --name dsh \
  -p 3080:3080 -p 2222:22 \
  -e SSH_ROOT_PASSWORD='change-me' \
  -v dsh-data:/root/.dsh \
  dsh:devtools-0.2.2-rc.5

# 3. use
#   Web: http://127.0.0.1:3080/
#   SSH: ssh -p 2222 root@127.0.0.1
```

Compose example: [`examples/docker-compose.yml`](examples/docker-compose.yml).

### Mounts

| Host | Container | Purpose |
| --- | --- | --- |
| `./dsh-data` | `/root/.dsh` | sessions / config (upstream convention) |
| `./ssh` | `/etc/ssh` | host keys + sshd config; keeps the fingerprint stable across recreations |
| `./workspaces` | `/root/workspaces` | workspace; add `/root/workspaces` in the Web UI |

An empty `/etc/ssh` bind mount gets a generated `sshd_config` and fresh host keys on first start.

## Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `SSH_ROOT_PASSWORD` | – | root password, applied at start |
| `SSH_ROOT_PASSWORD_FILE` | – | read password from a file |
| `SSH_AUTHORIZED_KEYS` | – | authorized keys for root |
| `SSH_PORT` | `22` | sshd port inside the container |
| `SSH_PERMIT_ROOT_LOGIN` | `yes` | e.g. `prohibit-password` |
| `SSH_ENABLED` | `true` | `false` = no sshd |
| `DSH_APP_ENABLED` | `true` | `false` = SSH only |
| `GH_TOKEN` | – | token for the bundled `gh` |

Upstream variables (`DSH_PORT`, `PROXY_USERNAME`, …) keep working.

## How it works

1. Hourly: pick the highest `devtools-<version>` tag and use its manifest digest as the fingerprint.
2. Same fingerprint as `state/upstream.json` ⇒ skip; otherwise pull upstream and rebuild (failed builds don't update state).
3. Build: upstream image + `openssh-server` + `gh` + `tini`; `tini` is PID 1 and reaps zombies, the entrypoint starts sshd, then execs the upstream command.
4. Smoke test: real container, real SSH login, asserts `root`, asserts wrong passwords are rejected.
5. Export `tar.gz` + `SHA256SUMS.txt` → publish a GitHub Release (tag mirrors upstream, `-rc` ⇒ pre-release).

## Repository configuration

| Variable | Default | Description |
| --- | --- | --- |
| `PLATFORMS` | `linux/amd64,linux/arm64` here | architectures to build |
| `UPSTREAM_TRACK` | `version` | `version` or a fixed `tag` |
| `UPSTREAM_TAG_PREFIX` | `devtools` | prefix for version mode, `none` for plain versions |
| `UPSTREAM_TAG` | `devtools-latest` | used when `UPSTREAM_TRACK=tag` |

Manual rebuild: Actions → **Build SSH image** → Run workflow → tick `force`.

## Image size

About **530 MB**: the upstream devtools variant is 514 MB and this image adds ~15 MB
(mostly the `gh` 42 MB and `openssh-server` 5.8 MB layers).

Note that `rm`-ing files in a later layer does **not** shrink the image (the data stays in lower layers),
so the exported tar stays ~531 MB.

The release `.tar.gz` is a *second* copy on disk (527 MB; the content is already compressed, so gzip barely helps) —
delete it after `docker load`. Re-importing a newer build leaves the previous image dangling, so `docker image prune -f` occasionally.

## Known issue: `fork of unprivileged child failed`

**Symptom**: after a while the log is flooded with that line and SSH stops working; `docker exec` shows many `<defunct>`.

**Cause**: upstream runs `node` as PID 1, which never calls `waitpid(-1)`. Every sshd connection that completes
the handshake and authentication leaves a privsep child behind; it exits as a permanent zombie holding a PID.
Once `pids.max` (often 4537) is full, `fork()` returns EAGAIN and every connection logs that line until a restart.
Measured: **1 connection = 1 zombie**; ~4.5 h under a brute force, ~5 days with only dsh-go reconnections.

**Fix**: `tini` is PID 1, so orphans are reaped immediately.

```dockerfile
ENTRYPOINT ["tini", "-g", "--", "/usr/local/bin/dsh-entrypoint.sh"]
```

**Check**:

```bash
docker exec dsh cat /proc/1/comm                                                     # tini
docker exec dsh sh -c 'grep -lE "^State:[[:space:]]+Z" /proc/[0-9]*/status | wc -l'  # 0
docker exec dsh cat /sys/fs/cgroup/pids.current                                      # should not grow
```

> This only fixes the PID exhaustion. Connection volume (brute force, clients reconnecting) is out of scope
> for the image — for public exposure prefer keys only or allow-list at the forwarder.

## Notes

- Root SSH login is allowed; keep it on a private network. Prefer `SSH_AUTHORIZED_KEYS` + `SSH_PASSWORD_AUTHENTICATION=no`.
- `SSH_ROOT_PASSWORD` is visible via `docker inspect`; use `SSH_ROOT_PASSWORD_FILE` when that matters.
- Host keys are generated on first start and are not baked into the image.

## Credits

- Application: [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
- Base image: [smanx/deepseek-harness-docker](https://github.com/smanx/deepseek-harness-docker)

## License

[MIT](LICENSE)
