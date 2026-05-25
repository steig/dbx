# Changelog

All notable changes to dbx are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **New wizard "Runs" view** (between Backups and Restore) renders the last 200 audit-log entries — `dbx backup`, `dbx restore`, and vault operations — as a sortable table with When / Action / Host-DB / Outcome / Duration / File columns. Failed runs get a soft red row wash and the `✗ failure` chip so you actually notice cron-driven backups that died silently. Filter by action (Backup / Restore / Other) and free-text host/db search. The backing `GET /api/audit-log` endpoint validates the `action` allowlist + clamps `limit` to 1-500, reads only the tail of `audit.log` so the request stays cheap even on multi-year accumulations, and returns `[]` (not 500) when the log doesn't exist yet. Closes the user's "if the backup fails I actually don't know" gap — until now, audit visibility required `cat ~/.local/share/dbx/audit.log | jq` from a terminal.
- **`dbx analyze` now flags PII candidates inline.** Before the existing exclude-data picker fires, the command walks `information_schema.columns` for the target database, runs each column through the same dictionary used by `dbx scrub init`, and prints a per-table summary: `users  3 candidate(s): email, phone, ip_address`. Honors the host's manifest `dictionary.extend` / `.exclude` if a scrub manifest is already configured. Skip with `--no-pii-scan` if you want the previous flow only.
- **`dbx analyze --suggest-scrub` writes a draft scrub manifest** containing suggested strategies for every dictionary-matching column found by the pre-scan. Defaults the output path to `dbx.scrub.json` next to your config; override with `--manifest-output FILE`. Equivalent to running `dbx scrub init <host>/<db> --output …` but as a one-shot during analyze. Inherits the configured `seed_env` name from the existing manifest (if any), so re-running it doesn't fight a chosen seed convention.
- **`dbx scrub init/check local/<db>`** — run scrub commands against a database that already lives in the managed `postgres-dbx` / `mysql-dbx` container without configuring a host. The pseudo-host `local` (alias `localhost`) auto-detects which container holds the named db (postgres wins if both have it) and uses the container's root credentials. `dbx scrub check local/<db>` requires `--manifest <path>` since there's no host config to resolve. Useful for iterating on a manifest against a freshly-restored snapshot before wiring up a real source.

### Changed

- **Wizard UX polish: bumped contrast + saturation.** User feedback was "the UX of this wizard is awful, needs more color. It's so dark and hard to read." Conservative changes only — no redesign:
  - Primary accent goes from a muted `#0b6bcb` to a vibrant `#0066ff` in light mode (dark mode's `#4ea8de` was already fine). Primary buttons and active sidebar items now pop instead of fading into the chrome.
  - Sidebar background is now meaningfully distinct from the main content (light: `#eef1f7` vs `#fff`; dark: `#0e1014` vs `#14161a`) so the left nav reads as a separate region.
  - `--md-default-fg-color--lightest` is darker / lighter in both modes so table dividers + section borders are actually visible (was nearly invisible at `#24272e` on `#14161a` in dark mode).
  - Status chip backgrounds (`--age`, `--gpg`, `--complete`, `--incomplete`, `--prod`, `--stage`) bumped from ~15% alpha to ~28-30% so they read as filled chips, not whisper-tints. Dark-mode chip text is lightened to keep legibility on the more-saturated fills.
  - Section dividers in main views: `.dbx-view__header` now has a bottom border so the header reliably separates from the table/form below.
  - Active sidebar nav item is rendered in the accent color (in addition to the left-edge accent bar) so the current tab is unmistakable.

### Fixed

- **`dbx restore --into` safety gate now fires on macOS even when the source is given as an absolute path.** Before: the prefix check `[[ "$source" == "$DATA_DIR"/* ]]` used a literal string match, so a source produced by `realpath`/`find` (resolving `/tmp -> /private/tmp` on macOS) failed to match `$DATA_DIR` which had stayed `/tmp/...`. Host extraction skipped, the `[[ -n "$host" ]]` guard on the safety check kicked in, and the prod-safety refusal silently never fired. Now `cd … && pwd -P` normalizes both sides before the comparison so the prefix match works regardless of which side went through symlink resolution. As a side benefit, the safety gate also got moved to fire BEFORE `require_docker`, so the test now passes on hosts with no docker installed (notably the macOS CI runner) — the `[[ "$(uname)" == "Darwin" ]] && skip` in `tests/unit/safety.bats` is dropped.

### Fixed

- **Restore success line now says WHERE the data landed.** Previously `[OK] Restore complete: b2c_v1_20260524` left the user guessing whether the data went to the managed `mysql-dbx` container, a docker-compose `mysql` service, or a remote `DEV_SERVICES_MODE=remote` host. Now: `[OK] Restore complete: b2c_v1_20260524 on mysql:3306 (DEV_SERVICES_MODE=remote)` for remote mode or `… on container mysql-dbx` for the default. Applies to both MySQL and Postgres restore paths.
- **`Connecting:` log line no longer prints a stray trailing colon when port is empty.** Was `[INFO] Connecting: 1.2.3.4: (user: …)` for hosts with SSH-tunnel-resolved ports that come back empty; now elides the `:port` portion entirely.

### Fixed

- **Wizard Restore view now disables the `--into` container picker for MySQL backups.** The CLI rejects `dbx restore --into` for non-postgres backups (`--into is only supported for postgres restores`); the UI was happily letting the user select a container, then hitting that error after Start. Now the dropdown is disabled when the selected backup's `source_flavor` is `mysql` / `mariadb`, with a small explanation underneath. Also clears any stale `form.into` value when the source flips from a postgres backup to a MySQL one, so the wizard server doesn't see a leftover value in the POST body.
- **mysql cred file is now per-invocation instead of a hardcoded `/tmp/my.cnf`.** Three `lib/mysql.sh` functions (`mysql_backup`, `mysql_restore_backup`, `mysql_analyze_tables`) all wrote credentials to the same file inside the shared mysql-dbx container. Any concurrent invocation — a scheduled `dbx schedule run` while you were mid `dbx backup`, a sibling Claude session via cmux, the schedule.bats integration test running in parallel — would race on the file. The race manifests as the second invocation's after-success cleanup hitting `docker exec rm -f /tmp/my.cnf` between the FIRST invocation's pass 1 and pass 2, causing `mysqldump: [ERROR] Failed to open required defaults file: /tmp/my.cnf`. Each function now generates a unique path (`/tmp/dbx-my.$$-$RANDOM.cnf`) and uses a `trap … RETURN` for cleanup so the file is always removed regardless of which exit path is taken.

### Added

- **`dbx restore -v` / `--verbose`** now works (previously errored `Unknown option`). Surfaces verbose log paths into the restore code; also exports `DBX_VERBOSE=1` for downstream libs that gate output on it.
- **`dbx backup -v` now tees mysqldump's stderr live** to the terminal instead of only capturing it for post-hoc inspection. mysqldump `--verbose` emits per-table progress (`-- Retrieving table structure for table X...`) — invaluable when diagnosing a missing-table situation since you can watch and see exactly which table doesn't appear. Without this, the only way to see the progress was to wait for the whole dump to finish and then read the captured file. Also prints `mysqldump target: user@host:port → database` at the start of each pass when verbose.

### Fixed

- **`dbx backup <host> <mysqldb>` now surfaces mysqldump warnings even on exit-0.** Previously, mysqldump's stderr was captured into a tmpfile and only printed on non-zero exit. But mysqldump's default behavior on access-denied errors is to silently skip the inaccessible table and emit a `Got error: 1142` or `Access denied` warning to stderr — exit code 0. The backup was "successful" but missing tables, and the user only discovered this at restore time when views referencing the skipped tables failed with `ERROR 1146 ("Table 'b2b.udropship_po' doesn't exist")`. Now both passes always pipe their stderr through a filter that drops only the cosmetic "Using a password" warning and surfaces everything else as `[WARN] mysqldump (<pass>) emitted warnings/errors: …` so the missing-tables case is obvious at backup time. Affects: every MySQL backup where the backup user lacks SELECT on some table the rest of the schema references.
- **`filter_sql` runs under `LC_ALL=C`** so BSD sed (macOS default) doesn't error `RE error: illegal byte sequence` on binary content in the SQL stream. Same family of fix as the `grep -a` change in #60; without `LC_ALL=C`, BSD sed's UTF-8 locale chokes on the latin1 / binary bytes routinely present in BLOB INSERTs and locale-encoded strings, dropping every line after that point.

### Fixed

- **MySQL restore now tolerates per-statement SQL errors via `--force`** instead of aborting on the first one. Real-world dumps routinely contain DDL that's valid in source but won't fully resolve against a fresh local target — views with cross-database JOINs (`b2c.rpt_sales_fact` referencing `reporting.dim_b2c_sales`), views/triggers referencing excluded-data tables, or stale view definitions whose underlying table was dropped. Without `--force`, the FIRST such reference aborted the entire import and you lost every table after it. Errors still emit to stderr so you see what didn't load. Opt out with `DBX_STRICT_IMPORT=1` for cases where partial restores are worse than no restore. Final log line tells the user the restore was tolerant.
- **MySQL restore of encrypted backups was passing encrypted bytes straight to mysql.** The `pv`-pipe restore path in `lib/mysql.sh` was using `decompress_stdin "${backup_file##*.}"` (lib/core.sh:601), which only handles the SINGLE final extension and falls through to `cat` for `.age` and `.gpg`. For a `b2b.sql.zst.age` backup the helper would see "age" and pipe the encrypted bytes (age header and all) straight through `sed | grep | mysql`, producing a fake `ERROR 1064 (42000) … near 'age-encryption.org/v1'` and a 0% import. Replaced with a new `decompress_stream_by_filename` helper in `lib/encrypt.sh` that mirrors `decompress_backup`'s full extension dispatch but reads from stdin so `pv` can still wrap the source-file read for progress. This bug had been hidden for months by the `2>/dev/null` removed in #59. Affects: every encrypted MySQL restore.
- **`filter_sql`'s grep calls now use `-a`** so binary-looking SQL (BLOB columns, latin1-encoded INSERT strings) passes through correctly. Without it, GNU grep silently drops the entire stream on binary input; BSD grep on macOS emits the literal line `Binary file (standard input) matches` INTO the pipe, which mysql then tries to execute as SQL.
- **`dbx restore` no longer hides MySQL errors behind `2>/dev/null`.** The four restore-time `mysql` invocations in `lib/mysql.sh` were silencing all stderr to suppress the cosmetic `[Warning] Using a password on the command line interface can be insecure.` line — which also swallowed every real error (failed `LOAD DATA`, missing tables, syntax errors in the dump). On a recent prod-mysql restore the user saw "Importing 47M..." → 100% on `pv` → "Restore failed (exit 1)" with no diagnostic, and the data wasn't actually restored. Each call now routes stderr through a new `mysql_stderr_filter` helper that drops only the known-cosmetic warning lines and passes everything else through to the user.

### Added

- **Wizard Backups view: per-row Delete button + complete/incomplete status chip.** Each row now shows a green ✓ chip when a `.meta.json` sidecar exists, red ⚠ when it doesn't (the sidecar is written only after `pg_dump`/`mysqldump` returns success, so its absence reliably indicates a partial/orphaned backup from a crashed run). The Restore button is disabled on incomplete rows. Delete button removes the file + sidecar after a confirm dialog, backed by a new `POST /api/backups/delete` endpoint that validates the path resolves under `$DATA_DIR` and has a `.sql.zst[.age|.gpg]` suffix. Source label gracefully renders `—` for the `"unknown" / "0"` sentinel values from a failed version-detect.
- **Wizard Config view: separate Save and Save & exit buttons.** Previously the only action was "Save & exit" which terminated the wizard. Now there's a primary "Save" button that writes config.json in place and leaves the wizard running, plus a secondary "Save & exit" preserving the legacy unblock-the-terminal behavior. Backed by a new `POST /api/config-save` endpoint that reuses the same merge logic as `POST /save` but does NOT touch the done-marker.
- **`dbx wizard --remote`** — server-only mode for SSH-tunneled access. Skips the SSH-TTY auto-fallback and the local browser launch; prints the URL, the suggested `ssh -L` tunnel command, and the localhost open-URL so you can forward the port from your laptop. Bind stays on 127.0.0.1; transport is SSH.
- **`dbx wizard --port N`** — pin the local port instead of letting the OS pick a free one. Pairs with `--remote` so the SSH-tunnel command is stable across runs. Validates the value is numeric, in range, and actually bindable before spawning the server.
- **`dbx wizard` Config view now loads the user's existing `config.json`** instead of starting blank. New `GET /api/config` endpoint reads the current config; the form's Alpine `init()` calls a new `loadFromConfig()` that maps the JSON shape back into the form's host-array / storage / defaults / notifications state. Static online builder (mkdocs embed) is unaffected — it still starts blank because it has no backend.
- **`dbx completion <bash|zsh|fish>`** — print a shell completion script. Add `eval "$(dbx completion bash)"` to your `~/.bashrc` (or the zsh / fish equivalent) and TAB will dynamically complete host aliases, databases, vault keys, restore candidates from `$DBX_DATA_DIR`, schedule shorthands (daily/hourly/weekly/...), and per-command flags. Dynamic data comes from a new hidden `dbx __complete` subcommand the script invokes on each TAB press; it reads `config.json` and walks `$DBX_DATA_DIR` but never touches docker or the network, so TAB stays fast.
- **Backup / restore timing** — `dbx backup` and `dbx restore` now report wall-clock duration and on-disk size in their final `[OK]` line (e.g. `Backup complete in 1m 42s — 230 MB → …`). Before starting, both commands look up the last successful run from `~/.local/share/dbx/audit.log` and print a `Last backup of prod/myapp took 1m 41s, produced 228 MB` baseline so you have a rough ETA. Under `-v`, `pg_backup` and `mysql_backup` log each step with a `+<elapsed>` prefix (`pg_dump started`, `pg_dump done — 410 MB`, `sha256 done`, `wrote .meta.json`). Tail-bounded audit read (last 500 lines) keeps the baseline lookup cheap.
- **`pv` live progress on restore** — when `pv` is on `PATH`, `dbx restore` pipes the compressed input through `pv -s <size>` so you get a real percentage and bytes/sec bar. Postgres restore enables it for plain (non-encrypted) `.zst` backups; MySQL already piped through `pv` and now passes `-s` for an accurate ETA. Falls back to plain `cat` / `decompress_backup` when `pv` is missing — no new dependency.
- **Wizard Restore elapsed counter** — the Restore view in `dbx wizard` shows a live `Elapsed: 0m 14s` badge in the header from the moment a job starts until the SSE `done` event fires. Pure Alpine; no server-side wiring.

### Changed

- **`POST /save` now merges into the existing `config.json` instead of overwriting**. Form-managed top-level keys (`hosts`, `defaults`, `storage`, `notifications`) are replaced — including being deleted if the form omitted them (e.g., user unchecked storage.enabled) — but every other key (`schedules`, `scrub`, `vault`, etc.) is preserved verbatim. Fixes a pre-existing footgun where saving from the Config view would wipe a `schedules[]` block edited in the Schedule view. Atomic write via `.wizard-tmp` swap, same pattern as `POST /api/schedules`.

## [0.12.0] - 2026-05-24

Single-theme minor release: `dbx wizard` graduates from a one-shot config builder into a multi-view local control panel. The same CLI is still the source of truth; the browser shells out to it. No Chromium bundle, no Electron — the existing 127.0.0.1 + URL-token Python server gained an `/api/` surface and three new views.

### Added

- **`dbx wizard` is now a multi-view control panel** with **Config** (existing), **Backups**, **Restore**, and **Schedule** tabs. The sidebar is gated by the existing `data-mode="cli"` attribute, so the static online builder at https://steig.github.io/dbx/config-builder/ continues to show only the Config form, unchanged. (#51, #52)
  - **Backups view**: filesystem walk of `$DATA_DIR/<host>/<db>/*.sql.zst[.age|.gpg]` enriched with sidecar `.meta.json` (timestamp, source flavor + major version). Filter + refresh + per-row "Restore" button that stages the backup for the Restore view.
  - **Restore view**: full form binding to `dbx restore` (target name, `--into` container picker populated from `docker ps`, `--no-post-restore`, `--hooks-only`, `--no-scrub`, `--keep-download`). Server spawns `dbx restore`; output streams to the browser via Server-Sent Events (`text/event-stream`). Cancel button SIGTERMs the running restore. `--transform` is **intentionally not exposed** — browser-triggered exec of host scripts is the wrong attack surface.
  - **Schedule view**: three tables side by side — the declarative `schedules[]` block in `config.json` (editable: add / edit / remove rows with client-side validation + dirty-check), the installed launchd / systemd units (read-only, reuses `lib/schedule.sh:schedule_installed_read`), and the sync plan diff (`install` / `update` / `orphan` / `nochange`). Save rewrites `schedules[]` in place via an atomic `.wizard-tmp` swap, preserving every other top-level key. Reconciling units to disk still goes via `dbx schedule sync --apply` from the CLI — the write path is deliberately CLI-only.
  - **New endpoints** (all `127.0.0.1`, all `?token=<32-hex>`-gated):
    - `GET /api/backups`, `GET /api/containers`, `GET /api/schedules`
    - `POST /api/restore` → `{job_id}`, `GET /api/jobs/<id>/events` (SSE), `POST /api/jobs/<id>/cancel`
    - `POST /api/schedules` (declarative-only write; rewrites the block atomically)
  - **Security**: every `POST` input is strictly validated. Source paths must match `<host>/<db>/(latest|<filename>)` shape OR resolve via `realpath` to a file inside `$DATA_DIR` matching `*.sql.zst[.age|.gpg]`. Host / database identifiers match `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` — the same shape used by `host_alias_valid` on the bash side. `--into` must reference a currently running docker container. `subprocess.Popen(argv_list, shell=False)` everywhere; no string interpolation into a shell. (#51, #52)

### Changed

- The Python HTTP server backing `dbx wizard` moved out of a 200-line heredoc in `lib/wizard.sh` into a standalone `lib/wizard-server.py` invoked via argparse flags. No behavior change on the existing config-save path; the extraction made room for the multi-view server logic and unlocked unit tests against the server itself (`tests/unit/wizard_server.bats`, **21 new tests** spawning the real server against fixture data + curling endpoints). (#51, #52)

## [0.11.0] - 2026-05-24

Two-feature minor release: streaming restore-time sanitize / sidecar-container restore (#41, #45), and declarative schedules with a read-only sync preview (#39 part 1). Plus a `dbx --help` cleanup that fixes a long-standing first-line error and trims the help to a one-screen reference.

### Added

- **`dbx restore --transform=PATH`** — pipe the restore byte-stream through a host-side executable before any write to the target. Unsanitized bytes never touch disk; the script receives plain SQL on stdin (postgres custom-format dumps are converted via `pg_restore -f -`) and emits sanitized SQL on stdout. Atomic on postgres (single-transaction wrap with `psql -1 -v ON_ERROR_STOP=1`); best-effort on MySQL (DDL implicitly commits). Non-zero exit from the script aborts the restore and drops the target. The script runs under `env -i` with a minimal allowlist (`PATH`, `HOME`, `LANG`, `LC_*`, `TZ`, `USER`, `SHELL`, `TMPDIR`) so dbx's credentials (`PGPASSWORD`, `MYSQL_PWD`, `DBX_SCRUB_SEED`, vault tokens) are NOT inherited by default. Pass-through any var via the `DBX_TRANSFORM_*` prefix. Use `--transform-inherit-env` to opt out of the cleaning and inherit dbx's full environment (legacy behavior). (#41, #45)
- **`dbx restore --into NAME`** — restore into a named external running docker container (e.g. a compose-managed postgres sidecar) instead of the managed `postgres-dbx`. Reads `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` from the container's env via `docker inspect`; waits up to 30s for `pg_isready`. Postgres only — MySQL `--into` is rejected with a clear error. Implicitly bypasses the scrub gate (dbx can't safely DROP a user-managed container's DB) with a loud warning + `scrub_bypass` audit log entry. (#41)
- The two flags compose: `dbx restore <src> --transform=./sanitize.sh --into sidecar-container` runs the streaming sanitize pipeline into a non-dbx-managed container. The load-bearing [boring](https://github.com/steig/boring) v0.5 integration use case.
- **`dbx schedule sync` (read-only preview)** — declarative schedules. A new `schedules` block in `config.json` (`[{host, database, when}, ...]`) is the source of truth; `dbx schedule sync` diffs the installed launchd/systemd units against it and prints a plan (`install` / `update` / `orphan` / `nochange`). Today this is preview-only (the write path lands in a follow-up). `dbx config validate` also reports drift. New plists/timers get a `DbxScheduleExpression` marker so `sync` reads back the friendly schedule form without reverse-parsing cron. (#39, part 1)

### Fixed

- **`dbx` / `dbx --help`** no longer prints `./dbx: line 2295: storage: command not found` as its first line. The `cmd_help` heredoc was unquoted and an EXAMPLES entry contained literal backticks (`` `storage download` ``), which bash was evaluating during heredoc expansion. (#49)

### Changed

- **`dbx --help` trimmed to a one-screen reference** (~140 → 32 lines) with the duplicated EXAMPLES, CONFIG STRUCTURE, FEATURES, STORAGE-paths, and REQUIREMENTS sections moved to the docs site. Added cyan on command names, green on quick-start examples, blue on the docs URL, all gated by the existing TTY check so piped output stays plain. (#49)

## [0.10.0] - 2026-05-24

Two-feature minor release: a browser-based config builder with an online static variant (#38), and a first-class PII scrubber with declarative manifest, schema drift detection, and a fail-closed restore-time gate (#40).

### Added

- **`dbx wizard`**: browser-based interactive config builder. Spins up a one-shot local HTTP server on `127.0.0.1:<random-port>` with a URL token, opens your default browser to a polished form (hosts, databases, storage, defaults), POSTs the result back, writes `~/.config/dbx/config.json` + shuts down. Auto-falls back to the gum-based `dbx host add` flow on SSH sessions, missing `python3`, or no GUI; explicit `--no-browser` / `--browser` flags override detection. (#38)
- **Online config builder** at `https://steig.github.io/dbx/config-builder/` — the same form, runs entirely in your browser, **Copy** or **Download** the resulting `config.json`. Nothing is sent to any server. Useful for previewing the config shape before installing dbx. (#38)
- **PII scrub** (#40) — declarative manifest + schema drift detection + fail-closed restore-time gate. New commands: `dbx scrub init <host>/<db>` (walks `information_schema` and emits a draft `dbx.scrub.json` with suggested strategies), `dbx scrub check <host>/<db>` (CI-friendly drift detection — exit 0 clean, 2 on drift, 1 on error), `dbx scrub validate <host>`. Per-column strategies: `fake_email`, `fake_phone`, `fake_ip`, `fake_name`, `redact` (optional `replacement` literal for NOT NULL columns), `truncate`, `shift_date`, `passthrough`, `jsonb_scrub_paths`. When `hosts.<h>.scrub.required: true`, every restore from that host is wrapped with (1) **pre-restore** drift check against the schema snapshot captured in the backup's `.meta.json` — aborts before any data lands in the local container when drift is detected; legacy backups without the snapshot fall back to (1b) a post-restore drift check that DROPs the just-restored target on drift; (2) declarative UPDATE execution in one transaction with the seed redacted from any error output; (3) per-strategy sniff verification; (4) DROP-on-failure (a half-scrubbed clone is more dangerous than no clone). `scrub_report.json` written next to the backup. `--no-scrub` flag for break-glass debugging (loud warning + separate audit log entry). `dbx config validate` schema-checks the manifest. JSON columns get implicit-deny: any `json`/`jsonb` column in a non-`no_pii` table must declare a strategy. Path keys in `jsonb_scrub_paths` are regex-validated against SQL injection. Stable masking via a salt env var (`seed_env`) so dev clones stay coherent across restores. Backup metadata now includes a `scrub_schema` field (best-effort capture of `information_schema.columns`) — adds a few hundred ms to backup time on schemas of any size. See [docs/scrub.md](docs/scrub.md) for the full feature.

## [0.9.0] - 2026-05-23

Three-feature minor release: restore directly from S3/MinIO (#33), interactive `dbx host add` / `dbx storage add` wizards (#35), and post-restore SQL hooks on `dbx restore` (#36). Removes the experimental TUI.

### Added

- `dbx restore --from-remote <host>/<db>/<file>` (and `s3://<host>/<db>/...` URI shorthand) pulls a backup straight from cloud storage instead of requiring a prior `dbx storage download`. `--keep-download` preserves the staged temp file after success. (#33)
- `dbx host add` — interactive wizard for adding a backup host. Prompts
  for connection details, validates against the live database, lets you
  pick which databases to back up, and chains into storage setup if it
  isn't already configured. (#35)
- `dbx storage add` — interactive wizard for configuring S3 /
  S3-compatible remote storage. Validates the config with a real
  upload-list-download-delete round-trip before committing — catches the
  read-but-no-write IAM case that a plain credentials check would miss. (#35)
- **Post-restore hooks** on `dbx restore`: per-database (and inherited per-host) SQL run automatically after every restore, in single-transaction wraps with fail-fast semantics. Supports `.sql` files and inline `sql` entries; six interpolation variables (`target_db`, `source_host`, `source_db`, `backup_file`, `backup_timestamp`, `restored_at`). New flags: `--no-post-restore`, `--hooks-only --name <existing-db>`. `dbx config validate` checks hook paths and entry shapes. (#36)

### Changed
- `audit_restore` runs from `cmd_restore` after hooks complete, so the audit log no longer reports `success` for a restore whose post-restore hooks failed.

### Removed
- Experimental TUI (`dbx tui` command and `lib/tui.sh`) — incomplete, confused the surface area. The `dbx host add` / `dbx storage add` wizards remain fully available as standalone CLI commands.

## [0.8.0] - 2026-05-17

Two-feature minor release: version-aware Docker images for backup and restore (#28 / PR #29), and a fix for `dbx clean --older-than` being a no-op against the default `--keep` (#22 / PR #30).

### Added
- Version-aware Docker image selection: the restore container now matches the source database's major version. Postgres extensions (`vector`, `postgis`, `timescaledb`) auto-select the right specialized image.
- `--recreate-container` flag on `dbx restore` for explicit consent to destroy user DBs when switching versions.
- `DBX_POSTGRES_IMAGE` / `DBX_MYSQL_IMAGE` env vars and matching config keys (`defaults.postgres_image`, `defaults.mysql_image`) for image override. Templates support `{major}`, `{minor}`, `{version}` substitution.
- New `.meta.json` fields written at backup time: `source_flavor`, `source_major_version`, `source_extensions`, plus `source_minor_version` for MySQL.

### Changed
- MariaDB sources now use the `mariadb:<major>.<minor>` image for the dumper container, replacing the Oracle `mysql:8.0` image that previously caused subtle definer/encoding drift in MariaDB dumps.
- `mysqldump --set-gtid-purged=OFF` is now conditional on flavor — MariaDB rejects the flag.

### Fixed
- `pg_detect_extensions` and `pg_detect_server_version` redirect stdin from `/dev/null` so they don't consume the outer `while read` loop's stdin in multi-database backup runs.
- `dbx clean --older-than D` was effectively a no-op when combined with the default `--keep 10`. Count-based retention ran first and deleted `backups[$keep:]`; the `--older-than` pass then iterated the same array and skipped everything that was already gone. The two modes are now mutually exclusive, and the default `--keep` is treated as advisory in age-based mode (explicit `--keep N` is still honored as a floor). (#22)

## [0.7.1] - 2026-05-08

Eight latent bugs uncovered by the new bats test suite (PR #20), the new release-check feature (PR #21), and the doc/comment follow-ups from the in-depth review (PR #23).

### Added

- **Release-check on every interactive command.** Hits the GitHub Releases API and prints a one-line notice when a newer tag is available. Cached 24h, gated to TTY-only invocations, opt-out via `DBX_NO_UPDATE_CHECK=1`. New `dbx update` command (aliases: `self-update`, `upgrade`) re-runs `install.sh`. (#21)
- **bats test suite** under `tests/` — 92 tests across `tests/unit/` (pure functions, no docker) and `tests/integration/` (real postgres + mysql round-trips, plain + age-encrypted). New CI jobs: `unit-tests` (ubuntu + macOS matrix) and `integration-tests` (ubuntu + docker). (#20)
- `DBX_REPO_SLUG`, `DBX_CACHE_DIR`, `DBX_UPDATE_CHECK_INTERVAL`, `DBX_NO_UPDATE_CHECK` env vars for the release-check feature.

### Fixed

These were uncovered by writing the test suite:

- `parse_schedule "daily"` / `"weekly"` (bare, no `@` suffix) returned literal `"daily"` / `"weekly"` for the hour/day fields. `${schedule#daily@}` is a no-op without an `@`; defaults are now set first and only overridden when the suffix is present. The same shape was duplicated in `systemd_create`'s inline parser; both fixed.
- `make_job_name` produced trailing-dash names (`com.dbx.backup.prod.myapp-`) because `tr -c` translated `echo`'s newline into `-`. Switched to `printf '%s'` so the input has no trailing newline.
- `dbx restore <host>/<db>/latest` died silently with rc=2 when no encrypted backups existed. `ls -t a b c | head -1` returns 2 under `set -o pipefail` when any of the globs have no matches; appended `|| true`.
- `dbx clean` left orphan `.meta.json` files. Same path-strip bug as the original #3 fix, present independently in `cmd_clean`. Now uses `${backup}.meta.json` directly.
- `((var++))` killed the script when `var` was 0 — `((0))` returns 1, `set -e` exits. Six call sites in `cmd_clean` and `cmd_config validate` now have `|| true`.
- `dbx backup <host>` (no database) died silently when `databases` was missing or null. `jq '... | keys[]'` exits non-zero on null input, killing the assignment under `set -e` before the empty-string check could call `die`. Switched to `keys[]?` plus `|| true`.
- `strip_definer` left a stray space on macOS — GNU `sed` accepts `\s` as a Perl-style whitespace shorthand; BSD `sed` (macOS default) does not. Switched to POSIX `[[:space:]]`.

### Changed

- `lib/core.sh` no longer auto-installs the `EXIT/INT/TERM` cleanup trap on source. `setup_security_trap` is still defined there but is now invoked from `dbx` itself. Without this, sourcing the lib in tests clobbered bats's own EXIT trap and silently dropped failing tests from TAP output.

## [0.7.0] - 2026-05-08

Bugfix and hardening release. The 0.6.0 version constant was bumped on `main` but never tagged or released, so 0.7.0 is the first published release after [v0.5.0](https://github.com/steig/dbx/releases/tag/v0.5.0).

### Added

- `dbx test <host>` — verify SSH, container, credentials, and connectivity for a configured host.
- `dbx config validate` — sanity-check the config file (JSON, host types, users, encryption settings).
- `dbx backup <host>` (no database) — back up every database configured for that host.
- `dbx clean --dry-run` — preview which backups would be removed without deleting.
- `dbx clean --older-than <days>` — time-based retention; preserves the newest `keep_backups` regardless of age.
- `defaults.auto_upload` — implicit S3 upload after every backup without needing `--upload`.
- `defaults.keep_backups` — config-driven retention count (was hardcoded to 10).
- `defaults.compression_level` — zstd compression level read from config instead of hardcoded `-3`.
- `DBX_BIND_ADDR` — env var to override the host bind address for the auto-managed Docker containers.

### Changed (behavior — recreate containers to pick these up)

- **Auto-managed Docker containers now bind to `127.0.0.1` by default.** `postgres-dbx` and `mysql-dbx` were previously bound to `0.0.0.0`, exposing them on the LAN with the default `devpassword`. Set `DBX_BIND_ADDR=0.0.0.0` if you need remote access. (#8)
- **Containers are created with `--add-host=host.docker.internal:host-gateway`.** SSH-tunnel mode now uses `host.docker.internal` on Linux as well as macOS, replacing the hardcoded `172.17.0.1` that broke on rootless Docker, Podman, and custom networks. (#9)
- Notifications are fired on backup success/failure and restore success when configured.
- Config file is `chmod 600` on creation, and JSON is re-validated after `dbx config edit`.

### Fixed

- `dbx restore` now finds `.meta.json` for plain (non-encrypted) backups. Previously the path strip silently failed and the metadata file was orphaned. (#3)
- `dbx list` shows the real on-disk filename (with timestamp and `.age`/`.gpg` suffix) instead of a fabricated name reconstructed from metadata fields. Two backups taken on the same day no longer collide. (#1)
- `dbx storage sync` reports the correct count of synced backups. The increment used to live inside a subshell pipe and was always reported as `0`. (#2)
- `dbx schedule add ... weekly@N:H` produces a valid `OnCalendar` on Linux. Numeric weekdays (0–6) are now translated to day names; the timer was previously rejected by systemd and never fired. (#4)
- fzf restore picker no longer breaks when `DBX_DATA_DIR` contains spaces or shell metacharacters — preview command receives the path via env, not string interpolation. (#7)
- `cmd_list` reads metadata correctly (was reading nonexistent `.filename` / `.size_human` fields).
- Recursive `cmd_backup <host>` builds args via array instead of unquoted subshell expansion that failed under `set -e`.
- `cmd_clean --older-than` skips the newest `keep_backups` so it can't fight count-based retention.
- `cmd_clean` rejects unknown flags instead of silently dropping them.
- Restore target-name auto-generation strips `.age` extension correctly.

### Security

- `cleanup_secrets` clears `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION` on EXIT/INT/TERM. They were exported by `aws_configure_env` and previously leaked into subprocesses for the rest of the session. (#6)
- See also the loopback container bind in **Changed** above. (#8)

### Refactor

- Removed duplicate `decompress` function from `lib/core.sh`; all callers (dbx content sniffing, mysql restore, verify backup) now use the canonical `decompress_backup` from `lib/encrypt.sh`. (#5)

### Migration

If you have an existing `postgres-dbx` or `mysql-dbx` container from an earlier version, recreate it to pick up the new `--add-host` alias and loopback bind:

```bash
docker rm -f postgres-dbx mysql-dbx
# dbx will recreate on next `backup` / `restore`
```

[Unreleased]: https://github.com/steig/dbx/compare/v0.8.0...HEAD
[0.8.0]: https://github.com/steig/dbx/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/steig/dbx/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/steig/dbx/compare/v0.5.0...v0.7.0
