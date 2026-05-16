# Changelog

All notable changes to dbx are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/steig/dbx/compare/v0.7.1...HEAD
[0.7.1]: https://github.com/steig/dbx/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/steig/dbx/compare/v0.5.0...v0.7.0
