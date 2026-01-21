#!/usr/bin/env bash
#
# db-lib/postgres.sh - PostgreSQL backup and restore functions
#
# Requires: core.sh, tunnel.sh, encrypt.sh to be sourced first
#

# ============================================================================
# PostgreSQL Backup
# ============================================================================

pg_backup() {
  local host="$1"
  local database="$2"
  local output_file="$3"
  local verbose="${4:-false}"

  local start_time
  start_time=$(date +%s)

  # Use effective host/port (handles SSH tunnels)
  local db_host db_port db_user db_pass
  db_host=$(get_effective_host "$host")
  db_port=$(get_effective_port "$host")
  db_user=$(get_config_value ".hosts[\"$host\"].user")
  db_pass=$(get_password "$host")

  # Warn about plaintext passwords
  warn_plaintext_password "$host"

  local jobs
  jobs=$(get_parallel_jobs "$host" "$database")

  # Build exclude options
  local exclude_opts=()
  while IFS= read -r table; do
    [[ -n "$table" ]] && exclude_opts+=(--exclude-table-data="$table")
  done < <(get_excluded_tables "$host" "$database")

  # Check encryption settings
  local enc_type enc_ext
  enc_type=$(get_encryption_type)
  enc_ext=$(get_encryption_extension)

  # Adjust output filename if encryption is enabled
  if [[ -n "$enc_ext" && "$output_file" != *"$enc_ext" ]]; then
    output_file="${output_file}${enc_ext}"
  fi

  log_step "Backing up PostgreSQL: $database@$host"
  log_info "Host: $db_host:$db_port, User: $db_user"
  [[ "$enc_type" != "none" ]] && log_info "Encryption: $enc_type"
  [[ ${#exclude_opts[@]} -gt 0 ]] && log_info "Excluding data from: ${exclude_opts[*]}"

  require_container "$POSTGRES_CONTAINER"

  # Use pg_dump from container, connect to remote, pipe through zstd
  # Capture stderr to check for errors while still allowing verbose progress
  local tmpdir
  tmpdir=$(mktemp -d)
  chmod 700 "$tmpdir"
  trap "rm -rf '$tmpdir'" RETURN

  local err_file="$tmpdir/errors.log"

  # Build pg_dump command options
  local pg_opts=(
    --host="$db_host"
    --port="$db_port"
    --username="$db_user"
    --format=custom
    --compress=0
  )
  [[ "$verbose" == "true" ]] && pg_opts+=(--verbose)
  pg_opts+=("${exclude_opts[@]}")

  # Run pg_dump with compression and optional encryption
  log_info "Running pg_dump..."
  if [[ "$enc_type" != "none" && -n "$enc_type" ]]; then
    # With encryption
    if ! docker exec -e PGPASSWORD="$db_pass" "$POSTGRES_CONTAINER" \
      pg_dump "${pg_opts[@]}" "$database" 2> >(tee "$err_file" >&2) | zstd -T0 -3 | encrypt_backup_stream > "$output_file"; then
      log_error "pg_dump failed"
      rm -f "$output_file"
      audit_backup "$host" "$database" "failure"
      return 1
    fi
  else
    # Without encryption
    if ! docker exec -e PGPASSWORD="$db_pass" "$POSTGRES_CONTAINER" \
      pg_dump "${pg_opts[@]}" "$database" 2> >(tee "$err_file" >&2) | zstd -T0 -3 > "$output_file"; then
      log_error "pg_dump failed"
      rm -f "$output_file"
      audit_backup "$host" "$database" "failure"
      return 1
    fi
  fi

  # Check if output file was actually created and has content
  if [[ ! -s "$output_file" ]]; then
    log_error "pg_dump produced no output. Errors:"
    cat "$err_file" >&2
    rm -f "$output_file"
    audit_backup "$host" "$database" "failure"
    return 1
  fi

  # Secure file permissions
  secure_file "$output_file"

  # Calculate checksum and create metadata file
  local file_size checksum
  file_size=$(stat -f%z "$output_file" 2>/dev/null || stat -c%s "$output_file" 2>/dev/null || echo "0")
  checksum=$(sha256sum "$output_file" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$output_file" 2>/dev/null | cut -d' ' -f1)

  # Create metadata JSON
  local meta_file="${output_file}.meta.json"
  jq -n \
    --arg host "$host" \
    --arg database "$database" \
    --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg size "$file_size" \
    --arg checksum "$checksum" \
    --arg encryption "$enc_type" \
    --arg dbx_version "${VERSION:-unknown}" \
    '{
      host: $host,
      database: $database,
      timestamp: $timestamp,
      size: ($size | tonumber),
      checksums: { sha256: $checksum },
      encryption: $encryption,
      dbx_version: $dbx_version
    }' > "$meta_file"
  secure_file "$meta_file"

  # Calculate duration and audit
  local end_time duration
  end_time=$(date +%s)
  duration=$((end_time - start_time))
  audit_backup "$host" "$database" "success" "$output_file" "$file_size" "$duration"

  log_success "Backup complete: $output_file"
  log_info "Checksum (SHA256): $checksum"
}

# ============================================================================
# PostgreSQL Restore
# ============================================================================

pg_restore_backup() {
  local backup_file="$1"
  local target_db="$2"

  local start_time
  start_time=$(date +%s)

  log_step "Restoring PostgreSQL backup to: $target_db"

  # Decompress backup first (use DATA_DIR to avoid /tmp quota issues)
  local tmp_dir="$DATA_DIR/.tmp"
  mkdir -p "$tmp_dir"
  chmod 700 "$tmp_dir"
  local tmpfile
  tmpfile=$(mktemp -p "$tmp_dir")
  trap "rm -f '$tmpfile'" RETURN

  # Check if file is encrypted
  if is_file_encrypted "$backup_file"; then
    log_info "Decrypting and decompressing backup..."
  else
    log_info "Decompressing backup..."
  fi

  # Use the unified decompress function that handles encryption
  decompress_backup "$backup_file" > "$tmpfile"

  local file_size
  file_size=$(ls -lh "$tmpfile" | awk '{print $5}')
  log_info "Decompressed size: $file_size"

  # Check if using remote mode
  if [[ "${DEV_SERVICES_MODE:-local}" == "remote" ]]; then
    local pg_host="${DEV_PG_HOST:-postgres}"
    local pg_port="${DEV_PG_PORT:-5432}"
    local pg_pass="${DEV_PG_PASSWORD:-devpassword}"

    log_info "Restoring to remote: $pg_host:$pg_port"

    # Create database if it doesn't exist
    PGPASSWORD="$pg_pass" psql -h "$pg_host" -p "$pg_port" -U postgres \
      -c "CREATE DATABASE \"$target_db\"" 2>/dev/null || true

    # Restore
    log_info "Running pg_restore (this may take a while for large databases)..."
    PGPASSWORD="$pg_pass" pg_restore \
      -h "$pg_host" \
      -p "$pg_port" \
      -U postgres \
      --dbname="$target_db" \
      --no-owner \
      --no-privileges \
      "$tmpfile" 2>&1 | grep -E "^pg_restore: (error|warning)" || true
  else
    require_container "$POSTGRES_CONTAINER"

    # Create database if it doesn't exist
    docker exec "$POSTGRES_CONTAINER" \
      psql -U postgres -c "CREATE DATABASE \"$target_db\"" 2>/dev/null || true

    # Copy to container
    log_info "Copying to container..."
    docker cp "$tmpfile" "$POSTGRES_CONTAINER:/tmp/restore.dump"

    # Restore
    log_info "Running pg_restore (this may take a while for large databases)..."
    docker exec "$POSTGRES_CONTAINER" \
      pg_restore \
        -U postgres \
        --dbname="$target_db" \
        --no-owner \
        --no-privileges \
        /tmp/restore.dump 2>&1 | grep -E "^pg_restore: (error|warning)" || true

    # Cleanup inside container
    docker exec "$POSTGRES_CONTAINER" rm -f /tmp/restore.dump
  fi

  # Calculate duration and audit
  local end_time duration
  end_time=$(date +%s)
  duration=$((end_time - start_time))
  audit_restore "$backup_file" "$target_db" "success" "$duration"

  log_success "Restore complete: $target_db"
}

# ============================================================================
# PostgreSQL Backup Verification
# ============================================================================

# Backward compatibility alias - use verify_backup from core.sh
pg_verify_backup() {
  verify_backup "$@"
}

# ============================================================================
# PostgreSQL Analysis
# ============================================================================

analyze_postgres() {
  local host="$1"
  local database="$2"

  local db_host db_port db_user db_pass
  db_host=$(get_effective_host "$host")
  db_port=$(get_effective_port "$host")
  db_user=$(get_config_value ".hosts[\"$host\"].user")
  db_pass=$(get_password "$host")

  require_container "$POSTGRES_CONTAINER"

  log_step "Analyzing tables in $database@$host..."

  # Get current exclusions
  local current_exclusions
  current_exclusions=$(jq -r ".hosts[\"$host\"].databases[\"$database\"].exclude_data // [] | .[]" "$CONFIG_FILE" 2>/dev/null | tr '\n' '|')

  # Query table stats (tab-separated for parsing)
  local stats_query="
    SELECT
      schemaname || '.' || relname,
      COALESCE(n_live_tup, 0),
      pg_total_relation_size(schemaname || '.' || quote_ident(relname))
    FROM pg_stat_user_tables
    ORDER BY pg_total_relation_size(schemaname || '.' || quote_ident(relname)) DESC;
  "

  local tmpfile
  tmpfile=$(mktemp)

  docker exec -e PGPASSWORD="$db_pass" "$POSTGRES_CONTAINER" \
    psql -h "$db_host" -p "$db_port" -U "$db_user" -d "$database" \
    -t -A -F $'\t' -c "$stats_query" 2>/dev/null > "$tmpfile"

  if [[ ! -s "$tmpfile" ]]; then
    rm -f "$tmpfile"
    die "Failed to get table stats. Check connection and permissions."
  fi

  # Calculate totals
  local total_rows total_size table_count
  total_rows=$(awk -F'\t' '{sum += $2} END {print sum+0}' "$tmpfile")
  total_size=$(awk -F'\t' '{sum += $3} END {printf "%.2f", sum/1024/1024}' "$tmpfile")
  table_count=$(wc -l < "$tmpfile" | tr -d ' ')

  echo ""
  echo -e "${BOLD}Database: $database${NC}"
  echo -e "Tables: $table_count | Total Size: ${total_size}MB | Total Rows: $total_rows"
  echo ""

  # Check if fzf is available for interactive mode
  if ! command -v fzf &>/dev/null; then
    echo -e "${BOLD}Table Stats (largest first):${NC}"
    echo ""
    printf "%-50s %12s %12s %s\n" "TABLE" "ROWS" "SIZE_MB" "EXCLUDED"
    printf "%-50s %12s %12s %s\n" "-----" "----" "-------" "--------"

    while IFS=$'\t' read -r tbl rows size_bytes; do
      [[ -z "$tbl" ]] && continue
      local size_mb
      size_mb=$(awk "BEGIN {printf \"%.2f\", $size_bytes/1024/1024}")
      local excluded=""
      if echo "|${current_exclusions}" | grep -q "|${tbl}|" || [[ "$current_exclusions" == "${tbl}|" ]]; then
        excluded="[EXCLUDED]"
      fi
      printf "%-50s %12s %12s %s\n" "$tbl" "$rows" "$size_mb" "$excluded"
    done < "$tmpfile"

    echo ""
    log_info "Install fzf for interactive table selection"
    rm -f "$tmpfile"
    return
  fi

  # Interactive mode with fzf
  echo -e "${YELLOW}Select tables to EXCLUDE from data backup (schema always included)${NC}"
  echo -e "Use TAB to select multiple, ENTER to confirm"
  echo ""

  # Format for fzf with pre-selection of currently excluded tables
  local formatted
  formatted=$(mktemp)

  while IFS=$'\t' read -r tbl rows size_bytes; do
    [[ -z "$tbl" ]] && continue
    local size_mb
    size_mb=$(awk "BEGIN {printf \"%.2f\", $size_bytes/1024/1024}")
    local marker=""
    # Check if already excluded
    if echo "|${current_exclusions}" | grep -q "|${tbl}|" || [[ "$current_exclusions" == "${tbl}|" ]]; then
      marker="*"
    fi
    printf "%s%-55s %12s rows %10sMB\n" "$marker" "$tbl" "$rows" "$size_mb"
  done < "$tmpfile" > "$formatted"

  # Run fzf for selection
  local selected
  selected=$(cat "$formatted" | fzf --multi \
    --header="TAB=select  ENTER=confirm  ESC=cancel  Ctrl-A=all  Ctrl-D=none" \
    --prompt="Exclude tables> " \
    --height=80% \
    --layout=reverse \
    --preview="echo 'Selected tables will have schema backed up but DATA excluded.
This reduces backup size for large/regenerable tables.

Common exclusions:
  - Session tables (regenerated)
  - Log tables (historical, large)
  - Cache tables (regenerated)
  - Search index tables (rebuilt)
  - django_celery_* (task history)
  - Audit/history tables'" \
    --preview-window=right:40%:wrap \
    --bind='ctrl-a:select-all' \
    --bind='ctrl-d:deselect-all' \
    | awk '{print $1}' | sed 's/^\*//' | grep -v '^$')

  rm -f "$tmpfile" "$formatted"

  if [[ -z "$selected" ]]; then
    log_info "No changes made"
    return
  fi

  # Convert to JSON array
  local exclude_json
  exclude_json=$(echo "$selected" | jq -R -s 'split("\n") | map(select(. != ""))')

  # Calculate excluded size
  local excluded_size=0
  while IFS= read -r tbl; do
    [[ -z "$tbl" ]] && continue
    local tbl_size
    tbl_size=$(docker exec -e PGPASSWORD="$db_pass" "$POSTGRES_CONTAINER" \
      psql -h "$db_host" -p "$db_port" -U "$db_user" -d "$database" \
      -t -A -c "SELECT ROUND(pg_total_relation_size('$tbl') / 1024.0 / 1024.0, 2)" 2>/dev/null)
    excluded_size=$(awk "BEGIN {print $excluded_size + ${tbl_size:-0}}")
  done <<< "$selected"

  echo ""
  echo -e "${BOLD}Selected for exclusion:${NC}"
  echo "$selected" | while read -r t; do [[ -n "$t" ]] && echo "  - $t"; done
  echo ""
  echo -e "Estimated backup reduction: ${CYAN}${excluded_size}MB${NC}"
  echo ""

  # Confirm and save
  echo -n "Save this exclusion profile? [y/N] "
  read -r confirm
  if [[ "$confirm" =~ ^[Yy] ]]; then
    # Update config
    local tmp_config
    tmp_config=$(mktemp)

    jq ".hosts[\"$host\"].databases[\"$database\"].exclude_data = $exclude_json" "$CONFIG_FILE" > "$tmp_config"
    mv "$tmp_config" "$CONFIG_FILE"

    log_success "Exclusion profile saved to config"
    log_info "Run 'dbx backup $host $database' to backup with these exclusions"
  else
    log_info "Changes discarded"
  fi
}
