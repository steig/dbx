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
# Colors
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

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

  # Doesn't exist - create it
  log_info "Creating container: $container"
  case "$container" in
    postgres-shared)
      docker run -d --name postgres-shared \
        -e POSTGRES_PASSWORD="${DB_PG_PASSWORD:-devpassword}" \
        postgres:15-alpine >/dev/null
      # Wait for postgres to be ready
      log_info "Waiting for PostgreSQL to initialize..."
      for i in {1..30}; do
        if docker exec postgres-shared pg_isready -U postgres >/dev/null 2>&1; then
          break
        fi
        sleep 1
      done
      ;;
    mysql-shared)
      docker run -d --name mysql-shared \
        -e MYSQL_ROOT_PASSWORD="${DB_MYSQL_PASSWORD:-devpassword}" \
        mysql:8.0 >/dev/null
      # Wait for mysql to be ready
      log_info "Waiting for MySQL to initialize..."
      for i in {1..60}; do
        if docker exec mysql-shared mysqladmin ping -h localhost -u root -p"${DB_MYSQL_PASSWORD:-devpassword}" >/dev/null 2>&1; then
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
# Keychain/Vault Functions (macOS Keychain for secure credential storage)
# ============================================================================

keychain_get() {
  local account="$1"
  security find-generic-password -a "$account" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null
}

keychain_set() {
  local account="$1"
  local password="$2"
  # -U updates if exists, -a is account, -s is service, -w is password
  security add-generic-password -U -a "$account" -s "$KEYCHAIN_SERVICE" -w "$password"
}

keychain_delete() {
  local account="$1"
  security delete-generic-password -a "$account" -s "$KEYCHAIN_SERVICE" 2>/dev/null
}

keychain_list() {
  # List all db-backup entries in keychain
  security dump-keychain 2>/dev/null | grep -B5 "\"svce\"<blob>=\"$KEYCHAIN_SERVICE\"" | grep "\"acct\"" | sed 's/.*<blob>="\([^"]*\)".*/\1/' | sort -u
}

get_password() {
  local host="$1"

  # Priority 1: Try keychain first (most secure)
  local keychain_pass
  keychain_pass=$(keychain_get "$host" 2>/dev/null || true)
  if [[ -n "$keychain_pass" ]]; then
    echo "$keychain_pass"
    return
  fi

  # Priority 2: password_cmd in config (e.g., 1Password CLI, pass, etc.)
  local password_cmd
  password_cmd=$(get_config_value ".hosts[\"$host\"].password_cmd")
  if [[ -n "$password_cmd" ]]; then
    eval "$password_cmd"
    return
  fi

  # Priority 3: Plain text password in config (least secure, for dev only)
  get_config_value ".hosts[\"$host\"].password"
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

# Strip MySQL DEFINER clauses for clean restores
strip_definer() {
  local handling="${1:-strip}"
  case "$handling" in
    strip)
      # Remove DEFINER clause entirely
      sed -E 's/DEFINER=`[^`]+`@`[^`]+`\s*//g'
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

# Decompress based on file extension (.gz, .zst, or plain)
decompress() {
  local file="$1"
  case "$file" in
    *.zst)
      zstd -d < "$file"
      ;;
    *.gz)
      gunzip -c "$file"
      ;;
    *.sql)
      cat "$file"
      ;;
    *)
      # Try to detect by magic bytes
      if head -c 4 "$file" | grep -q $'\x28\xb5\x2f\xfd'; then
        zstd -d < "$file"
      elif head -c 2 "$file" | grep -q $'\x1f\x8b'; then
        gunzip -c "$file"
      else
        cat "$file"
      fi
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
