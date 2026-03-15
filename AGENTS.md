# AGENTS.md - dbx

Database backup and restore CLI utility written entirely in Bash. Uses Docker
for pg_dump/mysqldump (no local DB install needed). Supports SSH tunnels,
encryption (age/GPG), S3 storage, scheduled backups, and a TUI mode.

## Project Structure

```
dbx                    # Main entrypoint script (~1900 lines)
lib/
  core.sh              # Config, logging, vault, crypto, verification, utilities
  tunnel.sh            # SSH tunnel creation/cleanup
  encrypt.sh           # Age and GPG encryption (unified interface)
  postgres.sh          # PostgreSQL backup, restore, analysis
  mysql.sh             # MySQL/MariaDB backup, restore, analysis
  notify.sh            # Notification backends (Slack, desktop, email, command)
  schedule.sh          # Scheduled backups (launchd on macOS, systemd on Linux)
  storage.sh           # Cloud storage (S3/MinIO via mc or aws CLI)
install.sh             # Curl-based installer script
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

No formal test suite. CI (`.github/workflows/ci.yml`, push/PR to `main`) validates:
1. ShellCheck passes (severity: error) on all `.sh` files and `dbx`
2. Bash syntax check (`bash -n`) on all scripts
3. Install script works + `dbx help` runs (ubuntu + macOS matrix)
4. `dbx config init` creates a valid config file

Verify changes manually:
```bash
bash -n dbx && for f in lib/*.sh; do bash -n "$f"; done  # syntax
shellcheck dbx lib/*.sh                                   # lint
./dbx help && ./dbx version                               # smoke test
```

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
