#!/usr/bin/env bash
#
# lib/storage.sh - Cloud storage support (S3/MinIO)
#
# Requires: core.sh to be sourced first
#

# ============================================================================
# Configuration — multiple named backends
#
# Storage can be configured two ways, both supported:
#   - Named map:  .storages.<name> = { type, s3 {...} }  (+ .defaults.storage)
#   - Legacy:     .storage         = { type, s3 {...} }  (single, unnamed)
#
# A dynamically-scoped `_STORAGE_NAME` selects the active backend for the
# duration of an operation: "" means the legacy `.storage` block; any other
# value means `.storages[<name>]`. Public entry points set it (via
# resolve_storage_name) and pass it to any sibling they call; the mc_*/aws_*
# helpers and get_storage_config read it implicitly through bash dynamic scope.
# Backend names are validated against IDENT_RE before they reach here, so they
# are safe to interpolate into jq paths and vault/alias names.
# ============================================================================

# jq root for the active backend.
storage_root_jq() {
  if [[ -n "${_STORAGE_NAME:-}" ]]; then
    printf '.storages["%s"]' "$_STORAGE_NAME"
  else
    printf '.storage'
  fi
}

# Vault/keychain key holding the active backend's S3 secret.
storage_vault_key() {
  if [[ -n "${_STORAGE_NAME:-}" ]]; then
    echo "s3-secret-key-${_STORAGE_NAME}"
  else
    echo "s3-secret-key"
  fi
}

# mc alias for the active backend (kept distinct so backends don't clobber).
mc_alias_name() {
  if [[ -n "${_STORAGE_NAME:-}" ]]; then
    echo "dbx-storage-${_STORAGE_NAME}"
  else
    echo "dbx-storage"
  fi
}

# Names of all configured named backends (one per line). The legacy .storage
# block is NOT listed here (it has no name); callers handle it separately.
storage_list_backends() {
  get_config_value '(.storages // {}) | keys[]' 2>/dev/null || true
}

# Resolve which backend to use. Echoes the concrete name, or "" for the legacy
# single .storage block. Returns non-zero (with a logged error) when nothing is
# configured or the choice is ambiguous.
# Arg: $1 = explicit name (from --storage / arg), optional.
resolve_storage_name() {
  local explicit="${1:-}"
  if [[ -n "$explicit" ]]; then
    echo "$explicit"; return 0
  fi
  local default_name
  default_name=$(get_config_value '.defaults.storage' 2>/dev/null || echo "")
  if [[ -n "$default_name" ]]; then
    echo "$default_name"; return 0
  fi
  # No explicit, no default: a single named backend wins; else legacy; else error.
  local names count
  names=$(storage_list_backends)
  count=$(printf '%s\n' "$names" | grep -c . || true)
  if [[ "$count" -eq 1 ]]; then
    echo "$names"; return 0
  elif [[ "$count" -gt 1 ]]; then
    log_error "Multiple storage backends configured; set .defaults.storage or pass --storage <name>. Available: $(echo $names)"
    return 1
  fi
  local legacy_type
  legacy_type=$(get_config_value '.storage.type' 2>/dev/null || echo "")
  if [[ -n "$legacy_type" && "$legacy_type" != "none" ]]; then
    echo ""; return 0   # legacy sentinel
  fi
  log_error "No storage configured. Run 'dbx storage add'."
  return 1
}

# Check if storage is configured. With an explicit name (or an inherited
# _STORAGE_NAME), checks that backend; otherwise true if ANY backend (named or
# legacy) is configured.
is_storage_configured() {
  local name="${1:-${_STORAGE_NAME:-}}"
  if [[ -n "$name" ]]; then
    local t
    t=$(get_config_value ".storages[\"$name\"].type" 2>/dev/null || echo "")
    [[ -n "$t" && "$t" != "none" ]]
    return
  fi
  [[ -n "$(storage_list_backends)" ]] && return 0
  local lt
  lt=$(get_config_value ".storage.type" 2>/dev/null || echo "")
  [[ -n "$lt" && "$lt" != "none" ]]
}

# Get a config value for the active backend (e.g. "s3.bucket").
get_storage_config() {
  local key="$1"
  get_config_value "$(storage_root_jq).$key" 2>/dev/null || echo ""
}

# ============================================================================
# S3 Client Detection
# ============================================================================

# Detect available S3 client (prefer mc for MinIO compatibility)
detect_s3_client() {
  if command -v mc &>/dev/null; then
    echo "mc"
  elif command -v aws &>/dev/null; then
    echo "aws"
  else
    echo "none"
  fi
}

require_s3_client() {
  local client
  client=$(detect_s3_client)
  if [[ "$client" == "none" ]]; then
    die "No S3 client found. Install 'mc' (MinIO Client) or 'aws' CLI"
  fi
}

# ============================================================================
# MinIO Client (mc) Operations
# ============================================================================

mc_configure() {
  local endpoint bucket access_key secret_key

  endpoint=$(get_storage_config "s3.endpoint")
  access_key=$(get_storage_config "s3.access_key")

  # Get secret key from vault or config
  local secret_cmd
  secret_cmd=$(get_storage_config "s3.secret_key_cmd")
  if [[ -n "$secret_cmd" ]]; then
    secret_key=$(eval "$secret_cmd")
  else
    secret_key=$(keychain_get "$(storage_vault_key)" 2>/dev/null || true)
    if [[ -z "$secret_key" ]]; then
      secret_key=$(get_storage_config "s3.secret_key")
    fi
  fi

  if [[ -z "$endpoint" || -z "$access_key" || -z "$secret_key" ]]; then
    die "S3 storage not fully configured. Required: endpoint, access_key, secret_key"
  fi

  # Configure mc alias (quietly)
  mc alias set "$(mc_alias_name)" "$endpoint" "$access_key" "$secret_key" --api S3v4 >/dev/null 2>&1
}

mc_upload() {
  local local_file="$1"
  local remote_path="$2"

  mc_configure

  local bucket prefix
  bucket=$(get_storage_config "s3.bucket")
  prefix=$(get_storage_config "s3.prefix")
  prefix="${prefix%/}"  # Remove trailing slash

  local full_path="$(mc_alias_name)/${bucket}/${prefix}/${remote_path}"

  log_info "Uploading to: $full_path"
  if mc cp "$local_file" "$full_path" >/dev/null; then
    log_success "Upload complete"
    return 0
  else
    log_error "Upload failed"
    return 1
  fi
}

mc_download() {
  local remote_path="$1"
  local local_file="$2"

  mc_configure

  local bucket prefix
  bucket=$(get_storage_config "s3.bucket")
  prefix=$(get_storage_config "s3.prefix")
  prefix="${prefix%/}"

  local full_path="$(mc_alias_name)/${bucket}/${prefix}/${remote_path}"

  log_info "Downloading from: $full_path"
  if mc cp "$full_path" "$local_file" >/dev/null; then
    log_success "Download complete"
    return 0
  else
    log_error "Download failed"
    return 1
  fi
}

mc_list() {
  local path="${1:-}"

  mc_configure

  local bucket prefix
  bucket=$(get_storage_config "s3.bucket")
  prefix=$(get_storage_config "s3.prefix")
  prefix="${prefix%/}"

  local full_path="$(mc_alias_name)/${bucket}/${prefix}"
  [[ -n "$path" ]] && full_path="${full_path}/${path}"

  mc ls "$full_path" 2>/dev/null
}

mc_delete() {
  local remote_path="$1"

  mc_configure

  local bucket prefix
  bucket=$(get_storage_config "s3.bucket")
  prefix=$(get_storage_config "s3.prefix")
  prefix="${prefix%/}"

  local full_path="$(mc_alias_name)/${bucket}/${prefix}/${remote_path}"

  log_info "Deleting: $full_path"
  if mc rm "$full_path" >/dev/null 2>&1; then
    log_success "Deleted"
    return 0
  else
    log_error "Delete failed"
    return 1
  fi
}

# ============================================================================
# AWS CLI Operations
# ============================================================================

aws_get_endpoint_arg() {
  local endpoint
  endpoint=$(get_storage_config "s3.endpoint")
  if [[ -n "$endpoint" && "$endpoint" != "https://s3.amazonaws.com" ]]; then
    echo "--endpoint-url $endpoint"
  fi
}

aws_configure_env() {
  local access_key secret_key region

  access_key=$(get_storage_config "s3.access_key")
  region=$(get_storage_config "s3.region")

  # Get secret key
  local secret_cmd
  secret_cmd=$(get_storage_config "s3.secret_key_cmd")
  if [[ -n "$secret_cmd" ]]; then
    secret_key=$(eval "$secret_cmd")
  else
    secret_key=$(keychain_get "$(storage_vault_key)" 2>/dev/null || true)
    if [[ -z "$secret_key" ]]; then
      secret_key=$(get_storage_config "s3.secret_key")
    fi
  fi

  export AWS_ACCESS_KEY_ID="$access_key"
  export AWS_SECRET_ACCESS_KEY="$secret_key"
  export AWS_DEFAULT_REGION="${region:-us-east-1}"
}

aws_upload() {
  local local_file="$1"
  local remote_path="$2"

  aws_configure_env

  local bucket prefix endpoint_arg
  bucket=$(get_storage_config "s3.bucket")
  prefix=$(get_storage_config "s3.prefix")
  prefix="${prefix%/}"
  endpoint_arg=$(aws_get_endpoint_arg)

  local s3_path="s3://${bucket}/${prefix}/${remote_path}"

  log_info "Uploading to: $s3_path"
  if aws s3 cp "$local_file" "$s3_path" $endpoint_arg >/dev/null; then
    log_success "Upload complete"
    return 0
  else
    log_error "Upload failed"
    return 1
  fi
}

aws_download() {
  local remote_path="$1"
  local local_file="$2"

  aws_configure_env

  local bucket prefix endpoint_arg
  bucket=$(get_storage_config "s3.bucket")
  prefix=$(get_storage_config "s3.prefix")
  prefix="${prefix%/}"
  endpoint_arg=$(aws_get_endpoint_arg)

  local s3_path="s3://${bucket}/${prefix}/${remote_path}"

  log_info "Downloading from: $s3_path"
  if aws s3 cp "$s3_path" "$local_file" $endpoint_arg >/dev/null; then
    log_success "Download complete"
    return 0
  else
    log_error "Download failed"
    return 1
  fi
}

aws_list() {
  local path="${1:-}"

  aws_configure_env

  local bucket prefix endpoint_arg
  bucket=$(get_storage_config "s3.bucket")
  prefix=$(get_storage_config "s3.prefix")
  prefix="${prefix%/}"
  endpoint_arg=$(aws_get_endpoint_arg)

  local s3_path="s3://${bucket}/${prefix}"
  [[ -n "$path" ]] && s3_path="${s3_path}/${path}"

  aws s3 ls "$s3_path" $endpoint_arg 2>/dev/null
}

aws_delete() {
  local remote_path="$1"

  aws_configure_env

  local bucket prefix endpoint_arg
  bucket=$(get_storage_config "s3.bucket")
  prefix=$(get_storage_config "s3.prefix")
  prefix="${prefix%/}"
  endpoint_arg=$(aws_get_endpoint_arg)

  local s3_path="s3://${bucket}/${prefix}/${remote_path}"

  log_info "Deleting: $s3_path"
  if aws s3 rm "$s3_path" $endpoint_arg >/dev/null 2>&1; then
    log_success "Deleted"
    return 0
  else
    log_error "Delete failed"
    return 1
  fi
}

# ============================================================================
# Unified Storage Interface
# ============================================================================

# Upload a local file (and its sibling .meta.json, if present) to
# the configured S3-compatible storage. Picks `mc` (MinIO Client) if
# available, falling back to `aws` CLI; dies if neither is installed.
# Args: $1=local file path, $2=remote path (default: basename of $1)
storage_upload() {
  local local_file="$1"
  local remote_path="${2:-}"
  local _STORAGE_NAME
  _STORAGE_NAME=$(resolve_storage_name "${3:-}") || return 1

  require_s3_client

  # Default remote path: host/database/filename
  if [[ -z "$remote_path" ]]; then
    remote_path=$(basename "$local_file")
  fi

  local client
  client=$(detect_s3_client)

  case "$client" in
    mc)
      mc_upload "$local_file" "$remote_path"
      ;;
    aws)
      aws_upload "$local_file" "$remote_path"
      ;;
  esac

  # Also upload metadata if exists
  local meta_file="${local_file}.meta.json"
  if [[ -f "$meta_file" ]]; then
    case "$client" in
      mc)
        mc_upload "$meta_file" "${remote_path}.meta.json"
        ;;
      aws)
        aws_upload "$meta_file" "${remote_path}.meta.json"
        ;;
    esac
  fi
}

storage_download() {
  local remote_path="$1"
  local local_file="${2:-}"
  local _STORAGE_NAME
  _STORAGE_NAME=$(resolve_storage_name "${3:-}") || return 1

  require_s3_client

  # Default local path: DATA_DIR/downloads/filename
  if [[ -z "$local_file" ]]; then
    local_file="$DATA_DIR/downloads/$(basename "$remote_path")"
    mkdir -p "$(dirname "$local_file")"
  fi

  local client
  client=$(detect_s3_client)

  case "$client" in
    mc)
      mc_download "$remote_path" "$local_file"
      ;;
    aws)
      aws_download "$remote_path" "$local_file"
      ;;
  esac

  # Also download metadata if exists
  local meta_remote="${remote_path}.meta.json"
  local meta_local="${local_file}.meta.json"
  case "$client" in
    mc)
      mc_download "$meta_remote" "$meta_local" 2>/dev/null || true
      ;;
    aws)
      aws_download "$meta_remote" "$meta_local" 2>/dev/null || true
      ;;
  esac

  echo "$local_file"
}

storage_list() {
  local path="${1:-}"
  local _STORAGE_NAME
  _STORAGE_NAME=$(resolve_storage_name "${2:-}") || return 1

  require_s3_client

  local client
  client=$(detect_s3_client)

  echo -e "${BOLD}Remote Backups:${NC}"
  echo ""

  case "$client" in
    mc)
      mc_list "$path"
      ;;
    aws)
      aws_list "$path"
      ;;
  esac
}

# storage_resolve_remote_path — translate a user-facing remote path
# (which may end in `/latest`) into a concrete `<host>/<db>/<filename>`.
#
# Args: $1 = "<host>/<db>/<filename-or-latest>"
# Echoes: the resolved "<host>/<db>/<filename>"
# Exits non-zero on malformed input or when /latest finds no backups.
#
# Resolution rules for /latest:
#  - List entries under "<host>/<db>" via storage_list_raw.
#  - Filter to candidates whose filename ends in .sql.zst, .sql.zst.age,
#    or .sql.zst.gpg.
#  - Pick the lex-max filename. Backup names embed a zero-padded
#    YYYYMMDD_HHMMSS timestamp, so lex order == chronological order.
storage_resolve_remote_path() {
  local remote_path="$1"
  local _STORAGE_NAME
  _STORAGE_NAME=$(resolve_storage_name "${2:-}") || return 1

  # Validate shape: must have at least host/db/something.
  local host db tail
  host="${remote_path%%/*}"
  local rest="${remote_path#*/}"
  if [[ "$rest" == "$remote_path" || -z "$host" ]]; then
    log_error "Invalid remote path: '$remote_path' (expected <host>/<db>/<file_or_latest>)"
    return 1
  fi
  db="${rest%%/*}"
  tail="${rest#*/}"
  if [[ "$tail" == "$rest" || -z "$db" || -z "$tail" ]]; then
    log_error "Invalid remote path: '$remote_path' (expected <host>/<db>/<file_or_latest>)"
    return 1
  fi

  if [[ "$tail" != "latest" ]]; then
    # Already a concrete filename — pass through.
    echo "$remote_path"
    return 0
  fi

  # /latest — list the directory and pick the newest backup. We use
  # the unified storage_list (which adds a header banner) and just
  # filter to lines whose last token matches a backup filename — the
  # header lines don't match and get dropped naturally.
  local listing
  listing=$(storage_list "$host/$db" "$_STORAGE_NAME" 2>/dev/null || true)

  # Extract bare filenames. `mc ls` and `aws s3 ls` both print the
  # filename as the last whitespace-separated token on each line.
  local best=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local fname
    fname=$(awk '{print $NF}' <<< "$line")
    # Skip directories ("PRE foo/" in aws output, "x/" with trailing slash in mc).
    [[ "$fname" == */ ]] && continue
    case "$fname" in
      *.sql.zst|*.sql.zst.age|*.sql.zst.gpg) ;;
      *) continue ;;
    esac
    if [[ -z "$best" || "$fname" > "$best" ]]; then
      best="$fname"
    fi
  done <<< "$listing"

  if [[ -z "$best" ]]; then
    log_error "No backups found at remote path: $host/$db"
    return 1
  fi

  echo "$host/$db/$best"
}

# storage_fetch_remote_backup — download a remote backup into a
# temp area under $DATA_DIR/.remote/ and echo the local file path.
#
# Args: $1 = resolved "<host>/<db>/<filename>"
# Echoes (to stdout): the absolute local path to the downloaded file.
# Returns non-zero if download fails or the file ends up empty.
storage_fetch_remote_backup() {
  local remote_path="$1"
  local _STORAGE_NAME
  _STORAGE_NAME=$(resolve_storage_name "${2:-}") || return 1

  local base
  base=$(basename "$remote_path")
  local tmp_root="$DATA_DIR/.remote"
  mkdir -p "$tmp_root"

  # mktemp -d on the same filesystem as the eventual restore target so
  # we don't end up moving files across mount points.
  local tmp_dir
  tmp_dir=$(mktemp -d "$tmp_root/dl.XXXXXX")
  local local_file="$tmp_dir/$base"

  # Run storage_download but route its informational/log chatter to
  # stderr so the resolved local path (echoed last) isn't intermingled
  # when callers capture stdout.
  if ! storage_download "$remote_path" "$local_file" "$_STORAGE_NAME" >&2; then
    log_error "Download failed: $remote_path"
    return 1
  fi

  if [[ ! -s "$local_file" ]]; then
    log_error "Downloaded file is empty: $local_file"
    return 1
  fi

  echo "$local_file"
}

storage_delete() {
  local remote_path="$1"
  local _STORAGE_NAME
  _STORAGE_NAME=$(resolve_storage_name "${2:-}") || return 1

  require_s3_client

  local client
  client=$(detect_s3_client)

  case "$client" in
    mc)
      mc_delete "$remote_path"
      mc_delete "${remote_path}.meta.json" 2>/dev/null || true
      ;;
    aws)
      aws_delete "$remote_path"
      aws_delete "${remote_path}.meta.json" 2>/dev/null || true
      ;;
  esac
}

# ============================================================================
# Sync Operations
# ============================================================================

# Sync local backups to remote storage
storage_sync_upload() {
  local host="$1"
  local database="${2:-}"
  local _STORAGE_NAME
  _STORAGE_NAME=$(resolve_storage_name "${3:-}") || return 1

  require_s3_client

  log_step "Syncing backups to remote storage"

  local backup_dir="$DATA_DIR/$host"
  if [[ -n "$database" ]]; then
    backup_dir="$backup_dir/$database"
  fi

  if [[ ! -d "$backup_dir" ]]; then
    log_warn "No local backups found: $backup_dir"
    return 0
  fi

  local count=0
  while read -r file; do
    # Skip metadata files
    [[ "$file" == *.meta.json ]] && continue

    local relative_path="${file#"$DATA_DIR/"}"
    log_info "Uploading: $relative_path"
    storage_upload "$file" "$relative_path" "$_STORAGE_NAME"
    ((count++)) || true
  done < <(find "$backup_dir" -name "*.sql.zst*" -type f)

  log_success "Synced $count backup(s) to remote storage"
}

# Sync remote backups to local storage
storage_sync_download() {
  local host="$1"
  local database="${2:-}"
  local _STORAGE_NAME
  _STORAGE_NAME=$(resolve_storage_name "${3:-}") || return 1

  require_s3_client

  log_step "Syncing backups from remote storage"

  local remote_path="$host"
  [[ -n "$database" ]] && remote_path="$host/$database"

  local client
  client=$(detect_s3_client)

  # List remote files and download
  local count=0
  case "$client" in
    mc)
      mc_configure
      local bucket prefix
      bucket=$(get_storage_config "s3.bucket")
      prefix=$(get_storage_config "s3.prefix")
      prefix="${prefix%/}"

      while read -r remote_file; do
        [[ "$remote_file" == *.meta.json ]] && continue
        local relative="${remote_file#"$(mc_alias_name)/${bucket}/${prefix}/"}"
        local local_file="$DATA_DIR/$relative"
        mkdir -p "$(dirname "$local_file")"
        log_info "Downloading: $relative"
        mc cp "$remote_file" "$local_file" >/dev/null
        ((count++)) || true
      done < <(mc find "$(mc_alias_name)/${bucket}/${prefix}/${remote_path}" --name "*.sql.zst*" 2>/dev/null)
      ;;
    aws)
      aws_configure_env
      local bucket prefix endpoint_arg
      bucket=$(get_storage_config "s3.bucket")
      prefix=$(get_storage_config "s3.prefix")
      prefix="${prefix%/}"
      endpoint_arg=$(aws_get_endpoint_arg)

      aws s3 sync "s3://${bucket}/${prefix}/${remote_path}" "$DATA_DIR/$remote_path" \
        --exclude "*" --include "*.sql.zst*" $endpoint_arg
      count=$(find "$DATA_DIR/$remote_path" -name "*.sql.zst*" -type f 2>/dev/null | wc -l)
      ;;
  esac

  log_success "Synced backups from remote storage"
}

# End-to-end validation of the configured S3 storage. Uploads a 1-byte
# probe file to .dbx-test/<timestamp>, lists the prefix to confirm,
# downloads it and checks byte-identity, then deletes it. Returns 0
# only if all four steps succeed; returns 1 with the failing step
# logged. Side effects on the bucket are cleaned up unless delete fails.
storage_test_roundtrip() {
  local _STORAGE_NAME
  _STORAGE_NAME=$(resolve_storage_name "${1:-}") || return 1
  is_storage_configured || { log_error "storage not configured"; return 1; }

  local ts probe_src probe_local probe_remote
  ts=$(date +%s)
  probe_src=$(mktemp)
  printf '.' > "$probe_src"   # 1-byte payload
  probe_remote=".dbx-test/probe-${ts}"
  probe_local=$(mktemp)

  log_info "storage test: upload"
  if ! storage_upload "$probe_src" "$probe_remote" "$_STORAGE_NAME" >/dev/null 2>&1; then
    log_error "storage test: upload failed"
    rm -f "$probe_src" "$probe_local"
    return 1
  fi

  log_info "storage test: list"
  if ! storage_list ".dbx-test" "$_STORAGE_NAME" 2>/dev/null | grep -q "probe-${ts}"; then
    log_error "storage test: list did not contain the uploaded probe"
    storage_delete "$probe_remote" "$_STORAGE_NAME" >/dev/null 2>&1 || true
    rm -f "$probe_src" "$probe_local"
    return 1
  fi

  log_info "storage test: download"
  if ! storage_download "$probe_remote" "$probe_local" "$_STORAGE_NAME" >/dev/null 2>&1; then
    log_error "storage test: download failed"
    storage_delete "$probe_remote" "$_STORAGE_NAME" >/dev/null 2>&1 || true
    rm -f "$probe_src" "$probe_local"
    return 1
  fi

  if ! cmp -s "$probe_src" "$probe_local"; then
    log_error "storage test: downloaded bytes mismatch original"
    storage_delete "$probe_remote" "$_STORAGE_NAME" >/dev/null 2>&1 || true
    rm -f "$probe_src" "$probe_local"
    return 1
  fi

  log_info "storage test: delete"
  if ! storage_delete "$probe_remote" "$_STORAGE_NAME" >/dev/null 2>&1; then
    log_error "storage test: delete failed (probe left in bucket)"
    rm -f "$probe_src" "$probe_local"
    return 1
  fi

  rm -f "$probe_src" "$probe_local"
  log_success "storage test: round-trip OK"
  return 0
}

# ============================================================================
# Storage Info
# ============================================================================

# Print one backend's details. Reads the active backend via the
# dynamically-scoped _STORAGE_NAME set by the caller.
_storage_print_one() {
  local label="$1" tag="${2:-}"
  echo "  [${label}]${tag:+  ${tag}}"
  echo "    Type:     $(get_storage_config "type")"
  echo "    Endpoint: $(get_storage_config "s3.endpoint")"
  echo "    Bucket:   $(get_storage_config "s3.bucket")"
  echo "    Prefix:   $(get_storage_config "s3.prefix")"
}

# storage_info [name] — show one backend, or all (named + legacy) when no name.
storage_info() {
  local want="${1:-}"
  echo -e "${BOLD}Storage Configuration:${NC}"
  echo ""

  local default_name names legacy_type
  default_name=$(get_config_value '.defaults.storage' 2>/dev/null || echo "")
  names=$(storage_list_backends)
  legacy_type=$(get_config_value '.storage.type' 2>/dev/null || echo "")

  if [[ -z "$want" && -z "$names" && ( -z "$legacy_type" || "$legacy_type" == "none" ) ]]; then
    echo "  Not configured"
    echo ""
    echo "  Add one with: dbx storage add"
    return
  fi

  if [[ -n "$want" ]]; then
    local _STORAGE_NAME="$want" tag=""
    [[ "$want" == "$default_name" ]] && tag="(default)"
    _storage_print_one "$want" "$tag"
  else
    if [[ -n "$names" ]]; then
      while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        local _STORAGE_NAME="$n" tag=""
        [[ "$n" == "$default_name" ]] && tag="(default)"
        _storage_print_one "$n" "$tag"
      done <<< "$names"
    fi
    if [[ -n "$legacy_type" && "$legacy_type" != "none" ]]; then
      local _STORAGE_NAME=""
      _storage_print_one "legacy" "(.storage)"
    fi
  fi
  echo "    Client:   $(detect_s3_client)"
}
