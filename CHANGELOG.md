# Changelog

All notable changes to dbx are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

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

[0.7.0]: https://github.com/steig/dbx/compare/v0.5.0...v0.7.0
