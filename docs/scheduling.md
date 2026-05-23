# Scheduled backups

launchd (macOS) or systemd user timers (Linux):

```bash
dbx schedule add production myapp daily          # 2am daily
dbx schedule add production myapp daily@5        # 5am daily
dbx schedule add production myapp hourly
dbx schedule add production myapp weekly@0:3     # Sun 3am (0..6 = Sun..Sat)
dbx schedule add production myapp '*/15 4 * * 1-5'  # raw cron syntax

dbx schedule list
dbx schedule run production myapp                # one-shot manually
dbx schedule remove production myapp
```

Logs at `~/.local/share/dbx/logs/`.

## Schedule syntax

| Form | Means |
|------|-------|
| `hourly` | `0 * * * *` |
| `daily` | `0 2 * * *` |
| `daily@N` | `0 N * * *` |
| `weekly` | `0 2 * * 0` (Sun 2am) |
| `weekly@D` | `0 2 * * D` |
| `weekly@D:H` | `0 H * * D` |
| Raw cron | passed through unchanged |

## What gets scheduled

`dbx schedule add` writes a launchd `.plist` (macOS) or systemd `.timer` + `.service` (Linux user-mode) that runs `dbx backup <host> <database>` at the configured cadence. The scheduled run inherits your shell `PATH` via `dbx`'s installed location.

Notifications fire from inside the scheduled run, so failures show up in Slack/desktop/email even when you're not watching.
