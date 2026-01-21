#!/usr/bin/env bash
#
# lib/mysql.sh - MySQL/MariaDB backup and restore functions
#
# Requires: core.sh, tunnel.sh, encrypt.sh to be sourced first
#

# ============================================================================
# MySQL Backup
# ============================================================================

mysql_backup() {
  local host="$1"
  local database="$2"
  local output_file="$3"
  local verbose="${4:-false}"

  local start_time
  start_time=$(date +%s)

  # Use effective host/port (handles SSH tunnels)
  local db_host db_port db_user db_pass definer_handling
  db_host=$(get_effective_host "$host")
  db_port=$(get_effective_port "$host")
  db_user=$(get_config_value ".hosts[\"$host\"].user")
  db_pass=$(get_password "$host")
  definer_handling=$(get_definer_handling "$host")

  # Warn about plaintext passwords
  warn_plaintext_password "$host"

  # Get excluded tables
  local exclude_tables=()
  while IFS= read -r table; do
    [[ -n "$table" ]] && exclude_tables+=("$table")
  done < <(get_excluded_tables "$host" "$database")

  # Check encryption settings
  local enc_type enc_ext
  enc_type=$(get_encryption_type)
  enc_ext=$(get_encryption_extension)

  # Adjust output filename if encryption is enabled
  if [[ -n "$enc_ext" && "$output_file" != *"$enc_ext" ]]; then
    output_file="${output_file}${enc_ext}"
  fi

  log_step "Backing up MySQL: $database@$host"
  log_info "Connecting: $db_host:$db_port (user: $db_user)"
  log_info "DEFINER handling: $definer_handling"
  [[ "$enc_type" != "none" ]] && log_info "Encryption: $enc_type"
  [[ ${#exclude_tables[@]} -gt 0 ]] && log_info "Excluding data: ${exclude_tables[*]}"

  require_container "$MYSQL_CONTAINER"

  local tmpdir
  tmpdir=$(mktemp -d)
  chmod 700 "$tmpdir"
  trap "rm -rf '$tmpdir'" RETURN

  # Create secure credential file using helper
  local cred_file
  cred_file=$(create_mysql_credential_file "$db_user" "$db_pass" "$db_host" "$db_port")

  # Copy to tmpdir for cleanup tracking
  mv "$cred_file" "$tmpdir/my.cnf"
  cred_file="$tmpdir/my.cnf"

  local err_file="$tmpdir/errors.log"
  local verbose_flag=""
  [[ "$verbose" == "true" ]] && verbose_flag="--verbose"

  # Copy credential file to container for secure access
  docker cp "$cred_file" "$MYSQL_CONTAINER:/tmp/my.cnf" 2>/dev/null
  docker exec "$MYSQL_CONTAINER" chmod 600 /tmp/my.cnf 2>/dev/null

  # Pass 1: Schema for ALL tables (including excluded ones)
  log_info "Dumping schema (tables, views, routines, triggers)..."
  if ! docker exec "$MYSQL_CONTAINER" \
    mysqldump \
      --defaults-extra-file=/tmp/my.cnf \
      --single-transaction \
      --set-gtid-purged=OFF \
      --skip-lock-tables \
      --no-data \
      --routines \
      --triggers \
      --events \
      $verbose_flag \
      "$database" 2>"$err_file" | strip_definer "$definer_handling" > "$tmpdir/schema.sql"; then
    cat "$err_file" >&2
    docker exec "$MYSQL_CONTAINER" rm -f /tmp/my.cnf 2>/dev/null
    audit_backup "$host" "$database" "failure"
    die "Schema dump failed"
  fi

  if [[ ! -s "$tmpdir/schema.sql" ]]; then
    cat "$err_file" >&2
    docker exec "$MYSQL_CONTAINER" rm -f /tmp/my.cnf 2>/dev/null
    audit_backup "$host" "$database" "failure"
    die "Schema dump produced empty output - check connection and permissions"
  fi

  # Pass 2: Data for non-excluded tables
  log_info "Dumping data..."
  local ignore_opts=()
  for table in "${exclude_tables[@]}"; do
    ignore_opts+=(--ignore-table="${database}.${table}")
  done

  if ! docker exec "$MYSQL_CONTAINER" \
    mysqldump \
      --defaults-extra-file=/tmp/my.cnf \
      --single-transaction \
      --set-gtid-purged=OFF \
      --skip-lock-tables \
      --no-create-info \
      --skip-triggers \
      $verbose_flag \
      "${ignore_opts[@]}" \
      "$database" 2>"$err_file" > "$tmpdir/data.sql"; then
    cat "$err_file" >&2
    docker exec "$MYSQL_CONTAINER" rm -f /tmp/my.cnf 2>/dev/null
    audit_backup "$host" "$database" "failure"
    die "Data dump failed"
  fi

  # Clean up credential file in container
  docker exec "$MYSQL_CONTAINER" rm -f /tmp/my.cnf 2>/dev/null

  # Combine, compress, and optionally encrypt
  log_info "Compressing..."
  if [[ "$enc_type" != "none" && -n "$enc_type" ]]; then
    cat "$tmpdir/schema.sql" "$tmpdir/data.sql" | zstd -T0 -3 | encrypt_backup_stream > "$output_file"
  else
    cat "$tmpdir/schema.sql" "$tmpdir/data.sql" | zstd -T0 -3 > "$output_file"
  fi
  secure_file "$output_file"

  # Calculate checksum and create metadata
  local end_time duration file_size checksum
  end_time=$(date +%s)
  duration=$((end_time - start_time))
  file_size=$(stat -f%z "$output_file" 2>/dev/null || stat -c%s "$output_file" 2>/dev/null || echo "0")
  checksum=$(sha256sum "$output_file" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$output_file" 2>/dev/null | cut -d' ' -f1)

  # Create metadata JSON
  local meta_file="${output_file}.meta.json"
  jq -n \
    --arg host "$host" \
    --arg database "$database" \
    --arg db_type "mysql" \
    --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg size "$file_size" \
    --arg checksum "$checksum" \
    --arg encryption "$enc_type" \
    --arg dbx_version "${VERSION:-unknown}" \
    '{
      host: $host,
      database: $database,
      type: $db_type,
      timestamp: $timestamp,
      size: ($size | tonumber),
      checksums: { sha256: $checksum },
      encryption: $encryption,
      dbx_version: $dbx_version
    }' > "$meta_file"
  secure_file "$meta_file"

  # Audit log
  audit_backup "$host" "$database" "success" "$output_file" "$file_size" "$duration"

  log_success "Backup complete: $output_file"
  log_info "Checksum (SHA256): $checksum"
}

# ============================================================================
# MySQL Restore
# ============================================================================

mysql_restore_backup() {
  local backup_file="$1"
  local target_db="$2"

  local start_time
  start_time=$(date +%s)

  log_step "Restoring MySQL backup to: $target_db"

  # Get file size for progress
  local file_size
  file_size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null || echo "0")
  local human_size
  human_size=$(numfmt --to=iec "$file_size" 2>/dev/null || echo "${file_size} bytes")

  # Filter function to clean SQL stream for MariaDB compatibility
  # - Removes mysqldump warnings
  # - Fixes VARCHAR length limits (MySQL allows 65000, MariaDB max 16383)
  # - Prepends FK/unique check disabling for faster import
  filter_sql() {
    (echo "SET foreign_key_checks=0; SET unique_checks=0;" && \
     grep -v "^mysqldump: \[Warning\]" | grep -v "^Warning: Using a password" | \
     command sed 's/VARCHAR(65000)/TEXT/g; s/VARCHAR(32000)/TEXT/g')
  }

  # Check if using remote mode
  if [[ "${DEV_SERVICES_MODE:-local}" == "remote" ]]; then
    local mysql_host="${DEV_MYSQL_HOST:-mysql}"
    local mysql_port="${DEV_MYSQL_PORT:-3306}"
    local mysql_pass="${DEV_MYSQL_PASSWORD:-devpassword}"

    log_info "Restoring to remote: $mysql_host:$mysql_port"

    # Create secure credential file
    local cred_file
    cred_file=$(create_mysql_credential_file "root" "$mysql_pass" "$mysql_host" "$mysql_port")
    trap "rm -f '$cred_file'" RETURN

    # Create database if it doesn't exist
    log_info "Creating database if not exists..."
    mysql --defaults-extra-file="$cred_file" \
      -e "CREATE DATABASE IF NOT EXISTS \`$target_db\`" 2>/dev/null

    log_info "Importing $human_size (compressed)..."

    # Restore with progress if pv is available
    if command -v pv &>/dev/null; then
      pv -N "Importing" "$backup_file" | decompress_stdin "${backup_file##*.}" | filter_sql | \
        mysql --defaults-extra-file="$cred_file" "$target_db" 2>/dev/null
    else
      log_info "Tip: Install 'pv' for progress bar (nix-shell -p pv)"
      decompress "$backup_file" | filter_sql | \
        mysql --defaults-extra-file="$cred_file" "$target_db" 2>/dev/null
    fi
  else
    require_container "$MYSQL_CONTAINER"

    # Get root password from container env (if set)
    local root_pass
    root_pass=$(docker exec "$MYSQL_CONTAINER" printenv MYSQL_ROOT_PASSWORD 2>/dev/null || echo "")

    # Create secure credential file and copy to container
    local tmpdir
    tmpdir=$(mktemp -d)
    chmod 700 "$tmpdir"
    trap "rm -rf '$tmpdir'" RETURN

    local cred_file
    cred_file=$(create_mysql_credential_file "root" "$root_pass")
    mv "$cred_file" "$tmpdir/my.cnf"
    cred_file="$tmpdir/my.cnf"
    docker cp "$cred_file" "$MYSQL_CONTAINER:/tmp/my.cnf" 2>/dev/null
    docker exec "$MYSQL_CONTAINER" chmod 600 /tmp/my.cnf 2>/dev/null

    # Create database if it doesn't exist
    log_info "Creating database if not exists..."
    docker exec "$MYSQL_CONTAINER" \
      mysql --defaults-extra-file=/tmp/my.cnf -e "CREATE DATABASE IF NOT EXISTS \`$target_db\`" 2>/dev/null

    log_info "Importing $human_size (compressed)..."

    # Restore with progress if pv is available
    if command -v pv &>/dev/null; then
      pv -N "Importing" "$backup_file" | decompress_stdin "${backup_file##*.}" | filter_sql | \
        docker exec -i "$MYSQL_CONTAINER" mysql --defaults-extra-file=/tmp/my.cnf "$target_db"
    else
      log_info "Tip: Install 'pv' for progress bar (nix-shell -p pv)"
      decompress "$backup_file" | filter_sql | docker exec -i "$MYSQL_CONTAINER" \
        mysql --defaults-extra-file=/tmp/my.cnf "$target_db"
    fi

    # Clean up credential file in container
    docker exec "$MYSQL_CONTAINER" rm -f /tmp/my.cnf 2>/dev/null
  fi

  # Calculate duration and audit
  local end_time duration
  end_time=$(date +%s)
  duration=$((end_time - start_time))
  audit_restore "$backup_file" "$target_db" "success" "$duration"

  log_success "Restore complete: $target_db"
}

# ============================================================================
# MySQL Analysis (Interactive table exclusion picker)
# ============================================================================

analyze_mysql() {
  local host="$1"
  local database="$2"

  local db_host db_port db_user db_pass
  db_host=$(get_effective_host "$host")
  db_port=$(get_effective_port "$host")
  db_user=$(get_config_value ".hosts[\"$host\"].user")
  db_pass=$(get_password "$host")

  require_container "$MYSQL_CONTAINER"

  log_step "Analyzing tables in $database@$host..."

  # Create secure credential file
  local tmpdir
  tmpdir=$(mktemp -d)
  chmod 700 "$tmpdir"
  trap "rm -rf '$tmpdir'" RETURN

  local cred_file
  cred_file=$(create_mysql_credential_file "$db_user" "$db_pass" "$db_host" "$db_port")
  mv "$cred_file" "$tmpdir/my.cnf"
  cred_file="$tmpdir/my.cnf"
  docker cp "$cred_file" "$MYSQL_CONTAINER:/tmp/my.cnf" 2>/dev/null
  docker exec "$MYSQL_CONTAINER" chmod 600 /tmp/my.cnf 2>/dev/null

  # Get current exclusions
  local current_exclusions
  current_exclusions=$(jq -r ".hosts[\"$host\"].databases[\"$database\"].exclude_data // [] | .[]" "$CONFIG_FILE" 2>/dev/null | tr '\n' '|')

  # Query table stats
  local stats_query="
    SELECT
      TABLE_NAME as tbl,
      TABLE_ROWS as rows,
      ROUND(DATA_LENGTH / 1024 / 1024, 2) as data_mb,
      ROUND(INDEX_LENGTH / 1024 / 1024, 2) as idx_mb,
      ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2) as total_mb,
      TABLE_TYPE as type
    FROM information_schema.TABLES
    WHERE TABLE_SCHEMA = '$database'
    ORDER BY (DATA_LENGTH + INDEX_LENGTH) DESC;
  "

  local tmpfile="$tmpdir/stats.txt"

  docker exec "$MYSQL_CONTAINER" \
    mysql --defaults-extra-file=/tmp/my.cnf \
    -N -e "$stats_query" 2>/dev/null > "$tmpfile"

  if [[ ! -s "$tmpfile" ]]; then
    docker exec "$MYSQL_CONTAINER" rm -f /tmp/my.cnf 2>/dev/null
    die "Failed to get table stats. Check connection and permissions."
  fi

  # Calculate totals
  local total_rows total_size table_count
  total_rows=$(awk '{sum += $2} END {print sum}' "$tmpfile")
  total_size=$(awk '{sum += $5} END {printf "%.2f", sum}' "$tmpfile")
  table_count=$(wc -l < "$tmpfile" | tr -d ' ')

  echo ""
  echo -e "${BOLD}Database: $database${NC}"
  echo -e "Tables: $table_count | Total Size: ${total_size}MB | Total Rows: $total_rows"
  echo ""

  # Check if fzf is available for interactive mode
  if ! command -v fzf &>/dev/null; then
    echo -e "${BOLD}Table Stats (largest first):${NC}"
    echo ""
    printf "%-40s %12s %10s %10s %s\n" "TABLE" "ROWS" "DATA_MB" "TOTAL_MB" "EXCLUDED"
    printf "%-40s %12s %10s %10s %s\n" "-----" "----" "-------" "--------" "--------"

    while IFS=$'\t' read -r tbl rows data_mb idx_mb total_mb ttype; do
      local excluded=""
      if echo "$current_exclusions" | grep -q "^${tbl}|" || echo "$current_exclusions" | grep -q "|${tbl}|" || echo "$current_exclusions" | grep -q "|${tbl}$" || [[ "$current_exclusions" == "${tbl}|" ]]; then
        excluded="[EXCLUDED]"
      fi
      printf "%-40s %12s %10s %10s %s\n" "$tbl" "$rows" "$data_mb" "$total_mb" "$excluded"
    done < "$tmpfile"

    echo ""
    log_info "Install fzf for interactive table selection"
    docker exec "$MYSQL_CONTAINER" rm -f /tmp/my.cnf 2>/dev/null
    return
  fi

  # Interactive mode with fzf
  echo -e "${YELLOW}Select tables to EXCLUDE from data backup (schema always included)${NC}"
  echo -e "Use TAB to select multiple, ENTER to confirm"
  echo ""

  # Format for fzf with pre-selection of currently excluded tables
  local formatted="$tmpdir/formatted.txt"

  while IFS=$'\t' read -r tbl rows data_mb idx_mb total_mb ttype; do
    local marker=""
    # Check if already excluded
    if echo "|$current_exclusions" | grep -q "|${tbl}|" || [[ "$current_exclusions" == "${tbl}|" ]] || echo "$current_exclusions" | grep -q "^${tbl}|"; then
      marker="*"  # Pre-select marker
    fi
    printf "%s%-45s %12s rows %10sMB\n" "$marker" "$tbl" "$rows" "$total_mb"
  done < "$tmpfile" > "$formatted"

  # Run fzf for selection
  local selected
  selected=$(cat "$formatted" | fzf --multi \
    --header="TAB=select  ENTER=confirm  ESC=cancel" \
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
  - Report/analytics tables (can rebuild)'" \
    --preview-window=right:40%:wrap \
    --bind='ctrl-a:select-all' \
    --bind='ctrl-d:deselect-all' \
    | awk '{print $1}' | sed 's/^\*//' | grep -v '^$')

  if [[ -z "$selected" ]]; then
    log_info "No changes made"
    docker exec "$MYSQL_CONTAINER" rm -f /tmp/my.cnf 2>/dev/null
    return
  fi

  # Convert to JSON array
  local exclude_json
  exclude_json=$(echo "$selected" | jq -R -s 'split("\n") | map(select(. != ""))')

  # Calculate excluded size (using secure credential file already in container)
  local excluded_size=0
  while IFS= read -r tbl; do
    [[ -z "$tbl" ]] && continue
    local tbl_size
    tbl_size=$(docker exec "$MYSQL_CONTAINER" \
      mysql --defaults-extra-file=/tmp/my.cnf -N \
      -e "SELECT ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$database' AND TABLE_NAME='$tbl'" 2>/dev/null)
    excluded_size=$(awk "BEGIN {print $excluded_size + ${tbl_size:-0}}")
  done <<< "$selected"

  # Clean up credential file in container
  docker exec "$MYSQL_CONTAINER" rm -f /tmp/my.cnf 2>/dev/null

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
