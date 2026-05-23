---
hide:
  - navigation
  - toc
---

<div class="dbx-hero" markdown>

# dbx

<p class="dbx-hero__tagline">
A pragmatic database backup and restore CLI for PostgreSQL and MySQL.<br>
No local DB install. SSH tunnels. Encryption at rest. S3-compatible storage. Scheduled backups.
</p>

<div class="dbx-hero__buttons" markdown>
[Get started :material-arrow-right:](install.md){ .md-button .md-button--primary }
[View on GitHub :material-github:](https://github.com/steig/dbx){ .md-button }
</div>

</div>

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

Raw `pg_dump` and `mysqldump` are fine — until they're not. dbx wraps them with the operational glue you'd otherwise build yourself.

<div class="grid cards" markdown>

-   :fontawesome-brands-docker:{ .lg .middle } **No local Postgres or MySQL**

    ---

    Dumps and restores happen inside official Docker images. Your laptop stays clean.

-   :material-vector-link:{ .lg .middle } **SSH tunnels handled**

    ---

    Remote DBs in private VPCs (RDS, EC2 internal hosts) just work. Tunnels are reused across runs and torn down on exit.

-   :material-flask-outline:{ .lg .middle } **Restore to a fresh local DB**

    ---

    `dbx restore prod/myapp/latest` creates a versioned, sandboxed copy in a managed Docker container. Production stays untouched.

-   :material-lock-outline:{ .lg .middle } **Encryption at rest**

    ---

    Backups can be `age`-encrypted with one command. Keys live in your sops directory.

-   :material-key-chain:{ .lg .middle } **Credentials in the system vault**

    ---

    No plaintext passwords in shell history or config files. macOS Keychain, GNOME libsecret, `pass`, or a GPG-encrypted file as fallback.

-   :material-database-cog:{ .lg .middle } **Post-restore hooks**

    ---

    Declare SQL to scrub PII or repoint webhooks; dbx runs it automatically after every restore, in a transaction.

-   :material-cloud-upload-outline:{ .lg .middle } **S3 / MinIO / R2**

    ---

    Push every backup to cloud storage. Restore directly from S3 with `--from-remote` — no two-step download dance.

-   :material-clock-outline:{ .lg .middle } **Scheduled backups**

    ---

    launchd on macOS, systemd timers on Linux. One command to schedule, log everything.

</div>

!!! info "Not for you if"
    You need streaming/PITR replication, point-in-time recovery from WAL, or anything beyond logical dumps.

## What's new in v0.9.0

-   **[Restore directly from S3 / MinIO](restore.md#restoring-from-cloud-storage)** with `--from-remote` or `s3://`
-   **[Interactive wizards](wizards.md)** for adding hosts and configuring cloud storage
-   **[Post-restore SQL hooks](post-restore-hooks.md)** — scrub PII, repoint webhooks, fail-fast on errors

See the full [changelog](https://github.com/steig/dbx/blob/main/CHANGELOG.md) on GitHub.

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/steig/dbx/main/install.sh | bash
```

Then walk through the [quick start](quick-start.md) — five commands to your first backup and restore.
