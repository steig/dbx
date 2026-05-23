# AGENTS.md - dbx

Database backup and restore CLI utility written entirely in Bash. Uses Docker
for pg_dump/mysqldump (no local DB install needed). Supports SSH tunnels,
encryption (age/GPG), S3 storage, and scheduled backups.

## Project Structure

```
dbx                    # Main entrypoint script (~1800 lines), houses cmd_* dispatchers (config, vault, schedule, storage, host)
lib/
  core.sh              # Config, logging, vault, crypto, verification, utilities
  tunnel.sh            # SSH tunnel creation/cleanup
  encrypt.sh           # Age and GPG encryption (unified interface)
  postgres.sh          # PostgreSQL backup, restore, analysis
  mysql.sh             # MySQL/MariaDB backup, restore, analysis
  notify.sh            # Notification backends (Slack, desktop, email, command)
  schedule.sh          # Scheduled backups (launchd on macOS, systemd on Linux)
  storage.sh           # Cloud storage (S3/MinIO via mc or aws CLI)
  update.sh            # GitHub Releases API check + caching
install.sh             # Curl-based installer script
tests/
  helpers/             # Shared bats helpers
  unit/                # Pure-function tests, no docker
  integration/         # CLI round-trip tests against real postgres + mysql
```

## Build / Lint / Test Commands

There is no build step. This is a pure Bash project.

### Linting

```bash
# ShellCheck (CI runs with severity=error)
shellcheck dbx lib/*.sh

# Bash syntax check
bash -n dbx && for f in lib/*.sh; do bash -n "$f"; done
```

### Testing & CI

Two-tier bats test suite under `tests/`. See `tests/README.md` for layout, conventions, and a debugging guide.

```bash
# Unit tests — pure functions, no docker, ~1s
bats tests/unit/

# Integration tests — boots postgres-dbx + mysql-dbx, runs CLI
# round-trips, ~30s. Requires docker.
bats tests/integration/

# Full sweep
bats tests/unit/ tests/integration/
```

CI (`.github/workflows/ci.yml`, push/PR to `main`) runs:
1. **Shellcheck** (severity: error) on all `.sh` files and `dbx`
2. **Bash syntax** (`bash -n`) on all scripts
3. **Test Install** — runs `install.sh`, verifies `dbx help` works (ubuntu + macOS matrix)
4. **Unit tests (bats)** — ubuntu + macOS matrix
5. **Integration tests (docker)** — ubuntu only

Pre-PR smoke check:
```bash
bash -n dbx && for f in lib/*.sh; do bash -n "$f"; done
shellcheck -S error dbx lib/*.sh
bats tests/unit/ tests/integration/
```

### Lessons / patterns to follow

The early test pass surfaced eight bugs whose root causes are easy to repeat. If you find yourself writing one of these patterns, look twice.

- **`((var++))` under `set -e`.** `((expr))` returns 1 when `expr` evaluates to 0, which under strict mode exits the script. Counter increments where `var` starts at 0 must use `((var++)) || true` (or `var=$((var + 1))`).
- **`cmd1 | cmd2 | head -N` under `set -o pipefail`.** If `cmd1` exits non-zero (e.g. `ls` with a missing glob), the whole pipeline returns non-zero, and the surrounding `var=$()` exits the script. Append `|| true`.
- **`jq '... | keys[]'` on null.** Errors at runtime when the path doesn't exist. Use `keys[]?` (the optional iterator) plus `|| true` if you want a clean empty-string fallback.
- **Cross-platform sed.** GNU sed accepts `\s`, `\d`, `\w`. BSD sed (macOS default) does not. Use POSIX classes: `[[:space:]]`, `[[:digit:]]`, `[[:alnum:]]`.
- **`tr -c` with `echo` input.** `echo` adds a trailing newline; `tr -c '<allowed>'` translates that newline along with everything else, leaving a `-` (or whatever) at the end of the output. Use `printf '%s'` for input that shouldn't have a trailing newline.
- **`ls -t pat1 pat2 pat3`.** Returns 2 if any of the patterns have no matches, even with `2>/dev/null` redirected. Wrap the pipeline in `|| true`, or use `find -type f \( -name pat1 -o -name pat2 \)` instead.
- **Don't install EXIT traps at module load time.** A library that calls `trap '...' EXIT INT TERM` on source clobbers the caller's trap. Define the function but require the caller to invoke it (see `setup_security_trap` in `lib/core.sh`).
- **`local x=$(cmd)` masks return codes (SC2155).** Splitting `local x; x=$(cmd)` lets `set -e` see failures.
- **Postgres `server_version_num` is `MMMmmmm` for PG 10+** (130000 = 13, 160003 = 16). Parsing via `(raw / 10000)` gives the major. Pre-10 used `MMmmm` (90605 = 9.6) — dbx targets PG 10+ only, so we don't handle it.
- **MariaDB's `VERSION()` contains the literal substring "MariaDB"** (e.g. `10.11.6-MariaDB-1:10.11.6+maria~ubu2204`). Detect flavor by substring match, not by parsing the first numeric component.
- **`docker exec -i` inside a `while read` loop steals the loop's stdin.** Add `< /dev/null` to detection helpers like `pg_detect_extensions` when they're called inside multi-database backup loops, or the second iteration silently skips.
- **bats `setup_file` locals aren't visible in `@test` bodies** unless explicitly `export`ed. Use `export TEST_CONTAINER=...` when sharing container names across tests.
- **`mysqldump --set-gtid-purged=OFF` is a MySQL-only flag.** MariaDB's mysqldump rejects it as unknown. Branch on `flavor` before adding it.
- **Container-to-container connectivity in tests** prefers the Docker bridge IP (`docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'`) over host-port forwarding. NixOS firewalls often block container → host:loopback even when the host port is published.

## Code Style Guidelines

### Shell Conventions

- **Shebang**: `#!/usr/bin/env bash` on all files
- **Strict mode**: `set -euo pipefail` in the main `dbx` script only (not in libs)
- **Quoting**: Always double-quote variables: `"$var"`, `"$@"`, `"${array[@]}"`
- **Variable declaration**: Use `local` for all function-scoped variables
- **Command substitution**: Use `$(cmd)` not backticks
- **Conditionals**: Use `[[ ]]` not `[ ]`; use `&&`/`||` for simple checks
- **String comparison**: `[[ "$var" == "value" ]]` (double equals)

### Naming Conventions

- **Functions**: `snake_case` -- e.g., `get_config_value`, `create_ssh_tunnel`
- **Command functions**: `cmd_<name>` in main `dbx` script (e.g., `cmd_backup`)
- **Module-prefixed helpers**: `pg_backup`, `mysql_backup`, `mc_upload`, `aws_upload`
- **Global constants**: `UPPER_SNAKE_CASE` -- e.g., `DATA_DIR`, `CONFIG_FILE`
- **Local variables**: `lower_snake_case`
- **Environment overrides**: `DBX_` prefix -- e.g., `DBX_DATA_DIR`, `DBX_POSTGRES_CONTAINER`

### Error Handling

- Use `die "message"` for fatal errors (logs to stderr, exits 1)
- Use `log_error` for non-fatal errors
- Use `log_warn` for warnings
- Check command existence with `command -v cmd &>/dev/null`
- Redirect stderr: `2>/dev/null` or `2>&1`
- Use `|| true` to prevent `set -e` from exiting on expected failures
- Pattern: `result=$(cmd 2>/dev/null || true)` then check `[[ -n "$result" ]]`

### Logging

Use functions from `lib/core.sh`:
```bash
log_info "message"      # Blue [INFO]
log_success "message"   # Green [OK]
log_warn "message"      # Yellow [WARN]
log_error "message"     # Red [ERROR] (stderr)
log_step "message"      # Cyan ==> Bold
die "message"           # log_error + exit 1
```

### Argument Parsing

Use `while [[ $# -gt 0 ]]; do case "$1" in ... esac; done` pattern:
```bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) verbose=true; shift ;;
    --name|-n)    name="$2"; shift 2 ;;
    -*)           die "Unknown option: $1" ;;
    *)            positional_args+=("$1"); shift ;;
  esac
done
```

### Platform Compatibility

- Support both macOS and Linux
- Use `is_macos` / `is_linux` helpers from core.sh for platform branching
- `stat` differs: use `stat -f%z "$f" 2>/dev/null || stat -c%s "$f"`
- `sed -i` differs: handle both `sed -i ''` (macOS) and `sed -i` (Linux)
- `sha256sum` vs `shasum -a 256`: try both with fallback
- Use `ps -eo pid,command` instead of `pgrep -a` (macOS compat)

### Security Practices

- Never log passwords or secrets
- Use `chmod 600` on credential/config files (`secure_file`)
- Use `chmod 700` on sensitive directories (`secure_dir`)
- Prefer vault/keychain over plaintext passwords in config
- Clean up temp files in traps: `trap "rm -rf '$tmpdir'" RETURN`
- Clean up secrets on exit: `cleanup_secrets` removes env vars
- Use `create_mysql_credential_file` instead of passing passwords on CLI

### Docker Usage

- All DB operations run inside Docker containers (`postgres-dbx`, `mysql-dbx`)
- Containers are auto-created by `require_container` if they don't exist
- Pass credentials via environment variables to containers, not CLI args
- Use `docker exec -e PGPASSWORD=... / MYSQL_PWD=...` for auth

### Config Access

- Config is JSON at `~/.config/dbx/config.json`
- Use `get_config_value ".path.to.key"` (wraps `jq -r "$path // empty"`)
- Use `get_host_config "$host"` for full host object
- Check for null/empty with `[[ -n "$val" && "$val" != "null" ]]`

### Adding a New Command

1. Add `cmd_<name>()` function in `dbx`
2. Add case to `main()` dispatcher (include aliases if appropriate)
3. Add to `cmd_help()` output
4. Update usage comment block at top of `dbx`
5. If it needs a new library, create `lib/<name>.sh` and source it at top of `dbx`

### Adding a New Library Module

1. Create `lib/<name>.sh` with proper header
2. Source it in `dbx` after its dependencies (core.sh must be first)
3. Prefix public functions with the module name
4. Update `install.sh` to include the new file in the download list
5. Update `tests/helpers/common.bash::source_dbx_libs` so unit tests can call into the new module
6. Don't fire EXIT traps or other side effects at module load time — define the function and have `dbx` call it

### Adding a Test

Pure function (fast, runs in CI on ubuntu + macOS):
```bash
# tests/unit/<lib>.bats
load '../helpers/common'
setup() { setup_dbx_env; source_dbx_libs; }

@test "describe what is being tested" {
  result=$(your_function arg)
  [ "$result" = "expected" ]
}
```

End-to-end behavior (slower, ubuntu-only, needs docker):
```bash
# tests/integration/<feature>.bats
load '../helpers/integration'
setup_file() { require_docker; ensure_postgres_container; }
setup() { setup_dbx_env; write_local_config; }

@test "behavior under <condition>" {
  dbx_run backup local-pg some_db
  [ "$status" -eq 0 ]
}
```
