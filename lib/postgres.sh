#!/usr/bin/env bash
#
# db-lib/postgres.sh - PostgreSQL backup and restore functions
#
# Requires: core.sh, tunnel.sh, encrypt.sh to be sourced first
#

# ============================================================================
# PostgreSQL Backup
# ============================================================================

# Run pg_dump from inside postgres-dbx, piping through zstd and the
# configured encryption (if any) into $output_file. If encryption is
# enabled, $output_file gets the matching extension appended (.age /
# .gpg) and a sibling .meta.json is written next to it with size,
# checksum, and dbx_version.
# Args: $1=host alias, $2=database name, $3=output base path,
#       $4=verbose ("true"/"false")
# Returns 0 on success, non-zero (and removes $output_file) on failure.
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

  # Get compression level from config
  local comp_level
  comp_level=$(get_config_value ".defaults.compression_level" 2>/dev/null || echo "3")
  [[ ! "$comp_level" =~ ^[0-9]+$ ]] && comp_level=3

  # Run pg_dump with compression and optional encryption
  log_info "Running pg_dump..."
  if [[ "$enc_type" != "none" && -n "$enc_type" ]]; then
    # With encryption
    if ! docker exec -e PGPASSWORD="$db_pass" "$POSTGRES_CONTAINER" \
      pg_dump "${pg_opts[@]}" "$database" 2> >(tee "$err_file" >&2) | zstd -T0 -"$comp_level" | encrypt_backup_stream > "$output_file"; then
      log_error "pg_dump failed"
      rm -f "$output_file"
      audit_backup "$host" "$database" "failure"
      return 1
    fi
  else
    # Without encryption
    if ! docker exec -e PGPASSWORD="$db_pass" "$POSTGRES_CONTAINER" \
      pg_dump "${pg_opts[@]}" "$database" 2> >(tee "$err_file" >&2) | zstd -T0 -"$comp_level" > "$output_file"; then
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

  # Detect source server version + extensions for restore-time image picking.
  # Redirect stdin from /dev/null so that `docker exec -i` inside these
  # helpers does not consume stdin from a surrounding while-read loop when
  # pg_backup is called in a multi-database backup pass.
  local src_major src_exts_raw
  src_major=$(pg_detect_server_version "$db_host" "$db_port" "$db_user" "$db_pass" "$database" < /dev/null)
  src_exts_raw=$(pg_detect_extensions "$db_host" "$db_port" "$db_user" "$db_pass" "$database" < /dev/null)
  # Build a JSON array from the space-separated list.
  local src_exts_json="[]"
  if [[ -n "$src_exts_raw" ]]; then
    src_exts_json=$(printf '%s\n' "$src_exts_raw" | tr ' ' '\n' \
      | jq -R . | jq -s 'map(select(length > 0))')
  fi

  # Capture information_schema.columns into the meta.json so that
  # `dbx restore` can run a pre-restore drift check against the manifest
  # BEFORE any data hits the local container. Best-effort — if the
  # query fails (permissions, transient connectivity), we write an
  # empty schema and the restore-time gate falls back to its own
  # post-restore check. The stream is the same TSV → JSON pipeline
  # used by `dbx scrub init`/`check`.
  local scrub_schema_tsv scrub_schema_json="{}"
  scrub_schema_tsv=$(docker exec -i -e PGPASSWORD="$db_pass" "$POSTGRES_CONTAINER" \
    psql -h "$db_host" -p "$db_port" -U "$db_user" -d "$database" \
    -tA -F $'\t' -c "SELECT table_name, column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema = 'public' ORDER BY table_name, ordinal_position;" 2>/dev/null < /dev/null || true)
  if [[ -n "$scrub_schema_tsv" ]]; then
    scrub_schema_json=$(printf '%s\n' "$scrub_schema_tsv" | scrub_schema_tsv_to_json 2>/dev/null || echo "{}")
  fi

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
    --arg src_flavor "postgres" \
    --arg src_major "$src_major" \
    --argjson src_exts "$src_exts_json" \
    --argjson scrub_schema "$scrub_schema_json" \
    '{
      host: $host,
      database: $database,
      timestamp: $timestamp,
      size: ($size | tonumber),
      checksums: { sha256: $checksum },
      encryption: $encryption,
      dbx_version: $dbx_version,
      source_flavor: $src_flavor,
      source_major_version: $src_major,
      source_extensions: $src_exts,
      scrub_schema: $scrub_schema
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

# Decompress (and decrypt if needed) $backup_file, then restore into
# $target_db on the postgres-dbx container. Creates the target
# database if it doesn't exist. pg_restore warnings are passed through;
# fatal errors are surfaced.
# Args: $1=backup file path, $2=target database name
pg_restore_backup() {
  local backup_file="$1"
  local target_db="$2"

  log_step "Restoring PostgreSQL backup to: $target_db"

  # Determine the right container image based on backup metadata. Legacy
  # backups without source_* fields use the default (postgres:17-alpine).
  local src_major src_exts override desired_image
  local meta_file="${backup_file%.zst}.meta.json"
  [[ ! -f "$meta_file" ]] && meta_file="${backup_file}.meta.json"
  # Handle .age/.gpg suffixes too (they sit on top of .zst).
  [[ ! -f "$meta_file" ]] && meta_file="${backup_file%.age}.meta.json"
  [[ ! -f "$meta_file" ]] && meta_file="${backup_file%.gpg}.meta.json"

  if [[ -f "$meta_file" ]]; then
    src_major=$(jq -r '.source_major_version // "unknown"' "$meta_file")
    src_exts=$(jq -r '.source_extensions // [] | join(" ")' "$meta_file")
  else
    src_major="unknown"
    src_exts=""
  fi

  override="${DBX_POSTGRES_IMAGE:-$(get_config_value '.defaults.postgres_image' 2>/dev/null || echo '')}"
  if ! desired_image=$(pick_postgres_image "$src_major" "$src_exts" "$override"); then
    return 1
  fi

  # If the running container doesn't match, gate on user DBs unless flag set.
  local recreate="${DBX_RECREATE_CONTAINER:-false}"
  ensure_container_image "$POSTGRES_CONTAINER" "$desired_image" "$recreate" || return 1

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

  # Audit is recorded by cmd_restore (after post-restore hooks complete) so we
  # don't claim success before user-visible mutations have actually run.
  log_success "Restore complete: $target_db"
}

# ============================================================================
# PostgreSQL: run a SQL stream against an existing database
# ============================================================================

# Pure helper: turn `key=value` args into a newline-separated list of psql
# `-v key=value` flags. One flag (two args) per kv pair, in input order.
# Entries without `=` are silently skipped. Output is printed one flag-arg
# per line so callers can `read` into an array.
pg_build_psql_var_flags() {
  local kv
  for kv in "$@"; do
    [[ "$kv" == *=* ]] || continue
    printf -- '-v\n%s\n' "$kv"
  done
}

# Pipe SQL from stdin into psql against $target_db inside POSTGRES_CONTAINER.
# Uses ON_ERROR_STOP=1 + -1 (single transaction): the whole stream commits
# as one unit or rolls back on the first error.
#
# Trailing args are `key=value` pairs passed as `-v` flags to psql; reference
# via :'key' / :"key" / :key in the SQL.
pg_run_sql_stream() {
  local target_db="$1"
  shift
  require_container "$POSTGRES_CONTAINER"
  local -a var_flags=()
  local line
  while IFS= read -r line; do var_flags+=("$line"); done < <(pg_build_psql_var_flags "$@")
  docker exec -i "$POSTGRES_CONTAINER" \
    psql -U postgres -d "$target_db" -v ON_ERROR_STOP=1 -q -1 "${var_flags[@]+"${var_flags[@]}"}"
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

# ============================================================================
# PostgreSQL Version Parsing
# ============================================================================

# Parse server_version_num integer → major version string.
# PG 10+: MMMmmmm encoding (130000 → 13, 160003 → 16).
# Returns "unknown" if input isn't a non-empty integer.
pg_parse_server_version_num() {
  local raw="$1"
  [[ -z "$raw" ]] && { echo "unknown"; return 0; }
  [[ "$raw" =~ ^[0-9]+$ ]] || { echo "unknown"; return 0; }
  echo "$((raw / 10000))"
}

# Detect the major version of a remote Postgres server. Returns "unknown" on
# any failure (connection, permissions, parse error) — callers fall back to
# the default image.
# Args: $1=host $2=port $3=user $4=password [$5=database, default "postgres"]
pg_detect_server_version() {
  local host="$1" port="$2" user="$3" password="$4" db="${5:-postgres}"
  local raw
  raw=$(docker exec -i -e PGPASSWORD="$password" \
    "${POSTGRES_CONTAINER:-postgres-dbx}" \
    psql -h "$host" -p "$port" -U "$user" -d "$db" -tA -c \
    "SELECT current_setting('server_version_num')" 2>/dev/null \
    | tr -d '[:space:]')
  pg_parse_server_version_num "$raw"
}

# Resolve an external container named by `dbx restore --into` and emit its
# connection details as TSV (one line):
#   container TAB user TAB password TAB db TAB pg_major
#
# Reads POSTGRES_USER / POSTGRES_PASSWORD / POSTGRES_DB from the container's
# env. Waits up to 30s for the database to accept connections via pg_isready
# inside the container. Errors clearly if:
#   - container doesn't exist
#   - container has no POSTGRES_USER env (not a postgres container)
#   - pg_isready times out
# Args: $1 container name
pg_resolve_into_container() {
  local container="$1"

  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$container"; then
    die "--into: container '$container' is not running (docker ps does not list it)"
  fi

  local user pass db
  user=$(docker exec "$container" printenv POSTGRES_USER 2>/dev/null || true)
  pass=$(docker exec "$container" printenv POSTGRES_PASSWORD 2>/dev/null || true)
  db=$(docker exec "$container" printenv POSTGRES_DB 2>/dev/null || true)

  if [[ -z "$user" ]]; then
    die "--into: container '$container' has no POSTGRES_USER env — \`--into\` expects a postgres container (the standard postgres image sets these)"
  fi
  [[ -z "$db" ]] && db="$user"  # postgres image defaults POSTGRES_DB to POSTGRES_USER

  # Wait for postgres inside the container to accept connections.
  local i max_wait=30
  for ((i=1; i<=max_wait; i++)); do
    if docker exec -e PGPASSWORD="$pass" "$container" \
        pg_isready -U "$user" -d "$db" >/dev/null 2>&1; then
      break
    fi
    [[ $i -eq $max_wait ]] && die "--into: postgres in '$container' did not become ready within ${max_wait}s"
    sleep 1
  done

  printf '%s\t%s\t%s\t%s\n' "$container" "$user" "$pass" "$db"
}

# Streaming restore variant. Used when `--transform` or `--into` is set on
# `dbx restore`. Pipeline:
#
#   pg_restore -f - <backup>           # emit plain SQL on stdout
#       | <transform>                  # optional user script
#       | psql -1 ON_ERROR_STOP=1      # single transaction; atomic on failure
#
# The transform script runs on the host with the raw plain-SQL byte-stream
# on stdin; it emits the sanitized stream on stdout. Non-zero exit aborts
# the restore atomically (psql sees EOF mid-transaction → ROLLBACK).
#
# Args: $1 backup_file, $2 target_db, $3 target_container,
#       $4 target_user, $5 target_pass (may be empty),
#       $6 transform_script (may be empty)
pg_restore_backup_streaming() {
  local backup_file="$1" target_db="$2"
  local target_container="$3" target_user="$4" target_pass="$5"
  local transform_script="$6"

  log_step "Streaming restore (postgres) → $target_container:$target_db"

  # Decompress backup to a tempfile inside DATA_DIR (matches the existing
  # pg_restore_backup pattern). pg_restore on the custom format needs
  # random access, so we can't avoid the tempfile here. The transform
  # script itself never sees the tempfile — it sees the plain-SQL stream
  # emitted by pg_restore -f - downstream.
  local tmp_dir tmpfile
  tmp_dir="$DATA_DIR/.tmp"
  mkdir -p "$tmp_dir" && chmod 700 "$tmp_dir"
  tmpfile=$(mktemp -p "$tmp_dir")
  trap "rm -f '$tmpfile'" RETURN

  log_info "Decompressing backup..."
  decompress_backup "$backup_file" > "$tmpfile"

  # Source container must have pg_restore — we use postgres-dbx as the
  # "emit plain SQL" worker. require_container picks an image; for the
  # streaming path we just need pg_restore in the binary.
  require_container "$POSTGRES_CONTAINER"
  docker cp "$tmpfile" "$POSTGRES_CONTAINER:/tmp/restore-stream.dump"

  # Pre-create the target database in the target container. Doing this
  # outside the streamed transaction so the CREATE DATABASE itself isn't
  # subject to the -1 wrap (it can't be). We connect to the `postgres`
  # admin database — always present on a vanilla cluster — to issue
  # the CREATE. Without `-d postgres`, psql would try to connect to a
  # DB named after $target_user, which may not exist (especially in
  # the --into case where the user is `sidecaruser` or similar).
  log_info "Ensuring target database '$target_db' exists in $target_container..."
  if [[ -n "$target_pass" ]]; then
    docker exec -e PGPASSWORD="$target_pass" "$target_container" \
      psql -U "$target_user" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$target_db'" \
      | grep -q 1 || \
    docker exec -e PGPASSWORD="$target_pass" "$target_container" \
      psql -U "$target_user" -d postgres -c "CREATE DATABASE \"$target_db\"" >/dev/null
  else
    docker exec "$target_container" \
      psql -U "$target_user" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$target_db'" \
      | grep -q 1 || \
    docker exec "$target_container" \
      psql -U "$target_user" -d postgres -c "CREATE DATABASE \"$target_db\"" >/dev/null
  fi

  # The streaming pipeline. Atomicity: psql -1 wraps everything in a
  # single transaction. If the transform script exits non-zero mid-stream,
  # psql either hits a SQL error (ON_ERROR_STOP=1) or sees EOF mid-tx;
  # either way the whole thing rolls back. set -o pipefail (set in dbx)
  # propagates the first non-zero exit so the caller sees the failure.
  log_info "Streaming restore → transform → target..."
  local -a target_psql=(docker exec -i)
  [[ -n "$target_pass" ]] && target_psql+=(-e PGPASSWORD="$target_pass")
  target_psql+=("$target_container" psql -U "$target_user" -d "$target_db"
                -v ON_ERROR_STOP=1 -1 -q)

  # set -e + pipefail in dbx will exit the script on the first non-zero
  # pipe step. We need to inspect $rc and run cleanup, so explicitly
  # capture via `|| rc=$?` and reset to 0 first.
  local rc=0
  if [[ -n "$transform_script" ]]; then
    { docker exec "$POSTGRES_CONTAINER" \
        pg_restore --no-owner --no-privileges -f - /tmp/restore-stream.dump \
        | "$transform_script" \
        | "${target_psql[@]}"
    } || rc=$?
  else
    { docker exec "$POSTGRES_CONTAINER" \
        pg_restore --no-owner --no-privileges -f - /tmp/restore-stream.dump \
        | "${target_psql[@]}"
    } || rc=$?
  fi

  docker exec "$POSTGRES_CONTAINER" rm -f /tmp/restore-stream.dump 2>/dev/null || true

  if [[ "$rc" -ne 0 ]]; then
    # Best-effort cleanup of the partially-restored target. The -1
    # rollback should have done this already, but if the transform
    # script itself was killed (SIGPIPE) before psql saw any data,
    # an empty DB might remain. Drop it to leave no trace.
    log_error "Streaming restore FAILED (exit $rc). Dropping target '$target_db' for cleanliness."
    if [[ -n "$target_pass" ]]; then
      docker exec -e PGPASSWORD="$target_pass" "$target_container" \
        psql -U "$target_user" -d postgres -c "DROP DATABASE IF EXISTS \"$target_db\"" >/dev/null 2>&1 || true
    else
      docker exec "$target_container" \
        psql -U "$target_user" -d postgres -c "DROP DATABASE IF EXISTS \"$target_db\"" >/dev/null 2>&1 || true
    fi
    return $rc
  fi

  log_success "Streaming restore complete: $target_container:$target_db"
}

# Detect extensions installed in a specific database. Returns a space-separated
# list with plpgsql filtered out. Empty string when none or on failure.
# Args: $1=host $2=port $3=user $4=password $5=database
pg_detect_extensions() {
  local host="$1" port="$2" user="$3" password="$4" db="$5"
  docker exec -i -e PGPASSWORD="$password" \
    "${POSTGRES_CONTAINER:-postgres-dbx}" \
    psql -h "$host" -p "$port" -U "$user" -d "$db" -tA -c \
    "SELECT extname FROM pg_extension WHERE extname != 'plpgsql' ORDER BY extname" \
    2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

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
