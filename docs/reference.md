# Reference

## Commands

| Command | Description |
|---------|-------------|
| `dbx backup [-v] [--upload] <host> [database]` | Back up one DB or every DB on a host. See [Backup](backup.md). |
| `dbx restore <source> [-n\|--name N] [--into NAME] [--no-scrub] [--transform PATH] [--transform-inherit-env] [--recreate-container] [--from-remote PATH] [--keep-download] [--no-post-restore \| --hooks-only] [-v]` | Restore to a local container. See [Restore](restore.md). |
| `dbx build-image (--from-backup <file> \| pg<MAJOR> --extensions ext1,ext2)` | Pre-build a custom Postgres image for third-party extensions. See [Restore](restore.md). |
| `dbx verify [backup-file]` | Verify SHA-256 checksum (interactive if `fzf` is installed). |
| `dbx test <host>` | End-to-end connectivity check (SSH, container, creds, query). |
| `dbx query <host> [database]` | Open a `psql` / `mysql` shell to a remote DB. |
| `dbx analyze <host> <database> [--suggest-scrub] [--no-pii-scan] [--manifest-output FILE] [--json]` | Pick tables to exclude from data dumps; also pre-scans schema for PII candidates. `--suggest-scrub` writes a draft scrub manifest; `--no-pii-scan` skips the pre-scan. |
| `dbx scrub init <host>/<database> [--include-empty] [--output FILE]` | Build a PII scrub manifest. See [scrub](scrub.md). |
| `dbx scrub check <host>/<database> [--quiet] [--json] [--manifest FILE]` | Check live schema against a scrub manifest. |
| `dbx scrub validate <host>` | Validate the host's scrub config. |
| `dbx list [host] [database]` | List local backups. |
| `dbx clean [host] [database] [--keep N] [--dry-run] [--older-than D]` | Retention sweep. |
| `dbx host add` | [Interactive wizard](wizards.md#dbx-host-add) for adding a host. |
| `dbx storage add` | [Interactive wizard](wizards.md#dbx-storage-add) for cloud storage. |
| `dbx vault set\|get\|delete\|list\|info` | Manage host [credentials](credentials.md). |
| `dbx vault init-age\|set-encryption-key\|delete-encryption-key` | Initialize backup [encryption](encryption.md). |
| `dbx config init\|edit\|show\|validate` | Manage [configuration](configuration.md). |
| `dbx schedule add\|list\|remove\|run\|sync` | Manage [scheduled backups](scheduling.md). |
| `dbx storage upload\|download\|list\|sync\|info\|delete` | Cloud [storage](storage.md). |
| `dbx wizard` | Browser-based config + operations wizard. See [wizards](wizards.md). |
| `dbx completion <bash\|zsh\|fish>` | Print a shell completion script. |
| `dbx update` | Re-run `install.sh` to upgrade to the latest release. |
| `dbx version` | Print version. |
| `dbx help` | One-screen reference (links here for full docs). |

## Environment variables

| Variable | Default | Effect |
|----------|---------|--------|
| `DBX_DATA_DIR` | `~/.data/dbx` | Where backup files are stored. |
| `DBX_CONFIG_DIR` | `~/.config/dbx` | Where config and age recipients live. |
| `DBX_AUDIT_DIR` | `~/.local/share/dbx` | Audit log + scheduled-backup logs. |
| `DBX_CACHE_DIR` | `~/.cache/dbx` | Update-check cache. |
| `DBX_POSTGRES_CONTAINER` | `postgres-dbx` | Container name for PG operations. |
| `DBX_MYSQL_CONTAINER` | `mysql-dbx` | Container name for MySQL operations. |
| `DBX_PG_PASSWORD` | `devpassword` | Initial password for auto-created PG container. |
| `DBX_MYSQL_PASSWORD` | `devpassword` | Initial password for auto-created MySQL container. |
| `DBX_BIND_ADDR` | `127.0.0.1` | Host bind address for the auto-managed containers. |
| `DBX_PG_HOST_PORT` | `5432` | Host port the auto-managed PG container publishes. Change it if `5432` is already taken by another Postgres on the host. |
| `DBX_MYSQL_HOST_PORT` | `3306` | Host port the auto-managed MySQL container publishes. Change it if `3306` is already taken by another MySQL on the host. |
| `DBX_POSTGRES_IMAGE` | unset | Override the auto-managed PG container image. Supports `{major}` / `{version}` template substitution. |
| `DBX_MYSQL_IMAGE` | unset | Override the auto-managed MySQL container image. Supports `{major}` / `{minor}` / `{version}` template substitution. |
| `DBX_RECREATE_CONTAINER` | unset | Set to `true` (or pass `--recreate-container`) to allow destroying user DBs when the container's version doesn't match the backup. |
| `DBX_BUILD_MISSING_IMAGES` | `true` | Set `false` to disable on-demand building of custom Postgres images (for third-party extensions) at restore time. Overrides `defaults.build_missing_images`. |
| `DBX_STRICT_IMPORT` | unset | Set `1` to make a MySQL restore abort on the first error instead of continuing (drops mysql's `--force`). |
| `DBX_AGE_RECIPIENTS` | `$DBX_CONFIG_DIR/age-recipients.txt` | Path to the age recipients file used for backup encryption. |
| `DBX_AGE_IDENTITY` | `~/.config/sops/age/keys.txt` | Path to the age identity (private key) file used to decrypt backups. |
| `DBX_SCRUB_SEED` | unset | Default env-var name supplying the deterministic seed for scrub transforms. |
| `DBX_TRANSFORM_*` | unset | Any var with this prefix is passed through to a `--transform` subprocess (which otherwise runs under `env -i`). |
| `DBX_NO_UPDATE_CHECK` | unset | Set to `1` to suppress update notices. |
| `DBX_REPO_SLUG` | `steig/dbx` | Override for forks. |
| `DBX_UPDATE_CHECK_INTERVAL` | `86400` | Seconds between update API hits. |
| `DBX_GPG_KEY` | unset | GPG key id for vault encryption. |

## Storage layout

```text
~/.data/dbx/<host>/<database>/<database>_<timestamp>.sql.zst[.age|.gpg]
~/.data/dbx/<host>/<database>/<database>_<timestamp>.sql.zst.meta.json
~/.config/dbx/config.json
~/.config/dbx/age-recipients.txt
~/.local/share/dbx/audit.log
~/.local/share/dbx/logs/                 # scheduled backup logs
~/.cache/dbx/latest-release              # update-check cache
```

## Audit log

Every operation appends a JSON line to `~/.local/share/dbx/audit.log`:

```json
{"timestamp":"2026-05-08T10:30:00Z","action":"backup","outcome":"success","db_host":"production","database":"myapp","file":"...","size":1234567,"duration_sec":45}
```

For restores, the `outcome` field reflects the *full* operation including post-restore hooks — a successful engine restore + failing hook records `failure`, not `success`.

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success. |
| `1` | Generic failure (most `die "..."` paths). |
| `2` | Pre-flight failure (missing config, missing dependency). |

Use `$?` after any `dbx` command, or check via shell `&&` / `\|\|` chains.

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
| [AGENTS.md](https://github.com/steig/dbx/blob/main/AGENTS.md) | Conventions, error-handling patterns, gotchas. |
| [CHANGELOG.md](https://github.com/steig/dbx/blob/main/CHANGELOG.md) | Release notes. |
| [tests/README.md](https://github.com/steig/dbx/blob/main/tests/README.md) | Test layout, debugging guide. |

PRs welcome — see `AGENTS.md` for the patterns the test suite enforces (set-e gotchas, BSD vs GNU sed, etc.).
