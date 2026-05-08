#!/usr/bin/env bash
#
# lib/tui.sh - Interactive menu-driven UI on top of `gum`.
#
# Conventions:
#   - Two-accent palette (see "Theme" below). Anything outside the palette
#     should justify itself with a comment.
#   - Alt-screen mode (tput smcup/rmcup) on entry/exit so the user's
#     scrollback is preserved when they leave the TUI.
#   - Widths track $COLUMNS so panels don't look tiny on a 200-col
#     terminal or overflow on an 80-col one.
#   - Action labels and the functions they dispatch to are decoupled —
#     change the emoji or wording without breaking dispatch.
#
# Requires: lib/core.sh, lib/encrypt.sh, lib/update.sh sourced first.
#

# ============================================================================
# Theme
# ============================================================================

# Primary accent — used for chrome (borders, headers, dbx brand).
TUI_PRIMARY=99      # purple
# Secondary accent — used for highlights, CTAs, the update banner.
TUI_SECONDARY=214   # amber
# Status colors — reserved meanings.
TUI_OK=40           # green
TUI_WARN=220        # yellow
TUI_ERR=196         # red
TUI_FAINT=245       # neutral grey for hints and meta info

# ============================================================================
# Layout helpers
# ============================================================================

# Width of inset panels. Tracks COLUMNS but caps at a comfortable max so
# tables don't sprawl across ultra-wide terminals.
tui_panel_width() {
  local cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
  local width=$((cols - 4))
  [[ $width -gt 100 ]] && width=100
  [[ $width -lt 50 ]] && width=50
  echo "$width"
}

# Truncate a string to N chars, replacing the tail with a single-char
# ellipsis when the input doesn't fit. Avoids mid-name chops.
tui_truncate() {
  local s="$1" max="$2"
  if (( ${#s} > max )); then
    printf '%s…' "${s:0:max-1}"
  else
    printf '%s' "$s"
  fi
}

# Clear-screen replacement that uses the alternate screen buffer so the
# user's scrollback survives leaving the TUI. Falls back to plain clear
# when alt-screen isn't available.
tui_enter_alt_screen() { tput smcup 2>/dev/null || true; }
tui_leave_alt_screen() { tput rmcup 2>/dev/null || true; }

# Format a unix epoch as YYYY-MM-DD (ISO, locale-stable).
tui_iso_date() {
  local epoch="$1"
  date -u -d "@$epoch" +%Y-%m-%d 2>/dev/null \
    || date -u -r "$epoch" +%Y-%m-%d 2>/dev/null \
    || echo "?"
}

# stat -f%m (BSD) / stat -c%Y (GNU) — file mtime as epoch. Used by
# pickers + the dashboard for "what's recent."
tui_mtime() {
  stat -f%m "$1" 2>/dev/null || stat -c%Y "$1" 2>/dev/null || echo 0
}

# ============================================================================
# Requirements
# ============================================================================

require_gum() {
  command -v gum &>/dev/null \
    || die "gum is required for TUI mode. Install: brew install gum (or go install github.com/charmbracelet/gum@latest)"
}

# ============================================================================
# Self-update (TUI's "Update" entry; the global update notice is in
# lib/update.sh, this is the interactive variant)
# ============================================================================

# Cached for the lifetime of one TUI session. fetch_latest_release hits
# the network every call; the dashboard redraws on every action and we
# don't want a network blip on each keystroke.
LATEST_VERSION=""
tui_check_for_updates() {
  if [[ -z "$LATEST_VERSION" ]]; then
    LATEST_VERSION=$(fetch_latest_release 2>/dev/null || echo "")
  fi
  [[ -n "$LATEST_VERSION" ]] && version_gt "$LATEST_VERSION" "$VERSION"
}

tui_run_self_update() {
  echo
  gum style --foreground "$TUI_SECONDARY" --bold "  Updating dbx..."
  echo
  if curl -fsSL "https://raw.githubusercontent.com/${DBX_REPO_SLUG}/main/install.sh" | bash; then
    echo
    gum style --foreground "$TUI_OK" --bold "  ✓ Updated! Please restart dbx tui"
    sleep 2
    exit 0
  else
    gum style --foreground "$TUI_ERR" --bold "  ✗ Update failed"
    sleep 2
  fi
}

# ============================================================================
# Config helpers
# ============================================================================

tui_list_hosts() {
  require_config
  require_jq
  jq -r '.hosts | keys[]' "$CONFIG_FILE"
}

tui_list_databases_for_host() {
  local host="$1"
  require_jq
  jq -r ".hosts[\"$host\"].databases | keys[]?" "$CONFIG_FILE" 2>/dev/null
}

# ============================================================================
# Headers / dashboards
# ============================================================================

tui_header() {
  clear
  local width
  width=$(tui_panel_width)
  gum style \
    --border double \
    --border-foreground "$TUI_PRIMARY" \
    --foreground "$TUI_PRIMARY" \
    --bold \
    --padding "0 2" \
    --margin "0 0 1 0" \
    --width "$width" \
    "  dbx $VERSION  Database Backup & Restore"
}

# Top-of-screen status: hosts, recent backups, storage totals,
# encryption mode, update banner. Designed to be a fast read at a
# glance, not exhaustive.
tui_dashboard() {
  tui_header
  local width
  width=$(tui_panel_width)

  # Hosts panel.
  local hosts
  hosts=$(tui_list_hosts 2>/dev/null || true)
  if [[ -z "$hosts" ]]; then
    echo "No hosts configured. Run: dbx config edit" \
      | gum style --border rounded --border-foreground "$TUI_PRIMARY" \
                  --padding "1 2" --width "$width"
  else
    {
      printf "%-18s %-10s %-12s %s\n" "HOST" "TYPE" "DATABASES" "BACKUPS"
      printf '%*s\n' $((width - 6)) '' | tr ' ' '─'
      while IFS= read -r host; do
        local htype dbs_count backup_count
        htype=$(get_db_type "$host" 2>/dev/null || echo "?")
        dbs_count=$(tui_list_databases_for_host "$host" 2>/dev/null | grep -c .)
        backup_count=$(find "$DATA_DIR/$host" -name "*.sql.zst*" 2>/dev/null | grep -cv '\.meta\.json$')
        printf "%-18s %-10s %-12s %s\n" \
          "$(tui_truncate "$host" 17)" \
          "$htype" \
          "${dbs_count:-0} dbs" \
          "${backup_count:-0} files"
      done <<< "$hosts"
    } | gum style --border rounded --border-foreground "$TUI_PRIMARY" \
                  --padding "1 2" --width "$width"
  fi

  echo

  # Recent backups panel — actually sorted by mtime, not directory walk
  # order. Picks the 5 newest and labels encrypted ones.
  if [[ -d "$DATA_DIR" ]]; then
    local recent
    recent=$(find "$DATA_DIR" -type f \( -name "*.sql.zst" -o -name "*.sql.zst.gpg" -o -name "*.sql.zst.age" \) -printf '%T@ %p\n' 2>/dev/null \
             || find "$DATA_DIR" -type f \( -name "*.sql.zst" -o -name "*.sql.zst.gpg" -o -name "*.sql.zst.age" \) -exec stat -f '%m %N' {} \; 2>/dev/null)
    recent=$(echo "$recent" | sort -rn | head -5 | awk '{$1=""; sub(/^ /, ""); print}')

    if [[ -n "$recent" ]]; then
      {
        printf "%-40s %8s  %-10s\n" "RECENT BACKUPS" "SIZE" "DATE"
        printf '%*s\n' $((width - 6)) '' | tr ' ' '─'
        while IFS= read -r f; do
          [[ -z "$f" ]] && continue
          local rel size lock="" iso
          rel="${f#"$DATA_DIR/"}"
          size=$(ls -lh "$f" 2>/dev/null | awk '{print $5}')
          iso=$(tui_iso_date "$(tui_mtime "$f")")
          [[ "$f" == *.gpg || "$f" == *.age ]] && lock=" 🔒"
          printf "%-40s %8s  %-10s%s\n" "$(tui_truncate "$rel" 40)" "$size" "$iso" "$lock"
        done <<< "$recent"
      } | gum style --border rounded --border-foreground "$TUI_SECONDARY" \
                    --padding "1 2" --width "$width"
    else
      echo "No backups yet" | gum style --border rounded \
        --border-foreground "$TUI_SECONDARY" --padding "1 2" --width "$width"
    fi
  else
    echo "No backups yet" | gum style --border rounded \
      --border-foreground "$TUI_SECONDARY" --padding "1 2" --width "$width"
  fi

  echo

  # Footer: storage total + encryption + update hint (single source of
  # truth for the update banner — was previously duplicated in the
  # action menu and the global notice).
  local footer="Backups: $DATA_DIR"
  if [[ -d "$DATA_DIR" ]]; then
    local total_size total_count
    total_size=$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo "0B")
    total_count=$(find "$DATA_DIR" -name "*.sql.zst*" 2>/dev/null | grep -cv '\.meta\.json$')
    footer="Total: ${total_count:-0} backups (${total_size})"
  fi
  is_any_encryption_enabled 2>/dev/null && footer+="  🔒 Encrypted"
  gum style --foreground "$TUI_FAINT" "  $footer"

  if tui_check_for_updates; then
    echo
    echo "  Update: $VERSION → $LATEST_VERSION (Tools → Update)" \
      | gum style --border rounded --border-foreground "$TUI_SECONDARY" \
                  --foreground "$TUI_SECONDARY" --bold \
                  --padding "0 2" --width "$width"
  fi
  echo
}

# ============================================================================
# Action dispatch
#
# Single source of truth for what's in the main menu: an ordered array
# of "label|handler" tuples. Adding a menu entry means adding one line
# here; the label and the handler are colocated so an emoji change can't
# break dispatch (was a real risk with the previous case-statement
# approach where the menu and dispatch lived in different blocks).
# ============================================================================

TUI_MENU=(
  "⬆  Backup database|tui_action_backup"
  "⬇  Restore backup|tui_action_restore"
  "🔍 Test connection|tui_action_test"
  "✓  Verify backup|tui_action_verify"
  "⌨  Query database|tui_action_query"
  "📊 Analyze tables|tui_action_analyze"
  "📋 List all backups|tui_action_list"
  "🧹 Clean old backups|tui_action_clean"
  "⏰ Scheduled backups|tui_action_schedule"
  "🔑 Vault & credentials|tui_action_vault"
  "⚙  Configuration|tui_action_config"
)

tui_menu_labels() {
  local entry
  for entry in "${TUI_MENU[@]}"; do
    printf '%s\n' "${entry%%|*}"
  done
}

tui_dispatch() {
  local action="$1"
  case "$action" in
    ""|"❌ Quit") return 1 ;;        # signal "quit the loop"
    "⚡ Update"*) tui_run_self_update; return 0 ;;
  esac
  local entry
  for entry in "${TUI_MENU[@]}"; do
    if [[ "${entry%%|*}" == "$action" ]]; then
      "${entry##*|}"
      return 0
    fi
  done
  # Unrecognized — fall through quietly (likely Esc).
  return 0
}

tui_action_menu() {
  local labels
  labels=$(tui_menu_labels)
  if tui_check_for_updates; then
    labels+=$'\n'"⚡ Update to $LATEST_VERSION"
  fi
  labels+=$'\n'"❌ Quit"

  printf '%s' "$labels" \
    | gum choose --height 14 --cursor "▸ " --cursor-prefix "" \
                 --selected-prefix "▸ " --unselected-prefix "  "
}

# ============================================================================
# Pickers
# ============================================================================

tui_select_host() {
  local hosts
  hosts=$(tui_list_hosts)
  if [[ -z "$hosts" ]]; then
    gum style --foreground "$TUI_ERR" --bold "  No hosts configured!"
    sleep 1
    return 1
  fi

  local host_options=""
  while IFS= read -r host; do
    local htype backup_count
    htype=$(get_db_type "$host" 2>/dev/null || echo "?")
    backup_count=$(find "$DATA_DIR/$host" -name "*.sql.zst*" 2>/dev/null | grep -cv '\.meta\.json$')
    host_options+="$host ($htype, ${backup_count} backups)"$'\n'
  done <<< "$hosts"

  local selected
  selected=$(echo "$host_options" | gum choose --header "Select host:")
  echo "$selected" | sed 's/ (.*//'
}

# Backup picker. Builds a parallel array of (display_string -> path) so
# we never have to regex our way back to the path from the rendered
# label. Echoes the selected absolute path.
tui_select_backup() {
  if [[ ! -d "$DATA_DIR" ]]; then
    gum style --foreground "$TUI_ERR" "No backups found"
    return 1
  fi

  # Use a NUL-separated find pipeline so filenames with spaces or
  # newlines don't confuse the picker.
  local -a paths=()
  local -a labels=()
  while IFS= read -r -d '' f; do
    [[ -z "$f" ]] && continue
    local rel size lock="" iso
    rel="${f#"$DATA_DIR/"}"
    size=$(ls -lh "$f" 2>/dev/null | awk '{print $5}')
    iso=$(tui_iso_date "$(tui_mtime "$f")")
    [[ "$f" == *.gpg || "$f" == *.age ]] && lock="🔒 "
    paths+=("$f")
    labels+=("${lock}${rel}  ($size, $iso)")
  done < <(find "$DATA_DIR" -type f \
           \( -name "*.sql.zst" -o -name "*.sql.zst.gpg" -o -name "*.sql.zst.age" \) \
           -printf '%T@ %p\0' 2>/dev/null \
           | sort -zrn | sed -z 's/^[0-9.]* //')

  if [[ ${#paths[@]} -eq 0 ]]; then
    gum style --foreground "$TUI_ERR" "No backup files found"
    return 1
  fi

  local selected
  selected=$(printf '%s\n' "${labels[@]}" \
    | gum filter --height 15 --header "Select backup (type to filter):")
  [[ -z "$selected" ]] && return 1

  # Find the path whose label matches what gum returned.
  local i
  for i in "${!labels[@]}"; do
    if [[ "${labels[$i]}" == "$selected" ]]; then
      printf '%s' "${paths[$i]}"
      return 0
    fi
  done
  return 1
}

# ============================================================================
# Action handlers (one per menu entry; small + focused)
# ============================================================================

tui_action_backup() {
  echo
  local host
  host=$(tui_select_host) || return 0
  [[ -z "$host" ]] && return 0

  local databases db
  databases=$(tui_list_databases_for_host "$host")
  if [[ -n "$databases" ]]; then
    db=$(echo "$databases" | gum choose --header "Select database:")
  fi
  if [[ -z "$db" ]]; then
    db=$(gum input --placeholder "Enter database name" --header "Database:")
  fi
  [[ -z "$db" ]] && return 0

  echo
  if gum spin --spinner dot --title "Backing up $host/$db..." -- dbx backup "$host" "$db"; then
    gum style --foreground "$TUI_OK" --bold "  ✓ Backup complete: $host/$db"
  else
    gum style --foreground "$TUI_ERR" --bold "  ✗ Backup failed: $host/$db"
  fi
  sleep 2
}

tui_action_restore() {
  echo
  local backup_path
  backup_path=$(tui_select_backup) || return 0
  [[ -z "$backup_path" ]] && return 0

  local target
  target=$(gum input --placeholder "Leave empty for auto-generated name" \
                     --header "Target database name:")

  echo
  local rc=0
  if [[ -n "$target" ]]; then
    gum spin --spinner dot --title "Restoring to $target..." \
      -- dbx restore "$backup_path" --name "$target" || rc=$?
  else
    gum spin --spinner dot --title "Restoring backup..." \
      -- dbx restore "$backup_path" || rc=$?
  fi
  if [[ $rc -eq 0 ]]; then
    gum style --foreground "$TUI_OK" --bold "  ✓ Restore complete"
  else
    gum style --foreground "$TUI_ERR" --bold "  ✗ Restore failed (exit $rc)"
  fi
  sleep 2
}

tui_action_test() {
  echo
  local host
  host=$(tui_select_host) || return 0
  [[ -z "$host" ]] && return 0

  echo
  dbx test "$host" || true
  echo
  gum input --placeholder "Press Enter to continue..."
}

tui_action_verify() {
  echo
  local backup_path
  backup_path=$(tui_select_backup) || return 0
  [[ -z "$backup_path" ]] && return 0

  echo
  dbx verify "$backup_path" || true
  echo
  gum input --placeholder "Press Enter to continue..."
}

tui_action_query() {
  echo
  local host
  host=$(tui_select_host) || return 0
  [[ -z "$host" ]] && return 0

  local db
  db=$(gum input --placeholder "Leave empty for no database" \
                 --header "Database (optional):")

  echo
  gum style --foreground "$TUI_SECONDARY" --bold \
    "  Opening SQL session... (\\q or Ctrl+D to exit)"
  sleep 1
  if [[ -n "$db" ]]; then
    dbx query "$host" "$db"
  else
    dbx query "$host"
  fi
}

tui_action_analyze() {
  echo
  local host
  host=$(tui_select_host) || return 0
  [[ -z "$host" ]] && return 0

  local db
  db=$(gum input --placeholder "Database name" --header "Database:")
  [[ -z "$db" ]] && return 0

  dbx analyze "$host" "$db"
  echo
  gum input --placeholder "Press Enter to continue..."
}

tui_action_list() {
  tui_header
  echo
  dbx list
  echo
  gum input --placeholder "Press Enter to continue..."
}

tui_action_clean() {
  echo
  local keep
  keep=$(gum input --value "10" \
                   --header "Keep how many backups per database?")
  [[ -z "$keep" ]] && keep=10

  if gum confirm "Remove old backups, keeping $keep per database?"; then
    echo
    dbx clean --keep "$keep"
    echo
    gum input --placeholder "Press Enter to continue..."
  fi
}

tui_action_schedule() {
  while true; do
    tui_header
    local width
    width=$(tui_panel_width)
    gum style --border rounded --border-foreground "$TUI_PRIMARY" \
              --foreground "$TUI_PRIMARY" --bold \
              --padding "1 2" --width "$width" \
              "SCHEDULED BACKUPS"

    local action
    action=$(gum choose --cursor "▸ " \
      "📋 List scheduled backups" \
      "➕ Add schedule" \
      "➖ Remove schedule" \
      "▶  Run a scheduled backup now" \
      "← Back")

    case "$action" in
      "📋 List scheduled backups")
        echo
        dbx schedule list
        echo
        gum input --placeholder "Press Enter to continue..."
        ;;
      "➕ Add schedule")
        local host db sched
        host=$(tui_select_host) || continue
        [[ -z "$host" ]] && continue
        db=$(gum input --placeholder "Database name" --header "Database:")
        [[ -z "$db" ]] && continue
        sched=$(gum choose --header "Schedule:" \
          "daily" "daily@5" "hourly" "weekly@0:3" "weekly@1:5")
        [[ -z "$sched" ]] && continue
        dbx schedule add "$host" "$db" "$sched"
        sleep 1
        ;;
      "➖ Remove schedule")
        local host db
        host=$(tui_select_host) || continue
        [[ -z "$host" ]] && continue
        db=$(gum input --placeholder "Database name" --header "Database:")
        [[ -z "$db" ]] && continue
        dbx schedule remove "$host" "$db"
        sleep 1
        ;;
      "▶  Run a scheduled backup now")
        local host db
        host=$(tui_select_host) || continue
        [[ -z "$host" ]] && continue
        db=$(gum input --placeholder "Database name" --header "Database:")
        [[ -z "$db" ]] && continue
        dbx schedule run "$host" "$db"
        sleep 1
        ;;
      "← Back"|"") return 0 ;;
    esac
  done
}

tui_action_vault() {
  while true; do
    tui_header
    local width
    width=$(tui_panel_width)
    gum style --border rounded --border-foreground "$TUI_PRIMARY" \
              --foreground "$TUI_PRIMARY" --bold \
              --padding "1 2" --width "$width" \
              "VAULT & CREDENTIALS"

    local vault_action
    vault_action=$(gum choose --cursor "▸ " \
      "📋 List stored credentials" \
      "➕ Set host password" \
      "➖ Delete host password" \
      "🔐 Set encryption key" \
      "← Back")

    case "$vault_action" in
      "📋 List stored credentials")
        echo
        dbx vault list
        echo
        gum input --placeholder "Press Enter to continue..."
        ;;
      "➕ Set host password")
        local host
        host=$(tui_select_host) || continue
        [[ -n "$host" ]] && dbx vault set "$host"
        sleep 1
        ;;
      "➖ Delete host password")
        local host
        host=$(gum input --header "Host name to delete:")
        [[ -n "$host" ]] && dbx vault delete "$host"
        sleep 1
        ;;
      "🔐 Set encryption key")
        dbx vault set-encryption-key
        sleep 1
        ;;
      "← Back"|"") return 0 ;;
    esac
  done
}

tui_action_config() {
  while true; do
    tui_header
    local width
    width=$(tui_panel_width)
    gum style --border rounded --border-foreground "$TUI_PRIMARY" \
              --foreground "$TUI_PRIMARY" --bold \
              --padding "1 2" --width "$width" \
              "CONFIGURATION & MANAGEMENT"

    local config_action
    config_action=$(gum choose --cursor "▸ " \
      "➕ Add host" \
      "➖ Remove host" \
      "📁 Add database to host" \
      "🗑  Delete backups" \
      "✏  Edit config (advanced)" \
      "👁  Show config" \
      "🆕 Initialize config" \
      "← Back")

    case "$config_action" in
      "➕ Add host") tui_config_add_host ;;
      "➖ Remove host") tui_config_remove_host ;;
      "📁 Add database to host") tui_config_add_database ;;
      "🗑  Delete backups") tui_config_delete_backups ;;
      "👁  Show config")
        tui_header
        dbx config show
        echo
        gum input --placeholder "Press Enter to continue..."
        ;;
      "✏  Edit config (advanced)") dbx config edit ;;
      "🆕 Initialize config") dbx config init; sleep 2 ;;
      "← Back"|"") return 0 ;;
    esac
  done
}

tui_config_add_host() {
  echo
  local new_host new_type new_user new_hostaddr new_port
  new_host=$(gum input --header "Host alias (e.g., production):" --placeholder "production")
  [[ -z "$new_host" ]] && return 0
  new_type=$(gum choose --header "Database type:" "postgres" "mysql")
  [[ -z "$new_type" ]] && return 0
  new_user=$(gum input --header "Database user:" --placeholder "postgres")
  [[ -z "$new_user" ]] && return 0
  new_hostaddr=$(gum input --header "Host address:" --placeholder "localhost or db.internal")
  [[ -z "$new_hostaddr" ]] && return 0
  local default_port
  default_port=$([[ "$new_type" == "postgres" ]] && echo "5432" || echo "3306")
  new_port=$(gum input --header "Port:" --value "$default_port")

  local tmp_config
  tmp_config=$(mktemp)
  jq ".hosts[\"$new_host\"] = {type: \"$new_type\", host: \"$new_hostaddr\", port: $new_port, user: \"$new_user\", databases: {}}" \
    "$CONFIG_FILE" > "$tmp_config" && mv "$tmp_config" "$CONFIG_FILE"

  gum style --foreground "$TUI_OK" --bold "  ✓ Host '$new_host' added"

  if gum confirm "Set password for '$new_host' now?"; then
    dbx vault set "$new_host"
  fi
  sleep 1
}

tui_config_remove_host() {
  echo
  local host
  host=$(tui_select_host) || return 0
  [[ -z "$host" ]] && return 0

  if gum confirm --default=false "Remove host '$host' from config?"; then
    local tmp_config
    tmp_config=$(mktemp)
    jq "del(.hosts[\"$host\"])" "$CONFIG_FILE" > "$tmp_config" && mv "$tmp_config" "$CONFIG_FILE"
    gum style --foreground "$TUI_OK" --bold "  ✓ Host '$host' removed"
    sleep 1
  fi
}

tui_config_add_database() {
  echo
  local host
  host=$(tui_select_host) || return 0
  [[ -z "$host" ]] && return 0

  local new_db
  new_db=$(gum input --header "Database name:" --placeholder "myapp")
  [[ -z "$new_db" ]] && return 0

  local exclude_tables=""
  if gum confirm "Add tables to exclude from data dump?"; then
    exclude_tables=$(gum input --header "Tables to exclude (comma-separated):" \
                                --placeholder "sessions, cache, logs")
  fi

  local tmp_config
  tmp_config=$(mktemp)
  if [[ -n "$exclude_tables" ]]; then
    local exclude_json
    exclude_json=$(echo "$exclude_tables" | tr ',' '\n' \
      | sed 's/^ *//;s/ *$//' | jq -R . | jq -s .)
    jq ".hosts[\"$host\"].databases[\"$new_db\"] = {exclude_data: $exclude_json}" \
      "$CONFIG_FILE" > "$tmp_config" && mv "$tmp_config" "$CONFIG_FILE"
  else
    jq ".hosts[\"$host\"].databases[\"$new_db\"] = {}" \
      "$CONFIG_FILE" > "$tmp_config" && mv "$tmp_config" "$CONFIG_FILE"
  fi

  gum style --foreground "$TUI_OK" --bold "  ✓ Database '$new_db' added to '$host'"
  sleep 1
}

tui_config_delete_backups() {
  echo
  if [[ ! -d "$DATA_DIR" ]]; then
    gum style --foreground "$TUI_ERR" "No backups found"
    sleep 1
    return 0
  fi

  local choice
  choice=$(gum choose --header "Delete backups:" \
    "Select specific backup" \
    "Delete all for a host" \
    "Delete all for a database" \
    "Cancel")

  case "$choice" in
    "Select specific backup")
      local backup_path
      backup_path=$(tui_select_backup) || return 0
      [[ -z "$backup_path" ]] && return 0

      if gum confirm --default=false "Delete backup: $(basename "$backup_path")?"; then
        # The metadata file is at "<full>.meta.json" regardless of
        # encryption suffix (matches pg_backup / mysql_backup writers).
        rm -f "$backup_path" "${backup_path}.meta.json"
        gum style --foreground "$TUI_OK" --bold "  ✓ Backup deleted"
      fi
      ;;
    "Delete all for a host")
      local host count
      host=$(tui_select_host) || return 0
      [[ -z "$host" ]] && return 0
      count=$(find "$DATA_DIR/$host" -name "*.sql.zst*" 2>/dev/null | grep -cv '\.meta\.json$')
      if gum confirm --default=false "Delete ALL $count backups for '$host'?"; then
        rm -rf "${DATA_DIR:?}/${host:?}"
        gum style --foreground "$TUI_OK" --bold "  ✓ All backups for '$host' deleted"
      fi
      ;;
    "Delete all for a database")
      local host
      host=$(tui_select_host) || return 0
      [[ -z "$host" ]] && return 0

      local dbs
      dbs=$(ls -1 "$DATA_DIR/$host" 2>/dev/null)
      if [[ -z "$dbs" ]]; then
        gum style --foreground "$TUI_ERR" "No backups for this host"
        return 0
      fi

      local db count
      db=$(echo "$dbs" | gum choose --header "Select database:")
      [[ -z "$db" ]] && return 0
      count=$(find "$DATA_DIR/$host/$db" -name "*.sql.zst*" 2>/dev/null | grep -cv '\.meta\.json$')

      if gum confirm --default=false "Delete ALL $count backups for '$host/$db'?"; then
        rm -rf "${DATA_DIR:?}/${host:?}/${db:?}"
        gum style --foreground "$TUI_OK" --bold "  ✓ All backups for '$host/$db' deleted"
      fi
      ;;
  esac
  sleep 1
}

# ============================================================================
# Top-level entry point
# ============================================================================

cmd_tui() {
  require_gum
  require_config
  require_jq

  # Drop into the alternate screen so the user's scrollback survives
  # leaving the TUI. tput rmcup is run via the EXIT trap below.
  tui_enter_alt_screen
  trap 'tui_leave_alt_screen' EXIT INT TERM

  while true; do
    tui_dashboard

    local action
    action=$(tui_action_menu)

    # tui_dispatch returns 1 when the user picks Quit (or hits Esc on
    # the top-level menu) so we know to exit the loop. Any other return
    # means stay and redraw.
    tui_dispatch "$action" || break
  done

  tui_leave_alt_screen
  trap - EXIT INT TERM
}
