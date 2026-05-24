# dbx

> A pragmatic database backup and restore CLI for PostgreSQL and MySQL. No local DB install. SSH tunnels for remote production. Encryption at rest. S3-compatible cloud storage. Scheduled backups via launchd or systemd. macOS and Linux.

[![CI](https://github.com/steig/dbx/actions/workflows/ci.yml/badge.svg)](https://github.com/steig/dbx/actions/workflows/ci.yml)
[![Docs](https://github.com/steig/dbx/actions/workflows/docs.yml/badge.svg)](https://steig.github.io/dbx/)
[![Release](https://img.shields.io/github/v/release/steig/dbx)](https://github.com/steig/dbx/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-220%2B%20passing-brightgreen)](tests/)

> 📖 **Full documentation:** **<https://steig.github.io/dbx>**

```text
$ dbx backup production myapp
==> Backing up PostgreSQL: myapp@production
[INFO] SSH tunnel established (PID: 81923)
[INFO] Encryption: age
[INFO] Excluding data: sessions cache logs
[INFO] Running pg_dump...
[OK]   Backup complete: ~/.data/dbx/production/myapp/myapp_20260508_103000.sql.zst.age
[INFO] Checksum (SHA256): 7a3f...
```

---

## Why dbx?

Raw `pg_dump` and `mysqldump` are fine — until they're not. dbx wraps them with the operational glue you'd otherwise build yourself:

- **No local Postgres or MySQL** — dump and restore happen inside official Docker images. Your laptop stays clean.
- **SSH tunnels handled** — remote DBs in private VPCs (RDS, EC2 internal hosts) just work. Tunnels are reused across runs and torn down on exit.
- **Restore to a fresh local DB by default** — `dbx restore prod/myapp/latest` creates a versioned, sandboxed copy in a managed Docker container. Production stays untouched.
- **Encryption at rest** — backups can be `age`-encrypted with one command. Keys live in your sops directory.
- **Credentials in the system vault** — no plaintext passwords in shell history or config files. macOS Keychain, GNOME libsecret, `pass`, or a GPG-encrypted file as fallback.
- **One config file, JSON** — version-controllable, tab-completable, no surprises.

### What dbx is and isn't

dbx is for **logical backups** — periodic `pg_dump` / `mysqldump` snapshots you keep around for dev clones, ad-hoc audits, and recovery from "I dropped the wrong table at 14:32 and our last good state is yesterday morning." This is the operational layer most teams need first and don't get around to building cleanly.

It is **not a disaster-recovery system.** If your recovery objective is "rewind production to 14:31:59" or "lose no more than 30 seconds of writes on a hardware failure," you need WAL shipping or streaming replication — `pgbackrest`, `wal-g`, or your cloud provider's managed PITR. dbx will happily back up a database the moment you run it, but it will not capture the writes that happened between backups, and restoring an N-hours-old snapshot is the only recovery path it offers.

A reasonable production setup uses both: managed PITR for the "we lost the box at 14:32" case, and dbx (or equivalent) for the "give me yesterday's prod data in my laptop's docker container, scrubbed" case. They're solving different problems.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/steig/dbx/main/install.sh | bash
```

Or clone:

```bash
git clone https://github.com/steig/dbx.git
export PATH="$PWD/dbx:$PATH"
```

Once installed, `dbx update` upgrades in place when a new release is out.

> 💡 Prefer a browser-driven setup? After install, `dbx wizard` opens a form in your default browser. Or **try the form first without installing** at <https://steig.github.io/dbx/config-builder>.

<details>
<summary><b>Requirements</b></summary>

**Required**

- `docker`
- `jq`
- `zstd`
- `ssh` (for remote databases)

**Optional**

| Tool | What it enables |
|------|-----------------|
| `libsecret-tools` | Linux desktop credential storage (GNOME Keyring) |
| `pass` | Linux headless credential storage |
| `age` | Recommended modern backup encryption |
| `gpg` | Alternative encryption + headless vault fallback |
| `mc` or `aws` CLI | S3 / MinIO upload |
| `fzf` | Interactive backup picker for restore / verify |
| `pv` | Progress bar during MySQL restore |

</details>

## Quick Start

```bash
# 1. Initialize config + encryption
dbx config init
dbx config edit                       # add your hosts
dbx config init-encryption            # generate age keys

# 2. Store the DB password in the system vault
dbx vault set production

# 3. Test the connection end-to-end
dbx test production

# 4. Back up
dbx backup production myapp

# 5. Restore to a sandboxed local container
dbx restore production/myapp/latest
```

Restore creates a versioned database (e.g. `myapp_v1_20260508`) inside the auto-managed `postgres-dbx` or `mysql-dbx` container — production stays untouched.

## Commands

| Command | Description |
|---------|-------------|
| `dbx backup [-v] [--upload] <host> [database]` | Back up one DB or every DB on a host |
| `dbx restore <source> [--name N] [--recreate-container] [--from-remote PATH] [--keep-download] [--no-post-restore \| --hooks-only] [--transform PATH] [--into NAME]` | Restore to a local container; `--from-remote` (or `s3://...`) pulls straight from cloud storage; `--no-post-restore` skips configured hooks; `--hooks-only --name X` re-runs hooks against an existing DB; `--transform PATH` pipes the restore stream through a host script (streaming sanitize, atomic on postgres); `--into NAME` targets a named running container instead of the managed postgres-dbx (postgres only) |
| `dbx verify [backup-file]` | Verify SHA-256 checksum (interactive if `fzf` is installed) |
| `dbx test <host>` | End-to-end connectivity check (SSH, container, creds, query) |
| `dbx query <host> [database]` | Open a `psql` / `mysql` shell to a remote DB |
| `dbx analyze <host> <database>` | Pick tables to exclude from data dumps |
| `dbx list [host] [database]` | List local backups |
| `dbx clean [--keep N] [--dry-run] [--older-than D]` | Retention sweep |
| `dbx vault set\|get\|delete\|list\|info` | Manage host credentials |
| `dbx config init\|edit\|show\|validate` | Manage configuration |
| `dbx schedule add\|list\|remove\|run` | Manage scheduled backups |
| `dbx storage upload\|download\|list\|sync\|info` | Cloud storage |
| `dbx update` | Re-run install.sh to upgrade to the latest release |
| `dbx version` | Print version |
| `dbx help` | Full reference |

## Configuration

Config lives at `~/.config/dbx/config.json`. Minimal example:

```json
{
  "hosts": {
    "production": {
      "type": "postgres",
      "user": "backup_user",
      "ssh_tunnel": {
        "jump_host": "bastion",
        "target_host": "db.internal",
        "target_port": 5432
      },
      "databases": {
        "myapp": { "exclude_data": ["sessions", "cache", "logs"] }
      }
    }
  },
  "defaults": {
    "encryption_type": "age",
    "keep_backups": 10
  }
}
```

<details>
<summary><b>Full reference (storage, notifications, vault backend)</b></summary>

```json
{
  "defaults": {
    "encryption_type": "age",
    "age_recipients": "~/.config/dbx/age-recipients.txt",
    "age_identity": "~/.config/sops/age/keys.txt",
    "compression_level": 3,
    "keep_backups": 10,
    "auto_upload": false,
    "definer_handling": "strip"
  },
  "hosts": {
    "production": {
      "type": "postgres",
      "user": "backup_user",
      "ssh_tunnel": {
        "jump_host": "bastion",
        "target_host": "db.internal",
        "target_port": 5432
      },
      "databases": {
        "myapp": {
          "exclude_data": ["sessions", "cache", "logs"],
          "parallel_jobs": 4
        }
      }
    }
  },
  "vault": {
    "backend": "auto",
    "gpg_key": "your-gpg-key-id"
  },
  "storage": {
    "type": "s3",
    "s3": {
      "bucket": "backups",
      "endpoint": "http://minio:9000",
      "prefix": "dbx/",
      "access_key": "minioadmin",
      "secret_key_cmd": "dbx vault get s3-secret-key"
    }
  },
  "notifications": {
    "enabled": true,
    "on": "failure",
    "backends": ["slack", "desktop"],
    "slack": { "webhook_url_cmd": "dbx vault get slack-webhook" },
    "email": { "to": "admin@example.com", "smtp_host": "smtp.example.com" },
    "command": { "on_failure": "terminal-notifier -title DBX -message 'Backup failed'" }
  }
}
```

Validate after edits with `dbx config validate`.
</details>

### Adding a host

```bash
dbx host add
```

Interactive wizard that walks through alias → database type → user →
network (direct or SSH tunnel) → credentials → live connection test →
pick databases → per-database options. On test failure you can re-enter
credentials, re-enter host fields, save anyway, or abort (which rolls
back the config and vault). If remote storage isn't configured yet, the
wizard offers to set that up too; if it is, it offers to flip
auto-upload on for the new host.

Requires `gum`.

### Adding remote storage

```bash
dbx storage add
```

Interactive wizard for S3 / S3-compatible remote storage (MinIO, R2,
Backblaze B2, etc.). Collects provider, endpoint, bucket, prefix, and
credentials, then proves the config works with an upload → list →
download → delete round-trip against the configured bucket. The
secret key lives in the vault, never plaintext in `config.json`.
Re-running the wizard with storage already configured asks before
replacing.

## Encryption

Two backends. **age** is the recommended default.

### age (recommended)

```bash
dbx vault init-age            # generate keys at ~/.config/sops/age/keys.txt
# then in config: "defaults": { "encryption_type": "age" }
```

Keys live at:

| Path | Contents |
|------|----------|
| `~/.config/sops/age/keys.txt` | private identity |
| `~/.config/dbx/age-recipients.txt` | public recipient(s) |

Back the identity file up somewhere safe — without it, your encrypted backups are unreadable.

### GPG

```bash
dbx vault set-encryption-key   # symmetric passphrase, stored in vault
# then in config: "defaults": { "encryption_type": "gpg" }
```

## Credential Storage

Auto-detected in this order:

| Platform | Backend |
|----------|---------|
| macOS | `security` (Keychain) |
| Linux desktop | `secret-tool` (libsecret / GNOME Keyring) |
| Linux headless | `pass` (password-store) |
| Fallback | GPG-encrypted file at `~/.config/dbx/vault.gpg` |

Override in config:

```json
{ "vault": { "backend": "pass", "gpg_key": "your-key-id" } }
```

`dbx vault info` shows the active backend.

## Scheduled Backups

launchd (macOS) or systemd user timers (Linux):

```bash
dbx schedule add production myapp daily          # 2am daily
dbx schedule add production myapp daily@5        # 5am daily
dbx schedule add production myapp hourly
dbx schedule add production myapp weekly@0:3     # Sun 3am (0..6 = Sun..Sat)

dbx schedule list
dbx schedule run production myapp                # one-shot manually
dbx schedule remove production myapp
```

Logs at `~/.local/share/dbx/logs/`.

## Cloud Storage (S3 / MinIO)

```bash
dbx backup --upload production myapp             # backup + push in one shot
dbx storage upload production/myapp/latest.sql.zst
dbx storage list
dbx storage download production/myapp/backup.sql.zst
dbx storage sync upload production               # all backups for a host
dbx storage sync download production
```

Uses `mc` (MinIO Client) if available, falling back to `aws` CLI.

## Notifications

Slack, desktop, email, or any custom command:

```json
{
  "notifications": {
    "enabled": true,
    "on": "failure",
    "backends": ["slack", "desktop"],
    "slack": { "webhook_url_cmd": "dbx vault get slack-webhook" },
    "command": { "on_failure": "terminal-notifier -title DBX -message 'Backup failed'" }
  }
}
```

`on` accepts `failure`, `success`, or `all`.

## How Restore Works

Restores never touch your source database. They go to **local Docker containers** that dbx auto-manages:

```bash
dbx restore production/myapp/latest
# → restored as: myapp_v1_20260508 (auto-named to avoid conflicts)
# → connect:    psql -h 127.0.0.1 -p 5432 -U postgres myapp_v1_20260508
#               (default password: devpassword — see env vars below)
```

### Restoring directly from S3 / MinIO

To skip the explicit `dbx storage download` step, pass `--from-remote` (or use the `s3://` URI shorthand). The remote object is staged under `~/.data/dbx/.remote/dl.<rand>/` and removed after a successful restore. Pass `--keep-download` to keep the local copy.

```bash
# Latest backup for production/myapp from S3/MinIO
dbx restore --from-remote production/myapp/latest

# Equivalent URI form
dbx restore s3://production/myapp/latest --name myapp_review

# An exact filename, and keep the downloaded archive afterwards
dbx restore --from-remote prod/db/db_20260510_120000.sql.zst.age --keep-download
```

`latest` resolves to the lex-max filename returned by `storage list <host>/<db>` — since backups embed a zero-padded `YYYYMMDD_HHMMSS` timestamp, that's the newest one. Encrypted backups (`.age`, `.gpg`) are decrypted by the same code path as local restores. On download failure the file is left in place so you can retry without re-fetching.


| Container | Image | Default port |
|-----------|-------|--------------|
| `postgres-dbx` | `postgres:17-alpine` (UTF-8) | 5432 |
| `mysql-dbx` | `mysql:8.0` | 3306 |

Both bind to `127.0.0.1` only by default so dev databases aren't reachable from the LAN with the default password. Set `DBX_BIND_ADDR=0.0.0.0` before first run if you need remote access. Containers are also created with `--add-host=host.docker.internal:host-gateway` so SSH-tunnel mode works on Linux as well as macOS.

## Post-restore hooks

Declare SQL to run after every restore — scrub PII, repoint webhooks, reset feature flags. Per database, optionally inherited per host:

```jsonc
{
  "hosts": {
    "production": {
      "type": "postgres",
      "post_restore": [
        { "file": "hooks/scrub-pii.sql" }              // runs for every DB on production
      ],
      "databases": {
        "myapp": {
          "post_restore": [
            { "sql": "UPDATE config SET base_url = 'http://localhost';" },
            { "file": "hooks/disable-cron.sql" }
          ]
        }
      }
    }
  }
}
```

Each hook runs in its own transaction (psql `-1`; MySQL `START TRANSACTION; … COMMIT;`). The first failure aborts the restore and leaves the partial DB in place. Host hooks run before per-database hooks; file paths are absolute or relative to the config file. MySQL DDL implicitly commits — keep DDL hooks small.

`dbx config validate` checks hook paths and entry shape before you ship.

```bash
dbx restore prod/myapp/latest --no-post-restore             # skip hooks once
dbx restore prod/myapp/latest --hooks-only --name myapp_v1  # re-run hooks against an existing DB
```

Inside every hook, `target_db` is bound to the freshly-restored DB name — `:target_db` in PG, `@target_db` in MySQL. Additional vars (`source_host`, `source_db`, `backup_file`, `backup_timestamp`, `restored_at`) are also bound; useful for stamping provenance rows.

For PII masking specifically, prefer the declarative scrub manifest over hand-written `scrub-pii.sql` hooks — it ships with schema-drift detection and a pre-restore gate that aborts when the live schema has columns the manifest doesn't know about. See [docs/scrub.md](docs/scrub.md).

## Image Selection

dbx auto-picks the Docker image for the restore container based on the source database's version and extensions, recorded in `.meta.json` at backup time:

- **Postgres, no extensions** → `postgres:<major>-alpine`
- **Postgres + `vector`** → `pgvector/pgvector:pg<major>`
- **Postgres + `postgis`** → `postgis/postgis:<major>-3.5`
- **Postgres + `timescaledb`** → `timescale/timescaledb:latest-pg<major>`
- **MySQL** → `mysql:<major>.<minor>`
- **MariaDB** → `mariadb:<major>.<minor>` (MariaDB sources now use the correct dumper — Oracle `mysqldump` previously introduced subtle drift)

For anything outside this list, set `DBX_POSTGRES_IMAGE` or `DBX_MYSQL_IMAGE` (or the `defaults.postgres_image` / `defaults.mysql_image` config keys). The template supports `{major}` and `{version}` substitution:

```bash
export DBX_POSTGRES_IMAGE='myregistry/pg-everything:{major}'
```

If the existing restore container's image doesn't match what's needed, dbx will:
- **Silently recreate** when the container has no user databases.
- **Fail with a list of restored DBs** and instructions to pass `--recreate-container` when there are user DBs to preserve.

### Limitations

- Postgres backups always use the existing `postgres-dbx` client image. If you back up from a source whose major version is *newer* than `postgres-dbx`'s current image (e.g. `postgres-dbx` is on 13, source is 16), pg_dump will fail because older clients can't dump newer servers. Workaround: restore an older backup first (which switches the image), or set `DBX_POSTGRES_IMAGE='postgres:N-alpine'` to the source version and recreate.
- The extension allowlist is intentionally narrow (3 known images). For anything else (`pg_partman`, `pg_cron`, Citus, `pgaudit`, etc.), use `DBX_POSTGRES_IMAGE`.

## Verification & Audit

Every backup writes a sibling `.meta.json` with size, timestamp, encryption mode, and SHA-256 checksum:

```bash
dbx verify ~/.data/dbx/production/myapp/myapp_20260508_103000.sql.zst.age
# [OK] Checksum verified
```

Every operation appends a JSON line to `~/.local/share/dbx/audit.log`:

```json
{"timestamp":"2026-05-08T10:30:00Z","action":"backup","outcome":"success","db_host":"production","database":"myapp","file":"...","size":1234567,"duration_sec":45}
```

## Storage Layout

```
~/.data/dbx/<host>/<database>/<database>_<timestamp>.sql.zst[.age|.gpg]
~/.data/dbx/<host>/<database>/<database>_<timestamp>.sql.zst.meta.json
~/.config/dbx/config.json
~/.config/dbx/age-recipients.txt
~/.local/share/dbx/audit.log
~/.local/share/dbx/logs/                 # scheduled backup logs
~/.cache/dbx/latest-release              # update-check cache
```

## Environment Variables

| Variable | Default | Effect |
|----------|---------|--------|
| `DBX_DATA_DIR` | `~/.data/dbx` | Where backup files are stored |
| `DBX_CONFIG_DIR` | `~/.config/dbx` | Where config and age recipients live |
| `DBX_AUDIT_DIR` | `~/.local/share/dbx` | Audit log + scheduled-backup logs |
| `DBX_CACHE_DIR` | `~/.cache/dbx` | Update-check cache |
| `DBX_POSTGRES_CONTAINER` | `postgres-dbx` | Container name for PG operations |
| `DBX_MYSQL_CONTAINER` | `mysql-dbx` | Container name for MySQL operations |
| `DBX_PG_PASSWORD` | `devpassword` | Initial password for auto-created PG container |
| `DBX_MYSQL_PASSWORD` | `devpassword` | Initial password for auto-created MySQL container |
| `DBX_BIND_ADDR` | `127.0.0.1` | Host bind address for the auto-managed containers |
| `DBX_POSTGRES_IMAGE` | unset | Override the auto-managed PG container image. Supports `{major}` / `{version}` template substitution. |
| `DBX_MYSQL_IMAGE` | unset | Override the auto-managed MySQL container image. Supports `{major}`, `{minor}`, `{version}` template substitution. |
| `DBX_RECREATE_CONTAINER` | unset | Set to `true` (or pass `--recreate-container`) to allow destroying user DBs when the container's version doesn't match the backup. |
| `DBX_NO_UPDATE_CHECK` | unset | Set to `1` to suppress update notices |
| `DBX_REPO_SLUG` | `steig/dbx` | Override for forks |
| `DBX_UPDATE_CHECK_INTERVAL` | `86400` | Seconds between update API hits |
| `DBX_GPG_KEY` | unset | GPG key id for vault encryption |

## Update Notifications

dbx checks GitHub Releases at the end of each interactive command and prints a one-liner when a newer tag is published. Cached 24h. Skipped when stdout isn't a TTY (so cron and scheduled runs stay silent).

```bash
$ dbx version
dbx 0.7.0
[INFO] dbx 0.7.1 is available (you have 0.7.0). Run 'dbx update' to upgrade.
```

Opt out with `DBX_NO_UPDATE_CHECK=1`.

## Development

```bash
# Lint
shellcheck -S error dbx lib/*.sh

# Unit tests (no docker, ~1s)
bats tests/unit/

# Integration tests (docker, real postgres + mysql, ~30s)
bats tests/integration/
```

| File | Contents |
|------|----------|
| [`AGENTS.md`](AGENTS.md) | Conventions, error-handling patterns, gotchas |
| [`CHANGELOG.md`](CHANGELOG.md) | Release notes |
| [`tests/README.md`](tests/README.md) | Test layout, debugging guide |

PRs welcome — see `AGENTS.md` for the patterns the test suite enforces (set-e gotchas, BSD vs GNU sed, etc.).

## License

[MIT](LICENSE)
