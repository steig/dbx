#!/usr/bin/env bash
#
# lib/mysql.sh - MySQL/MariaDB backup and restore functions
#
# Requires: core.sh, tunnel.sh, encrypt.sh to be sourced first
#

# ============================================================================
# Helpers
# ============================================================================

# Filter cosmetic mysql/mariadb warnings out of stderr while letting real
# errors through. Used as `2> >(mysql_stderr_filter)` on `mysql` invocations
# that the user is meant to see the result of (restore imports, DDL setup).
#
# Why: mysql / mariadb clients emit `[Warning] Using a password on the
# command line interface can be insecure.` (or `Warning: Using a password
# ...` on older versions) even when invoked with --defaults-extra-file, with
# no flag to silence just that one. The previous code worked around it with
# `2>/dev/null`, which also swallowed every real error — so a failed
# `LOAD DATA` or syntax error in the dump looked indistinguishable from a
# successful restore (user complaint, PR #56 review feedback).
#
# Pattern keeps the legitimate stderr path open while only dropping the
# known-cosmetic line. Output is rewritten to stderr (>&2) of the parent.
mysql_stderr_filter() {
  grep -vE '^(mysql: )?\[?[Ww]arning\]?.*Using a password' >&2 || true
}

# ============================================================================
# MySQL Backup
# ============================================================================

# Run a two-pass mysqldump from inside mysql-dbx (schema for all
# tables including excluded; data for non-excluded), strip DEFINER
# per the host's `definer_handling` setting, pipe through zstd and
# the configured encryption (if any) into $output_file. Writes a
# sibling .meta.json with size, checksum, dbx_version, and
# `type: "mysql"`.
# Args: $1=host alias, $2=database name, $3=output base path,
#       $4=verbose ("true"/"false")
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
  # Omit the trailing ":port" when port is empty (SSH-tunnel hosts without
  # an explicit target_port end up here with $db_port="" and used to print
  # "Connecting: 1.2.3.4: (user: ...)" with the stray colon).
  if [[ -n "$db_port" ]]; then
    log_info "Connecting: $db_host:$db_port (user: $db_user)"
  else
    log_info "Connecting: $db_host (user: $db_user)"
  fi
  log_info "DEFINER handling: $definer_handling"
  [[ "$enc_type" != "none" ]] && log_info "Encryption: $enc_type"
  [[ ${#exclude_tables[@]} -gt 0 ]] && log_info "Excluding data: ${exclude_tables[*]}"

  # Match the dumper container to the source flavor/version. mysqldump grammar
  # drifts across major versions, and Oracle's mysqldump doesn't speak
  # MariaDB. This is the dumper container — nothing valuable lives in
  # mysql-dbx during a backup, so we always recreate if mismatched.
  local flavor src_major src_minor
  local mysql_ver
  mysql_ver=$(mysql_detect_server_version "$db_host" "$db_port" "$db_user" "$db_pass" < /dev/null)
  read -r flavor src_major src_minor <<<"$mysql_ver"

  local override
  override="${DBX_MYSQL_IMAGE:-$(get_config_value '.defaults.mysql_image' 2>/dev/null || echo '')}"
  local desired_image
  desired_image=$(pick_mysql_image "$flavor" "$src_major" "$src_minor" "$override")
  ensure_container_image "$MYSQL_CONTAINER" "$desired_image" "true" || return 1

  require_container "$MYSQL_CONTAINER"

  local tmpdir
  tmpdir=$(mktemp -d)
  chmod 700 "$tmpdir"

  # Per-invocation unique credential file inside the SHARED mysql-dbx
  # container. The previous code hardcoded /tmp/my.cnf for every backup
  # against the same container, which races with any concurrent invocation
  # (a scheduled `dbx schedule run` while the user is mid-`dbx backup`, a
  # sibling Claude session via cmux, the schedule.bats integration test,
  # …). Race manifests as mysqldump pass 2 erroring with
  # "Failed to open required defaults file: /tmp/my.cnf" because the OTHER
  # invocation's after-success cleanup deleted the file between THIS
  # invocation's pass 1 and pass 2.
  local container_cnf
  container_cnf="/tmp/dbx-my.$$-$RANDOM.cnf"

  # Trap-based cleanup runs on every return path (success, die, ^C), so
  # the per-invocation file is always cleaned up. Old code only cleaned
  # up in specific exit paths via inline `docker exec ... rm`, which left
  # files behind on unhappy paths.
  trap "rm -rf '$tmpdir'; docker exec '$MYSQL_CONTAINER' rm -f '$container_cnf' 2>/dev/null; true" RETURN

  # Create secure credential file using helper
  local cred_file
  cred_file=$(create_mysql_credential_file "$db_user" "$db_pass" "$db_host" "$db_port")

  # Copy to tmpdir for cleanup tracking
  mv "$cred_file" "$tmpdir/my.cnf"
  cred_file="$tmpdir/my.cnf"

  local err_file="$tmpdir/errors.log"
  local verbose_flag=""
  [[ "$verbose" == "true" ]] && verbose_flag="--verbose"

  # Print the sanitized mysqldump target when verbose so the user can
  # confirm exactly which connection/db is being dumped (no password —
  # that's in cred_file, not on the argv).
  if [[ "$verbose" == "true" ]]; then
    log_info "mysqldump target: $db_user@$db_host:$db_port → $database"
  fi

  # --set-gtid-purged is MySQL-only; MariaDB rejects it as an unknown variable.
  local gtid_flag=""
  [[ "$flavor" != "mariadb" ]] && gtid_flag="--set-gtid-purged=OFF"

  # Copy credential file to container for secure access
  docker cp "$cred_file" "$MYSQL_CONTAINER:$container_cnf" 2>/dev/null
  docker exec "$MYSQL_CONTAINER" chmod 600 "$container_cnf" 2>/dev/null

  # Pass 1: Schema for ALL tables (including excluded ones)
  log_info "Dumping schema (tables, views, routines, triggers)..."
  [[ "$verbose" == "true" ]] && log_step_elapsed "$start_time" "mysqldump (schema pass) started"
  # When verbose, tee mysqldump's stderr live to the user's terminal in
  # addition to the err_file. mysqldump --verbose emits per-table progress
  # ("-- Retrieving table structure for table X...") — invaluable when
  # diagnosing a missing-table situation since you can watch and see
  # exactly which table doesn't appear. Without the live tee, the
  # progress only showed up post-hoc in err_file (and only on failure
  # before PR #62, only as warnings after).
  if [[ "$verbose" == "true" ]]; then
    if ! docker exec "$MYSQL_CONTAINER" \
      mysqldump \
        --defaults-extra-file=$container_cnf \
        --single-transaction \
        $gtid_flag \
        --skip-lock-tables \
        --no-data \
        --routines \
        --triggers \
        --events \
        $verbose_flag \
        "$database" 2> >(tee -a "$err_file" >&2) | strip_definer "$definer_handling" > "$tmpdir/schema.sql"; then
      cat "$err_file" >&2
      docker exec "$MYSQL_CONTAINER" rm -f $container_cnf 2>/dev/null
      audit_backup "$host" "$database" "failure"
      die "Schema dump failed"
    fi
  else
    if ! docker exec "$MYSQL_CONTAINER" \
      mysqldump \
        --defaults-extra-file=$container_cnf \
        --single-transaction \
        $gtid_flag \
        --skip-lock-tables \
        --no-data \
        --routines \
        --triggers \
        --events \
        $verbose_flag \
        "$database" 2>"$err_file" | strip_definer "$definer_handling" > "$tmpdir/schema.sql"; then
      cat "$err_file" >&2
      docker exec "$MYSQL_CONTAINER" rm -f $container_cnf 2>/dev/null
      audit_backup "$host" "$database" "failure"
      die "Schema dump failed"
    fi
  fi

  # ALWAYS surface mysqldump's stderr (even on exit 0), filtering only the
  # cosmetic password warning. mysqldump SILENTLY SKIPS tables the backup
  # user can't SELECT on, emitting a `mysqldump: Got error: 1142: ...
  # when using LOCK TABLES` or `Access denied` warning to stderr — the
  # exit code is 0 so the previous `die`-on-failure path never fires.
  # Result: an "OK" backup is missing tables, views fail at restore time
  # ("Table 'b2b.udropship_po' doesn't exist"), and the user has no idea
  # why. Surfacing these warnings at backup time makes the problem
  # obvious BEFORE the restore goes sideways.
  _dbx_mysqldump_surface_warnings() {
    local label="$1"
    local err="$2"
    [[ -s "$err" ]] || return 0
    local count
    count=$(grep -cE '^(mysqldump: )?(Got error|\[?[Ww]arning\]?|Error)' "$err" 2>/dev/null || echo "0")
    # Skip the all-cosmetic case (just the password warning).
    if [[ "$count" -gt 0 ]] \
       && ! grep -qE '^(mysqldump: )?(Got error|Error)' "$err" \
       && ! grep -qvE 'Using a password' "$err"; then
      return 0
    fi
    log_warn "mysqldump ($label) emitted warnings/errors:"
    grep -vE '^(mysqldump: )?\[?[Ww]arning\]?.*Using a password' "$err" \
      | grep -v '^$' \
      | sed 's/^/  /' \
      >&2 || true
  }
  _dbx_mysqldump_surface_warnings "schema pass" "$err_file"

  if [[ ! -s "$tmpdir/schema.sql" ]]; then
    cat "$err_file" >&2
    docker exec "$MYSQL_CONTAINER" rm -f $container_cnf 2>/dev/null
    audit_backup "$host" "$database" "failure"
    die "Schema dump produced empty output - check connection and permissions"
  fi

  # Pass 2: Data for non-excluded tables
  log_info "Dumping data..."
  [[ "$verbose" == "true" ]] && log_step_elapsed "$start_time" "mysqldump (data pass) started"
  local ignore_opts=()
  for table in "${exclude_tables[@]}"; do
    ignore_opts+=(--ignore-table="${database}.${table}")
  done

  if [[ "$verbose" == "true" ]]; then
    if ! docker exec "$MYSQL_CONTAINER" \
      mysqldump \
        --defaults-extra-file=$container_cnf \
        --single-transaction \
        $gtid_flag \
        --skip-lock-tables \
        --no-create-info \
        --skip-triggers \
        $verbose_flag \
        "${ignore_opts[@]}" \
        "$database" 2> >(tee -a "$err_file" >&2) > "$tmpdir/data.sql"; then
      cat "$err_file" >&2
      docker exec "$MYSQL_CONTAINER" rm -f $container_cnf 2>/dev/null
      audit_backup "$host" "$database" "failure"
      die "Data dump failed"
    fi
  else
    if ! docker exec "$MYSQL_CONTAINER" \
      mysqldump \
        --defaults-extra-file=$container_cnf \
        --single-transaction \
        $gtid_flag \
        --skip-lock-tables \
        --no-create-info \
        --skip-triggers \
        $verbose_flag \
        "${ignore_opts[@]}" \
        "$database" 2>"$err_file" > "$tmpdir/data.sql"; then
      cat "$err_file" >&2
      docker exec "$MYSQL_CONTAINER" rm -f $container_cnf 2>/dev/null
      audit_backup "$host" "$database" "failure"
      die "Data dump failed"
    fi
  fi
  _dbx_mysqldump_surface_warnings "data pass" "$err_file"

  # Clean up credential file in container
  docker exec "$MYSQL_CONTAINER" rm -f $container_cnf 2>/dev/null

  # Get compression level from config
  local comp_level
  comp_level=$(get_config_value ".defaults.compression_level" 2>/dev/null || echo "3")
  [[ ! "$comp_level" =~ ^[0-9]+$ ]] && comp_level=3

  # Combine, compress, and optionally encrypt
  log_info "Compressing..."
  [[ "$verbose" == "true" ]] && log_step_elapsed "$start_time" "zstd + encrypt pipeline started"
  if [[ "$enc_type" != "none" && -n "$enc_type" ]]; then
    cat "$tmpdir/schema.sql" "$tmpdir/data.sql" | zstd -T0 -"$comp_level" | encrypt_backup_stream > "$output_file"
  else
    cat "$tmpdir/schema.sql" "$tmpdir/data.sql" | zstd -T0 -"$comp_level" > "$output_file"
  fi
  secure_file "$output_file"

  # Calculate checksum and create metadata
  local end_time duration file_size checksum
  end_time=$(date +%s)
  duration=$((end_time - start_time))
  file_size=$(stat -f%z "$output_file" 2>/dev/null || stat -c%s "$output_file" 2>/dev/null || echo "0")
  if [[ "$verbose" == "true" ]]; then
    log_step_elapsed "$start_time" "compress + encrypt done — $(human_size "$file_size") on disk"
  fi
  checksum=$(sha256sum "$output_file" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$output_file" 2>/dev/null | cut -d' ' -f1)
  [[ "$verbose" == "true" ]] && log_step_elapsed "$start_time" "sha256 done"

  # Capture information_schema.columns for the pre-restore scrub drift
  # check. See the same block in pg_backup for rationale. Best-effort;
  # falls back to empty JSON on any query failure so the backup still
  # completes (the restore-time gate will then do its own post-restore
  # check as a fallback for legacy/empty meta).
  local scrub_schema_tsv scrub_schema_json="{}"
  scrub_schema_tsv=$(docker exec -i -e MYSQL_PWD="$db_pass" "$MYSQL_CONTAINER" \
    mysql -h "$db_host" -P "$db_port" -u "$db_user" -B -N \
    -e "SELECT table_name, column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema = '$database' ORDER BY table_name, ordinal_position" 2>/dev/null < /dev/null || true)
  if [[ -n "$scrub_schema_tsv" ]]; then
    scrub_schema_json=$(printf '%s\n' "$scrub_schema_tsv" | scrub_schema_tsv_to_json 2>/dev/null || echo "{}")
  fi

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
    --arg src_flavor "$flavor" \
    --arg src_major "$src_major" \
    --arg src_minor "$src_minor" \
    --argjson scrub_schema "$scrub_schema_json" \
    '{
      host: $host,
      database: $database,
      type: $db_type,
      timestamp: $timestamp,
      size: ($size | tonumber),
      checksums: { sha256: $checksum },
      encryption: $encryption,
      dbx_version: $dbx_version,
      source_flavor: $src_flavor,
      source_major_version: $src_major,
      source_minor_version: $src_minor,
      source_extensions: [],
      scrub_schema: $scrub_schema
    }' > "$meta_file"
  secure_file "$meta_file"
  [[ "$verbose" == "true" ]] && log_step_elapsed "$start_time" "wrote .meta.json"

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

  log_step "Restoring MySQL backup to: $target_db"

  # Tolerant mode: `--force` lets mysql keep going past SQL errors instead
  # of aborting on the first one. This is the right default for restore
  # because dumps often contain DDL that's valid in the source but won't
  # fully resolve in a fresh local target:
  #   - VIEWs that JOIN tables in OTHER databases (cross-db views like
  #     `b2c.rpt_sales_fact` referencing `reporting.dim_b2c_sales`)
  #   - VIEWs or TRIGGERs referencing tables that were excluded from the
  #     data pass via --exclude-data
  #   - Stale view definitions whose underlying table was dropped from the
  #     source DB but the view stuck around
  # Without --force, the FIRST cross-db reference aborts the entire import
  # and you lose every table after that point. Errors are still emitted
  # to stderr (PR #59) so the user can see what didn't load.
  #
  # Opt out via DBX_STRICT_IMPORT=1 for cases where partial restores are
  # worse than no restore.
  local mysql_force_flag="--force"
  [[ "${DBX_STRICT_IMPORT:-}" == "1" ]] && mysql_force_flag=""

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
    # -a / --text: treat input as text even when grep sniffs binary-looking
    # bytes (BLOB columns, latin1-encoded strings in INSERTs). Without it,
    # grep emits the literal line "Binary file (standard input) matches"
    # INTO the pipe, which mysql then tries to execute as SQL and rejects
    # with ERROR 1064 (42000) — turning a valid dump into a fake syntax
    # error. Surfaced after PR #59 stopped silencing mysql stderr; the
    # previous 2>/dev/null had been hiding this for months.
    #
    # LC_ALL=C: BSD sed (macOS default) errors `RE error: illegal byte
    # sequence` on binary input under UTF-8 locales. Forcing the C locale
    # makes sed treat each byte as opaque and lets the regex match on
    # ASCII content without choking on the binary surrounding it.
    (echo "SET foreign_key_checks=0; SET unique_checks=0;" && \
     LC_ALL=C grep -av "^mysqldump: \[Warning\]" \
     | LC_ALL=C grep -av "^Warning: Using a password" \
     | LC_ALL=C command sed 's/VARCHAR(65000)/TEXT/g; s/VARCHAR(32000)/TEXT/g')
  }

  # Track which target we're restoring to so the final success message
  # can say WHERE the data landed. Without this, the user sees
  # "Restore complete: b2c_v1_2026..." and has to grep upstream lines
  # to figure out if it went to mysql-dbx, a docker-compose `mysql`
  # service, a remote NixOS host, etc.
  local restore_target

  # Check if using remote mode
  if [[ "${DEV_SERVICES_MODE:-local}" == "remote" ]]; then
    local mysql_host="${DEV_MYSQL_HOST:-mysql}"
    local mysql_port="${DEV_MYSQL_PORT:-3306}"
    local mysql_pass="${DEV_MYSQL_PASSWORD:-devpassword}"
    restore_target="$mysql_host:$mysql_port (DEV_SERVICES_MODE=remote)"

    log_info "Restoring to remote: $mysql_host:$mysql_port"

    # Create secure credential file
    local cred_file
    cred_file=$(create_mysql_credential_file "root" "$mysql_pass" "$mysql_host" "$mysql_port")
    trap "rm -f '$cred_file'" RETURN

    # Create database if it doesn't exist
    log_info "Creating database if not exists..."
    mysql --defaults-extra-file="$cred_file" \
      -e "CREATE DATABASE IF NOT EXISTS \`$target_db\`" 2> >(mysql_stderr_filter)

    log_info "Importing $human_size (compressed)..."

    # Restore with progress if pv is available. `-s` gives pv the
    # compressed file size so the bar shows a real % / ETA — the bytes
    # pv counts are the source file's, not the post-decompress stream.
    if command -v pv &>/dev/null; then
      pv -N "Importing" -s "$file_size" "$backup_file" | decompress_stream_by_filename "$backup_file" | filter_sql | \
        mysql --defaults-extra-file="$cred_file" $mysql_force_flag "$target_db" 2> >(mysql_stderr_filter)
    else
      log_info "Tip: Install 'pv' for progress bar (nix-shell -p pv)"
      decompress_backup "$backup_file" | filter_sql | \
        mysql --defaults-extra-file="$cred_file" $mysql_force_flag "$target_db" 2> >(mysql_stderr_filter)
    fi
  else
    require_container "$MYSQL_CONTAINER"
    restore_target="container $MYSQL_CONTAINER"

    # Get root password from container env (if set)
    local root_pass
    root_pass=$(docker exec "$MYSQL_CONTAINER" printenv MYSQL_ROOT_PASSWORD 2>/dev/null || echo "")

    # Create secure credential file and copy to container. Per-invocation
    # unique container path so concurrent backups/restores against the
    # same mysql-dbx container don't race on $container_cnf.
    local tmpdir
    tmpdir=$(mktemp -d)
    chmod 700 "$tmpdir"

    local container_cnf="/tmp/dbx-my.$$-$RANDOM.cnf"
    trap "rm -rf '$tmpdir'; docker exec '$MYSQL_CONTAINER' rm -f '$container_cnf' 2>/dev/null; true" RETURN

    local cred_file
    cred_file=$(create_mysql_credential_file "root" "$root_pass")
    mv "$cred_file" "$tmpdir/my.cnf"
    cred_file="$tmpdir/my.cnf"
    docker cp "$cred_file" "$MYSQL_CONTAINER:$container_cnf" 2>/dev/null
    docker exec "$MYSQL_CONTAINER" chmod 600 "$container_cnf" 2>/dev/null

    # Create database if it doesn't exist
    log_info "Creating database if not exists..."
    docker exec "$MYSQL_CONTAINER" \
      mysql --defaults-extra-file=$container_cnf -e "CREATE DATABASE IF NOT EXISTS \`$target_db\`" \
      2> >(mysql_stderr_filter)

    log_info "Importing $human_size (compressed)..."

    # Restore with progress if pv is available. `-s` gives pv the
    # compressed file size so the bar shows a real % / ETA — the bytes
    # pv counts are the source file's, not the post-decompress stream.
    if command -v pv &>/dev/null; then
      pv -N "Importing" -s "$file_size" "$backup_file" | decompress_stream_by_filename "$backup_file" | filter_sql | \
        docker exec -i "$MYSQL_CONTAINER" mysql --defaults-extra-file=$container_cnf $mysql_force_flag "$target_db"
    else
      log_info "Tip: Install 'pv' for progress bar (nix-shell -p pv)"
      decompress_backup "$backup_file" | filter_sql | docker exec -i "$MYSQL_CONTAINER" \
        mysql --defaults-extra-file=$container_cnf $mysql_force_flag "$target_db"
    fi

    # Clean up credential file in container
    docker exec "$MYSQL_CONTAINER" rm -f $container_cnf 2>/dev/null
  fi

  # Audit is recorded by cmd_restore (after post-restore hooks complete) so we
  # don't claim success before user-visible mutations have actually run.
  log_success "Restore complete: $target_db on ${restore_target:-unknown target}"
  if [[ -n "$mysql_force_flag" ]]; then
    log_info "Note: mysql import ran with --force (tolerant mode). Any [ERROR …] lines"
    log_info "  above were emitted but did NOT abort the restore — typically views or"
    log_info "  triggers referencing tables in other databases. Set DBX_STRICT_IMPORT=1"
    log_info "  to make SQL errors fatal."
  fi
}

# Streaming restore variant for `--transform`. mysqldump output is plain
# SQL so the pipeline skips the pg_restore -f - step:
#   decompress → filter_sql → [transform] → mysql in target
# Atomicity is best-effort — MySQL DDL implicitly commits. On failure we
# DROP the target as cleanup. See docs/restore.md for caveats.
# Transform script runs under `env -i` by default (see transform_exec_argv).
#
# Args: $1 backup_file, $2 target_db, $3 transform_script (may be empty),
#       $4 transform_inherit_env ("true" to skip env cleaning)
mysql_restore_backup_streaming() {
  local backup_file="$1" target_db="$2" transform_script="$3"
  local transform_inherit_env="${4:-false}"

  log_step "Streaming restore (mysql) → $target_db"
  require_container "$MYSQL_CONTAINER"

  local root_pass
  root_pass=$(docker exec "$MYSQL_CONTAINER" printenv MYSQL_ROOT_PASSWORD 2>/dev/null || echo "")

  # Pre-create target DB outside the streamed import.
  docker exec -e MYSQL_PWD="$root_pass" "$MYSQL_CONTAINER" \
    mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$target_db\`" >/dev/null

  # filter_sql is defined inline as a function-scoped here so the streaming
  # variant doesn't depend on mysql_restore_backup having been sourced.
  # See the comment on mysql_restore_backup's filter_sql for why -a is
  # essential — grep otherwise emits "Binary file (standard input) matches"
  # into the pipe and mysql chokes with ERROR 1064.
  local filter_sql_cmd='(printf "SET foreign_key_checks=0; SET unique_checks=0;\n" &&
    LC_ALL=C grep -av "^mysqldump: \[Warning\]" |
    LC_ALL=C grep -av "^Warning: Using a password" |
    LC_ALL=C sed "s/VARCHAR(65000)/TEXT/g; s/VARCHAR(32000)/TEXT/g")'

  log_info "Streaming restore → transform → target..."
  local rc=0
  if [[ -n "$transform_script" ]]; then
    local -a transform_argv=()
    local line
    while IFS= read -r line; do transform_argv+=("$line"); done \
      < <(transform_exec_argv "$transform_inherit_env" "$transform_script")
    { decompress_backup "$backup_file" \
        | bash -c "$filter_sql_cmd" \
        | "${transform_argv[@]}" \
        | docker exec -i -e MYSQL_PWD="$root_pass" "$MYSQL_CONTAINER" \
          mysql -u root "$target_db"
    } || rc=$?
  else
    { decompress_backup "$backup_file" \
        | bash -c "$filter_sql_cmd" \
        | docker exec -i -e MYSQL_PWD="$root_pass" "$MYSQL_CONTAINER" \
          mysql -u root "$target_db"
    } || rc=$?
  fi

  if [[ "$rc" -ne 0 ]]; then
    log_error "Streaming restore FAILED (exit $rc). Dropping target '$target_db' for cleanliness."
    docker exec -e MYSQL_PWD="$root_pass" "$MYSQL_CONTAINER" \
      mysql -u root -e "DROP DATABASE IF EXISTS \`$target_db\`" >/dev/null 2>&1 || true
    return $rc
  fi

  log_success "Streaming restore complete: $target_db"
}

# ============================================================================
# MySQL: run a SQL stream against an existing database
# ============================================================================

# Pure helper: turn `key=value` args into a newline-separated `SET @key :=
# 'value';` prelude. Single quotes in values are doubled (SQL standard
# escape). Entries without `=` are silently skipped. Output ends with a
# trailing newline only if there was at least one valid kv pair.
mysql_build_var_prelude() {
  # bash 3.2 oddity: `${var//$x/$x$x}` does NOT match a literal backslash
  # held in $x (the pattern engine fails to expand the var to a glob char),
  # AND `${var//\'/\'\'}` keeps the backslashes in the replacement instead
  # of stripping them. So: use the literal escape for the backslash
  # substitution, and a variable for the single-quote substitution.
  local sq=\'
  local kv key val
  for kv in "$@"; do
    [[ "$kv" == *=* ]] || continue
    key="${kv%%=*}"
    val="${kv#*=}"
    # Escape backslashes BEFORE doubling single quotes — otherwise the
    # second pass would also touch our newly-added backslashes. MySQL with
    # default NO_BACKSLASH_ESCAPES=OFF interprets \n, \t, \\ inside strings.
    val="${val//\\/\\\\}"
    val="${val//$sq/$sq$sq}"
    printf "SET @%s := '%s';\n" "$key" "$val"
  done
}

# Pipe SQL from stdin into mysql against $target_db inside MYSQL_CONTAINER,
# wrapped in `START TRANSACTION;` … `COMMIT;` so a failing hook rolls back.
# NOTE: MySQL DDL implicitly commits — the wrap only protects pure-DML hooks.
#
# Trailing args are `key=value` pairs; emitted as `SET @key := 'value';` lines
# before the transaction so the stream can reference them via @key.
mysql_run_sql_stream() {
  local target_db="$1"
  shift
  require_container "$MYSQL_CONTAINER"

  local root_pass prelude
  root_pass=$(docker exec "$MYSQL_CONTAINER" printenv MYSQL_ROOT_PASSWORD 2>/dev/null || echo "")
  prelude=$(mysql_build_var_prelude "$@")

  local -a exec_args=(docker exec -i)
  [[ -n "$root_pass" ]] && exec_args+=(-e "MYSQL_PWD=$root_pass")
  exec_args+=("$MYSQL_CONTAINER" mysql -u root "$target_db")

  { [[ -n "$prelude" ]] && printf '%s\n' "$prelude"
    printf 'START TRANSACTION;\n'
    cat
    printf 'COMMIT;\n'
  } | "${exec_args[@]}"
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

  # Create secure credential file. Per-invocation unique container path
  # avoids races with other backups/restores/analyze runs against the
  # same mysql-dbx container.
  local tmpdir
  tmpdir=$(mktemp -d)
  chmod 700 "$tmpdir"

  local container_cnf="/tmp/dbx-my.$$-$RANDOM.cnf"
  trap "rm -rf '$tmpdir'; docker exec '$MYSQL_CONTAINER' rm -f '$container_cnf' 2>/dev/null; true" RETURN

  local cred_file
  cred_file=$(create_mysql_credential_file "$db_user" "$db_pass" "$db_host" "$db_port")
  mv "$cred_file" "$tmpdir/my.cnf"
  cred_file="$tmpdir/my.cnf"
  docker cp "$cred_file" "$MYSQL_CONTAINER:$container_cnf" 2>/dev/null
  docker exec "$MYSQL_CONTAINER" chmod 600 "$container_cnf" 2>/dev/null

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
    mysql --defaults-extra-file=$container_cnf \
    -N -e "$stats_query" 2>/dev/null > "$tmpfile"

  if [[ ! -s "$tmpfile" ]]; then
    docker exec "$MYSQL_CONTAINER" rm -f $container_cnf 2>/dev/null
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
    docker exec "$MYSQL_CONTAINER" rm -f $container_cnf 2>/dev/null
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
    docker exec "$MYSQL_CONTAINER" rm -f $container_cnf 2>/dev/null
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
      mysql --defaults-extra-file=$container_cnf -N \
      -e "SELECT ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$database' AND TABLE_NAME='$tbl'" 2>/dev/null)
    excluded_size=$(awk "BEGIN {print $excluded_size + ${tbl_size:-0}}")
  done <<< "$selected"

  # Clean up credential file in container
  docker exec "$MYSQL_CONTAINER" rm -f $container_cnf 2>/dev/null

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

# ============================================================================
# MySQL/MariaDB Version Parsing
# ============================================================================

# Parse a VERSION() string into "flavor major minor".
# MariaDB version strings contain "MariaDB"; everything else is treated as
# MySQL. Patch level is discarded — major.minor is the image tag granularity.
mysql_parse_version_string() {
  local raw="$1"
  [[ -z "$raw" ]] && { echo "unknown 0 0"; return 0; }

  local flavor="mysql"
  [[ "$raw" == *MariaDB* ]] && flavor="mariadb"

  # First numeric component "X.Y" anchored at the start of the string.
  local major minor
  if [[ "$raw" =~ ^([0-9]+)\.([0-9]+) ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
  else
    echo "unknown 0 0"
    return 0
  fi

  echo "$flavor $major $minor"
}

# Detect flavor + major + minor of a remote MySQL or MariaDB server.
# Returns "flavor major minor" or "unknown 0 0" on any failure.
# Uses the dbx-managed mysql container as the client to avoid needing a
# local mysql binary.
# Args: $1=host $2=port $3=user $4=password
mysql_detect_server_version() {
  local host="$1" port="$2" user="$3" password="$4"
  local raw
  raw=$(docker exec -i -e MYSQL_PWD="$password" \
    "${MYSQL_CONTAINER:-mysql-dbx}" \
    mysql -h "$host" -P "$port" -u "$user" -N -e 'SELECT VERSION()' \
    2>/dev/null | tr -d '\r')
  mysql_parse_version_string "$raw"
}
