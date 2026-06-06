# Post-restore hooks

Declare SQL to run after every restore — scrub PII, repoint webhooks at localhost, disable cron rows, reset feature flags. Per database, optionally inherited per host.

For PII scrubbing specifically, see [PII scrub](scrub.md) — a manifest-based feature with schema drift detection. To have these hooks **drafted for you** — repoint URLs, disable cron/queues, clear token tables, framework-aware — see [AI restore prep](restore-prep.md).

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

## Behavior

- **Each hook runs in its own transaction.** psql `-1` for Postgres; `START TRANSACTION; … COMMIT;` wrap for MySQL. A failing hook rolls back atomically; previously-committed hooks stand.
- **Fail-fast.** The first failure aborts the restore. The partial DB is left in place for inspection and `dbx restore` exits non-zero. `notify_restore_failure` fires.
- **Host hooks run before per-database hooks**, in array order within each.
- **File paths** are absolute or resolved relative to the config file's directory.
- **MySQL DDL implicitly commits** — the transaction wrap only protects pure-DML hook scripts. Document this for hooks that mix DDL with DML.

## Variables

Inside every hook, six variables are bound. Postgres uses `:'name'` (quoted) or `:name` (unquoted); MySQL uses `@name`:

| Variable | Example value |
|---|---|
| `target_db` | `myapp_v1_20260523` |
| `source_host` | `production` |
| `source_db` | `myapp` |
| `backup_file` | `myapp_20260508_103000.sql.zst.age` (empty in `--hooks-only`) |
| `backup_timestamp` | `2026-05-08T10:30:00Z` (empty in `--hooks-only`) |
| `restored_at` | `2026-05-23T14:22:01Z` |

Example use — stamp provenance into the restored DB:

```sql
-- hooks/stamp-provenance.sql
CREATE TABLE IF NOT EXISTS _restore_provenance(
  restored_into text, source_host text, source_db text,
  backup_file text, backup_timestamp text, restored_at text
);
INSERT INTO _restore_provenance VALUES
  (:'target_db', :'source_host', :'source_db',
   :'backup_file', :'backup_timestamp', :'restored_at');
```

## Iterating on hook scripts

`--hooks-only --name <existing-db>` skips the engine restore and only runs hooks against an existing DB. Fast iteration loop while you author scrub scripts:

```bash
# First restore once to get a clone
dbx restore production/myapp/latest --name myapp_v1_20260523

# Now edit hooks/scrub-pii.sql and re-run hooks against the same clone
dbx restore production/myapp/latest --hooks-only --name myapp_v1_20260523
```

The DB must already exist in the appropriate container. dbx will not auto-provision one in `--hooks-only` mode.

## Skipping hooks for one run

```bash
dbx restore production/myapp/latest --no-post-restore
```

Useful when you want a raw clone for debugging — bypasses the mutation. The flag is mutually exclusive with `--hooks-only` (asking for both leaves nothing to do).

## Validation

`dbx config validate` resolves every hook `file` path and stat's it, flagging missing files or entries that have both `file` and `sql` (or neither). Catch broken hooks before a 2am scheduled run does.

## Shrinking the clone

The hooks pattern is also the easiest way to make a dev clone smaller — `TRUNCATE` noisy tables, delete rows outside a recent time window, prune inactive users. See [Subsetting dev clones](subsetting.md) for the patterns and gotchas.

## Ad-hoc file restores

When restoring a backup file directly (`dbx restore /tmp/backup.sql.zst --name foo`) without a `<host>/<db>` path, dbx doesn't know which host config to look at, so hooks are skipped with a `log_warn` line. If you need hooks to run on an ad-hoc restore, use `--hooks-only --name foo` afterwards.

## With `--transform` and `--into`

- **`--transform`** runs hooks normally after the streaming restore. The sanitization happens inside the pipeline; hooks see the post-transform, post-restore DB.
- **`--into <container>`** **skips post-restore hooks** with a `log_warn`. The hook runners (`pg_run_sql_stream` / `mysql_run_sql_stream`) target the managed `postgres-dbx` / `mysql-dbx` container by design, so running them after an `--into` restore would mutate the wrong DB. The `--into` flow is intended for streaming sanitization via `--transform`; if you need additional SQL to run against the external container, do it from your tool side after `dbx restore` returns.
