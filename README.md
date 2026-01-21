# dbx

Database backup and restore utility. Uses Docker for pg_dump/mysqldump (no local DB install needed). Supports SSH tunnels for remote databases (AWS RDS, EC2, etc.).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/steig/dbx/main/install.sh | bash
```

Or clone manually:
```bash
git clone https://github.com/steig/dbx.git
export PATH="$PWD/dbx:$PATH"
```

### Requirements

- docker
- jq
- zstd
- ssh (for remote databases)

#### Optional

- libsecret-tools (Linux, for credential storage) or macOS Keychain
- pass (Linux, alternative credential storage)
- age (for age encryption)
- gpg (for GPG encryption)
- mc or aws (for S3/MinIO storage)
- gum (for TUI mode) - `brew install gum`

## Quick Start

```bash
# Create config
dbx config init
dbx config edit

# Store credentials securely
dbx vault set production

# Enable encryption (recommended)
dbx config init-encryption  # Sets up age encryption

# Backup
dbx backup production myapp

# Restore to local Docker container
dbx restore production/myapp/latest

# Verify backup integrity
dbx verify production/myapp/latest
```

## Commands

| Command | Description |
|---------|-------------|
| `dbx tui` | Interactive TUI mode (requires gum) |
| `dbx backup <host> <database> [--upload]` | Backup a database (optionally upload to S3) |
| `dbx restore <source> [--name N]` | Restore to local container |
| `dbx verify <backup-file>` | Verify backup checksum |
| `dbx query <host> [database]` | Interactive SQL shell |
| `dbx analyze <host> <database>` | Table size analysis |
| `dbx list [host] [database]` | List available backups |
| `dbx clean [--keep N]` | Remove old backups |
| `dbx vault set\|get\|delete\|list\|info` | Manage credentials |
| `dbx config init\|edit\|show` | Manage configuration |
| `dbx schedule add\|list\|remove` | Manage scheduled backups |
| `dbx storage list\|upload\|download\|sync` | Manage cloud storage |

## Configuration

Config lives at `~/.config/dbx/config.json`:

```json
{
  "defaults": {
    "encryption_type": "age",
    "age_recipients": "~/.config/dbx/age-recipients.txt",
    "age_identity": "~/.config/sops/age/keys.txt"
  },
  "hosts": {
    "production": {
      "type": "postgres",
      "user": "backup_user",
      "ssh_tunnel": {
        "jump_host": "bastion",
        "target_host": "db.internal",
        "target_port": 5432
      },
      "databases": {
        "myapp": {
          "exclude_data": ["sessions", "cache", "logs"]
        }
      }
    }
  },
  "storage": {
    "type": "s3",
    "s3": {
      "bucket": "backups",
      "endpoint": "http://minio:9000",
      "prefix": "dbx/",
      "access_key": "minioadmin",
      "secret_key_cmd": "dbx vault get s3-secret-key"
    }
  },
  "notifications": {
    "on_failure": true,
    "backends": {
      "slack": {
        "webhook_url_cmd": "dbx vault get slack-webhook"
      }
    }
  },
  "vault": {
    "backend": "auto"
  }
}
```

## How Restore Works

Restores go to **local Docker containers** that dbx manages automatically:

```bash
# Restore creates a new database in a local container
dbx restore production/myapp/latest

# Restored as: myapp_v1_20240115 (auto-named to avoid conflicts)
# Connect: psql -h localhost -p 5432 -U postgres myapp_v1_20240115
```

**Containers are auto-created** if they don't exist:
- `postgres-dbx` - PostgreSQL 17 with UTF-8 (port 5432)
- `mysql-dbx` - MySQL 8.0 (port 3306)

No setup required - just run `dbx restore` and it handles everything.

### Custom container names

Override with environment variables:
```bash
export DBX_POSTGRES_CONTAINER=my-postgres
export DBX_MYSQL_CONTAINER=my-mysql
```

## Encryption

dbx supports two encryption backends: **age** (recommended) and **GPG**.

### Age Encryption (Recommended)

```bash
# Initialize age encryption (generates keys if needed)
dbx config init-encryption

# Enable in config
dbx config edit
# Set: "defaults": { "encryption_type": "age" }
```

Age is modern, simple, and doesn't require a keyring. Keys are stored at:
- Identity (private): `~/.config/sops/age/keys.txt`
- Recipients (public): `~/.config/dbx/age-recipients.txt`

### GPG Encryption

```bash
# Set encryption passphrase
dbx vault set-encryption-key

# Enable in config
dbx config edit
# Set: "defaults": { "encryption_type": "gpg" }
```

GPG uses symmetric encryption with a passphrase stored in your system keychain.

**Important**: Store your keys/passphrase safely - you cannot recover backups without them!

## Credential Storage

dbx automatically selects the best available credential backend:

| Platform | Priority |
|----------|----------|
| macOS | Keychain |
| Linux (Desktop) | libsecret (GNOME Keyring) |
| Linux (Headless) | pass (password-store) |
| Fallback | GPG-encrypted file |

Override with config:
```json
{
  "vault": {
    "backend": "pass",
    "gpg_key": "your-gpg-key-id"
  }
}
```

Check current backend: `dbx vault info`

## Scheduled Backups

Schedule automatic backups using launchd (macOS) or systemd (Linux):

```bash
# Add a daily backup at 2 AM
dbx schedule add production myapp daily

# Add an hourly backup
dbx schedule add production myapp hourly

# Add a weekly backup on Sunday at 3 AM
dbx schedule add production myapp weekly@0:3

# List scheduled backups
dbx schedule list

# Remove a scheduled backup
dbx schedule remove production myapp
```

Logs are stored at `~/.local/share/dbx/logs/`.

## Cloud Storage (S3/MinIO)

Upload backups to S3-compatible storage:

```bash
# Upload after backup
dbx backup --upload production myapp

# Upload existing backup
dbx storage upload production/myapp/latest.sql.zst

# List remote backups
dbx storage list

# Download from remote
dbx storage download production/myapp/backup.sql.zst

# Sync all local backups to remote
dbx storage sync upload production

# Sync all remote backups to local
dbx storage sync download production
```

Requires `mc` (MinIO Client) or `aws` CLI.

## Notifications

Get notified on backup failures:

```json
{
  "notifications": {
    "on_failure": true,
    "on_success": false,
    "backends": {
      "slack": {
        "webhook_url_cmd": "dbx vault get slack-webhook"
      },
      "desktop": {
        "enabled": true
      },
      "email": {
        "to": "admin@example.com",
        "smtp_host": "smtp.example.com"
      },
      "command": {
        "on_failure": "terminal-notifier -title 'DBX' -message 'Backup failed'"
      }
    }
  }
}
```

## Backup Verification

Every backup includes a `.meta.json` file with SHA-256 checksum:

```bash
# Verify a backup
dbx verify /path/to/backup.sql.zst

# Interactive selection
dbx verify
```

Verification checks:
1. File exists and is readable
2. Can decrypt (if encrypted)
3. Checksum matches metadata

## Audit Logging

All operations are logged to `~/.local/share/dbx/audit.log`:

```json
{"timestamp":"2024-01-15T10:30:00Z","action":"backup","outcome":"success","db_host":"production","database":"myapp","file":"/path/to/backup.sql.zst","size":1234567,"duration_sec":45}
```

## Features

- **TUI Mode**: Interactive menu-driven interface with gum (`dbx tui`)
- **SSH Tunnels**: Auto-creates tunnel for remote DBs, cleans up on exit
- **Encryption**: Age or GPG encryption at rest
- **Auto Containers**: Creates local Docker DB containers on demand
- **DEFINER Strip**: MySQL views/triggers work locally (no permission errors)
- **Table Exclusions**: Dump schema but skip data for large/sensitive tables
- **Compression**: zstd compression for fast, small backups
- **Credential Storage**: macOS Keychain, libsecret, pass, or GPG file
- **Scheduled Backups**: launchd (macOS) or systemd (Linux) timers
- **Cloud Storage**: S3/MinIO upload and sync
- **Notifications**: Slack, email, desktop, or custom command
- **Verification**: SHA-256 checksums with metadata
- **Audit Logging**: JSON log of all operations

## Storage

```
~/.data/dbx/<host>/<database>/<database>_<timestamp>.sql.zst[.age|.gpg]
~/.data/dbx/<host>/<database>/<database>_<timestamp>.sql.zst.meta.json
~/.config/dbx/config.json
~/.local/share/dbx/audit.log
~/.local/share/dbx/logs/  (scheduled backup logs)
```

## License

MIT
