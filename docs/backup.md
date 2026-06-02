# Backup

```bash
dbx backup production myapp                  # one DB on a configured host
dbx backup production                        # every DB configured for production
dbx backup -v production myapp               # verbose (passes through to pg_dump/mysqldump)
dbx backup --upload production myapp         # backup + push to cloud storage in one shot
```

Files land at `~/.data/dbx/<host>/<database>/<database>_<timestamp>.sql.zst[.age|.gpg]`.

Uploads also happen automatically (without `--upload`) when `defaults.auto_upload` is `true`, or per-host `hosts.<host>.auto_upload` is `true` (the per-host value overrides the default). See [configuration](configuration.md).

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

dbx maps a source's flavor and major version to a container image as follows. **Timing differs by engine:** for **MySQL/MariaDB** the image is matched at *backup* time (where `mysqldump` grammar drift across majors matters). For **Postgres** the image is reused at backup time (`pg_dump` is forward-compatible — see [Limitations](#limitations)); the matching + build-on-demand below happens at *restore* time, when the dump is loaded back. The mapping is the same either way:

| Source | Image |
|--------|-------|
| Postgres (no extensions, or only bundled contrib like `btree_gin`, `pg_trgm`, `hstore`) | `postgres:<major>-alpine` |
| Postgres + `vector` | `pgvector/pgvector:pg<major>` |
| Postgres + `postgis` | `postgis/postgis:<major>-3.5` |
| Postgres + `timescaledb` | `timescale/timescaledb:latest-pg<major>` |
| Postgres + a buildable third-party extension (`pg_partman`, `pg_cron`, …) | `dbx-pg<major>:<hash>` (built on demand, see below) |
| MySQL | `mysql:<major>.<minor>` |
| MariaDB | `mariadb:<major>.<minor>` |

Override with `DBX_POSTGRES_IMAGE` / `DBX_MYSQL_IMAGE` or `defaults.postgres_image` / `defaults.mysql_image` in config. Templates support `{major}` / `{minor}` / `{version}`:

```bash
export DBX_POSTGRES_IMAGE='myregistry/pg-everything:{major}'
```

### Build-on-demand custom images

When a backup uses a third-party extension that has no off-the-shelf image
(`pg_partman`, `pg_cron`, `pgaudit`, …), dbx builds a small custom image on the
fly: `FROM postgres:<major>` (Debian) + the extension's PGDG package, tagged
`dbx-pg<major>:<hash>` where the hash is derived from the exact extension set.
The build runs **once** and is cached by tag, so subsequent restores of the same
extension set are network-free and reproducible. Extensions that need
`shared_preload_libraries` (e.g. `pg_cron`) get it baked into the image.

- **Toggle:** auto-build is on by default. Disable with
  `defaults.build_missing_images: false` or `DBX_BUILD_MISSING_IMAGES=false`;
  dbx then fails with an instruction to pre-build instead of building inline.
- **Pre-warm** (recommended for scheduled jobs, so a restore never blocks on a
  build): `dbx build-image --from-backup <file>` or
  `dbx build-image pg<MAJOR> --extensions pg_partman,pg_cron`.
- **Built-in registry:** `pg_partman`, `pg_cron`, `pgaudit`, `hypopg`,
  `pg_repack`, `pg_hint_plan`, `hll`. Add more via `defaults.extension_packages`
  (see [configuration](configuration.md)) — the key is the extension name, the
  value is the PGDG package suffix (`postgresql-<major>-<suffix>`).

### Limitations

- Postgres backups use the existing `postgres-dbx` client image. If you back up from a source whose major version is *newer* than `postgres-dbx`'s image, `pg_dump` will fail (older clients can't dump newer servers). Workaround: set `DBX_POSTGRES_IMAGE='postgres:N-alpine'` to the source version and let dbx recreate the container.
- An extension that dbx neither bundles, has a specialized image for, nor can build (not in the registry or `defaults.extension_packages`) still fails with a hint — add it to `defaults.extension_packages` or set `DBX_POSTGRES_IMAGE` explicitly.
- dbx won't auto-combine a specialized extension (`vector`/`postgis`/`timescaledb`) with a build-on-demand one in a single image. Build one image with both and point `DBX_POSTGRES_IMAGE` at it.

## Multi-database backup

`dbx backup <host>` (no database argument) backs up every database configured for that host, one after another. Individual failures don't abort the rest — the command returns non-zero if any DB failed and prints a count at the end.
