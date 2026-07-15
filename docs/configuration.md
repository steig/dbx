# Configuration

Config lives at `~/.config/dbx/config.json`. Minimal example:

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
        "myapp": { "exclude_data": ["sessions", "cache", "logs"] }
      }
    }
  },
  "defaults": {
    "encryption_type": "age",
    "keep_backups": 10
  }
}
```

Validate after edits with `dbx config validate`.

## Full reference

```json
{
  "defaults": {
    "encryption_type": "age",
    "age_recipients": "~/.config/dbx/age-recipients.txt",
    "age_identity": "~/.config/sops/age/keys.txt",
    "compression_level": 3,
    "keep_backups": 10,
    "auto_upload": false,
    "backup_globals": false,
    "storage": "r2",
    "definer_handling": "strip",
    "build_missing_images": true,
    "extension_packages": {
      "pg_cron": { "package": "cron", "preload": "pg_cron" },
      "my_ext": "myext"
    }
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
          "exclude_data": ["sessions", "cache", "logs"],
          "parallel_jobs": 4
        }
      }
    }
  },
  "vault": {
    "backend": "auto",
    "gpg_key": "your-gpg-key-id"
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
  "//storages": "Optional: multiple named backends instead of the single `storage` above. defaults.storage names the default; a host may set upload_storage. See storage.md.",
  "storages": {
    "r2":    { "type": "s3", "s3": { "endpoint": "https://<acct>.r2.cloudflarestorage.com", "region": "auto", "bucket": "backups", "access_key": "…" } },
    "minio": { "type": "s3", "s3": { "endpoint": "http://10.0.0.88:9000", "bucket": "backups", "access_key": "…" } }
  },
  "notifications": {
    "enabled": true,
    "on": "failure",
    "backends": ["slack", "desktop"],
    "slack": { "webhook_url_cmd": "dbx vault get slack-webhook" },
    "email": { "to": "admin@example.com", "smtp_host": "smtp.example.com" },
    "command": { "on_failure": "terminal-notifier -title DBX -message 'Backup failed'" }
  }
}
```

## Image-build defaults

These control [build-on-demand custom Postgres images](backup.md#build-on-demand-custom-images) for third-party extensions.

| Key | Type | Notes |
|-----|------|-------|
| `build_missing_images` | bool | Default `true`. When a restore needs a custom image that isn't built yet, build it inline. Set `false` (or `DBX_BUILD_MISSING_IMAGES=false`) to instead fail with a `dbx build-image` hint — useful to keep scheduled jobs from ever blocking on a build. |
| `extension_packages` | object | Escape hatch extending the built-in extension registry. Key = extension name. Value = the PGDG package suffix string (`postgresql-<major>-<suffix>`), or an object `{ "package": "<suffix>", "preload": "<lib>" }` when the extension needs `shared_preload_libraries`. Entries override built-ins of the same name. |

## Per-host options

| Key | Type | Notes |
|-----|------|-------|
| `type` | `"postgres"` \| `"mysql"` \| `"mariadb"` | Required. Drives engine adapter selection. `mariadb` uses the MySQL adapter (server flavor is auto-detected, so `mysql` works for MariaDB too). |
| `user` | string | DB role used for the dump. |
| `host`, `port` | string, int | Direct-connect alternatives to `ssh_tunnel`. |
| `ssh_tunnel.jump_host` | string | `ssh` alias or `user@host`. |
| `ssh_tunnel.target_host`, `target_port` | | DB host as seen from the bastion. |
| `password` | string | **Plaintext fallback** — prefer the vault (`dbx vault set <host>`) or `password_cmd`. dbx warns if this is set. |
| `password_cmd` | string | Shell command whose stdout is the password. |
| `definer_handling` | `"strip"` \| `"keep"` \| `"rewrite"` | MySQL only. Default `strip` removes `DEFINER` clauses so restores don't fail on missing users. |
| `safety` | `"prod"` \| `"stage"` \| `"local"` | Risk tier for the host (absent defaults to `local`). `prod` opens `dbx query` sessions read-only and blocks `dbx restore --into` from that source. |
| `scrub` | object | PII scrub settings. `scrub.manifest` is the path to the [scrub](scrub.md) manifest; `scrub.required` (bool) makes restores from this host run the scrub gate. |
| `backup_globals` | bool | Postgres only. When `true`, [`dbx backup`](backup.md#roles-grants-and-globals) also captures cluster roles/grants/tablespaces into a `<backup>.globals.sql` sidecar (`pg_dumpall --globals-only --no-role-passwords`). Default `false`. Per-host overrides the global `defaults.backup_globals`; the `--globals` / `--no-globals` flag overrides both. Apply at restore with `dbx restore --with-globals`. |
| `databases` | object | Map of database name → per-DB options. |
| `post_restore` | array | Host-level [post-restore hooks](post-restore-hooks.md) — run for every DB on this host. |

## Per-database options

| Key | Type | Notes |
|-----|------|-------|
| `exclude_data` | array of strings | Tables to dump schema-only (data omitted). |
| `exclude_dependents` | bool | Postgres only. When `exclude_data` empties a table that other (kept) tables reference by foreign key, those references dangle and the restore fails FK validation. With `exclude_dependents: true`, dbx cascades the exclusion to the referencing tables (transitively) so the dump stays consistent. Default `false` — dbx instead **warns** at backup time, listing each `child → parent` that would dangle. Also settable globally as `defaults.exclude_dependents`. |
| `parallel_jobs` | int | Passed to `pg_dump --jobs`. |
| `post_restore` | array | Per-DB [post-restore hooks](post-restore-hooks.md). |
