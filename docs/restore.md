# Restore

Restores never touch your source database. They go to **local Docker containers** that dbx auto-manages:

```bash
dbx restore production/myapp/latest
# → restored as: myapp_v1_20260508 (auto-named to avoid conflicts)
# → connect:    psql -h 127.0.0.1 -p 5432 -U postgres myapp_v1_20260508
#               (default password: devpassword — see env vars below)
```

| Container | Image | Default port |
|-----------|-------|--------------|
| `postgres-dbx` | `postgres:17-alpine` (UTF-8) | 5432 |
| `mysql-dbx` | `mysql:8.0` | 3306 |

Both bind to `127.0.0.1` only by default so dev databases aren't reachable from the LAN with the default password. Set `DBX_BIND_ADDR=0.0.0.0` before first run if you need remote access. Containers are also created with `--add-host=host.docker.internal:host-gateway` so SSH-tunnel mode works on Linux as well as macOS.

## Naming

If you don't pass `--name`, dbx generates `<db>_v<N>_<YYYYMMDD>` and bumps `<N>` until it finds an unused name in both PG and MySQL containers. Pass `--name X` to override.

## Flags

| Flag | Effect |
|------|--------|
| `--name N` | Target DB name (default: auto-versioned). |
| `--recreate-container` | Allow destroying user DBs when the container's image doesn't match what the backup needs (see [image selection](backup.md#image-selection)). |
| `--from-remote PATH` | Fetch the backup from cloud storage instead of looking locally. See below. |
| `--keep-download` | Keep the locally-staged copy after a `--from-remote` restore succeeds (default: deleted). |
| `--no-post-restore` | Skip configured [post-restore hooks](post-restore-hooks.md) for this run. |
| `--hooks-only` | Skip the engine restore; only run configured hooks against the DB named by `--name`. Useful for iterating on hook scripts. |

`--hooks-only` requires `--name <existing-db>` and is mutually exclusive with `--no-post-restore` and `--from-remote`.

## Restoring from cloud storage

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

## Container version handling

If the existing restore container's image doesn't match what's needed for the backup, dbx will:

- **Silently recreate** when the container has no user databases.
- **Fail with a list of restored DBs** and instructions to pass `--recreate-container` when there are user DBs to preserve.

This protects you from accidentally nuking a week's worth of restored clones because the container image needs to switch from `postgres:15` to `postgres:17`.

## Audit

The full restore (engine + post-restore hooks) is audited as a single line in `~/.local/share/dbx/audit.log`. Status is recorded **after** hooks complete, so a successful engine restore + failing hook records `failure` — the audit log never reports `success` on a tainted clone.
