#!/usr/bin/env bash
#
# lib/host.sh - Host aliases, safety levels, and host CRUD.
#
# Requires: core.sh to be sourced first
#
# Two halves:
#   - alias validation and safety levels, read by the restore path,
#     lib/post_restore.sh and lib/scrub.sh
#   - the interactive `dbx host add` flow (also driven by lib/wizard.sh)
#     and the config-block writers it uses. host_add calls back into the
#     dispatcher's cmd_test and lib/storage.sh's storage_add.
#

# ============================================================================
# Alias validation and safety levels
# ============================================================================

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

# Safety gate specifically for `restore --into` when the SOURCE backup comes from a
# prod-flagged host. By default this refuses — raw production data flowing into a local
# sidecar is exactly what safety=prod guards against. DBX_ALLOW_PROD_RESTORE=1 is an
# explicit, loud opt-out for acknowledged dev workflows (e.g. boring sidecars): it
# bypasses ONLY this gate and leaves every other prod protection intact (read-only
# transactions, the post-restore-hook / scrub-apply refusals still go through
# require_writable_host). Args: $1 = source host alias.
require_writable_host_for_restore_into() {
  local alias="${1:-}"
  [[ -z "$alias" ]] && return 0
  host_exists "$alias" || return 0
  [[ "$(host_safety "$alias")" != "prod" ]] && return 0
  if [[ "${DBX_ALLOW_PROD_RESTORE:-}" == "1" ]]; then
    log_warn "DBX_ALLOW_PROD_RESTORE=1 — restoring prod-source backup from '$alias' into a local container."
    log_warn "  Production data may contain unsanitized PII; keep the target container local and ephemeral."
    return 0
  fi
  die "Refusing restore --into from prod-source backup (host '$alias', safety=prod).
This guards against raw production data landing in a local container. To allow it
intentionally, set DBX_ALLOW_PROD_RESTORE=1 (keeps the host's other prod protections),
or remove the safety flag for '$alias' in config.json."
}

# ============================================================================
# Host CRUD
# ============================================================================

# Prompt for a TCP port and validate it's numeric. Re-prompts on
# non-numeric input. Empty input returns non-zero so callers can abort.
# Args: $1 prompt header, $2 default value. Prints the validated port.
host_prompt_port() {
  local header="$1" default="$2" port
  while :; do
    port=$(gum input --header "$header" --value "$default")
    [[ -z "$port" ]] && return 1
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      echo "$port"
      return 0
    fi
    log_warn "Port must be a number (got: $port)"
  done
}

# Write a host block to $CONFIG_FILE atomically via jq + temp-file.
# Args: alias, type, user, then either:
#   "direct" <host> <port>
#   "tunnel" <jump_host> <target_host> <target_port>
host_write_block() {
  local alias="$1" type="$2" user="$3" mode="$4"
  local tmp; tmp=$(mktemp)
  if [[ "$mode" == "direct" ]]; then
    local h="$5" p="$6"
    jq --arg a "$alias" --arg t "$type" --arg u "$user" \
       --arg h "$h" --argjson p "$p" \
       '.hosts[$a] = {type: $t, host: $h, port: $p, user: $u, databases: {}}' \
       "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
  else
    local jh="$5" th="$6" tp="$7"
    jq --arg a "$alias" --arg t "$type" --arg u "$user" \
       --arg jh "$jh" --arg th "$th" --argjson tp "$tp" \
       '.hosts[$a] = {type: $t, user: $u, ssh_tunnel: {jump_host: $jh, target_host: $th, target_port: $tp}, databases: {}}' \
       "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
  fi
  secure_file "$CONFIG_FILE"
}

# Delete a host block from $CONFIG_FILE. Used by the wizard's rollback path.
host_delete_block() {
  local alias="$1"
  local tmp; tmp=$(mktemp)
  jq --arg a "$alias" 'del(.hosts[$a])' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
  secure_file "$CONFIG_FILE"
}

host_add() {
  require_config
  require_jq
  require_docker
  require_gum

  local alias new_type new_user
  while :; do
    alias=$(gum input --header "Host alias:" --placeholder "production")
    [[ -z "$alias" ]] && { log_info "Aborted."; return 0; }
    if ! host_alias_valid "$alias"; then
      log_warn "Alias must start with a letter or digit and use only letters, digits, '_', or '-'."
      continue
    fi
    if host_exists "$alias"; then
      local existing_type existing_user
      existing_type=$(get_config_value ".hosts[\"$alias\"].type")
      existing_user=$(get_config_value ".hosts[\"$alias\"].user")
      log_warn "Host '$alias' already exists (type=$existing_type, user=$existing_user)."
      continue
    fi
    break
  done

  new_type=$(gum choose --header "Database type:" "postgres" "mysql" "mariadb")
  [[ -z "$new_type" ]] && { log_info "Aborted."; return 0; }

  new_user=$(gum input --header "Database user:" --placeholder "postgres")
  [[ -z "$new_user" ]] && { log_info "Aborted."; return 0; }

  local network_mode
  network_mode=$(gum choose --header "How does dbx reach this database?" \
    "Direct connection" "SSH tunnel (jump host)")
  [[ -z "$network_mode" ]] && { log_info "Aborted."; return 0; }

  local default_port direct_host direct_port
  local tunnel_jump tunnel_target tunnel_port
  default_port=$([[ "$new_type" == "postgres" ]] && echo "5432" || echo "3306")

  if [[ "$network_mode" == "Direct connection" ]]; then
    direct_host=$(gum input --header "Host address:" --value "localhost")
    [[ -z "$direct_host" ]] && { log_info "Aborted."; return 0; }
    direct_port=$(host_prompt_port "Port:" "$default_port") \
      || { log_info "Aborted."; return 0; }
  else
    tunnel_jump=$(gum input --header "SSH jump host (from your ~/.ssh/config):" \
                            --placeholder "bastion")
    [[ -z "$tunnel_jump" ]] && { log_info "Aborted."; return 0; }
    tunnel_target=$(gum input --header "Database hostname (as seen from the jump host):" \
                              --placeholder "db.internal")
    [[ -z "$tunnel_target" ]] && { log_info "Aborted."; return 0; }
    tunnel_port=$(host_prompt_port "Database port (on the jump-side network):" "$default_port") \
      || { log_info "Aborted."; return 0; }
  fi

  # Credentials. keychain_set persists via the active backend (Keychain on
  # macOS, pass on Linux, age fallback) so the password never lands in
  # config.json.
  local existing_pass
  existing_pass=$(get_password "$alias" 2>/dev/null || true)
  if [[ -n "$existing_pass" ]]; then
    local creds_choice
    creds_choice=$(gum choose --header "Vault already has a password for '$alias'." \
                              "Use existing" "Replace")
    [[ -z "$creds_choice" ]] && { log_info "Aborted."; return 0; }
    if [[ "$creds_choice" == "Replace" ]]; then
      local new_pass
      new_pass=$(gum input --password --header "New password for '$alias':")
      [[ -z "$new_pass" ]] && { log_info "Aborted."; return 0; }
      keychain_set "$alias" "$new_pass"
    fi
  else
    local new_pass
    new_pass=$(gum input --password --header "Password for '$alias':")
    [[ -z "$new_pass" ]] && { log_info "Aborted."; return 0; }
    keychain_set "$alias" "$new_pass"
  fi

  log_info "Credentials stored."

  while :; do
    log_step "Writing provisional host block and validating..."
    if [[ "$network_mode" == "Direct connection" ]]; then
      host_write_block "$alias" "$new_type" "$new_user" direct "$direct_host" "$direct_port"
    else
      host_write_block "$alias" "$new_type" "$new_user" tunnel \
        "$tunnel_jump" "$tunnel_target" "$tunnel_port"
    fi

    if cmd_test "$alias"; then
      log_success "Connection validated."
      break
    fi

    log_error "Connection validation failed."
    local recover
    recover=$(gum choose --header "What now?" \
      "Re-enter credentials and retry" \
      "Re-enter host fields and retry" \
      "Save anyway (broken host kept in config)" \
      "Abort and roll back")

    case "$recover" in
      "Re-enter credentials and retry")
        local new_pass
        new_pass=$(gum input --password --header "New password for '$alias':")
        [[ -z "$new_pass" ]] && { log_info "Aborted."; host_delete_block "$alias"; keychain_delete "$alias" 2>/dev/null || true; return 1; }
        keychain_set "$alias" "$new_pass"
        continue
        ;;
      "Re-enter host fields and retry")
        # Re-collect network branch only; identity stays.
        network_mode=$(gum choose --header "How does dbx reach this database?" \
          "Direct connection" "SSH tunnel (jump host)")
        [[ -z "$network_mode" ]] && { log_info "Aborted."; host_delete_block "$alias"; keychain_delete "$alias" 2>/dev/null || true; return 1; }
        if [[ "$network_mode" == "Direct connection" ]]; then
          direct_host=$(gum input --header "Host address:" --value "${direct_host:-localhost}")
          direct_port=$(host_prompt_port "Port:" "${direct_port:-$default_port}") \
            || { log_info "Aborted."; host_delete_block "$alias"; keychain_delete "$alias" 2>/dev/null || true; return 1; }
        else
          tunnel_jump=$(gum input --header "SSH jump host:" --value "${tunnel_jump:-}")
          tunnel_target=$(gum input --header "Database hostname:" --value "${tunnel_target:-}")
          tunnel_port=$(host_prompt_port "Database port:" "${tunnel_port:-$default_port}") \
            || { log_info "Aborted."; host_delete_block "$alias"; keychain_delete "$alias" 2>/dev/null || true; return 1; }
        fi
        continue
        ;;
      "Save anyway (broken host kept in config)")
        log_warn "Host '$alias' saved with failing connection test. Fix it with: dbx config edit"
        return 0
        ;;
      "Abort and roll back"|"")
        log_info "Rolling back..."
        host_delete_block "$alias"
        keychain_delete "$alias" 2>/dev/null || true
        log_info "Rolled back. Config and vault unchanged."
        return 1
        ;;
    esac
  done

  local remote_dbs picked
  remote_dbs=$(list_remote_databases "$alias" 2>/dev/null | grep -v '^$' || true)

  if [[ -z "$remote_dbs" ]]; then
    log_warn "No user databases found on '$alias' (or list query failed)."
    log_info "Continuing with empty database list — edit them later via 'dbx config edit'."
    picked=""
  else
    picked=$(echo "$remote_dbs" | gum choose --no-limit \
      --header "Pick databases to back up (space to toggle, enter to confirm):")
    if [[ -z "$picked" ]]; then
      log_info "No databases selected."
    fi
  fi

  # Per-database exclude tables.
  if [[ -n "$picked" ]]; then
    while IFS= read -r db; do
      [[ -z "$db" ]] && continue
      local excl
      excl=$(gum input --header "Tables to exclude data from in '$db' (comma-separated, blank for none):")
      local tmp; tmp=$(mktemp)
      if [[ -n "$excl" ]]; then
        local excl_json
        excl_json=$(printf '%s' "$excl" | tr ',' '\n' \
          | awk 'NF { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0); print }' \
          | jq -R . | jq -s .)
        jq --arg a "$alias" --arg d "$db" --argjson e "$excl_json" \
           '.hosts[$a].databases[$d] = {exclude_data: $e}' \
           "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
      else
        jq --arg a "$alias" --arg d "$db" \
           '.hosts[$a].databases[$d] = {}' \
           "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
      fi
      secure_file "$CONFIG_FILE"
    done <<< "$picked"
  fi

  # MySQL-only: strip DEFINER clauses? Default yes.
  if [[ "$new_type" == "mysql" ]]; then
    local definer_value
    if gum confirm --default=true "Strip DEFINER clauses from MySQL dumps?"; then
      definer_value="strip"
    else
      definer_value="keep"
    fi
    local tmp; tmp=$(mktemp)
    jq --arg a "$alias" --arg dh "$definer_value" \
       '.hosts[$a].definer_handling = $dh' \
       "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    secure_file "$CONFIG_FILE"
  fi

  # Summary.
  local db_count
  db_count=$(printf '%s' "$picked" | grep -c . || true)
  echo
  log_success "Host '$alias' added."
  log_info "  Type:      $new_type"
  if [[ "$network_mode" == "Direct connection" ]]; then
    log_info "  Network:   direct ($direct_host:$direct_port)"
  else
    log_info "  Network:   ssh tunnel via $tunnel_jump to $tunnel_target:$tunnel_port"
  fi
  log_info "  Databases: ${db_count:-0}"

  # Storage chain (conditional). See spec: "Step 7 — Storage chain".
  if is_storage_configured; then
    if gum confirm --default=false "Enable auto-upload to remote storage for '$alias' backups?"; then
      local tmp; tmp=$(mktemp)
      jq --arg a "$alias" '.hosts[$a].auto_upload = true' \
        "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
      secure_file "$CONFIG_FILE"
      # With more than one named backend, let the host pick which one its
      # auto-uploads target; otherwise it uses .defaults.storage / the only one.
      local _backends; _backends=$(storage_list_backends)
      if [[ "$(printf '%s\n' "$_backends" | grep -c .)" -gt 1 ]]; then
        local _pick
        _pick=$(printf '%s\n' "$_backends" | gum choose --header "Upload '$alias' backups to which storage?")
        if [[ -n "$_pick" ]]; then
          tmp=$(mktemp)
          jq --arg a "$alias" --arg s "$_pick" '.hosts[$a].upload_storage = $s' \
            "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
          secure_file "$CONFIG_FILE"
          log_info "  Storage:   auto-upload enabled for $alias → $_pick"
        else
          log_info "  Storage:   auto-upload enabled for $alias"
        fi
      else
        log_info "  Storage:   auto-upload enabled for $alias"
      fi
    else
      log_info "  Storage:   configured globally (auto-upload off for $alias)"
    fi
  else
    if gum confirm --default=true "Configure remote storage for these backups now?"; then
      storage_add
    else
      log_info "  Storage:   not configured (skipped). Set up later with: dbx storage add"
    fi
  fi

  log_info "Try: dbx backup $alias"
}

cmd_host() {
  local action="${1:-}"; shift || true
  case "$action" in
    add)
      host_add "$@"
      ;;
    remove|rm|delete|list|ls|test|edit)
      die "host $action: not yet implemented"
      ;;
    ""|help)
      die "Usage: dbx host <action>
  Actions:
    add        Interactively add a new backup host"
      ;;
    *)
      die "Unknown host action: $action (use: add)"
      ;;
  esac
}
