#!/usr/bin/env bash
#
# lib/core.sh - Core utilities, configuration, and logging
#

# ============================================================================
# Configuration
# ============================================================================

DATA_DIR="${DBX_DATA_DIR:-$HOME/.data/dbx}"
CONFIG_DIR="${DBX_CONFIG_DIR:-$HOME/.config/dbx}"
CONFIG_FILE="$CONFIG_DIR/config.json"

# Docker container names
POSTGRES_CONTAINER="${DBX_POSTGRES_CONTAINER:-postgres-dbx}"
MYSQL_CONTAINER="${DBX_MYSQL_CONTAINER:-mysql-dbx}"

# macOS Keychain service name for credentials
KEYCHAIN_SERVICE="dbx"

# ============================================================================
# Colors (disabled if not a TTY)
# ============================================================================

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  BLUE=$'\033[0;34m'
  CYAN=$'\033[0;36m'
  NC=$'\033[0m'
  BOLD=$'\033[1m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  CYAN=''
  NC=''
  BOLD=''
fi

# ============================================================================
# Logging Functions
# ============================================================================

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step() { echo -e "${CYAN}==>${NC} ${BOLD}$*${NC}"; }

die() {
  log_error "$@"
  exit 1
}

# ============================================================================
# Requirement Checks
# ============================================================================

require_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    die "Config not found. Run: dbx config init"
  fi
  # Ensure config has secure permissions (contains host info)
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

require_jq() {
  command -v jq &>/dev/null || die "jq is required but not installed"
}

require_docker() {
  command -v docker &>/dev/null || die "docker is required but not installed"
}

# Compose the docker `-p` publish mapping for an auto-managed dev container.
# The host-side port is configurable (DBX_PG_HOST_PORT / DBX_MYSQL_HOST_PORT) so
# the container can avoid clashing with a Postgres/MySQL already bound to the
# engine default on the host. The container-internal port is always the engine
# default. An empty/unset host port falls back to it.
#   $1 = bind address (e.g. 127.0.0.1)
#   $2 = host port (may be empty)
#   $3 = container/internal port (the engine default)
dbx_publish_arg() {
  local bind_addr="$1" host_port="${2:-}" container_port="$3"
  printf '%s:%s:%s' "$bind_addr" "${host_port:-$container_port}" "$container_port"
}

# Read the host port an existing container is published on for a given
# container-internal port; empty if unbound. Reads HostConfig.PortBindings so it
# works for stopped containers too (NetworkSettings.Ports is only populated while
# the container is running). Takes the first binding if several are present.
#   $1 = container name   $2 = container-internal port (e.g. 5432)
dbx_container_host_port() {
  local container="$1" internal="$2"
  docker inspect \
    -f "{{with index .HostConfig.PortBindings \"${internal}/tcp\"}}{{range .}}{{.HostPort}} {{end}}{{end}}" \
    "$container" 2>/dev/null | awk '{print $1}'
}

# Pure predicate (no docker, so unit-testable): a published-port mismatch is
# worth warning about only when both the container's current port and the
# requested port are known and they differ.
#   $1 = host port the container actually has   $2 = host port requested now
dbx_port_mismatch() {
  local have="$1" want="$2"
  [[ -n "$have" && -n "$want" && "$have" != "$want" ]]
}

# Warn (don't fail) when an existing managed container is published on a host
# port other than the one currently requested. The published port is fixed at
# `docker run` time, so changing DBX_PG_HOST_PORT / DBX_MYSQL_HOST_PORT has no
# effect until the container is recreated — surface that instead of silently
# ignoring the override (or, on a now-occupied port, dying with an opaque error).
#   $1 = container name   $2 = container-internal port   $3 = requested host port
warn_stale_container_port() {
  local container="$1" internal="$2" want_host="$3"
  [[ -n "$internal" && -n "$want_host" ]] || return 0
  local have_host
  have_host=$(dbx_container_host_port "$container" "$internal")
  dbx_port_mismatch "$have_host" "$want_host" || return 0
  log_warn "Container '$container' is published on host port ${have_host}, but ${want_host} was requested."
  log_warn "A container's published port is fixed when it is created — recreate it to apply the new port:"
  log_warn "  docker rm -f $container    # on-disk backups in \$DBX_DATA_DIR are unaffected"
}

require_container() {
  local container="$1"

  # The published host port for the managed containers is fixed at `docker run`
  # time, so changing DBX_PG_HOST_PORT / DBX_MYSQL_HOST_PORT has no effect on an
  # already-created container. Resolve the requested host + internal port up front
  # so we can flag a stale binding clearly rather than silently ignoring the
  # override or hitting an opaque bind error.
  local want_internal="" want_host=""
  case "$container" in
    postgres-dbx) want_internal=5432; want_host="${DBX_PG_HOST_PORT:-5432}" ;;
    mysql-dbx)    want_internal=3306; want_host="${DBX_MYSQL_HOST_PORT:-3306}" ;;
  esac

  # Already running?
  if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
    warn_stale_container_port "$container" "$want_internal" "$want_host"
    return 0
  fi

  # Exists but stopped? Start it
  if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
    warn_stale_container_port "$container" "$want_internal" "$want_host"
    log_info "Starting stopped container: $container"
    if ! docker start "$container" >/dev/null 2>&1; then
      log_error "Failed to start existing container '$container'."
      log_error "If the cause is a port conflict, recreate it to (re)bind the port:"
      log_error "  docker rm -f $container    # on-disk backups in \$DBX_DATA_DIR are unaffected"
      die "could not start container: $container"
    fi
    sleep 2
    return 0
  fi

  # Doesn't exist - create it.
  # Bind to loopback by default so the auto-managed dev containers aren't
  # reachable from the LAN with the default password. Override the interface
  # with DBX_BIND_ADDR (e.g. 0.0.0.0) if you have a reason to expose them, and
  # the published host port with DBX_PG_HOST_PORT / DBX_MYSQL_HOST_PORT if the
  # default 5432 / 3306 collides with a Postgres / MySQL already on the host.
  # --add-host=host.docker.internal:host-gateway makes the host reachable
  # from inside the container at the same well-known name on macOS, Linux,
  # rootless docker, and podman — so SSH-tunnel mode can use one address
  # rather than guessing the bridge IP.
  local bind_addr="${DBX_BIND_ADDR:-127.0.0.1}"
  log_info "Creating container: $container"
  case "$container" in
    postgres-dbx)
      docker run -d --name postgres-dbx \
        --add-host=host.docker.internal:host-gateway \
        -e POSTGRES_PASSWORD="${DBX_PG_PASSWORD:-devpassword}" \
        -e POSTGRES_INITDB_ARGS="--encoding=UTF8 --locale=C.UTF-8" \
        -e LANG=C.UTF-8 \
        -p "$(dbx_publish_arg "$bind_addr" "${DBX_PG_HOST_PORT:-}" 5432)" \
        "${DBX_FORCE_IMAGE:-postgres:17-alpine}" >/dev/null
      unset DBX_FORCE_IMAGE
      # Wait for postgres to be ready
      log_info "Waiting for PostgreSQL to initialize..."
      for i in {1..30}; do
        if docker exec postgres-dbx pg_isready -U postgres >/dev/null 2>&1; then
          break
        fi
        sleep 1
      done
      ;;
    mysql-dbx)
      docker run -d --name mysql-dbx \
        --add-host=host.docker.internal:host-gateway \
        -e MYSQL_ROOT_PASSWORD="${DBX_MYSQL_PASSWORD:-devpassword}" \
        -p "$(dbx_publish_arg "$bind_addr" "${DBX_MYSQL_HOST_PORT:-}" 3306)" \
        "${DBX_FORCE_IMAGE:-mysql:8.0}" >/dev/null
      unset DBX_FORCE_IMAGE
      # Wait for mysql to be ready
      log_info "Waiting for MySQL to initialize..."
      for i in {1..60}; do
        if docker exec -e MYSQL_PWD="${DBX_MYSQL_PASSWORD:-devpassword}" mysql-dbx mysqladmin ping -h localhost -u root >/dev/null 2>&1; then
          break
        fi
        sleep 1
      done
      ;;
    *)
      die "Unknown container: $container"
      ;;
  esac
}

# ============================================================================
# Config Accessors
# ============================================================================

get_config_value() {
  local path="$1"
  jq -r "$path // empty" "$CONFIG_FILE"
}

get_host_config() {
  local host="$1"
  jq -r ".hosts[\"$host\"] // empty" "$CONFIG_FILE"
}

get_db_type() {
  local host="$1"
  get_config_value ".hosts[\"$host\"].type"
}

get_excluded_tables() {
  local host="$1"
  local database="$2"
  jq -r ".hosts[\"$host\"].databases[\"$database\"].exclude_data // [] | .[]" "$CONFIG_FILE" 2>/dev/null
}

get_parallel_jobs() {
  local host="$1"
  local database="$2"
  local jobs
  jobs=$(jq -r ".hosts[\"$host\"].databases[\"$database\"].parallel_jobs // .defaults.parallel_jobs // 4" "$CONFIG_FILE")
  echo "$jobs"
}

get_definer_handling() {
  local host="$1"
  local handling
  handling=$(get_config_value ".hosts[\"$host\"].definer_handling")
  echo "${handling:-strip}"  # Default to strip for safety
}

# Validate a host alias string. Allowed: alphanumeric start, then
# alphanumerics / underscore / dash. Keeps the alias safe to pass through
# `dbx test "$alias"`, jq paths, vault keys, etc. without quoting hazards.
host_alias_valid() {
  local name="${1:-}"
  [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]
}

# Return 0 if the given host alias exists in the config, 1 otherwise.
host_exists() {
  local name="${1:-}"
  [[ -z "$name" ]] && return 1
  local found
  found=$(jq -r --arg h "$name" '.hosts | has($h)' "$CONFIG_FILE" 2>/dev/null || echo "false")
  [[ "$found" == "true" ]]
}

# Echo the safety level for a host alias. One of `prod`, `stage`, `local`.
# Falls back to `local` if the field is missing OR set to anything outside
# the allowed set (defense in depth — `config validate` catches malformed
# values up front, but a typo'd hand-edit shouldn't silently promote a
# host to a level the user didn't mean).
# Args: $1 = host alias
host_safety() {
  local alias="${1:-}"
  [[ -z "$alias" ]] && { echo "local"; return; }
  local s
  s=$(jq -r --arg a "$alias" '.hosts[$a].safety // "local"' "$CONFIG_FILE" 2>/dev/null || echo "local")
  case "$s" in
    prod|stage|local) echo "$s" ;;
    *) echo "local" ;;
  esac
}

# Die with a clear error if the host is marked prod. Used at write-shaped
# call sites (restore --into, post-restore hooks, scrub apply). Reads are
# never blocked — pg_dump / SELECT-only flows don't call this.
# Args: $1 = host alias, $2 = action description (e.g. "restore", "post-restore hooks")
require_writable_host() {
  local alias="${1:-}" action="${2:-write}"
  [[ -z "$alias" ]] && return 0
  local safety
  safety=$(host_safety "$alias")
  if [[ "$safety" == "prod" ]]; then
    die "Refusing $action against host '$alias' (safety=prod). Remove the safety flag in config.json if this is intentional."
  fi
}

# ============================================================================
# Keychain/Vault Functions (cross-platform credential storage)
# ============================================================================
#
# Backends by priority:
#   1. macOS: security (Keychain)
#   2. Linux desktop: secret-tool (libsecret/GNOME Keyring)
#   3. Linux headless: pass (password-store)
#   4. Fallback: GPG-encrypted file
#
# ============================================================================

# Detect platform
is_macos() { [[ "$(uname)" == "Darwin" ]]; }
is_linux() { [[ "$(uname)" == "Linux" ]]; }

# GPG-encrypted vault file location
VAULT_GPG_FILE="$CONFIG_DIR/vault.gpg"
VAULT_GPG_KEY=""  # Set via config or DBX_GPG_KEY env
_VAULT_BACKEND_CACHE=""

# Detect available vault backend
detect_vault_backend() {
  if [[ -n "$_VAULT_BACKEND_CACHE" ]]; then
    echo "$_VAULT_BACKEND_CACHE"
    return
  fi

  local result=""
  local configured_backend
  configured_backend=$(get_config_value ".vault.backend" 2>/dev/null || echo "")

  # If explicitly configured, use that
  if [[ -n "$configured_backend" && "$configured_backend" != "auto" ]]; then
    result="$configured_backend"
  elif is_macos; then
    result="keychain"
  elif is_linux && command -v secret-tool &>/dev/null; then
    result="secret-tool"
  elif command -v pass &>/dev/null; then
    result="pass"
  elif command -v gpg &>/dev/null; then
    result="gpg-file"
  else
    result="none"
  fi

  _VAULT_BACKEND_CACHE="$result"
  echo "$result"
}

# Get configured GPG key for vault
get_vault_gpg_key() {
  if [[ -n "${DBX_GPG_KEY:-}" ]]; then
    echo "$DBX_GPG_KEY"
  else
    get_config_value ".vault.gpg_key" 2>/dev/null || echo ""
  fi
}

# ============================================================================
# pass (password-store) backend
# ============================================================================

pass_get() {
  local account="$1"
  pass show "dbx/$account" 2>/dev/null | head -1
}

pass_set() {
  local account="$1"
  local password="$2"
  echo "$password" | pass insert -f "dbx/$account" 2>/dev/null
}

pass_delete() {
  local account="$1"
  pass rm -f "dbx/$account" 2>/dev/null
}

pass_list() {
  pass ls dbx 2>/dev/null | tail -n +2 | sed 's/[├└│─ ]//g' | grep -v '^$' | sort -u
}

# ============================================================================
# GPG-encrypted file backend (fallback for headless systems)
# ============================================================================

gpg_file_read() {
  if [[ ! -f "$VAULT_GPG_FILE" ]]; then
    echo "{}"
    return
  fi

  # GPG auto-detects symmetric vs asymmetric encryption
  # For asymmetric: uses matching private key from keyring
  # For symmetric: prompts for passphrase (or uses agent)
  gpg --batch --yes --decrypt "$VAULT_GPG_FILE" 2>/dev/null || echo "{}"
}

gpg_file_write() {
  local data="$1"
  local gpg_key
  gpg_key=$(get_vault_gpg_key)

  mkdir -p "$(dirname "$VAULT_GPG_FILE")"

  if [[ -n "$gpg_key" ]]; then
    echo "$data" | gpg --batch --yes -e -r "$gpg_key" -o "$VAULT_GPG_FILE"
  else
    # Symmetric encryption if no key specified
    local passphrase
    passphrase=$(get_encryption_key 2>/dev/null || true)
    if [[ -z "$passphrase" ]]; then
      die "No GPG key or encryption passphrase set for vault. Set DBX_GPG_KEY or run: dbx vault set-encryption-key"
    fi
    echo "$data" | gpg --batch --yes --passphrase "$passphrase" --symmetric --cipher-algo AES256 -o "$VAULT_GPG_FILE"
  fi
  chmod 600 "$VAULT_GPG_FILE"
}

gpg_file_get() {
  local account="$1"
  local data
  data=$(gpg_file_read)
  echo "$data" | jq -r ".[\"$account\"] // empty"
}

gpg_file_set() {
  local account="$1"
  local password="$2"
  local data
  data=$(gpg_file_read)
  data=$(echo "$data" | jq --arg k "$account" --arg v "$password" '.[$k] = $v')
  gpg_file_write "$data"
}

gpg_file_delete() {
  local account="$1"
  local data
  data=$(gpg_file_read)
  data=$(echo "$data" | jq --arg k "$account" 'del(.[$k])')
  gpg_file_write "$data"
}

gpg_file_list() {
  local data
  data=$(gpg_file_read)
  echo "$data" | jq -r 'keys[]' 2>/dev/null | sort -u
}

# ============================================================================
# Unified vault interface
# ============================================================================

keychain_get() {
  local account="$1"
  local backend
  backend=$(detect_vault_backend)

  case "$backend" in
    keychain)
      security find-generic-password -a "$account" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null
      ;;
    secret-tool)
      secret-tool lookup service "$KEYCHAIN_SERVICE" account "$account" 2>/dev/null
      ;;
    pass)
      pass_get "$account"
      ;;
    gpg-file)
      gpg_file_get "$account"
      ;;
    *)
      return 1
      ;;
  esac
}

keychain_set() {
  local account="$1"
  local password="$2"
  local backend
  backend=$(detect_vault_backend)

  case "$backend" in
    keychain)
      security add-generic-password -U -a "$account" -s "$KEYCHAIN_SERVICE" -w "$password"
      ;;
    secret-tool)
      echo -n "$password" | secret-tool store --label="$KEYCHAIN_SERVICE: $account" service "$KEYCHAIN_SERVICE" account "$account"
      ;;
    pass)
      pass_set "$account" "$password"
      ;;
    gpg-file)
      gpg_file_set "$account" "$password"
      ;;
    *)
      die "No credential storage available. Install one of: libsecret-tools, pass, or gpg"
      ;;
  esac
}

keychain_delete() {
  local account="$1"
  local backend
  backend=$(detect_vault_backend)

  case "$backend" in
    keychain)
      security delete-generic-password -a "$account" -s "$KEYCHAIN_SERVICE" 2>/dev/null
      ;;
    secret-tool)
      secret-tool clear service "$KEYCHAIN_SERVICE" account "$account" 2>/dev/null
      ;;
    pass)
      pass_delete "$account"
      ;;
    gpg-file)
      gpg_file_delete "$account"
      ;;
  esac
}

keychain_list() {
  local backend
  backend=$(detect_vault_backend)

  case "$backend" in
    keychain)
      # security dump-keychain emits each entry as a block of ~15 attribute
      # lines, with "acct" appearing 13 lines BEFORE "svce" in the modern
      # macOS format. The previous -B5 window was too narrow and silently
      # dropped every entry — `dbx vault list` then printed "(none)" while
      # `find-generic-password -s dbx -a <key>` still worked. -B20 is
      # comfortable headroom; sort -u dedupes if grep grabs adjacent blocks.
      security dump-keychain 2>/dev/null | grep -B20 "\"svce\"<blob>=\"$KEYCHAIN_SERVICE\"" | grep "\"acct\"" | sed 's/.*<blob>="\([^"]*\)".*/\1/' | sort -u
      ;;
    secret-tool)
      secret-tool search --all service "$KEYCHAIN_SERVICE" 2>/dev/null | grep "^attribute.account" | cut -d= -f2 | tr -d ' ' | sort -u
      ;;
    pass)
      pass_list
      ;;
    gpg-file)
      gpg_file_list
      ;;
  esac
}

# Show current vault backend
vault_info() {
  local backend
  backend=$(detect_vault_backend)
  echo "Vault backend: $backend"

  case "$backend" in
    keychain)
      echo "Location: macOS Keychain (service: $KEYCHAIN_SERVICE)"
      ;;
    secret-tool)
      echo "Location: GNOME Keyring / libsecret (service: $KEYCHAIN_SERVICE)"
      ;;
    pass)
      local store_dir="${PASSWORD_STORE_DIR:-$HOME/.password-store}"
      echo "Location: $store_dir/dbx/"
      ;;
    gpg-file)
      echo "Location: $VAULT_GPG_FILE"
      local gpg_key
      gpg_key=$(get_vault_gpg_key)
      if [[ -n "$gpg_key" ]]; then
        echo "GPG Key: $gpg_key"
      else
        echo "Encryption: symmetric (requires encryption key)"
      fi
      ;;
    none)
      echo "No vault backend available"
      ;;
  esac
}

# Resolve the password for a configured host. Tries sources in order:
#   1. The system vault backend (keychain / secret-tool / pass / gpg-file)
#   2. The configured `password_cmd` (eval'd — anything that prints a
#      password to stdout works, e.g. `op read op://...`)
#   3. Plaintext `.hosts[host].password` in the config file (dev only)
# Echoes the password on success; echoes nothing if no source succeeds.
get_password() {
  local host="$1"

  local keychain_pass
  keychain_pass=$(keychain_get "$host" 2>/dev/null || true)
  if [[ -n "$keychain_pass" ]]; then
    echo "$keychain_pass"
    return
  fi

  local password_cmd
  password_cmd=$(get_config_value ".hosts[\"$host\"].password_cmd")
  if [[ -n "$password_cmd" ]]; then
    eval "$password_cmd"
    return
  fi

  get_config_value ".hosts[\"$host\"].password"
}

# ============================================================================
# Encryption Functions
# ============================================================================

ENCRYPTION_KEY_ACCOUNT="_dbx_encryption_key"

get_encryption_key() {
  keychain_get "$ENCRYPTION_KEY_ACCOUNT" 2>/dev/null
}

set_encryption_key() {
  local key="$1"
  keychain_set "$ENCRYPTION_KEY_ACCOUNT" "$key"
}

delete_encryption_key() {
  keychain_delete "$ENCRYPTION_KEY_ACCOUNT"
}

require_gpg() {
  command -v gpg &>/dev/null || die "gpg is required for encryption but not installed"
}

# Encrypt stdin to stdout using GPG symmetric encryption
encrypt_stream() {
  local passphrase
  passphrase=$(get_encryption_key)
  [[ -z "$passphrase" ]] && die "No encryption key set. Run: dbx vault set-encryption-key"

  gpg --batch --yes --passphrase "$passphrase" --symmetric --cipher-algo AES256 -
}

# Decrypt stdin to stdout
decrypt_stream() {
  local passphrase
  passphrase=$(get_encryption_key)
  [[ -z "$passphrase" ]] && die "No encryption key set. Run: dbx vault set-encryption-key"

  gpg --batch --yes --passphrase "$passphrase" --decrypt -
}

# Check if file is GPG encrypted
is_encrypted() {
  local file="$1"
  [[ "$file" == *.gpg ]]
}

# ============================================================================
# Utility Functions
# ============================================================================

timestamp() {
  date +"%Y%m%d_%H%M%S"
}

human_size() {
  local bytes="$1"
  if [[ $bytes -lt 1024 ]]; then
    echo "${bytes}B"
  elif [[ $bytes -lt 1048576 ]]; then
    echo "$((bytes / 1024))KB"
  elif [[ $bytes -lt 1073741824 ]]; then
    echo "$((bytes / 1048576))MB"
  else
    echo "$((bytes / 1073741824))GB"
  fi
}

# Strip MySQL DEFINER clauses for clean restores. Uses POSIX
# [[:space:]] rather than \s so the regex works under BSD sed (macOS).
strip_definer() {
  local handling="${1:-strip}"
  case "$handling" in
    strip)
      # Remove DEFINER clause entirely
      sed -E 's/DEFINER=`[^`]+`@`[^`]+`[[:space:]]*//g'
      ;;
    current_user)
      # Replace with CURRENT_USER
      sed -E 's/DEFINER=`[^`]+`@`[^`]+`/DEFINER=CURRENT_USER/g'
      ;;
    keep|*)
      # Pass through unchanged
      cat
      ;;
  esac
}

# Decompress from stdin based on extension hint
decompress_stdin() {
  local ext="$1"
  case "$ext" in
    zst) zstd -d ;;
    gz)  gunzip ;;
    sql) cat ;;
    *)   cat ;;
  esac
}

# ============================================================================
# Audit Logging
# ============================================================================

AUDIT_LOG_DIR="${DBX_AUDIT_DIR:-$HOME/.local/share/dbx}"
AUDIT_LOG_FILE="$AUDIT_LOG_DIR/audit.log"

# Append a JSON audit-log entry to ~/.local/share/dbx/audit.log.
# Args: $1=action ("backup", "restore", "vault_set", ...)
#       $2=outcome ("success" | "failure"; default "success")
#       $3..N=alternating key/value pairs added as extra fields
# Example:
#   audit_log "backup" "success" "db_host" "$h" "size" "$bytes"
audit_log() {
  local action="$1"
  local outcome="${2:-success}"
  shift 2

  # Ensure directory exists
  mkdir -p "$AUDIT_LOG_DIR"

  # Build JSON entry. `-c` (compact / one-line) is REQUIRED: the audit
  # log is JSONL (one object per line), and pretty-printed `jq` output
  # would split each entry across ~5 lines. Readers like the wizard
  # Runs view + `last_backup_baseline` then can't parse it.
  local entry
  entry=$(jq -nc \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg action "$action" \
    --arg outcome "$outcome" \
    --arg user "${USER:-unknown}" \
    --arg host "${HOSTNAME:-$(hostname)}" \
    '{timestamp: $ts, action: $action, outcome: $outcome, user: $user, host: $host}')

  # Add optional fields
  while [[ $# -gt 0 ]]; do
    local key="$1"
    local value="$2"
    shift 2
    entry=$(echo "$entry" | jq -c --arg k "$key" --arg v "$value" '. + {($k): $v}')
  done

  # Append to log
  echo "$entry" >> "$AUDIT_LOG_FILE"
  chmod 600 "$AUDIT_LOG_FILE"
}

# Audit helper for backup operations
audit_backup() {
  local host="$1"
  local database="$2"
  local outcome="$3"
  local file="${4:-}"
  local size="${5:-}"
  local duration="${6:-}"

  if [[ -n "$file" ]]; then
    audit_log "backup" "$outcome" \
      "db_host" "$host" \
      "database" "$database" \
      "file" "$file" \
      "size" "$size" \
      "duration_sec" "$duration"
  else
    audit_log "backup" "$outcome" \
      "db_host" "$host" \
      "database" "$database"
  fi
}

# Audit helper for restore operations
audit_restore() {
  local file="$1"
  local target_db="$2"
  local outcome="$3"
  local duration="${4:-}"

  audit_log "restore" "$outcome" \
    "file" "$file" \
    "target_db" "$target_db" \
    "duration_sec" "$duration"
}

# Audit helper for vault operations
audit_vault() {
  local operation="$1"  # get, set, delete
  local account="$2"
  local outcome="$3"

  audit_log "vault_$operation" "$outcome" \
    "account" "$account"
}

# ============================================================================
# Duration helpers
# ============================================================================

# Format an integer number of seconds as a short human-readable duration.
#   <60s         → "Ns"        (e.g. "5s", "0s")
#   <3600s       → "XmYs"      (e.g. "1m 5s")
#   >=3600s      → "XhYmZs"    (e.g. "1h 2m 5s")
#
# Used by cmd_backup / cmd_restore end-of-run summaries and the verbose
# per-step elapsed prefix. Negative / non-numeric input falls back to "0s"
# so callers don't have to validate.
format_duration() {
  local secs="$1"
  # Accept only non-negative integers; everything else collapses to 0.
  if [[ ! "$secs" =~ ^[0-9]+$ ]]; then
    echo "0s"
    return 0
  fi

  if [[ "$secs" -lt 60 ]]; then
    echo "${secs}s"
  elif [[ "$secs" -lt 3600 ]]; then
    local m=$((secs / 60))
    local s=$((secs % 60))
    echo "${m}m ${s}s"
  else
    local h=$((secs / 3600))
    local rem=$((secs % 3600))
    local m=$((rem / 60))
    local s=$((rem % 60))
    echo "${h}h ${m}m ${s}s"
  fi
}

# Look up the duration_sec of the most recent successful audit entry that
# matches the given action / host / database. Used to print a "last took Xs"
# baseline before backup / restore so the user has a rough ETA.
#
# Reads only the tail of $AUDIT_LOG_FILE (last 500 lines) to keep the call
# bounded — the audit log is append-only and grows forever.
#
# Args: $1=action ("backup" or "restore")
#       $2=host alias (matched against the `db_host` field; for restore the
#          audit entry doesn't carry db_host so $2 is ignored there)
#       $3=database name (matched against the `database` field; for restore
#          the entry doesn't carry it either — ignored)
#
# Outputs: the integer duration_sec on stdout when a match is found, or
#          nothing when there's no match / no audit log / jq fails.
# Never errors out — failure is silent so callers can `local x=$(...)`.
audit_last_duration() {
  local action="$1"
  local host="$2"
  local database="$3"

  [[ -z "$action" ]] && return 0
  [[ ! -f "$AUDIT_LOG_FILE" ]] && return 0

  # Tail-bounded read: the audit log is unbounded, so we deliberately scan
  # only the last ~500 lines. For typical use this covers months of history.
  # `jq -s` slurps the array; `last` picks the most recent match.
  local query
  if [[ "$action" == "backup" ]]; then
    # Backups have db_host + database fields; require both to match.
    query='[.[] | select(.action == $a and .outcome == "success"'
    query+=' and .db_host == $h and .database == $d'
    query+=' and (.duration_sec // null) != null'
    query+=' and (.duration_sec | tostring | test("^[0-9]+$")))] | last'
  else
    # Restores don't carry db_host/database — match on action+outcome only.
    query='[.[] | select(.action == $a and .outcome == "success"'
    query+=' and (.duration_sec // null) != null'
    query+=' and (.duration_sec | tostring | test("^[0-9]+$")))] | last'
  fi

  local last_entry
  last_entry=$(tail -500 "$AUDIT_LOG_FILE" 2>/dev/null \
    | jq -s --arg a "$action" --arg h "$host" --arg d "$database" \
        "$query" 2>/dev/null) || return 0
  [[ -z "$last_entry" || "$last_entry" == "null" ]] && return 0

  # Pull duration_sec; print iff it's an integer. Sizes are emitted as
  # strings by audit_log (jq --arg), so we accept either string-int or int.
  echo "$last_entry" | jq -r '.duration_sec // empty' 2>/dev/null \
    | head -1 \
    | grep -E '^[0-9]+$' || true
}

# Same shape as audit_last_duration but returns the .size field of the most
# recent matching success entry. Used alongside the duration baseline so
# we can say "last backup … took 1m 41s, produced 228 MB".
audit_last_size() {
  local action="$1"
  local host="$2"
  local database="$3"

  [[ -z "$action" ]] && return 0
  [[ ! -f "$AUDIT_LOG_FILE" ]] && return 0

  local query
  if [[ "$action" == "backup" ]]; then
    query='[.[] | select(.action == $a and .outcome == "success"'
    query+=' and .db_host == $h and .database == $d'
    query+=' and (.size // null) != null)] | last'
  else
    query='[.[] | select(.action == $a and .outcome == "success"'
    query+=' and (.size // null) != null)] | last'
  fi

  local last_entry
  last_entry=$(tail -500 "$AUDIT_LOG_FILE" 2>/dev/null \
    | jq -s --arg a "$action" --arg h "$host" --arg d "$database" \
        "$query" 2>/dev/null) || return 0
  [[ -z "$last_entry" || "$last_entry" == "null" ]] && return 0

  echo "$last_entry" | jq -r '.size // empty' 2>/dev/null \
    | head -1 \
    | grep -E '^[0-9]+$' || true
}

# Emit a "[INFO] +<elapsed> <msg>" line where elapsed is wall-clock seconds
# since $start_epoch formatted via format_duration. Used by pg_backup /
# mysql_backup under -v so the user sees a per-step heartbeat without us
# trying to maintain a live ticking cursor (which fragments across terminals).
#
# Args: $1=start epoch (output of `date +%s` from the function entry),
#       $2..N=message
log_step_elapsed() {
  local start="$1"
  shift
  local now elapsed
  now=$(date +%s)
  # Guard against clock skew / missing start — format_duration handles 0.
  if [[ "$start" =~ ^[0-9]+$ ]]; then
    elapsed=$((now - start))
    [[ "$elapsed" -lt 0 ]] && elapsed=0
  else
    elapsed=0
  fi
  log_info "+$(format_duration "$elapsed")  $*"
}

# ============================================================================
# Security Functions
# ============================================================================

# Warn if using plaintext password in config
warn_plaintext_password() {
  local host="$1"
  local has_plaintext
  has_plaintext=$(get_config_value ".hosts[\"$host\"].password")

  if [[ -n "$has_plaintext" ]]; then
    log_warn "Host '$host' uses plaintext password in config. Consider using: dbx vault set $host"
  fi
}

# Ensure secure file permissions
secure_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    chmod 600 "$file"
  fi
}

# Ensure secure directory permissions
secure_dir() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    chmod 700 "$dir"
  fi
}

# Create a [client] credential file for `mysql --defaults-extra-file`
# so we never pass the password on the command line (would show up in
# `ps`). Echoes the path to the new tempfile (chmod 600). Caller must
# remove it — typically via a RETURN trap on the surrounding function:
#   trap "rm -f '$cred_file'" RETURN
# Args: $1=user, $2=password, $3=host (default localhost), $4=port (3306)
create_mysql_credential_file() {
  local user="$1"
  local password="$2"
  local host="${3:-localhost}"
  local port="${4:-3306}"

  local cred_file
  cred_file=$(mktemp)

  cat > "$cred_file" << EOF
[client]
user=$user
password=$password
host=$host
port=$port
EOF

  chmod 600 "$cred_file"
  echo "$cred_file"
}

# Cleanup sensitive environment variables on exit. Run by the
# EXIT/INT/TERM trap installed by setup_security_trap. Cleared:
#   - db_pass, PGPASSWORD, MYSQL_PWD: per-invocation DB credentials
#   - AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION:
#     exported by aws_configure_env (lib/storage.sh) for the AWS CLI
cleanup_secrets() {
  unset db_pass PGPASSWORD MYSQL_PWD \
        AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION \
        2>/dev/null || true
}

# Set trap to cleanup on exit. Caller (dbx entrypoint) is responsible
# for invoking this — sourcing the lib does not install the trap, so
# tests and other consumers can use the lib without clobbering their
# own EXIT trap.
setup_security_trap() {
  trap 'cleanup_secrets' EXIT INT TERM
}

# ============================================================================
# Backup Verification
# ============================================================================

# Verify backup integrity via SHA-256 checksum (database-agnostic).
# Args: $1=path to backup file (encrypted or plain)
# Returns 0 if the checksum in the matching .meta.json matches, or if
# the file is readable and there's no metadata to compare against.
# Returns 1 if the checksum mismatches or the file is missing/unreadable.
verify_backup() {
  local backup_file="$1"

  log_step "Verifying backup: $backup_file"

  # Check file exists
  if [[ ! -f "$backup_file" ]]; then
    log_error "Backup file not found: $backup_file"
    return 1
  fi

  # Check for metadata file
  local meta_file="${backup_file}.meta.json"
  if [[ ! -f "$meta_file" ]]; then
    log_warn "No metadata file found: $meta_file"
    log_info "Cannot verify checksum without metadata"

    # Still try to verify the file is readable
    log_info "Attempting to read backup header..."
    local is_encrypted=false
    [[ "$backup_file" == *.age || "$backup_file" == *.gpg ]] && is_encrypted=true

    if $is_encrypted; then
      if decompress_backup "$backup_file" 2>/dev/null | head -c 1024 >/dev/null; then
        log_success "Backup file is readable (encrypted)"
      else
        log_error "Failed to decrypt/read backup"
        return 1
      fi
    else
      if decompress_backup "$backup_file" 2>/dev/null | head -c 1024 >/dev/null; then
        log_success "Backup file is readable"
      else
        log_error "Failed to read backup"
        return 1
      fi
    fi
    return 0
  fi

  # Read expected checksum from metadata
  local expected_checksum
  expected_checksum=$(jq -r '.checksums.sha256 // empty' "$meta_file")

  if [[ -z "$expected_checksum" ]]; then
    log_warn "No SHA256 checksum in metadata"
    return 0
  fi

  # Calculate actual checksum
  log_info "Calculating checksum..."
  local actual_checksum
  actual_checksum=$(sha256sum "$backup_file" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$backup_file" 2>/dev/null | cut -d' ' -f1)

  # Compare
  if [[ "$expected_checksum" == "$actual_checksum" ]]; then
    log_success "Checksum verified: $actual_checksum"

    # Show metadata
    echo ""
    echo -e "${BOLD}Backup Metadata:${NC}"
    jq -r '
      "  Host:       " + .host,
      "  Database:   " + .database,
      "  Type:       " + (.type // "unknown"),
      "  Timestamp:  " + .timestamp,
      "  Size:       " + (.size | tostring) + " bytes",
      "  Encryption: " + .encryption,
      "  DBX Version:" + .dbx_version
    ' "$meta_file"
    return 0
  else
    log_error "Checksum mismatch!"
    log_error "Expected: $expected_checksum"
    log_error "Actual:   $actual_checksum"
    return 1
  fi
}

# ============================================================================
# Image Selection
# ============================================================================

# Bump to invalidate every cached dbx-built custom image (e.g. when a package
# mapping or the Dockerfile shape changes). Overridable via env for tests.
DBX_IMAGE_REGISTRY_EPOCH="${DBX_IMAGE_REGISTRY_EPOCH:-1}"

# Built-in registry of third-party Postgres extensions dbx can build a custom
# image for. One entry per line: "ext_name:pgdg_package_suffix:preload_lib".
# The Debian package is "postgresql-<major>-<suffix>" from apt.postgresql.org;
# an empty preload_lib means the extension needs no shared_preload_libraries.
_dbx_extension_registry() {
  cat <<'EOF'
pg_partman:partman:
pg_cron:cron:pg_cron
pgaudit:pgaudit:
hypopg:hypopg:
pg_repack:repack:
pg_hint_plan:pg-hint-plan:pg_hint_plan
hll:hll:
EOF
}

# Merge the built-in registry with caller-supplied extra entries (the config
# escape hatch, defaults.extension_packages). Both are newline lists of
# "ext:suffix:preload". On conflict the extra entry wins. Emits the merged
# registry, one entry per line. Bash 3.2 — no associative arrays.
resolve_extension_registry() {
  local extra="${1:-}"
  local seen=" "
  local line ext
  if [[ -n "$extra" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      ext="${line%%:*}"
      echo "$line"
      seen+="$ext "
    done <<< "$extra"
  fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ext="${line%%:*}"
    [[ "$seen" == *" $ext "* ]] && continue
    echo "$line"
  done < <(_dbx_extension_registry)
}

# For a set of extension names, emit the registry tuples
# "ext:suffix:preload" for those that are buildable, sorted for determinism.
# Names that aren't in the registry (contrib, specialized, unknown) are omitted.
# Args: $1=space-separated names  $2=extra registry entries (optional)
resolve_ext_tuples() {
  local names="$1"
  local extra="${2:-}"
  local registry
  registry=$(resolve_extension_registry "$extra")
  local out=() ext line
  local _names=()
  IFS=' ' read -ra _names <<< "$names"
  for ext in ${_names[@]+"${_names[@]}"}; do
    [[ -z "$ext" ]] && continue
    while IFS= read -r line; do
      [[ "${line%%:*}" == "$ext" ]] && { out+=("$line"); break; }
    done <<< "$registry"
  done
  [[ ${#out[@]} -eq 0 ]] && return 0
  printf '%s\n' "${out[@]}" | LC_ALL=C sort
}

# Hash stdin with sha256, portable across coreutils and macOS. Emits hex digest.
_sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# Deterministic local tag for a dbx-built image: dbx-pg<major>:<12-hex>.
# The hash covers the major, the registry epoch, and the sorted resolved
# tuples, so the same extension set always maps to the same tag and any
# registry/package change invalidates the cache.
# Args: $1=major  $2=sorted resolved tuples (newline list)
compute_custom_image_tag() {
  local major="$1"
  local resolved="$2"
  local h
  h=$(printf '%s\n%s\n%s\n' "$major" "$DBX_IMAGE_REGISTRY_EPOCH" "$resolved" \
        | _sha256_stdin | cut -c1-12)
  echo "dbx-pg${major}:${h}"
}

# Generate the Dockerfile (on stdout) for a dbx custom image. Relies on the
# official postgres:<major> (Debian) image already carrying the PGDG apt repo.
# shared_preload_libraries (for extensions that need it) is appended to the
# initdb sample conf, so a freshly-created container picks it up.
# Args: $1=major  $2=sorted resolved tuples (newline list)
generate_pg_dockerfile() {
  local major="$1"
  local resolved="$2"
  local pkgs=() preloads=()
  local ext suffix preload
  while IFS=: read -r ext suffix preload; do
    [[ -z "$ext" ]] && continue
    [[ -n "$suffix" ]] && pkgs+=("postgresql-${major}-${suffix}")
    [[ -n "$preload" ]] && preloads+=("$preload")
  done <<< "$resolved"

  echo "# Generated by dbx — rebuilt from the extension registry. Do not edit."
  echo "FROM postgres:${major}"
  if [[ ${#pkgs[@]} -gt 0 ]]; then
    echo ""
    echo "RUN apt-get update \\"
    echo " && apt-get install -y --no-install-recommends \\"
    local p
    for p in "${pkgs[@]}"; do
      echo "      ${p} \\"
    done
    echo " && rm -rf /var/lib/apt/lists/*"
  fi
  if [[ ${#preloads[@]} -gt 0 ]]; then
    local joined
    joined=$(IFS=,; echo "${preloads[*]}")
    echo ""
    echo "RUN echo \"shared_preload_libraries = '${joined}'\" >> /usr/share/postgresql/postgresql.conf.sample"
  fi
}

# Normalize a detected major version, applying dbx's default when unknown/empty.
# Used by both pick_postgres_image and the build path so tags stay consistent.
normalize_pg_major() {
  local m="$1"
  [[ "$m" == "unknown" || -z "$m" ]] && m="17"
  echo "$m"
}

# Choose a Postgres Docker image for the given major version and extension set.
# Args:
#   $1: major version (e.g. "15"). May be "unknown".
#   $2: space-separated extension names (e.g. "vector postgis"). May be empty.
#   $3: override template (e.g. "myrepo/pg:{major}"). May be empty.
#   $4: extra registry entries (config escape hatch), newline list. Optional.
# Returns: image string on stdout, exit 1 with message on stderr if unresolvable.
# A buildable third-party extension yields a dbx-pg<major>:<hash> tag, which the
# caller is responsible for building (see pg_ensure_custom_image).
pick_postgres_image() {
  local major="$1"
  local extensions="$2"
  local override="$3"
  local extra_registry="${4:-}"

  if [[ -n "$override" ]]; then
    local out="$override"
    out="${out//\{major\}/$major}"
    out="${out//\{version\}/$major}"
    echo "$out"
    return 0
  fi

  major=$(normalize_pg_major "$major")

  # Filter out plpgsql (always present, not a real extension for our purposes).
  local ext_list=()
  local ext
  local _raw_exts=()
  IFS=' ' read -ra _raw_exts <<< "$extensions"
  for ext in "${_raw_exts[@]}"; do
    [[ -z "$ext" ]] && continue
    [[ "$ext" == "plpgsql" ]] && continue
    ext_list+=("$ext")
  done

  if [[ ${#ext_list[@]} -eq 0 ]]; then
    echo "postgres:${major}-alpine"
    return 0
  fi

  # Contrib modules bundled in the stock postgres image (postgresql-contrib).
  # They ship in postgres:N-alpine — and in the specialized images too, since
  # those are all built on stock postgres — so they impose no image requirement
  # of their own. A backup that uses only these restores fine on the default
  # image; treating them as "unknown" was a false negative that blocked it.
  local contrib_exts=" amcheck autoinc bloom btree_gin btree_gist citext cube \
dblink dict_int dict_xsyn earthdistance file_fdw fuzzystrmatch hstore \
hstore_plperl insert_username intagg intarray isn lo ltree moddatetime \
old_snapshot pageinspect pg_buffercache pg_freespacemap pg_prewarm \
pg_stat_statements pg_surgery pg_trgm pg_visibility pg_walinspect pgcrypto \
pgrowlocks pgstattuple postgres_fdw refint seg sslinfo tablefunc tcn \
tsm_system_rows tsm_system_time unaccent uuid-ossp xml2 "

  # Set of extension names dbx can build a custom image for (built-in registry
  # merged with the config escape hatch), space-padded for membership testing.
  local registry buildable_names=" " _rline
  registry=$(resolve_extension_registry "$extra_registry")
  while IFS= read -r _rline; do
    [[ -z "$_rline" ]] && continue
    buildable_names+="${_rline%%:*} "
  done <<< "$registry"

  # Classify. Specialized extensions need a purpose-built image; contrib modules
  # need nothing; registry extensions can be built into a custom image; anything
  # else is genuinely unknown and we fail fast (so "one specialized + one
  # unknown" reports the unrecognized extension precisely).
  local specialized_exts=() buildable_exts=()
  for ext in "${ext_list[@]}"; do
    case "$ext" in
      vector|postgis|timescaledb)
        specialized_exts+=("$ext")
        ;;
      *)
        if [[ "$contrib_exts" == *" $ext "* ]]; then
          continue
        fi
        if [[ "$buildable_names" == *" $ext "* ]]; then
          buildable_exts+=("$ext")
          continue
        fi
        log_error "Source database uses extension '$ext' which dbx doesn't have a known image for."
        log_error "Set DBX_POSTGRES_IMAGE to an image that includes it, or add it to config:"
        log_error '  { "defaults": { "extension_packages": { "'"$ext"'": "<pgdg-package-suffix>" } } }'
        return 1
        ;;
    esac
  done

  # A specialized extension combined with a buildable one would need a single
  # image carrying both; we don't build atop the specialized bases (one is
  # Alpine), so this needs a hand-built image via the override.
  if [[ ${#specialized_exts[@]} -gt 0 && ${#buildable_exts[@]} -gt 0 ]]; then
    log_error "Source database mixes a specialized extension (${specialized_exts[*]}) with build-on-demand extensions (${buildable_exts[*]})."
    log_error "dbx can't combine these automatically; build one image with all of them and set DBX_POSTGRES_IMAGE to it."
    return 1
  fi

  # Multiple specialized extensions map to different purpose-built images, so
  # any combination is unresolvable without an override.
  if [[ ${#specialized_exts[@]} -gt 1 ]]; then
    log_error "Source database uses multiple extensions that map to different specialized images: ${specialized_exts[*]}."
    log_error "Set DBX_POSTGRES_IMAGE to an image that includes all of them, or in config:"
    log_error '  { "defaults": { "postgres_image": "your-registry/your-image:tag" } }'
    return 1
  fi

  # Exactly one specialized extension: its image wins. Any bundled-contrib
  # extensions alongside it ride along for free (these images carry contrib).
  if [[ ${#specialized_exts[@]} -eq 1 ]]; then
    case "${specialized_exts[0]}" in
      vector)       echo "pgvector/pgvector:pg${major}" ;;
      postgis)      echo "postgis/postgis:${major}-3.5" ;;
      timescaledb)  echo "timescale/timescaledb:latest-pg${major}" ;;
    esac
    return 0
  fi

  # Buildable third-party extensions (no specialized ones): a custom image,
  # keyed by the extension set. The caller builds it on demand.
  if [[ ${#buildable_exts[@]} -gt 0 ]]; then
    local resolved
    resolved=$(resolve_ext_tuples "${buildable_exts[*]}" "$extra_registry")
    compute_custom_image_tag "$major" "$resolved"
    return 0
  fi

  # No specialized and no buildable (bare PG, or contrib-only): stock image.
  echo "postgres:${major}-alpine"
}

# Return the Docker image string of a container, or empty if it doesn't exist.
container_image() {
  local name="$1"
  docker inspect --format '{{.Config.Image}}' "$name" 2>/dev/null || true
}

# Return 0 if the postgres container has at least one non-system database
# (anything other than postgres/template0/template1), 1 otherwise.
pg_container_has_user_dbs() {
  local container="$1"
  local password="${2:-${DBX_PG_PASSWORD:-devpassword}}"
  local count
  count=$(docker exec -e PGPASSWORD="$password" "$container" \
    psql -U postgres -tA -c \
    "SELECT count(*) FROM pg_database WHERE datname NOT IN ('postgres','template0','template1')" \
    2>/dev/null || echo 0)
  [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -gt 0 ]]
}

# Return 0 if the mysql container has at least one non-system database, else 1.
mysql_container_has_user_dbs() {
  local container="$1"
  local password="${2:-${DBX_MYSQL_PASSWORD:-devpassword}}"
  local count
  count=$(docker exec -e MYSQL_PWD="$password" "$container" \
    mysql -u root -N -e \
    "SELECT count(*) FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys')" \
    2>/dev/null || echo 0)
  [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -gt 0 ]]
}

# Choose a MySQL/MariaDB Docker image.
# Args:
#   $1: flavor ("mysql" | "mariadb" | "unknown")
#   $2: major version (e.g. "8", "10"). May be empty.
#   $3: minor version (e.g. "0", "11"). May be empty.
#   $4: override template. May be empty.
pick_mysql_image() {
  local flavor="$1"
  local major="$2"
  local minor="$3"
  local override="$4"

  # Normalize: if either component is empty, fall back to a sensible default.
  # This keeps the override path (which substitutes {version}) sane even when
  # detection upstream returned partial results.
  [[ -z "$major" ]] && major="8"
  [[ -z "$minor" ]] && minor="0"

  local version="${major}.${minor}"

  if [[ -n "$override" ]]; then
    local out="$override"
    out="${out//\{major\}/$major}"
    out="${out//\{minor\}/$minor}"
    out="${out//\{version\}/$version}"
    echo "$out"
    return 0
  fi

  case "$flavor" in
    mariadb)  echo "mariadb:${version}" ;;
    mysql)    echo "mysql:${version}" ;;
    *)        echo "mysql:8.0" ;;
  esac
}

# Given a container name and a desired image, ensure the container is running
# the desired image. Possible outcomes:
#   - image matches → no-op, return 0
#   - container doesn't exist → caller should use require_container, return 0
#     (DBX_FORCE_IMAGE is exported so require_container picks it up next)
#   - image mismatch + container has no user DBs → recreate silently
#   - image mismatch + has user DBs + recreate=true → recreate
#   - image mismatch + has user DBs + recreate=false → die with DB list
#
# Args:
#   $1: container name (postgres-dbx or mysql-dbx)
#   $2: desired image
#   $3: recreate flag ("true" or "false")
ensure_container_image() {
  local container="$1"
  local desired_image="$2"
  local recreate="$3"

  local current_image
  current_image=$(container_image "$container")

  # Nothing there → let require_container create it later with the right image.
  [[ -z "$current_image" ]] && { export DBX_FORCE_IMAGE="$desired_image"; return 0; }

  # Already on the right image.
  [[ "$current_image" == "$desired_image" ]] && return 0

  # Mismatch. Check for user DBs.
  # Detect the DB type from the container name first, then fall back to
  # the current image tag (covers non-standard names used in tests).
  local has_dbs="false"
  local _db_type=""
  case "$container" in
    *postgres*) _db_type="postgres" ;;
    *mysql*)    _db_type="mysql" ;;
    *)
      case "$current_image" in
        postgres:*|pgvector/*|postgis/*|timescale/*|dbx-pg*) _db_type="postgres" ;;
        mysql:*|mariadb:*)                           _db_type="mysql" ;;
      esac
      ;;
  esac
  case "$_db_type" in
    postgres) pg_container_has_user_dbs "$container" && has_dbs="true" ;;
    mysql)    mysql_container_has_user_dbs "$container" && has_dbs="true" ;;
  esac

  if [[ "$has_dbs" == "false" ]]; then
    log_info "Recreating $container: $current_image → $desired_image (no user DBs present)"
    _recreate_container "$container" "$desired_image"
    return $?
  fi

  if [[ "$recreate" == "true" ]]; then
    log_warn "Recreating $container: $current_image → $desired_image (user DBs will be destroyed)"
    _recreate_container "$container" "$desired_image"
    return $?
  fi

  # User DBs + no flag: fail with the DB list.
  log_error "$container is running $current_image but this restore needs $desired_image."
  log_error "The container has user databases that would be destroyed:"
  _list_user_dbs "$container" | sed 's/^/  - /' >&2
  log_error ""
  log_error "Recreate the container (destroys these DBs):"
  log_error "  dbx restore <source> --recreate-container"
  log_error ""
  log_error "Or save them first with: dbx backup <local-host> <db> for each."
  return 1
}

# Stop, remove, and recreate a managed container with a new image.
# For the well-known managed containers (postgres-dbx, mysql-dbx) this
# delegates to require_container (via DBX_FORCE_IMAGE) so that all port
# bindings and flags stay consistent. For other container names (e.g. in
# tests) it starts a minimal container using the image directly, detecting
# the DB type from the image tag.
_recreate_container() {
  local container="$1"
  local image="$2"
  docker rm -f "$container" >/dev/null 2>&1 || true
  case "$container" in
    postgres-dbx|mysql-dbx)
      export DBX_FORCE_IMAGE="$image"
      require_container "$container"
      ;;
    *)
      # Non-standard container name (e.g. integration test containers).
      # Detect DB type from the image name and start with minimal flags.
      if [[ "$image" == postgres:* || "$image" == pgvector/* || "$image" == postgis/* || "$image" == timescale/* || "$image" == dbx-pg* ]]; then
        docker run -d --name "$container" \
          -e POSTGRES_PASSWORD="${DBX_PG_PASSWORD:-devpassword}" \
          "$image" >/dev/null
        log_info "Waiting for PostgreSQL to initialize..."
        for i in {1..30}; do
          docker exec "$container" pg_isready -U postgres >/dev/null 2>&1 && break
          sleep 1
        done
      elif [[ "$image" == mysql:* || "$image" == mariadb:* ]]; then
        docker run -d --name "$container" \
          -e MYSQL_ROOT_PASSWORD="${DBX_MYSQL_PASSWORD:-devpassword}" \
          "$image" >/dev/null
        log_info "Waiting for MySQL to initialize..."
        for i in {1..60}; do
          docker exec -e MYSQL_PWD="${DBX_MYSQL_PASSWORD:-devpassword}" "$container" \
            mysqladmin ping -h localhost -u root >/dev/null 2>&1 && break
          sleep 1
        done
      else
        die "Cannot recreate container '$container' with unknown image type: $image"
      fi
      ;;
  esac
}

# List user (non-system) databases on a managed container.
# Detects DB type from the container name, with fallback to the running image.
_list_user_dbs() {
  local container="$1"
  local _db_type=""
  case "$container" in
    *postgres*) _db_type="postgres" ;;
    *mysql*)    _db_type="mysql" ;;
    *)
      local _img
      _img=$(container_image "$container")
      case "$_img" in
        postgres:*|pgvector/*|postgis/*|timescale/*|dbx-pg*) _db_type="postgres" ;;
        mysql:*|mariadb:*)                           _db_type="mysql" ;;
      esac
      ;;
  esac
  case "$_db_type" in
    postgres)
      docker exec -e PGPASSWORD="${DBX_PG_PASSWORD:-devpassword}" "$container" \
        psql -U postgres -tA -c \
        "SELECT datname FROM pg_database WHERE datname NOT IN ('postgres','template0','template1') ORDER BY datname" \
        2>/dev/null
      ;;
    mysql)
      docker exec -e MYSQL_PWD="${DBX_MYSQL_PASSWORD:-devpassword}" "$container" \
        mysql -u root -N -e \
        "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys') ORDER BY schema_name" \
        2>/dev/null
      ;;
  esac
}

# Query the remote server (via existing docker container + already-up
# tunnel) and print the user-visible database names, one per line.
# Filters out system / template databases so the output is a clean list
# for a "pick which to back up" prompt.
#
# Preconditions: the host exists in config, credentials resolve via
# get_password, the relevant docker container is up, and (if configured)
# the SSH tunnel is already established.
list_remote_databases() {
  local host="$1"
  local db_type db_host db_port db_user db_pass
  db_type=$(get_db_type "$host")
  db_host=$(get_effective_host "$host")
  db_port=$(get_effective_port "$host")
  db_user=$(get_config_value ".hosts[\"$host\"].user")
  db_pass=$(get_password "$host")

  case "$db_type" in
    postgres|postgresql)
      docker exec -e PGPASSWORD="$db_pass" "$POSTGRES_CONTAINER" \
        psql -h "$db_host" -p "$db_port" -U "$db_user" -t -A -c \
        "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname" \
        2>/dev/null
      ;;
    mysql|mariadb)
      docker exec -e MYSQL_PWD="$db_pass" "$MYSQL_CONTAINER" \
        mysql -h "$db_host" -P "$db_port" -u "$db_user" -N -e "SHOW DATABASES" \
        2>/dev/null \
        | grep -v -E "^(information_schema|performance_schema|mysql|sys)$" || true
      ;;
    *)
      return 1
      ;;
  esac
}

# ============================================================================
# --transform script exec helper
# ============================================================================

# Print the argv prefix to run a `--transform` subprocess. Default is
# `env -i` with a minimal allowlist (PATH, HOME, LANG, LC_*, TZ, USER,
# SHELL) plus any `DBX_TRANSFORM_*`-prefixed vars the operator wants to
# pass through explicitly. The transform script gets stdin/stdout but
# none of dbx's credentials (PGPASSWORD, vault tokens, DBX_SCRUB_SEED).
#
# When $1 == "true", inherits the full environment (legacy / opt-out).
# Use like: `... | $(transform_exec_prefix "$inherit") "$script" | ...`
# but for argv safety prefer building an array; see callers.
#
# Args: $1 = inherit_env ("true" to skip cleaning), $2 = script path
# Echoes one argument per line so callers can `mapfile`/`read` into
# an array safely.
transform_exec_argv() {
  local inherit_env="$1" script="$2"
  if [[ "$inherit_env" == "true" ]]; then
    printf '%s\n' "$script"
    return 0
  fi
  printf '%s\n' env -i
  # Minimal allowlist — what a script needs to find binaries and behave
  # correctly under different locales. NOT in the allowlist on purpose:
  # PGPASSWORD, MYSQL_PWD, DBX_SCRUB_SEED, vault tokens, AWS_*.
  local k v
  for k in PATH HOME LANG LC_ALL LC_CTYPE LC_COLLATE LC_MESSAGES TZ USER SHELL TMPDIR; do
    v="${!k:-}"
    [[ -n "$v" ]] && printf '%s=%s\n' "$k" "$v"
  done
  # DBX_TRANSFORM_* prefix: operator opt-in. Anything they want the
  # script to see, they prefix DBX_TRANSFORM_ and it gets passed.
  while IFS='=' read -r k v; do
    [[ "$k" == DBX_TRANSFORM_* ]] && printf '%s=%s\n' "$k" "$v"
  done < <(env)
  printf '%s\n' "$script"
}
