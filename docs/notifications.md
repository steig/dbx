# Notifications

Slack, desktop, email, or any custom command. Configured under `notifications` in `config.json`:

```json
{
  "notifications": {
    "enabled": true,
    "on": "failure",
    "backends": ["slack", "desktop"],
    "slack": { "webhook_url_cmd": "dbx vault get slack-webhook" },
    "command": { "on_failure": "terminal-notifier -title DBX -message 'Backup failed'" }
  }
}
```

`on` accepts `failure`, `success`, or `all`.

## Backends

| Backend | Config key | Notes |
|---------|-----------|-------|
| Slack | `slack.webhook_url` / `slack.webhook_url_cmd` | Incoming webhook URL. Prefer the `_cmd` form (vault). |
| Desktop | (auto) | macOS uses `osascript`; Linux uses `notify-send`. |
| Email | `email.to`, `email.smtp_host`, `email.smtp_port`, `email.from` | Uses `sendmail` if available, otherwise `msmtp`. |
| Command | `command.on_failure` / `command.on_success` | Shell template; runs with backup metadata in env vars (`DBX_NOTIFY_TITLE`, `DBX_NOTIFY_MESSAGE`, etc.). |

## Events

| Event | Fires on |
|-------|----------|
| `notify_backup_success` | `dbx backup` completes without error. |
| `notify_backup_failure` | `dbx backup` exits non-zero. |
| `notify_restore_success` | `dbx restore` completes including all post-restore hooks. |
| `notify_restore_failure` | Post-restore hook failure (engine-restore failures are pre-existing and currently silent at the notifier). |

The `on` filter applies across all events.
