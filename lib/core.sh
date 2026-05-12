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

require_container() {
  local container="$1"

  # Already running?
  if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
    return 0
  fi

  # Exists but stopped? Start it
  if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
    log_info "Starting stopped container: $container"
    docker start "$container" >/dev/null
    sleep 2
    return 0
  fi

  # Doesn't exist - create it.
  # Bind to loopback by default so the auto-managed dev containers aren't
  # reachable from the LAN with the default password. Override with
  # DBX_BIND_ADDR (e.g. 0.0.0.0) if you have a reason to expose them.
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
        -p "${bind_addr}:5432:5432" \
        postgres:17-alpine >/dev/null
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
        -p "${bind_addr}:3306:3306" \
        mysql:8.0 >/dev/null
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
      security dump-keychain 2>/dev/null | grep -B5 "\"svce\"<blob>=\"$KEYCHAIN_SERVICE\"" | grep "\"acct\"" | sed 's/.*<blob>="\([^"]*\)".*/\1/' | sort -u
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

is_encryption_enabled() {
  local enabled
  enabled=$(get_config_value ".defaults.encryption")
  [[ "$enabled" == "true" ]]
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

  # Build JSON entry
  local entry
  entry=$(jq -n \
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
    entry=$(echo "$entry" | jq --arg k "$key" --arg v "$value" '. + {($k): $v}')
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

# Choose a Postgres Docker image for the given major version and extension set.
# Args:
#   $1: major version (e.g. "15"). May be "unknown".
#   $2: space-separated extension names (e.g. "vector postgis"). May be empty.
#   $3: override template (e.g. "myrepo/pg:{major}"). May be empty.
# Returns: image string on stdout, exit 1 with message on stderr if no mapping.
pick_postgres_image() {
  local major="$1"
  local extensions="$2"
  local override="$3"

  if [[ -n "$override" ]]; then
    local out="$override"
    out="${out//\{major\}/$major}"
    out="${out//\{version\}/$major}"
    echo "$out"
    return 0
  fi

  if [[ "$major" == "unknown" || -z "$major" ]]; then
    major="17"
  fi

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

  # First pass: fail fast on any extension we don't have a mapping for. This
  # also produces a precise error for the case "one known + one unknown" — we
  # don't want to claim they all need a specialized image when one of them is
  # simply unrecognized.
  local known_exts=()
  for ext in "${ext_list[@]}"; do
    case "$ext" in
      vector|postgis|timescaledb)
        known_exts+=("$ext")
        ;;
      *)
        log_error "Source database uses extension '$ext' which dbx doesn't have a known image for."
        log_error "Set DBX_POSTGRES_IMAGE to an image that includes it, or in config:"
        log_error '  { "defaults": { "postgres_image": "your-registry/your-image:tag" } }'
        return 1
        ;;
    esac
  done

  # Multiple known extensions: none of our allowlist mappings share an image,
  # so any combination is unresolvable without an override.
  if [[ ${#known_exts[@]} -gt 1 ]]; then
    log_error "Source database uses multiple extensions that map to different specialized images: ${known_exts[*]}."
    log_error "Set DBX_POSTGRES_IMAGE to an image that includes all of them, or in config:"
    log_error '  { "defaults": { "postgres_image": "your-registry/your-image:tag" } }'
    return 1
  fi

  case "${known_exts[0]}" in
    vector)       echo "pgvector/pgvector:pg${major}" ;;
    postgis)      echo "postgis/postgis:${major}-3.5" ;;
    timescaledb)  echo "timescale/timescaledb:latest-pg${major}" ;;
  esac
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
