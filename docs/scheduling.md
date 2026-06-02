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

Actions: `add`, `remove` (aliases `rm` / `delete`), `list` (alias `ls`), `run`, and `sync`. (`run-job` is internal — invoked by the installed unit, not run by hand.)

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

`dbx schedule add` writes a launchd `.plist` (macOS) or systemd `.timer` + `.service` (Linux user-mode) that runs `dbx schedule run-job <host> <database>` at the configured cadence. The scheduled run inherits your shell `PATH` via `dbx`'s installed location.

`run-job` is internal — it's the action the installed unit invokes, not a command you run by hand. It performs the backup and then, if that schedule carries a `keep` value, applies retention for that pair (`dbx clean <host> <database> --keep <keep>`). With no `keep`, a scheduled run behaves exactly like a plain backup (no pruning).

Notifications fire from inside the scheduled run, so failures show up in Slack/desktop/email even when you're not watching.

## Declarative schedules in `config.json`

Schedules can also be declared in `config.json` and reconciled with `dbx schedule sync`:

```jsonc
{
  "hosts": { ... },
  "schedules": [
    { "host": "production", "database": "myapp",   "when": "daily@5",        "keep": 30 },
    { "host": "production", "database": "billing", "when": "weekly@1:3" },
    { "host": "staging",    "database": "myapp",   "when": "*/15 4 * * 1-5", "enabled": false }
  ]
}
```

Each `schedules[]` entry takes:

| Field | Required | Default | Means |
|-------|----------|---------|-------|
| `host` | yes | — | host key from `config.hosts` |
| `database` | yes | — | database to back up |
| `when` | yes | — | schedule expression (see [Schedule syntax](#schedule-syntax)) |
| `enabled` | no | `true` | set `false` to disable without deleting the entry (see below) |
| `keep` | no | none | retention count applied after each scheduled backup |

`dbx schedule sync` diffs the installed units against `config.schedules[]` and prints a plan:

```
$ dbx schedule sync
Schedule sync plan

  + install  production/billing @ weekly@1:3
  ~ update   production/myapp → daily@5
  ! orphan   staging/x @ daily@7 (installed but not in config)
  = same     production/audit @ daily

  (preview only — re-run with --apply to install / update / orphan units)
```

By default `sync` is a **read-only preview** of the drift (`install` / `update` / `orphan` / `nochange`) — it tells you what `sync` *would* do. `--dry-run` forces this preview mode explicitly. It exits non-zero whenever there's actionable drift, so it works as a CI / pre-commit check.

`dbx schedule sync --apply` (alias `--force`) executes the plan: it installs new units, updates changed ones, and removes orphaned units (launchd on macOS, systemd on Linux). `dbx schedule add` / `remove` remain the imperative way to change a single installed unit.

**Disabling a schedule.** Set `"enabled": false` on a `schedules[]` entry to exclude it from the desired state without deleting the entry. Its installed unit then shows up as an `orphan` under `sync`, and `sync --apply` removes it. (There is no `schedule enable`/`disable` subcommand — the `enabled` key surfaced through `sync` is the mechanism.)

`dbx config validate` also reports drift between `config.schedules[]` and the installed units, so a config-vs-state mismatch can be caught in CI.

**Source of truth.** `config.json` is intended to be canonical: a checked-in `config.json` + `dbx schedule sync` reproduces the same scheduled jobs on any machine. The legacy `dbx schedule add` flow (imperative, doesn't touch config) still works for users who don't want to manage schedules declaratively.

**Schedule expression form.** Use the same friendly forms (`hourly`, `daily@5`, `weekly@1:3`) or raw cron as `dbx schedule add` accepts. The literal expression is stamped into the plist/timer at install time (as a `DbxScheduleExpression` key / header comment) so `sync` can read it back without reverse-parsing cron.
