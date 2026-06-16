# Changelog

All notable changes to dbx are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- **`dbx schedule add` / `remove` now keep `config.schedules[]` in sync.** Config is the canonical source of truth for schedules, but the imperative commands previously only touched the installed launchd/systemd unit — leaving `dbx schedule sync` to report phantom drift after every `add`. `add` now upserts the entry into `config.schedules[]` (matching on `host`+`database`, updating `when` in place and preserving `enabled`/`keep`), and `remove` drops it. Completes the declarative-schedules work. (#39)

## [0.31.0] - 2026-06-16

### Added

- **Stale managed-container port detection.** When an auto-managed container already exists but is published on a different host port than `DBX_PG_HOST_PORT` / `DBX_MYSQL_HOST_PORT` now request, dbx warns that a container's published port is fixed at `docker run` time and points at `docker rm -f <container>` to recreate it — instead of silently ignoring the override or dying with an opaque daemon error. A failed `docker start` of an existing container now also exits with that recreate hint. Builds on the host-port overrides shipped in 0.26.0. The `-p` mapping is now built by a small unit-tested helper (`dbx_publish_arg`). Thanks @joepetrini (#96).

### Fixed

- **Tunneled runs no longer leak DB/cloud credentials into the environment on exit.** `create_ssh_tunnel` installed its cleanup trap over the same `EXIT`/`INT`/`TERM` slots as the startup `cleanup_secrets` trap, clobbering it — so a backup/restore over an SSH tunnel would exit without unsetting `PGPASSWORD` / `MYSQL_PWD` / AWS credentials. Both handlers now run on exit. (#113)
- **Concurrent wizard saves can no longer lost-update `config.json` or collide on the temp file.** `dbx serve` is threaded, so two browser tabs (or multiple clients) saving at once could overwrite each other's blocks or clash on the shared `.wizard-tmp` file. Every config read-modify-write now runs under a process-wide lock and writes to a per-writer unique temp file. (#113)
- **Postgres restore works on systems whose `mktemp` lacks `-p`** (BSD/macOS). The two restore paths now use a portable `mktemp` template. (#113)

## [0.30.1] - 2026-06-06

### Fixed

- **Read-only commands no longer exit non-zero once you're on the latest release.** The update notifier runs as the final statement of `main()`, and when no newer release existed its internal `version_gt` comparison returned 1 — leaking that as the exit code, so `dbx --version`, `dbx help`, etc. exited 1 whenever update checks were enabled and you were up to date. The notifier now always returns 0. (Surfaced by the LXC auto-updater: a successful self-update reported `status=1/FAILURE` because its `dbx --version` step died under `set -e`.)

## [0.30.0] - 2026-06-06

### Added

- **Referential-integrity guard for `exclude_data` (Postgres).** Excluding a table's data leaves it empty; a kept table with a foreign key into it then dangles and the restore fails FK validation. dbx now detects this at backup time and, by default, **warns** with each `child → parent` that would dangle. Set `exclude_dependents: true` (per-database or `defaults.exclude_dependents`) to instead **cascade** the exclusion transitively to referencing tables so the dump stays consistent. The FK query only runs when `exclude_data` is non-empty.

## [0.29.1] - 2026-06-06

### Fixed

- **`restore --from-remote` of a custom-format Postgres backup is no longer treated as MySQL.** dbx writes `pg_dump --format=custom` dumps (binary magic `PGDMP`), but the type sniff only recognized plain-format dumps (the text `PostgreSQL`). When neither the backup metadata nor a host config supplied the type — as with `--from-remote` — a Postgres dump fell through to the MySQL restore path and failed. The sniff now recognizes the `PGDMP` magic.

## [0.29.0] - 2026-06-06

### Fixed

- **Storage backends with no prefix now list and restore correctly.** Object paths were built as `${bucket}/${prefix}/${key}`, which with an empty prefix produced `bucket//key` (double slash) — S3 stored the object under a leading-slash key, so uploads worked but `dbx storage list <path>` and `restore --from-remote` (latest resolution) looked at the wrong key and found nothing. Paths now join segments with single slashes, skipping empties.

### Added

- Integration coverage for multiple named backends (two MinIO buckets): `--upload=<name>` routing, `storage list --storage <name>`, and `restore --storage <name> --from-remote` fetch targeting.

## [0.28.0] - 2026-06-06

### Added

- **Validate a storage backend from the GUI and CLI.** New `dbx storage test [--storage <name>]` runs a real upload→list→download→delete round-trip against a saved backend; the wizard's storage view gains a per-backend **Test** button (via `GET /api/storage/test`). `dbx host add` now prompts which backend a host auto-uploads to when more than one is configured.
- **Shareable wizard section URLs + browser history.** Each wizard section is reflected in the URL hash (`#restore`, `#config`, …): back/forward navigate between sections, and a reload or deep link lands on the right one.

## [0.27.0] - 2026-06-06

### Added

- **Multiple named storage backends.** dbx can now hold several S3-compatible backends at once (e.g. Cloudflare R2 + MinIO) under a top-level `storages.<name>` map, with `defaults.storage` naming the default. `dbx storage add` prompts for a backend name and stores its secret under `s3-secret-key-<name>`; pick a backend per operation with `dbx backup --upload[=<name>]`, `dbx restore --storage <name>`, or `dbx storage <op> --storage <name>`; a host can pin its own target with `upload_storage`. `dbx storage info` lists every backend and marks the default. The legacy single `storage` block keeps working unchanged (treated as the default; no migration). Generic S3 (endpoint + region) covers MinIO/R2/B2/AWS/Spaces — no per-provider code paths.
- **Wizard GUI manages multiple backends.** The web wizard's storage section is now a list of named backends — add/remove, set fields, and mark a default — saving to `storages` + `defaults.storage`. An existing single `storage` block is surfaced as a backend named `default` and migrated on the next save.

## [0.26.0] - 2026-06-06

### Added

- **AI-assisted restore prep (`restore-prep` skill).** A new [Claude Code](https://claude.com/claude-code) skill (`.claude/skills/restore-prep/`) that scans a *restored clone* — never prod — to make it safe for staging. It fingerprints the application framework (Django, Rails, Laravel, Node, Spring/Quartz, WordPress, Magento + commerce, Supabase), recursively deep-scans every JSON/JSONB column, and scans key/value config tables (Magento `core_config_data`, WordPress `wp_options`) — classifying secrets and PII by value-pattern and key-name with **value-free output** (locations and categories, never the secret itself). Those findings inform a generated [PII scrub manifest](https://steig.github.io/dbx/scrub/) and [post-restore cleanup hooks](https://steig.github.io/dbx/post-restore-hooks/) (repoint URLs, disable cron/queues, clear token tables). PostgreSQL (recursive CTE) and MySQL 8 (iterative worklist). Ships a `frameworks.md` playbook of where each stack hides jobs/tokens/config/login, new [docs](https://steig.github.io/dbx/restore-prep/), and AI-scan callouts in the wizard. The skill proposes; the operator reviews and wires the artifacts in. (#101)

## [0.25.0] - 2026-06-04

### Fixed

- **`dbx wizard` crashed on Python 3.9.** The wizard server used PEP 604 union syntax (`str | None`) in function signatures, which is evaluated at import time on Python < 3.10 and raised `TypeError: unsupported operand type(s) for |`. Because `wizard.sh` launched the server with bare `python3`, it picked up the stock macOS interpreter (3.9.6) and died with an opaque traceback — effectively requiring Python ≥ 3.10 without detecting or enforcing it. Added `from __future__ import annotations` (PEP 563) so the module imports cleanly back to Python 3.7, and `wizard.sh` now preflights the interpreter for both `dbx wizard` and `dbx serve` — resolving `${DBX_PYTHON:-python3}`, requiring ≥ 3.7, and failing with an actionable message (pointing at the `DBX_PYTHON` override) instead of crashing. (#99)
- **Browser tab froze or ran out of memory on verbose backups.** Verbose `pg_dump -v` / `mysqldump -v` emit a line per object/row. The wizard's job log buffered every line unbounded on the server (replaying the whole backlog on each SSE re-attach) and rendered one DOM node per line on the client, which could freeze or crash the tab. The server now uses a bounded ring buffer (`MAX_JOB_LINES`) with absolute-offset SSE so re-attach replay is capped, and the client caps its rendered log lines. The backup process itself was never affected.

## [0.24.0] - 2026-06-03

### Added

- **`dbx serve --no-token`.** Disables dbx's URL-token gate entirely, for when a trusted identity proxy (e.g. Cloudflare Access) or a private network (e.g. a tailnet) is providing access control — so there's no token to carry in the URL. Server-side this is a new `--no-auth` flag (`--token` becomes optional, required only when `--no-auth` is absent); `dbx serve` exposes it as `--no-token` (or `DBX_SERVE_NO_TOKEN=true`) and warns loudly if combined with a `0.0.0.0` bind. Default behavior is unchanged — a token is still required without `--no-token`.

## [0.23.0] - 2026-06-03

### Added

- **`dbx serve` — persistent, network-reachable wizard GUI.** A new `dbx serve` subcommand runs the wizard server as an always-on service, unlike `dbx wizard --remote` (which binds loopback and exits on the first config save). It binds a configurable address (`--bind`, default `0.0.0.0`), port (`--port`, default `8080`), and a stable token (`--token`) — each also settable via `DBX_SERVE_BIND` / `DBX_SERVE_PORT` / `DBX_SERVE_TOKEN` — stays up after saves, and runs in the foreground so a process manager (e.g. systemd) owns its lifecycle. Access is gated by the URL token plus your network; binding `0.0.0.0` exposes it on all interfaces, so run it only on a trusted network (e.g. a tailnet).

## [0.22.0] - 2026-06-02

### Added

- **`DBX_PG_HOST_PORT` / `DBX_MYSQL_HOST_PORT`.** The auto-managed `postgres-dbx` / `mysql-dbx` containers no longer hard-code the published host port, so dbx can run alongside a Postgres or MySQL already bound to `5432` / `3306`. Defaults are unchanged; only the published host port moves (`docker exec`-based restore/scrub are unaffected).

### Fixed

- **PII scrub gate now fires for `required_for`-only hosts.** A host configured with `scrub.required_for` but without `scrub.required: true` previously got **no scrub gate at all** — the per-destination logic was never wired in. The gate is now active when `scrub.required` is true **or** `scrub.required_for` is non-empty (host-wide; dbx restores always land in a local container, so there is no per-destination filtering to apply).
- **MySQL restores now match the container image to the backup's source.** Restores reused whatever image `mysql-dbx` was running (default `mysql:8.0`) regardless of the backup's source flavor/version; only the backup path matched. Restores now select the image from the backup's `.meta.json` (flavor + major.minor) via the same fail-closed path as Postgres, honoring `DBX_RECREATE_CONTAINER`. Legacy backups with no metadata fall back to `mysql:8.0`, unchanged.

### Documentation

- Audited `docs/` against the code and corrected drift across the reference, scheduling, restore, backup, scrub, wizard, credentials, and configuration pages (missing commands and flags, the stale `schedule sync` "not yet shipped" note, undocumented environment variables, scrub `<host>/<database>` syntax, and a non-existent `dbx scrub update`).

## [0.21.0] - 2026-06-02

### Added

- **Redesigned wizard control panel.** A purpose-built "Calm modern SaaS" interface replaces the documentation-derived theme: a big-picture **Overview** (health donut, needs-attention triage, recent activity, and weekly trend charts), a regrouped sidebar (**Operate / Configure / Insights**), and a consistent component system in light + dark mode across all eleven views.
- **Backups and restores resume after a page reload.** A backup or restore runs as a server-side job that keeps running independently of the browser; the wizard now remembers the running job and re-attaches to its live log on reload instead of showing an idle form. A stale job id (after a server restart) is detected and cleared.
- **Download a backup from the wizard.** New `GET /api/backups/download` streams a backup file (path-validated to the data dir, so traversal is rejected); the Backups view gains a **Download** action.
- **Add and remove scrub column rules in the editor.** The Scrub view can now add a column rule, edit its name, and remove rules — not just change strategies on existing ones — saved through the existing manifest write.
- **Dashboard trend charts.** Overview shows backups-per-week and data-backed-up-per-week for the last eight weeks, derived from the audit log.
- **Schedule view shows next run and last run**, computed from each schedule's expression and the audit log.
- **Enable / disable schedules.** Schedules carry an optional `enabled` flag (default on); disabling one excludes it from the sync plan so its installed unit is orphaned on the next sync. Existing configs are untouched.
- **Per-schedule retention (opt-in).** A schedule may set `keep: N`; its unit then prunes that host/database to the newest N backups after each run. Schedules without a `keep` behave exactly as before (no deletion).
- **`dbx schedule sync --apply`.** `schedule sync` can now execute its plan — install / update / orphan the launchd or systemd units — instead of only previewing it. The default stays a read-only preview.

### Changed

- **`dbx clean` accepts an optional `[host] [database]` scope** to prune a single host/database; with no arguments it still cleans every pair as before. (Enables per-schedule retention above.)

## [0.20.0] - 2026-05-27

### Added

- **Build-on-demand custom Postgres images for third-party extensions.** A backup that uses an extension with no off-the-shelf image (`pg_partman`, `pg_cron`, `pgaudit`, …) no longer hard-fails at restore. dbx now builds a small image on demand — `FROM postgres:<major>` (Debian) + the extension's PGDG package — tagged `dbx-pg<major>:<hash>` keyed by the exact extension set, builds it once, and caches it by tag so subsequent restores are network-free and reproducible. Extensions needing `shared_preload_libraries` (e.g. `pg_cron`) get it baked into the image. Auto-build is on by default (`defaults.build_missing_images`, `DBX_BUILD_MISSING_IMAGES`); the built-in registry is extensible via `defaults.extension_packages`. New `dbx build-image` command (`--from-backup <file>` or `pg<MAJOR> --extensions a,b,c`) pre-warms the cache so scheduled jobs never block on a build.

### Fixed

- **Restore no longer fails on bundled contrib extensions.** `pick_postgres_image` treated every extension outside `vector`/`postgis`/`timescaledb` as "no known image," so a backup using a stock contrib module (`btree_gin`, `btree_gist`, `pg_trgm`, `hstore`, `citext`, `pgcrypto`, `uuid-ossp`, …) was blocked even though those ship in `postgres:<major>-alpine`'s `postgresql-contrib`. Contrib modules are now recognized as satisfied by the stock image; only genuinely third-party, unmapped extensions fail (and most of those are now buildable — see above).

## [0.19.4] - 2026-05-26

### Documentation

- **Documented the browser wizard's views.** `docs/wizards.md` previously described `dbx wizard` only as a one-shot config form. It now covers the view sidebar — including the **Analyze** view's "Save exclusions" builder (tick tables to write `exclude_data`) and the auto-tailing verbose **Backup** log — and notes the wizard no longer times out. Bumped all 17 man-page `.TH` version strings from a stale `0.12.0` to `0.19.4`.

## [0.19.3] - 2026-05-26

### Fixed

- **`dbx update` no longer corrupts itself mid-run (`cker,: command not found`).** The installer wrote the new launcher with `curl -o` directly onto `$INSTALL_DIR/dbx` — the very file the running `dbx update` was still being read from. Bash reads scripts by offset on demand, so truncating + rewriting it in place made the in-flight process resume at a stale offset in new content and execute a mid-token fragment (e.g. a slice of `docker,`). The install still completed correctly, but the upgrade printed an alarming error. `install.sh` now downloads the launcher to a temp file and swaps it in with a single atomic rename at the very end, so the running process keeps reading its original file and a mid-install failure leaves the previous version untouched.

## [0.19.2] - 2026-05-26

### Added

- **The wizard's backup log auto-tails.** With `-v`/verbose the streaming log now follows the bottom as lines arrive, so you don't have to keep scrolling. It's sticky: scroll up to read and following pauses; scroll back to the bottom and it resumes. Resets to following on each new run and on Clear log.

### Fixed

- **`dbx update` installs from the latest release tag instead of `main`.** `raw.githubusercontent.com` serves `main` through a CDN that can lag a freshly-pushed release by several minutes, so running `dbx update` right after a release re-installed the *previous* version. It now resolves the latest release tag via the GitHub Releases API and installs pinned to that immutable tag (served fresh), falling back to `main` only if the API is unreachable. `install.sh` gained a `DBX_REF` knob (default `main`); the public one-liner installer is unchanged.

## [0.19.1] - 2026-05-26

### Fixed

- **Wizard Config view now reflects `exclude_data` saved from the Analyze view.** The wizard's tabs are `x-show`, so the Config form (`dbxBuilder`) read `config.json` only once at page load and never again. Exclusions written by the Analyze view's "Save exclusions" (a direct `config.json` patch) didn't show up when you switched to the Config tab, and a subsequent Config save would have rebuilt the `hosts` block from the stale form state and dropped them. The Config view now re-reads `config.json` on tab entry, gated on a pristine-form check so it never discards unsaved edits.

## [0.19.0] - 2026-05-26

### Added

- **Build up `exclude_data` from the wizard's Analyze view.** Each row in the Analyze table now has a "Skip data" checkbox seeded from the database's current `exclude_data`; check the big append-only/log/cache tables you don't need row data for and hit **Save exclusions** to write them back to `config.hosts[host].databases[db].exclude_data` (schema is always kept — this is data-only skip, the same semantics as the field's existing meaning). Previously Analyze only *showed* an `excluded` chip and you had to retype table names by hand in the Form view. Backed by a new `POST /api/analyze/exclude` endpoint that patches config.json in place (replace semantics; an empty set removes the key), mirroring how the Scrub view saves. Table names are constrained to the safe identifier shape before they reach `pg_dump --exclude-table-data=` / `mysqldump --ignore-table=`.

### Changed

- **`dbx wizard` no longer auto-times-out.** The form-wait loop previously gave up after 10 minutes (`elapsed -ge 1200`) and exited with a warning, which bit anyone who stepped away mid-config or was filling in a large multi-host setup. The wizard now waits until you submit the form or press Ctrl-C. The startup banner drops the now-meaningless "Timeout: 10 minutes" line (remote mode keeps the "Cancel: Ctrl-C" hint). The separate per-request subprocess timeout in `run_scrub_subcommand` (5 minutes, protecting the HTTP handler from a slow source-host schema query) is unchanged.

### Fixed

- **Encryption config guidance pointed at the wrong key and a non-existent command.** The canonical field is `defaults.encryption_type` (`none|gpg|age`, resolved by `get_encryption_type`); the boolean `defaults.encryption` survives only as a read-time legacy fallback (`true`→gpg). Several user-facing spots disagreed: `dbx vault set-encryption-key` told you to set `"encryption": true`, `dbx config init` seeded `"encryption": false` into new configs, and the age "recipients file not found" error told you to run `dbx config init-encryption` — a command that never existed (it's `dbx vault init-age`). All now point at `encryption_type`. Also removed the dead `is_encryption_enabled()` helper, which read the legacy key, had zero callers, and would have reported `false` for any age-encrypted config.

## [0.18.0] - 2026-05-26

### Added

- **`dbx wizard -v / --verbose`.** Streams the wizard server's stdout/stderr to the spawning terminal in real time (via a backgrounded `tail -F`) and preserves the log file on exit instead of deleting it. The path is printed on startup so you can also `tail -f` from another terminal. Without this, server-side CLI errors (auth failures, docker hiccups, missing containers) were captured by the wizard but never surfaced — they lived and died in a mktemp file the trap unlinked.
- **`POST /api/analyze` returns CLI stderr on success too.** Previously only `502` failure responses included `stderr`; now successful runs also include it when the CLI wrote to stderr (e.g. `log_step "Scanning prod-mysql/b2b for PII candidates..."`). The wizard's Analyze view renders this in a new yellow "CLI diagnostics" panel between the totals strip and the PII section. Empty stderr is elided so the panel only appears when there's something to say.

### Fixed

- **`dbx analyze --json` stops silently returning empty payloads on a broken database connection.** Old code wrapped both engine's stats queries in `2>/dev/null || true`, so a psql/mysql auth failure / "database does not exist" / SSH tunnel timeout produced a 200 OK with `tables: 0, rows: 0` — the wizard's Analyze view then rendered "0 tables" and the user assumed the call simply hadn't done anything. Stderr now flows through to the wizard server, a non-zero exit fails the command (caller sees 502 with the underlying error), and an empty result set raises a clear `die`: "Table stats query for X@Y returned no rows — does the database exist and does the configured user have SELECT on information_schema (or pg_stat_user_tables)?". The PII pre-scan path also stops `2>/dev/null`-swallowing its own errors; a failed PII scan now `log_warn`s and continues with empty PII rather than hiding the failure.

## [0.17.0] - 2026-05-26

### Added

- **Wizard Analyze view.** New "Analyze" sidebar tab between Scrub and Schedule that surfaces what `dbx analyze <host> <db>` shows on the CLI — per-table row count + on-disk size, totals, exclusion flags, PII candidates — in a sortable, filterable browser table instead of an fzf picker. Host + database pickers source from the existing `/api/config` endpoint; a "Skip PII scan" checkbox bypasses the dictionary match for faster runs against schemas with thousands of tables. Per-row chips: `excluded` when a table appears in `config.databases[].exclude_data`, and `PII` when the pre-scan flagged it.
- **`dbx analyze --json` mode.** Skips the fzf-aware interactive picker and the human-readable log output, emitting one structured object: `{host, database, engine, totals: {tables, rows, size_bytes}, tables: [{name, rows, size_bytes, excluded}], pii: [{table, columns: [...]}]}`. Reuses the per-engine stats query from `analyze_postgres` / `analyze_mysql` and the existing `scrub_pii_summary_tsv` helper, so the JSON path doesn't diverge from the interactive path. `--suggest-scrub` still writes its draft manifest on the side. Powers the new wizard tab via a new `POST /api/analyze` endpoint; also useful for scripted consumers.

### Fixed

- **`dbx vault list` actually lists credentials again.** `keychain_list()` walks `security dump-keychain` looking for entries with `"svce"<blob>="dbx"` and jumps -B5 lines back to find the matching `"acct"` attribute. On modern macOS the dump emits ~15 attribute lines per entry with `"acct"` 13 lines *before* `"svce"`, so `-B5` silently dropped every entry — `dbx vault list` showed "(none)" even when keychain had credentials, while `find-generic-password -s dbx -a <key>` continued to work. Downstream, the wizard's Vault tab also rendered empty because `/api/vault/list` shells out to this same function. Widened to `-B20` (comfortable headroom over the real ~15-line block). `sort -u` already dedupes if `-B` grabs into an adjacent entry's `"acct"` line.

## [0.16.0] - 2026-05-26

### Added

- **Wizard Scrub view.** New "Scrub" tab between Restore and Schedule that gives the wizard a real dashboard for PII-scrub manifests, not just the existing "Skip PII scrub gate" break-glass checkbox on Restore. Per-host status table (alias / type / safety chip / manifest path / `manifest_exists` / `scrub.required` chip) with three actions per row: **Init** drafts a manifest by shelling out to `dbx scrub init <host>/<db>`, previewing the JSON, and saving to a config-relative path while patching `hosts.<alias>.scrub.manifest` in `config.json`; **Check** runs `dbx scrub check --json` and renders the drift report (new dict-matching columns, new tables with matches, missing declared columns, undeclared JSON); **Edit** opens a per-table editor with strategy dropdowns and inline params (`length` for truncate, `max_days` for shift_date, `replacement` for redact, `reason` for passthrough) and round-trips unknown keys like `jsonb_scrub_paths.paths` via a `_extras` shadow so hand-edited shapes survive save. Five new endpoints under `/api/scrub/*` (`status`, `manifest`, `init`, `check`, `save`). The save path is containment-checked to `$HOME` / config-dir, must end `.json`, and rejects symlink targets that resolve outside the allowed roots. The Python pre-validator mirrors `lib/scrub.sh:scrub_validate_manifest` exactly — same strategy allowlist, same "tables must have either `no_pii=true` or non-empty `columns`" rule — so the wizard never saves a manifest the CLI would then reject. 16 new bats tests cover status / manifest read / init / check (clean + drift) / save (happy path, no-host, bad strategy, path escape, non-`.json`, symlink escape, orphan-on-bad-host).

### Fixed

- **Wizard Config form round-trips `safety` correctly.** `loadFromConfig` was loading every host field back from `config.json` *except* `safety`. A host with `safety: "prod"` silently showed up as Local on form open; clicking Save then stripped the prod marker from disk because `buildConfig` omits the field when it equals the default. Now reads the field like the other host attributes.
- **`dbx scrub init/check` works against hosts with no `port` in config.** `scrub_schema_query_mysql` / `scrub_schema_query_pg` were invoking the mysql/psql CLI with `-P "$db_port"` / `-p "$db_port"` on argv; an empty `$db_port` expanded to a literal empty string that mysql rejects with `[ERROR] mysql: Empty value for 'port' specified`. The backup path doesn't hit this because `create_mysql_credential_file` defaults port to 3306 inside the generated `my.cnf`. Scrub now applies the same 3306 / 5432 defaults when `get_effective_port` returns empty.
- **Wizard scrub timeout raised from 60s to 5 minutes.** The 60s cap in `run_scrub_subcommand` was tuned to the bats fake-`dbx` that returns instantly. In practice the schema query goes against the *source* host — a prod box behind a VPN with thousands of tables can easily exceed 60s. Five minutes sits comfortably inside the wizard's overall 10-minute idle timeout without spuriously killing slow-but-legitimate prod schema walks.

## [0.15.0] - 2026-05-25

### Added

- **Wizard Dashboard (landing tab).** New default-on-open view between the sidebar entries: per host/db backup health cards with status chips (`fresh` ≤24h / `aging` ≤7d / `stale` ≥7d), last-success age, last-failure with error excerpt, and next scheduled run derived from `schedules[]`. Summary strip at top: total backups + bytes + hosts/dbs + per-status counts. Stale cards first so broken backups stop hiding. Click a card → switches to the Backups view filtered to that pair. Backed by a new `GET /api/dashboard` endpoint that composes data from `$DATA_DIR`, `audit.log`, and `config.json` in one pass.
- **Wizard Backup view: kick off `dbx backup <host> [database]` from the browser** (PR-W). Same SSE log streaming + cancel as Restore. Host + Database dropdowns sourced from `config.json` via the existing `GET /api/config`. New `POST /api/backup` validates host against the configured allowlist before spawning.
- **Wizard Schedule view: dropdowns sourced from config.json** (PR-X). Host and Database columns are `<select>` instead of free-text inputs. Preserves unknown values referenced by hand-edited schedules as `(not in config)`-tagged options so the row stays editable.
- **Vault management UI.** New "Vault" tab between Restore and Schedule with credentials table (key, backend, last-set timestamp from audit log), inline add/update form, reveal-with-5s-countdown + clipboard copy, and an age-recipients editor that preserves comment lines. 7 new endpoints under `/api/vault/*`. Credentials are piped via `stdin=PIPE` to `dbx vault set <key>` — never on argv, never logged.
- **Per-host connection test from the dashboard.** Each dashboard host card gets a "Test connection" button that spawns `dbx test <host>` via the existing job/SSE plumbing and streams the 4-step staged output (ssh → container → creds → query) inline under the card. Multiple cards can run independently. New `POST /api/host-test` validates the host against the configured-hosts allowlist.
- **Storage view + retention sweep.** New "Storage" tab (after Schedule) showing disk usage bar (used / free / 70/90% color tiers), per host/db usage table (count, total, largest, oldest, newest), retention preview ("if you ran `dbx clean --keep 7` you'd reclaim 47 files / 12.3 GB"), and a confirm-gated Apply button that streams the cleanup output via SSE. 3 new endpoints: `GET /api/storage/usage`, `GET /api/storage/clean-preview`, `POST /api/storage/clean`.
- **Audit log search/filter.** Runs view gains a date-range picker (from/to ISO dates), outcome filter (success/failure), regex search across stringified entries with graceful fallback to substring on invalid regex, and a "Failed restores" preset chip. Result count strip ("Showing 42 of 1247"). `GET /api/audit-log` extended with `from=`, `to=`, `q=` (regex, 200-char cap, 400 on compile error), `outcome=` params and a `{entries, total, filtered}` envelope when any filter is active; bare-array shape preserved for legacy callers.
- **Guided restore (3-step flow).** Restore view gains a Quick/Guided mode toggle. Guided mode walks through (1) pick source backup, (2) name target DB + prod-safety acknowledgement + scrub toggle, (3) diff preview showing whether the target db exists + table count + flavor-resolved container. Quick mode unchanged. Backed by a new `GET /api/restore/diff` endpoint that docker-execs the target container for table list (silently no-op on hosts without docker).

### Fixed

- **Audit log is JSONL again, not pretty-printed multi-line JSON.** `audit_log()` was building each entry with `jq -n` (which defaults to pretty-printed output across ~5 lines per entry). The audit file's contract is one JSON object per line, read line-by-line by the wizard Runs view and by the bash-side last-successful-run baseline (`last_backup_baseline` at lib/core.sh:809). Pretty-printed output broke every reader silently — the wizard's Runs view appeared empty even when audit entries existed, and the "last backup took N seconds" baseline returned nothing. Fixed by passing `-c` (compact) to both `jq` calls in `audit_log()`. Existing pretty-printed entries can be recovered in place with `jq -c . ~/.local/share/dbx/audit.log > /tmp/x && mv /tmp/x ~/.local/share/dbx/audit.log && chmod 600 ~/.local/share/dbx/audit.log`. New `tests/unit/audit_log_jsonl.bats` asserts the JSONL contract on every call to prevent regression.
- **Wizard Backup + Schedule views: now read `config.json` correctly.** PR-W (Backup view) and PR-X (Schedule dropdowns) both assumed `config.json`'s `hosts` was an array of `{alias, databases}` objects. Real schema is an object keyed by alias (`{"prod-mysql": {"type": "mysql", "databases": {"b2b": {}, "b2c": {}}, ...}}`), and `databases` is similarly keyed by db name. The result: against a real working config, the Backup view rendered "No hosts configured yet" and the Schedule view rendered empty dropdowns. Both client-side loaders + the server-side `list_configured_hosts` validator now read the object-keyed shape correctly (with defensive array-shape fallback for hand-edited / informal configs). Added a wizard_server test against the real dict shape.

## [0.14.0] - 2026-05-25

### Added

- **Wizard Backup view.** New "Backup" tab between Config and Backups runs `dbx backup <host> [database] [-v] [--upload]` from the browser with the same SSE log streaming + cancel button as Restore. Host and Database are dropdowns sourced from `GET /api/config` — Host lists every alias in `config.json's` `hosts[]`, Database lists `hosts[<alias>].databases[]` when present (empty option = "all databases" so `dbx backup <host>` with no DB arg still works). The new `POST /api/backup` endpoint validates `host` against the configured allowlist (a hand-crafted POST cannot run `dbx backup` against an unknown target), validates `database` against `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`, and accepts booleans for `verbose` / `upload`. The internal `spawn_restore` helper got renamed to `spawn_dbx(subcommand, argv_tail)` so the same Popen / SSE plumbing handles both restore and backup jobs.

### Changed

- **Wizard Schedule view: Host and Database are now dropdowns sourced from `config.json`** instead of free-text inputs. Previously the user had to type the host alias + database name and remember the exact spelling — typos either landed silently in `schedules[]` (saving an invalid row) or got caught only at `dbx schedule sync` time. Now the Schedule view pulls `hosts[].alias` and `hosts[].databases[]` from `GET /api/config` on reload and renders them as selects. If a saved row references a host or database that isn't in the current config (manual edit, removed host), that value is preserved as a "(not in config)"-tagged option so the row stays editable instead of silently coercing to empty.

## [0.13.0] - 2026-05-25

### Added

- **New wizard "Runs" view** (between Backups and Restore) renders the last 200 audit-log entries — `dbx backup`, `dbx restore`, and vault operations — as a sortable table with When / Action / Host-DB / Outcome / Duration / File columns. Failed runs get a soft red row wash and the `✗ failure` chip so you actually notice cron-driven backups that died silently. Filter by action (Backup / Restore / Other) and free-text host/db search. The backing `GET /api/audit-log` endpoint validates the `action` allowlist + clamps `limit` to 1-500, reads only the tail of `audit.log` so the request stays cheap even on multi-year accumulations, and returns `[]` (not 500) when the log doesn't exist yet. Closes the user's "if the backup fails I actually don't know" gap — until now, audit visibility required `cat ~/.local/share/dbx/audit.log | jq` from a terminal.
- **`dbx analyze` now flags PII candidates inline.** Before the existing exclude-data picker fires, the command walks `information_schema.columns` for the target database, runs each column through the same dictionary used by `dbx scrub init`, and prints a per-table summary: `users  3 candidate(s): email, phone, ip_address`. Honors the host's manifest `dictionary.extend` / `.exclude` if a scrub manifest is already configured. Skip with `--no-pii-scan` if you want the previous flow only.
- **`dbx analyze --suggest-scrub` writes a draft scrub manifest** containing suggested strategies for every dictionary-matching column found by the pre-scan. Defaults the output path to `dbx.scrub.json` next to your config; override with `--manifest-output FILE`. Equivalent to running `dbx scrub init <host>/<db> --output …` but as a one-shot during analyze. Inherits the configured `seed_env` name from the existing manifest (if any), so re-running it doesn't fight a chosen seed convention.
- **`dbx scrub init/check local/<db>`** — run scrub commands against a database that already lives in the managed `postgres-dbx` / `mysql-dbx` container without configuring a host. The pseudo-host `local` (alias `localhost`) auto-detects which container holds the named db (postgres wins if both have it) and uses the container's root credentials. `dbx scrub check local/<db>` requires `--manifest <path>` since there's no host config to resolve. Useful for iterating on a manifest against a freshly-restored snapshot before wiring up a real source.
- **Man pages.** `man dbx` and `man dbx-<subcommand>` now work for every top-level command. 17 hand-written roff/groff pages under `man/man1/` (no `pandoc`/`ronn` build dep): `dbx`, `dbx-backup`, `dbx-restore`, `dbx-verify`, `dbx-list`, `dbx-clean`, `dbx-query`, `dbx-test`, `dbx-analyze`, `dbx-host`, `dbx-config`, `dbx-vault`, `dbx-wizard`, `dbx-schedule`, `dbx-storage`, `dbx-scrub`, `dbx-completion`. `install.sh` fetches them into `~/.local/share/man/man1/` (override with `$DBX_MAN_DIR`) and prints a `MANPATH` hint when the parent dir isn't already on `manpath`. `mandoc -Tlint` clean.

### Changed

- **Wizard UX polish: bumped contrast + saturation.** User feedback was "the UX of this wizard is awful, needs more color. It's so dark and hard to read." Conservative changes only — no redesign:
  - Primary accent goes from a muted `#0b6bcb` to a vibrant `#0066ff` in light mode (dark mode's `#4ea8de` was already fine). Primary buttons and active sidebar items now pop instead of fading into the chrome.
  - Sidebar background is now meaningfully distinct from the main content (light: `#eef1f7` vs `#fff`; dark: `#0e1014` vs `#14161a`) so the left nav reads as a separate region.
  - `--md-default-fg-color--lightest` is darker / lighter in both modes so table dividers + section borders are actually visible (was nearly invisible at `#24272e` on `#14161a` in dark mode).
  - Status chip backgrounds (`--age`, `--gpg`, `--complete`, `--incomplete`, `--prod`, `--stage`) bumped from ~15% alpha to ~28-30% so they read as filled chips, not whisper-tints. Dark-mode chip text is lightened to keep legibility on the more-saturated fills.
  - Section dividers in main views: `.dbx-view__header` now has a bottom border so the header reliably separates from the table/form below.
  - Active sidebar nav item is rendered in the accent color (in addition to the left-edge accent bar) so the current tab is unmistakable.
- **`dbx restore <TAB>` shows only `<host>/<db>/latest` rows by default.** Previously the completion brain emitted every backup filename for every host/db pair *as well as* the `latest` alias — for a moderately-used data dir that was hundreds of timestamped rows in the TAB ring, and the `latest` alias (which is what the user wants ~95% of the time) was buried in the middle. Now the default list is one `<host>/<db>/latest` per pair. Drill-down still works: once you've typed `host/db/<prefix>`, TAB emits the specific filenames for that one host/db so you can complete a timestamp. Lifts a small UX friction on every restore.

### Fixed

- **`dbx backup -v` now surfaces `mysql_detect_server_version` diagnostics.** Several users have seen prod-mysql backups land with `source_flavor: "unknown"` and `source_major_version: "0"` in their `.meta.json` — that's the sentinel `mysql_parse_version_string` returns when the upstream `SELECT VERSION()` query failed. The helper used to silence the underlying `mysql` client stderr via `2>/dev/null`, so when detection failed there was zero diagnostic — no way to tell whether it was an auth failure, a network failure, the SSH tunnel not being up yet, or a version-string format the regex didn't match. Under `DBX_VERBOSE=1` the helper now logs (a) the connection target, (b) the docker exec exit code, (c) the raw stdout (printf %q-escaped so newlines / control chars don't break the log), and (d) every stderr line. Pair with `dbx backup -v <host> <db>` to triage. Part 1 of fix; the actual root cause + permanent fix lands in part 2 once the diagnostic surfaces what's actually going wrong in the user's env.
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
