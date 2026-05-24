# Changelog

All notable changes to dbx are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **`dbx restore --transform=PATH`** — pipe the restore byte-stream through a host-side executable before any write to the target. Unsanitized bytes never touch disk; the script receives plain SQL on stdin (postgres custom-format dumps are converted via `pg_restore -f -`) and emits sanitized SQL on stdout. Atomic on postgres (single-transaction wrap with `psql -1 -v ON_ERROR_STOP=1`); best-effort on MySQL (DDL implicitly commits). Non-zero exit from the script aborts the restore and drops the target. The script runs under `env -i` with a minimal allowlist (`PATH`, `HOME`, `LANG`, `LC_*`, `TZ`, `USER`, `SHELL`, `TMPDIR`) so dbx's credentials (`PGPASSWORD`, `MYSQL_PWD`, `DBX_SCRUB_SEED`, vault tokens) are NOT inherited by default. Pass-through any var via the `DBX_TRANSFORM_*` prefix. Use `--transform-inherit-env` to opt out of the cleaning and inherit dbx's full environment (legacy behavior). (#41, #45)
- **`dbx restore --into NAME`** — restore into a named external running docker container (e.g. a compose-managed postgres sidecar) instead of the managed `postgres-dbx`. Reads `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` from the container's env via `docker inspect`; waits up to 30s for `pg_isready`. Postgres only — MySQL `--into` is rejected with a clear error. Implicitly bypasses the scrub gate (dbx can't safely DROP a user-managed container's DB) with a loud warning + `scrub_bypass` audit log entry. (#41)
- The two flags compose: `dbx restore <src> --transform=./sanitize.sh --into sidecar-container` runs the streaming sanitize pipeline into a non-dbx-managed container. The load-bearing [boring](https://github.com/steig/boring) v0.5 integration use case.
- **`dbx schedule sync` (read-only preview)** — declarative schedules. A new `schedules` block in `config.json` (`[{host, database, when}, ...]`) is the source of truth; `dbx schedule sync` diffs the installed launchd/systemd units against it and prints a plan (`install` / `update` / `orphan` / `nochange`). Today this is preview-only (the write path lands in a follow-up). `dbx config validate` also reports drift. New plists/timers get a `DbxScheduleExpression` marker so `sync` reads back the friendly schedule form without reverse-parsing cron. (#39, part 1)

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
