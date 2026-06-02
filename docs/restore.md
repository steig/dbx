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

If the default port is already taken on your host — e.g. you run a local Postgres on 5432 — set `DBX_POSTGRES_PORT` (or `DBX_MYSQL_PORT`) before the container is first created and connect on that port instead. The container-internal port is unchanged, so dbx's own backup/restore (which talk to the container over `docker exec`) work regardless.

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
| `--transform PATH` | Pipe the restore byte-stream through a host-side executable before any write to the target. Runs under `env -i` by default (cleaned env, only allowlisted vars + `DBX_TRANSFORM_*` passed through). See [Streaming sanitization](#streaming-sanitization-with-transform) below. |
| `--transform-inherit-env` | Inherit dbx's full environment into the `--transform` subprocess (legacy behavior). Requires `--transform`. |
| `--into NAME` | Restore into a named external docker container (e.g. a compose-managed postgres sidecar) instead of the managed `postgres-dbx`. Postgres only. See [Targeting an external container](#targeting-an-external-container-with-into) below. |

`--hooks-only` requires `--name <existing-db>` and is mutually exclusive with `--no-post-restore`, `--from-remote`, `--transform`, and `--into`.

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

## Streaming sanitization with `--transform`

When you need *unsanitized bytes never touch disk on the target* — for example, when handing a clone to a less-trusted environment that runs in a different container — pass `--transform=PATH` where PATH is any executable. The flow is:

```text
backup file → pg_restore -f - (emit plain SQL) → <your script> → psql -1 ON_ERROR_STOP=1
```

`<your script>` is run on the host with the raw plain-SQL byte stream on stdin and the sanitized stream on stdout. It can be a shell script, a small Go program, an awk one-liner — dbx doesn't care, it just `exec`'s it.

```bash
# A minimal sed-based sanitizer
cat > sanitize.sh <<'EOF'
#!/usr/bin/env bash
sed -E \
  -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/redacted@example.com/g' \
  -e 's/\+1[0-9]{10}/+15550000000/g'
EOF
chmod +x sanitize.sh

dbx restore production/myapp/latest --name myapp_review --transform=./sanitize.sh
```

**Atomicity (postgres):** the streamed input is wrapped in a single transaction (`psql -1 -v ON_ERROR_STOP=1`). If `sanitize.sh` exits non-zero mid-stream, psql sees EOF before COMMIT and rolls back. dbx then drops the target DB so no partial state remains. **MySQL is best-effort** — DDL implicitly commits in MySQL, so a transform script that fails partway through may leave the target DB in a partial state. dbx still drops it on failure, but the window of partial commit exists. Use postgres if you need atomicity.

**No post-flight verification.** dbx does not inspect the sanitized stream to confirm your script did the right thing — operator owns correctness. For declarative manifest-driven scrubbing with sniff verification, see [PII scrub](scrub.md) (a different feature with a different threat model).

**Constraints:** the source backup must be plain-SQL-readable (postgres custom-format dumps work — `pg_restore -f -` emits plain SQL). Binary formats incompatible with plain-SQL output will fail clearly.

!!! note "Transform scripts run with a cleaned environment by default"
    The script is `exec`'d under `env -i` with a minimal allowlist: `PATH`, `HOME`, `LANG`, `LC_*`, `TZ`, `USER`, `SHELL`, `TMPDIR`. dbx's credentials — `PGPASSWORD`, `MYSQL_PWD`, `DBX_SCRUB_SEED`, vault tokens, `AWS_*` — are **not** inherited by the script.

    **Explicit pass-through:** any environment variable starting with `DBX_TRANSFORM_` is passed through. Use this to hand the script project-specific values without exposing dbx's secrets:

    ```bash
    DBX_TRANSFORM_PROJECT=myapp DBX_TRANSFORM_SEED="$(pass show transform/seed)" \
        dbx restore prod/myapp/latest --transform=./sanitize.sh --name myapp_review
    ```

    **Opt-out:** pass `--transform-inherit-env` to inherit dbx's full environment (the original behavior — useful if you have a legacy script that reads `PGPASSWORD` directly, but audit it first).

## Targeting an external container with `--into`

By default, `dbx restore` lands data in dbx's managed `postgres-dbx` container. With `--into NAME` you can restore into a different running docker container — typically a compose sidecar that another tool (`boring`, `docker compose`, etc.) manages.

```bash
# Restore into a sidecar named `boring-content-infra-postgres-1`
dbx restore production/myapp/latest \
    --name myapp_review \
    --into boring-content-infra-postgres-1
```

dbx looks up the container with `docker inspect` and reads `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` from its env. Waits up to 30s for `pg_isready` to succeed inside it before starting the restore. Errors clearly when:

- The container isn't running
- The container has no `POSTGRES_USER` env (i.e. isn't a postgres-shaped container)
- Postgres in the container doesn't become ready within the timeout

**`--into` bypasses the [PII scrub gate](scrub.md).** dbx can't safely DROP a user-managed container's DB on a sniff failure, so the gate doesn't run. A loud warning is logged and a `scrub_bypass` audit record is written. The expectation is that you combine `--into` with `--transform` (where your script is the sanitization layer) — see the next section.

**Postgres only.** `--into` for MySQL is not supported yet. Use postgres if you need this.

## The combined invocation: `--transform` + `--into`

The boring v0.5 use case:

```bash
dbx restore production/myapp/latest \
    --name myapp_review \
    --transform=./sanitize.sh \
    --into boring-content-infra-postgres-1
```

This pipes the backup through `sanitize.sh` and lands the sanitized rows in the named sidecar — no unsanitized bytes on disk, no temp file the operator could read mid-restore, no managed-container clutter. The two flags compose; failures of either step trigger atomic rollback + drop.

## Container version handling

If the existing restore container's image doesn't match what's needed for the backup, dbx will:

- **Silently recreate** when the container has no user databases.
- **Fail with a list of restored DBs** and instructions to pass `--recreate-container` when there are user DBs to preserve.

This protects you from accidentally nuking a week's worth of restored clones because the container image needs to switch from `postgres:15` to `postgres:17`.

## Audit

The full restore (engine + post-restore hooks) is audited as a single line in `~/.local/share/dbx/audit.log`. Status is recorded **after** hooks complete, so a successful engine restore + failing hook records `failure` — the audit log never reports `success` on a tainted clone.
