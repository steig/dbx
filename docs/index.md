# dbx

> A pragmatic database backup and restore CLI for PostgreSQL and MySQL. No local DB install. SSH tunnels for remote production. Encryption at rest. S3-compatible cloud storage. Scheduled backups via launchd or systemd. macOS and Linux.

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

## Why dbx?

Raw `pg_dump` and `mysqldump` are fine — until they're not. dbx wraps them with the operational glue you'd otherwise build yourself:

- **No local Postgres or MySQL** — dump and restore happen inside official Docker images. Your laptop stays clean.
- **SSH tunnels handled** — remote DBs in private VPCs (RDS, EC2 internal hosts) just work. Tunnels are reused across runs and torn down on exit.
- **Restore to a fresh local DB by default** — `dbx restore prod/myapp/latest` creates a versioned, sandboxed copy in a managed Docker container. Production stays untouched.
- **Encryption at rest** — backups can be `age`-encrypted with one command. Keys live in your sops directory.
- **Credentials in the system vault** — no plaintext passwords in shell history or config files. macOS Keychain, GNOME libsecret, `pass`, or a GPG-encrypted file as fallback.
- **Post-restore hooks** — declare SQL to scrub PII or repoint webhooks; dbx runs it automatically after every restore, in a transaction.
- **One config file, JSON** — version-controllable, tab-completable, no surprises.

Not for you if: you need streaming/PITR replication, point-in-time recovery from WAL, or anything beyond logical dumps.

## Get started

1. [Install](install.md) dbx and its few dependencies
2. Run through the [quick start](quick-start.md)
3. Read about [configuration](configuration.md), or just use the [interactive wizards](wizards.md)

## What's new in v0.9.0

- [Restore directly from S3 / MinIO](restore.md#restoring-from-cloud-storage) with `--from-remote` or `s3://`
- [Interactive `dbx host add` and `dbx storage add`](wizards.md) wizards
- [Post-restore SQL hooks](post-restore-hooks.md) — scrub PII, repoint webhooks automatically

See the full [changelog](https://github.com/steig/dbx/blob/main/CHANGELOG.md) on GitHub.
