# Containerized `dbx serve`

The official image runs [`dbx serve`](serve.md) — the persistent wizard — as a
headless appliance: a long-lived container that hosts the GUI and orchestrates
backups/restores against the host Docker daemon.

```
ghcr.io/steig/dbx:latest        # also :0.36.0 etc. (pinned to a release)
```

!!! note "This is for the team / always-on server"
    Local single-user setups should keep running `dbx wizard` as a **host
    process**. Containerizing it adds the Docker-socket mount and loses the OS
    keychain credential story for no real gain. Reach for the image when you
    want one always-on box serving the wizard to a team.

## Why a container can't bundle the databases

dbx never installs `pg_dump`/`mysqldump` locally — it runs them **inside** the
managed `postgres-dbx` / `mysql-dbx` containers via `docker exec`, streaming the
dump back out to compress and encrypt it. The serve image is the dbx CLI + the
wizard server + the host-side tools it shells out to (`docker` client, `zstd`,
`age`/`gpg`, `openssh`, `jq`, `mc`). It drives the **host** Docker daemon through
a bind-mounted socket, so the managed containers run as siblings on the host, not
nested inside the dbx container.

## Quick start (compose)

A ready-to-edit [`docker/docker-compose.yml`](https://github.com/steig/dbx/blob/main/docker/docker-compose.yml)
ships in the repo:

```bash
# from a checkout, or copy the compose file next to a config/ data/ audit/ dir
DBX_SERVE_TOKEN=$(openssl rand -hex 16) docker compose up -d
docker compose logs -f          # the access URL is printed here
```

Or with plain `docker run`:

```bash
docker run -d --name dbx-serve \
  --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD/config:/config" \
  -v "$PWD/data:/data" \
  -v "$PWD/audit:/audit" \
  -v "$HOME/.ssh:/root/.ssh:ro" \
  -e DBX_SERVE_TOKEN="$(openssl rand -hex 16)" \
  -e DBX_VAULT_BACKEND=gpg-file \
  ghcr.io/steig/dbx:latest
```

Then open `http://<host>:8080/?token=…` (the token is in the logs). On first
load the token moves into an `HttpOnly` cookie and the URL is scrubbed — see
[Authentication](serve.md#authentication).

## The Docker socket is host-root-equivalent

Mounting `/var/run/docker.sock` lets the container start, stop, and `exec` into
any container on the host — that is **equivalent to root on the host**. Only run
this image behind the controls described in [serve.md](serve.md#authentication):
a token (default) or a trusted identity proxy / private tailnet, never on a
public interface. The v0.36.0 wizard hardening (token-in-cookie, loopback-only
secret reveal, config-write hardening) is what makes exposing it to a team
reasonable — but the socket mount still demands a trusted network.

## State: three volumes

| Mount | Env var | Holds |
|-------|---------|-------|
| `/config` | `DBX_CONFIG_DIR` | `config.json`, `vault.gpg`, age recipients |
| `/data` | `DBX_DATA_DIR` | backup files |
| `/audit` | `DBX_AUDIT_DIR` | `audit.log` |

The image sets these env vars and pre-declares the volumes, so you only bind
three host directories. Put your `config.json` in the `config/` dir before
starting (or build it from the running wizard and it persists there).

## Credentials without a host keychain

A container has no macOS Keychain / libsecret, so pick a keychain-free backend.
Force it with `DBX_VAULT_BACKEND` (overrides `config.json`):

- **`gpg-file`** — secrets in `/config/vault.gpg`. Mount your GnuPG home
  (`-v ~/.gnupg:/root/.gnupg`) for an asymmetric key, or set a symmetric
  encryption key via `dbx vault set-encryption-key`.
- **`pass`** — mount your store: `-v ~/.password-store:/root/.password-store`
  (plus the GnuPG home `pass` decrypts with).
- **age backup encryption** — set `DBX_AGE_IDENTITY=/config/age-key.txt` and
  mount the identity file; `encryption_type: age` in config.
- **`password_cmd`** — per-host, runs any command that prints the password
  (e.g. `vault kv get …`, `aws secretsmanager get-secret-value …`). No vault
  storage needed. See [Credential storage](credentials.md).

## Remote sources need host networking

dbx opens SSH tunnels to remote source databases on its own host and the managed
containers reach them via `host.docker.internal`. That only lines up when the
dbx container shares the host's network namespace — hence **`--network host`**
(the recommended default). It also means the wizard binds the host's `:8080`
directly and `docker exec` works without any network plumbing.

Bridge networking (`-p 8080:8080`) works **only** if every source is a local
managed container or a direct-connect cloud DB — SSH-tunnelled sources are
unreachable from the managed containers in that mode.

!!! note "`--no-token` under host networking needs `--allow-host`"
    The image pins `DBX_SERVE_BIND=0.0.0.0` so it's reachable in its namespace,
    but the server validates the `Host` header (DNS-rebinding defence, #126). If
    you also set `DBX_SERVE_NO_TOKEN=true`, a non-loopback `Host` is refused with
    `403 bad host` unless allow-listed — set `DBX_SERVE_ALLOW_HOST` to the name
    you reach the box by (e.g. its tailnet name). Token mode needs no allowlist.

## Updating

Pull a newer tag and recreate:

```bash
docker compose pull && docker compose up -d
# or: docker pull ghcr.io/steig/dbx:latest && docker rm -f dbx-serve && docker run … 
```

Pin to a version tag (e.g. `ghcr.io/steig/dbx:0.36.0`) for reproducible
deployments rather than tracking `:latest`.

## See also

- [Persistent wizard (`dbx serve`)](serve.md) — flags, auth, systemd
- [Credential storage](credentials.md) — backends and `DBX_VAULT_BACKEND`
- [Cloud storage](storage.md) — S3 offload (the image bundles `mc`)
