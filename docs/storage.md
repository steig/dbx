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

## Daily commands

```bash
dbx backup --upload production myapp             # backup + push in one shot
dbx storage upload production/myapp/latest.sql.zst
dbx storage list
dbx storage download production/myapp/backup.sql.zst
dbx storage sync upload production               # all backups for a host
dbx storage sync download production
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
dbx restore s3://production/myapp/latest --name myapp_review
```

See [Restore → Restoring from cloud storage](restore.md#restoring-from-cloud-storage).
