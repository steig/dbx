#!/usr/bin/env bash
#
# lib/storage.sh - Cloud storage support (S3/MinIO)
#
# Requires: core.sh to be sourced first
#

# ============================================================================
# Configuration
# ============================================================================

# Check if storage is configured
is_storage_configured() {
  local storage_type
  storage_type=$(get_config_value ".storage.type" 2>/dev/null || echo "")
  [[ -n "$storage_type" && "$storage_type" != "none" ]]
}

# Get storage configuration value
get_storage_config() {
  local key="$1"
  get_config_value ".storage.$key" 2>/dev/null || echo ""
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

MC_ALIAS="dbx-storage"

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
    secret_key=$(keychain_get "s3-secret-key" 2>/dev/null || true)
    if [[ -z "$secret_key" ]]; then
      secret_key=$(get_storage_config "s3.secret_key")
    fi
  fi

  if [[ -z "$endpoint" || -z "$access_key" || -z "$secret_key" ]]; then
    die "S3 storage not fully configured. Required: endpoint, access_key, secret_key"
  fi

  # Configure mc alias (quietly)
  mc alias set "$MC_ALIAS" "$endpoint" "$access_key" "$secret_key" --api S3v4 >/dev/null 2>&1
}

mc_upload() {
  local local_file="$1"
  local remote_path="$2"

  mc_configure

  local bucket prefix
  bucket=$(get_storage_config "s3.bucket")
  prefix=$(get_storage_config "s3.prefix")
  prefix="${prefix%/}"  # Remove trailing slash

  local full_path="${MC_ALIAS}/${bucket}/${prefix}/${remote_path}"

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

  local full_path="${MC_ALIAS}/${bucket}/${prefix}/${remote_path}"

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

  local full_path="${MC_ALIAS}/${bucket}/${prefix}"
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

  local full_path="${MC_ALIAS}/${bucket}/${prefix}/${remote_path}"

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
    secret_key=$(keychain_get "s3-secret-key" 2>/dev/null || true)
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

storage_upload() {
  local local_file="$1"
  local remote_path="${2:-}"

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

storage_delete() {
  local remote_path="$1"

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
  find "$backup_dir" -name "*.sql.zst*" -type f | while read -r file; do
    # Skip metadata files
    [[ "$file" == *.meta.json ]] && continue

    local relative_path="${file#$DATA_DIR/}"
    log_info "Uploading: $relative_path"
    storage_upload "$file" "$relative_path"
    ((count++)) || true
  done

  log_success "Synced $count backup(s) to remote storage"
}

# Sync remote backups to local storage
storage_sync_download() {
  local host="$1"
  local database="${2:-}"

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

      mc find "${MC_ALIAS}/${bucket}/${prefix}/${remote_path}" --name "*.sql.zst*" 2>/dev/null | while read -r remote_file; do
        [[ "$remote_file" == *.meta.json ]] && continue
        local relative="${remote_file#${MC_ALIAS}/${bucket}/${prefix}/}"
        local local_file="$DATA_DIR/$relative"
        mkdir -p "$(dirname "$local_file")"
        log_info "Downloading: $relative"
        mc cp "$remote_file" "$local_file" >/dev/null
        ((count++)) || true
      done
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

# ============================================================================
# Storage Info
# ============================================================================

storage_info() {
  echo -e "${BOLD}Storage Configuration:${NC}"
  echo ""

  local storage_type
  storage_type=$(get_storage_config "type")

  if [[ -z "$storage_type" || "$storage_type" == "none" ]]; then
    echo "  Not configured"
    echo ""
    echo "  Add to config.json:"
    echo '  "storage": {'
    echo '    "type": "s3",'
    echo '    "s3": {'
    echo '      "bucket": "backups",'
    echo '      "endpoint": "http://minio:9000",'
    echo '      "access_key": "...",'
    echo '      "secret_key_cmd": "dbx vault get s3-secret-key"'
    echo '    }'
    echo '  }'
    return
  fi

  echo "  Type: $storage_type"

  case "$storage_type" in
    s3)
      echo "  Endpoint: $(get_storage_config "s3.endpoint")"
      echo "  Bucket: $(get_storage_config "s3.bucket")"
      echo "  Prefix: $(get_storage_config "s3.prefix")"
      echo "  Client: $(detect_s3_client)"
      ;;
  esac
}
