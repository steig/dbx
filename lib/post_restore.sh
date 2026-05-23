#!/usr/bin/env bash
# Post-restore hooks. Run SQL against the freshly-restored target DB after
# every `dbx restore`. Config schema and full behavior documented in README
# under "Post-restore hooks".
#
# Implementation notes:
# - Host-level hooks (hosts.<h>.post_restore) run before per-DB hooks
#   (hosts.<h>.databases.<d>.post_restore), in array order within each.
# - Each hook runs in its own transaction (psql -1; MySQL START/COMMIT wrap).
# - Fail-fast: first failure returns non-zero; DB is left as-is.
# - MySQL DDL implicitly commits — the transaction wrap only protects DML
#   hook scripts. Document for users who put DDL in hooks.

# Resolve a hook path: absolute → unchanged; relative → relative to the
# directory containing $CONFIG_FILE. Echoes the resolved path.
resolve_hook_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s\n' "$(dirname "$CONFIG_FILE")/$path"
  fi
}

# Read the post_restore array at hosts.<host> or hosts.<host>.databases.<db>.
# Always echoes a JSON array (empty on missing or jq error).
read_host_post_restore_hooks() {
  [[ -f "$CONFIG_FILE" ]] || { printf '[]\n'; return 0; }
  jq -c ".hosts[\"$1\"].post_restore // []" "$CONFIG_FILE" 2>/dev/null || printf '[]\n'
}

read_post_restore_hooks() {
  [[ -f "$CONFIG_FILE" ]] || { printf '[]\n'; return 0; }
  jq -c ".hosts[\"$1\"].databases[\"$2\"].post_restore // []" "$CONFIG_FILE" 2>/dev/null || printf '[]\n'
}

# Parse dbx's `_YYYYMMDD_HHMMSS` suffix into ISO-8601, e.g.
# `app_20260508_103000.dump.zst` → `2026-05-08T10:30:00Z`. Empty on no match.
parse_backup_timestamp() {
  local name="$1"
  if [[ "$name" =~ _([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2}) ]]; then
    printf '%s-%s-%sT%s:%s:%sZ\n' \
      "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
      "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}"
  fi
}

# Validate one post_restore entry: must have exactly one of file/sql, and if
# `file` the resolved path must exist. Logs a specific error on failure and
# returns 1; returns 0 on success.
# Args: $1 host, $2 db (empty for host-level), $3 idx (0-based), $4 source_tag
#       ("host" or "db"), $5 cfg_dir.
validate_hook_entry() {
  local host="$1" db="$2" idx="$3" source_tag="$4" cfg_dir="$5"

  local jq_path location
  if [[ "$source_tag" == "host" ]]; then
    jq_path=".hosts[\"$host\"].post_restore[$idx]"
    location="host '$host' post_restore[$idx]"
  else
    jq_path=".hosts[\"$host\"].databases[\"$db\"].post_restore[$idx]"
    location="host '$host' db '$db' post_restore[$idx]"
  fi

  local entry has_file has_sql
  entry=$(jq -c "$jq_path" "$CONFIG_FILE")
  has_file=$(jq -r 'has("file")' <<<"$entry")
  has_sql=$(jq -r 'has("sql")' <<<"$entry")

  if [[ "$has_file" == "true" && "$has_sql" == "true" ]]; then
    log_error "$location: entry has both 'file' and 'sql' (must be exactly one)"
    return 1
  fi
  if [[ "$has_file" != "true" && "$has_sql" != "true" ]]; then
    log_error "$location: entry has neither 'file' nor 'sql'"
    return 1
  fi
  if [[ "$has_file" == "true" ]]; then
    local raw_path resolved
    raw_path=$(jq -r '.file' <<<"$entry")
    if [[ "$raw_path" = /* ]]; then resolved="$raw_path"; else resolved="$cfg_dir/$raw_path"; fi
    if [[ ! -f "$resolved" ]]; then
      log_error "$location: file not found: $resolved"
      return 1
    fi
  fi
}

# Run post-restore hooks against $target_db. Returns 0 if no hooks configured
# or all hooks succeed; non-zero on the first failure.
# All 8 args required. backup_file and backup_timestamp may be empty strings
# (the --hooks-only path passes both as "").
run_post_restore_hooks() {
  local host="$1" db="$2" target_db="$3" db_type="$4"
  local source_host="$5" source_db="$6" backup_file="$7" backup_timestamp="$8"

  local host_hooks db_hooks host_count db_count total
  host_hooks=$(read_host_post_restore_hooks "$host")
  db_hooks=$(read_post_restore_hooks "$host" "$db")
  host_count=$(jq 'length' <<<"$host_hooks")
  db_count=$(jq 'length' <<<"$db_hooks")
  total=$((host_count + db_count))
  [[ "$total" -eq 0 ]] && return 0

  log_step "Running post-restore hooks ($total)..."

  # Pre-collect into bash arrays. Never iterate via `... | while read` — the
  # loop body's `docker exec -i` would steal the loop's stdin and the second
  # iteration would silently misbehave (see AGENTS.md).
  local -a host_entries=() db_entries=()
  local entry
  if [[ "$host_count" -gt 0 ]]; then
    while IFS= read -r entry; do host_entries+=("$entry"); done < <(jq -c '.[]' <<<"$host_hooks")
  fi
  if [[ "$db_count" -gt 0 ]]; then
    while IFS= read -r entry; do db_entries+=("$entry"); done < <(jq -c '.[]' <<<"$db_hooks")
  fi

  local -a hook_vars=(
    "target_db=$target_db"
    "source_host=$source_host"
    "source_db=$source_db"
    "backup_file=$backup_file"
    "backup_timestamp=$backup_timestamp"
    "restored_at=$(date -u +%FT%TZ)"
  )

  # Global 1-based index across both arrays — users can pair `post_restore[N]`
  # errors with the `[N/total]` live log line. Source tag disambiguates.
  local global_idx=0
  if [[ "${#host_entries[@]}" -gt 0 ]]; then
    for entry in "${host_entries[@]}"; do
      global_idx=$((global_idx + 1))
      _process_post_restore_entry "$entry" "$global_idx" "$total" "host" \
        "$target_db" "$db_type" "${hook_vars[@]}" || return 1
    done
  fi
  if [[ "${#db_entries[@]}" -gt 0 ]]; then
    for entry in "${db_entries[@]}"; do
      global_idx=$((global_idx + 1))
      _process_post_restore_entry "$entry" "$global_idx" "$total" "db" \
        "$target_db" "$db_type" "${hook_vars[@]}" || return 1
    done
  fi

  log_success "Post-restore hooks complete"
}

# Internal: validate, log, and run one entry. Returns non-zero on failure.
_process_post_restore_entry() {
  local entry="$1" global_idx="$2" total="$3" source_tag="$4"
  local target_db="$5" db_type="$6"
  shift 6  # remaining args are the kv-var pairs

  local has_file has_sql err_idx label
  has_file=$(jq -r 'has("file")' <<<"$entry")
  has_sql=$(jq -r 'has("sql")' <<<"$entry")
  err_idx=$((global_idx - 1))

  if [[ "$has_file" == "true" && "$has_sql" == "true" ]]; then
    log_error "post_restore[$err_idx] ($source_tag): entry has both 'file' and 'sql' (must be exactly one)"
    return 1
  fi
  if [[ "$has_file" != "true" && "$has_sql" != "true" ]]; then
    log_error "post_restore[$err_idx] ($source_tag): entry has neither 'file' nor 'sql'"
    return 1
  fi

  if [[ "$has_file" == "true" ]]; then
    local raw_path resolved
    raw_path=$(jq -r '.file' <<<"$entry")
    resolved=$(resolve_hook_path "$raw_path")
    if [[ ! -f "$resolved" ]]; then
      log_error "post_restore[$err_idx] ($source_tag): file not found: $resolved"
      return 1
    fi
    label="$raw_path"
    log_info "  [$global_idx/$total] ($source_tag) $label"
    _run_hook_stream "$db_type" "$target_db" "$@" < "$resolved" || {
      log_error "post_restore[$err_idx] ($source_tag): hook failed: $label"
      return 1
    }
  else
    label="inline #$global_idx"
    log_info "  [$global_idx/$total] ($source_tag) $label"
    printf '%s\n' "$(jq -r '.sql' <<<"$entry")" | _run_hook_stream "$db_type" "$target_db" "$@" || {
      log_error "post_restore[$err_idx] ($source_tag): hook failed: $label"
      return 1
    }
  fi
}

# Internal: dispatch stdin to the engine helper. Trailing args are kv pairs.
_run_hook_stream() {
  local db_type="$1" target_db="$2"
  shift 2
  case "$db_type" in
    postgres|postgresql) pg_run_sql_stream "$target_db" "$@" ;;
    mysql|mariadb)       mysql_run_sql_stream "$target_db" "$@" ;;
    *) log_error "post_restore: unknown db_type: $db_type"; return 1 ;;
  esac
}
