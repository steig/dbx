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

## Declarative schedules in `config.json`

Schedules can also be declared in `config.json` and reconciled with `dbx schedule sync`:

```jsonc
{
  "hosts": { ... },
  "schedules": [
    { "host": "production", "database": "myapp",   "when": "daily@5" },
    { "host": "production", "database": "billing", "when": "weekly@1:3" },
    { "host": "staging",    "database": "myapp",   "when": "*/15 4 * * 1-5" }
  ]
}
```

`dbx schedule sync` diffs the installed units against `config.schedules[]` and prints a plan:

```
$ dbx schedule sync
Schedule sync plan

  + install  production/billing @ weekly@1:3
  ~ update   production/myapp → daily@5
  ! orphan   staging/x @ daily@7 (installed but not in config)
  = same     production/audit @ daily

  (read-only preview — the write path lands in a follow-up PR)
```

Today this is a **read-only preview**: it tells you what `sync` *would* do, but doesn't yet make the changes. The write path (with `--force` for orphan deletion) ships in a follow-up release. In the meantime, `dbx schedule add` / `remove` continue to be the way to actually change installed state.

`dbx config validate` also reports drift between `config.schedules[]` and the installed units, so a config-vs-state mismatch can be caught in CI.

**Source of truth.** `config.json` is intended to be canonical: a checked-in `config.json` + `dbx schedule sync` reproduces the same scheduled jobs on any machine. The legacy `dbx schedule add` flow (imperative, doesn't touch config) still works for users who don't want to manage schedules declaratively.

**Schedule expression form.** Use the same friendly forms (`hourly`, `daily@5`, `weekly@1:3`) or raw cron as `dbx schedule add` accepts. The literal expression is stamped into the plist/timer at install time (as a `DbxScheduleExpression` key / header comment) so `sync` can read it back without reverse-parsing cron.
