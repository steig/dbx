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
- libsecret-tools (Linux, for credential storage) or macOS Keychain

## Quick Start

```bash
# Create config
dbx config init
dbx config edit

# Store credentials securely
dbx vault set production

# Enable encryption (recommended)
dbx vault set-encryption-key
# Then set "encryption": true in config

# Backup
dbx backup production myapp

# Restore to local Docker container
dbx restore production/myapp/latest
```

## Commands

| Command | Description |
|---------|-------------|
| `dbx backup <host> <database>` | Backup a remote database |
| `dbx restore <source> [--name N]` | Restore to local container |
| `dbx query <host> [database]` | Interactive SQL shell |
| `dbx analyze <host> <database>` | Table size analysis |
| `dbx list [host] [database]` | List available backups |
| `dbx clean [--keep N]` | Remove old backups |
| `dbx vault set\|get\|delete\|list` | Manage credentials |
| `dbx config init\|edit\|show` | Manage configuration |

## Configuration

Config lives at `~/.config/dbx/config.json`:

```json
{
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

Enable encryption at rest for all backups:

```bash
# Set encryption passphrase (stored in Keychain/secret-tool)
dbx vault set-encryption-key

# Enable in config
dbx config edit
# Set "encryption": true in defaults section
```

Backups are encrypted with AES-256 via GPG. The passphrase is stored securely in your system keychain.

**Important**: Store your passphrase safely - you cannot recover backups without it!

## Features

- **SSH Tunnels**: Auto-creates tunnel for remote DBs, cleans up on exit
- **Encryption**: AES-256 encryption at rest (optional, via GPG)
- **Auto Containers**: Creates local Docker DB containers on demand
- **DEFINER Strip**: MySQL views/triggers work locally (no permission errors)
- **Table Exclusions**: Dump schema but skip data for large/sensitive tables
- **Compression**: zstd compression for fast, small backups
- **Credential Storage**: macOS Keychain or Linux secret-tool (libsecret)

## Storage

```
~/.data/dbx/<host>/<database>/<database>_<timestamp>.sql.zst
~/.config/dbx/config.json
```

## License

MIT
