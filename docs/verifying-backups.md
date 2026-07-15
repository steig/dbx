# Verifying backups are restorable

`dbx verify` answers one question: *is this file the same bytes dbx wrote?* It
recomputes the SHA-256 and compares it to the `.meta.json` checksum. That proves
the archive is **intact** — it does not prove the archive is **restorable**. A
dump can be byte-perfect and still fail to load (a truncated dump that was
checksummed after truncation, an extension the target lacks, a custom-format
file `pg_restore` chokes on).

The only way to know a backup restores is to restore it. This page documents a
**restore drill**: restore a recent backup into a throwaway database, assert it
actually loaded, then drop it. Run it on a schedule and you have evidence — not
hope — that your backups are good.

!!! tip "Why a drill, not just a checksum"
    Checksum verification is cheap and catches bit-rot and truncated uploads,
    so keep running `dbx verify`. The restore drill is the layer above it: it
    exercises the actual restore path end to end. Both together give you
    integrity *and* restorability.

## The drill, step by step

The drill restores into dbx's managed `postgres-dbx` container under a unique
throwaway name, checks that tables and rows landed, then drops the database.
Nothing touches your source, and the throwaway DB is gone at the end.

```bash
#!/usr/bin/env bash
# restore-drill.sh — prove production/myapp/latest restores cleanly.
set -euo pipefail

SOURCE="production/myapp/latest"     # <host>/<database>/<selector>
DRILL_DB="restoredrill_$(date +%Y%m%d_%H%M%S)"   # unique throwaway name
PGPASS="${DBX_PG_PASSWORD:-devpassword}"          # managed-container password

cleanup() {
  # Drop the throwaway DB whether the drill passed or failed.
  docker exec -e PGPASSWORD="$PGPASS" postgres-dbx \
    psql -U postgres -d postgres \
    -c "DROP DATABASE IF EXISTS \"$DRILL_DB\" WITH (FORCE);" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# 1. Restore the latest backup into the throwaway DB.
#    dbx verifies the SHA-256 before importing (unless --skip-verify),
#    so a corrupt archive fails here before any rows load.
dbx restore "$SOURCE" --name "$DRILL_DB"

# 2. Assert the restore actually loaded data: at least one user table.
tables=$(docker exec -e PGPASSWORD="$PGPASS" postgres-dbx \
  psql -U postgres -d "$DRILL_DB" -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema');")

if [[ "${tables:-0}" -lt 1 ]]; then
  echo "RESTORE DRILL FAILED: restored DB has no user tables." >&2
  exit 1
fi

echo "RESTORE DRILL PASSED: $SOURCE restored into $DRILL_DB with $tables table(s)."
```

What each step buys you:

- **Step 1** runs the real restore code path, including the pre-import SHA-256
  check. A corrupted archive, an unreadable custom-format dump, or a missing
  extension fails here — exactly the failures a checksum-only check misses.
- **Step 2** confirms the dump *had content* and `pg_restore` ran it: an empty
  database means the restore did nothing useful even if it exited cleanly.
- **`trap cleanup EXIT`** drops the throwaway DB on success *or* failure, so the
  drill leaves no clutter in `postgres-dbx`.

### A stronger assertion: row counts

"At least one table" is the cheapest signal. If you know your schema, assert on a
table you expect to be non-empty — a far stronger restorability check:

```bash
users=$(docker exec -e PGPASSWORD="$PGPASS" postgres-dbx \
  psql -U postgres -d "$DRILL_DB" -tAc "SELECT count(*) FROM users;")
[[ "${users:-0}" -ge 1 ]] || { echo "DRILL FAILED: users table empty" >&2; exit 1; }
echo "users rows restored: $users"
```

You can also list the relations the way `\dt` does, to eyeball that the expected
tables exist:

```bash
docker exec -e PGPASSWORD="$PGPASS" postgres-dbx \
  psql -U postgres -d "$DRILL_DB" -c '\dt'
```

## MySQL

For a MySQL source, the managed container is `mysql-dbx` (root user, password
`devpassword` or `DBX_MYSQL_PASSWORD`). The shape is identical — only the client
and the cleanup statement change:

```bash
DRILL_DB="restoredrill_$(date +%Y%m%d_%H%M%S)"
MYSQLPASS="${DBX_MYSQL_PASSWORD:-devpassword}"

cleanup() {
  docker exec -e MYSQL_PWD="$MYSQLPASS" mysql-dbx \
    mysql -u root -e "DROP DATABASE IF EXISTS \`$DRILL_DB\`;" >/dev/null 2>&1 || true
}
trap cleanup EXIT

dbx restore "production/myapp/latest" --name "$DRILL_DB"

tables=$(docker exec -e MYSQL_PWD="$MYSQLPASS" mysql-dbx \
  mysql -u root -NB -e \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema = '$DRILL_DB';")

[[ "${tables:-0}" -ge 1 ]] || { echo "DRILL FAILED: no tables in $DRILL_DB" >&2; exit 1; }
echo "RESTORE DRILL PASSED: $tables table(s) in $DRILL_DB."
```

## Isolating the drill in its own container with `--into`

The drill above restores into the shared `postgres-dbx` container, which is fine
— it uses a unique name and drops it afterward. If you'd rather keep drill data
completely separate from your other restored clones, run a throwaway postgres
container yourself and point the drill at it with
[`--into`](restore.md#targeting-an-external-container-with-into):

```bash
# Spin up a disposable postgres just for this drill.
# POSTGRES_USER must be set explicitly: --into reads it from the
# container's env, and the official image does not export a default.
docker run -d --rm --name drill-pg \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=devpassword \
  postgres:17-alpine

# Wait for it, then restore into it. dbx reads POSTGRES_USER/PASSWORD/DB
# from the container's env and waits for pg_isready before loading.
dbx restore production/myapp/latest --name drilldb --into drill-pg

docker exec drill-pg psql -U postgres -d drilldb -tAc \
  "SELECT count(*) FROM information_schema.tables
   WHERE table_schema NOT IN ('pg_catalog','information_schema');"

# Tear the whole container down — nothing to clean up inside it.
docker rm -f drill-pg
```

`--into` requires the container to be **running already** (dbx will not create
it) and is **postgres only**. Note that `--into` bypasses the
[PII scrub gate](scrub.md) and skips configured
[post-restore hooks](post-restore-hooks.md) — neither matters for a drill that
you immediately throw away, but see [Restore](restore.md) for the full
semantics.

!!! warning "Restoring a `safety: prod` source"
    If the drill's source host is marked `safety: prod` in config, a
    `--into` restore is refused outright (raw production data is not allowed to
    land in an externally-managed container). To run the drill against a prod
    source anyway, restore into the managed `postgres-dbx` container instead (the
    first recipe on this page) — or, if you specifically need `--into`, set
    `DBX_ALLOW_PROD_RESTORE=1` and keep the target container local and
    ephemeral. Either way, the drill data is dropped at the end.

## Running the drill on a schedule

A backup you never test is a backup you don't know you have. Wire the drill
script into cron (or launchd / systemd) so it runs after your backup schedule:

```cron
# Run the restore drill every morning at 06:30, after the nightly backup.
30 6 * * *  /path/to/restore-drill.sh >> ~/.local/share/dbx/restore-drill.log 2>&1
```

The script exits non-zero on failure, so any job runner that alerts on non-zero
exit (cron MAILTO, a CI cron, a systemd `OnFailure=`) will tell you the moment a
backup stops being restorable — which is exactly when you want to know, not the
day you actually need the restore.

## See also

- [Restore](restore.md) — all restore flags, `--into`, `--transform`, container handling.
- [Reference](reference.md) — `dbx verify` and the full command list.
- [Scheduled backups](scheduling.md) — scheduling the backups this drill validates.
