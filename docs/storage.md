# Cloud storage (S3 / MinIO)

dbx talks to S3, MinIO, Cloudflare R2, Backblaze B2, or anything S3-compatible. Uses `mc` (MinIO Client) if available, falling back to `aws` CLI.

## Setting it up

Easiest path is the [interactive wizard](wizards.md#dbx-storage-add):

```bash
dbx storage add
```

It validates the config with a real upload-list-download-delete round-trip before committing — catches the read-but-no-write IAM case a plain credentials check would miss.

Or hand-edit `config.json`:

```json
{
  "storage": {
    "type": "s3",
    "s3": {
      "bucket": "backups",
      "endpoint": "http://minio:9000",
      "prefix": "dbx/",
      "access_key": "minioadmin",
      "secret_key_cmd": "dbx vault get s3-secret-key"
    }
  }
}
```

## Multiple named backends

dbx can hold several storage backends at once — e.g. a Cloudflare R2 archive and a local MinIO — under a top-level `storages` map, with `defaults.storage` naming the one used when you don't pick explicitly. Each `dbx storage add` prompts for a name and stores its secret in the vault under `s3-secret-key-<name>`.

```json
{
  "storages": {
    "r2":    { "type": "s3", "s3": { "endpoint": "https://<acct>.r2.cloudflarestorage.com", "region": "auto", "bucket": "backups", "prefix": "dbx/", "access_key": "…" } },
    "minio": { "type": "s3", "s3": { "endpoint": "http://10.0.0.88:9000", "bucket": "backups", "access_key": "…" } }
  },
  "defaults": { "storage": "r2" }
}
```

Pick a backend per operation with `--upload=<name>` (backup) or `--storage <name>` (restore and the `dbx storage` subcommands); omit it to use `defaults.storage`. A host can pin its own target with `"upload_storage": "<name>"`. `dbx storage info` lists every configured backend and marks the default.

The legacy single `storage` block above still works unchanged and is treated as the default when no `storages` map is present — no migration needed.

## Daily commands

```bash
dbx backup --upload production myapp             # backup + push to the default backend
dbx backup --upload=r2 production myapp          # push to a specific backend
dbx storage list --storage minio                 # list a specific backend
dbx storage upload production/myapp/latest.sql.zst
dbx storage download production/myapp/backup.sql.zst
dbx storage sync upload production               # all backups for a host
dbx storage info                                  # show all backends + the default
```

## Auto-upload on every backup

Flip `defaults.auto_upload` (or per-host `auto_upload`) in config:

```json
{ "defaults": { "auto_upload": true } }
```

Equivalent to passing `--upload` to every `dbx backup` invocation. Useful for scheduled backups.

## Restoring directly from cloud storage

You don't need to `dbx storage download` first. Use `--from-remote` on restore:

```bash
dbx restore --from-remote production/myapp/latest
dbx restore --storage r2 --from-remote production/myapp/latest   # pull from a specific backend
dbx restore s3://production/myapp/latest --name myapp_review
```

See [Restore → Restoring from cloud storage](restore.md#restoring-from-cloud-storage).
