# Backup

```bash
dbx backup production myapp                  # one DB on a configured host
dbx backup production                        # every DB configured for production
dbx backup -v production myapp               # verbose (passes through to pg_dump/mysqldump)
dbx backup --upload production myapp         # backup + push to cloud storage in one shot
```

Files land at `~/.data/dbx/<host>/<database>/<database>_<timestamp>.sql.zst[.age|.gpg]`.

## What dbx writes

For every backup:

- **The dump file** — `pg_dump --format=custom` for Postgres, `mysqldump` (two-pass schema + data) for MySQL, piped through `zstd` and optionally `age`/`gpg`.
- **A sibling `.meta.json`** with size, timestamp, encryption mode, SHA-256 checksum, source flavor + major version, and (Postgres) source extensions. Used at restore time to pick the right container image.
- **An audit log line** at `~/.local/share/dbx/audit.log`.

## Skipping table data

To dump schema only for noisy or huge tables (sessions, caches, logs), set `exclude_data` per database in [config](configuration.md):

```json
"databases": {
  "myapp": { "exclude_data": ["sessions", "cache", "logs"] }
}
```

`dbx analyze <host> <database>` walks you through this interactively, showing size per table.

## SSH tunnels

If a host has `ssh_tunnel` configured, dbx opens it before the dump runs and tears it down on exit. Tunnels are reused across `dbx` invocations in the same shell.

## Image selection

The backup container (`postgres-dbx` or `mysql-dbx`) is chosen from the source's flavor and major version:

| Source | Image |
|--------|-------|
| Postgres (no listed extensions) | `postgres:<major>-alpine` |
| Postgres + `vector` | `pgvector/pgvector:pg<major>` |
| Postgres + `postgis` | `postgis/postgis:<major>-3.5` |
| Postgres + `timescaledb` | `timescale/timescaledb:latest-pg<major>` |
| MySQL | `mysql:<major>.<minor>` |
| MariaDB | `mariadb:<major>.<minor>` |

Override with `DBX_POSTGRES_IMAGE` / `DBX_MYSQL_IMAGE` or `defaults.postgres_image` / `defaults.mysql_image` in config. Templates support `{major}` / `{minor}` / `{version}`:

```bash
export DBX_POSTGRES_IMAGE='myregistry/pg-everything:{major}'
```

### Limitations

- Postgres backups use the existing `postgres-dbx` client image. If you back up from a source whose major version is *newer* than `postgres-dbx`'s image, `pg_dump` will fail (older clients can't dump newer servers). Workaround: set `DBX_POSTGRES_IMAGE='postgres:N-alpine'` to the source version and let dbx recreate the container.
- The extension allowlist is intentionally narrow. For anything else (`pg_partman`, `pg_cron`, Citus, `pgaudit`, etc.), set `DBX_POSTGRES_IMAGE` explicitly.

## Multi-database backup

`dbx backup <host>` (no database argument) backs up every database configured for that host, one after another. Individual failures don't abort the rest — the command returns non-zero if any DB failed and prints a count at the end.
