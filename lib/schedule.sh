#!/usr/bin/env bash
#
# lib/schedule.sh - Scheduled backup management (launchd/systemd)
#
# Requires: core.sh to be sourced first
#

# ============================================================================
# Configuration
# ============================================================================

# Service/job naming
SCHEDULE_PREFIX="com.dbx.backup"

# Platform-specific paths
if is_macos; then
  LAUNCHD_DIR="$HOME/Library/LaunchAgents"
else
  SYSTEMD_DIR="$HOME/.config/systemd/user"
fi

# ============================================================================
# Common Utilities
# ============================================================================

# Generate a launchd/systemd-safe job identifier from a host and
# database name. Lowercases input and replaces anything outside
# [a-z0-9.] with "-". Uses printf so the input has no trailing
# newline — `tr -c` would otherwise translate that newline into a
# "-" and the job name would end with a dash.
# Args: $1=host alias, $2=database name
# Echoes: "com.dbx.backup.<host>.<database>"
make_job_name() {
  local host="$1"
  local database="$2"
  printf '%s' "${SCHEDULE_PREFIX}.${host}.${database}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9.' '-'
}

# Translate a friendly schedule string to a 5-field cron expression.
# Accepted forms:
#   hourly         -> "0 * * * *"
#   daily          -> "0 2 * * *"           (default 2am)
#   daily@<H>      -> "0 <H> * * *"
#   weekly         -> "0 2 * * 0"            (default Sun 2am)
#   weekly@<D>:<H> -> "0 <H> * * <D>"        (D = 0..6, Sun..Sat)
#   "<m> <h> ..."  -> passed through unchanged (raw cron)
# Echoes the cron expression. Used by the launchd path; the systemd
# path has its own translator (it needs day names rather than numbers).
parse_schedule() {
  local schedule="$1"

  case "$schedule" in
    hourly)
      echo "0 * * * *"
      ;;
    daily|daily@*)
      # ${schedule#daily@} is a no-op when there's no "@", so set the
      # default first and only override when an @-suffix is present.
      local hour=2
      [[ "$schedule" == daily@* ]] && hour="${schedule#daily@}"
      echo "0 $hour * * *"
      ;;
    weekly|weekly@*)
      local day=0 hour=2
      if [[ "$schedule" == weekly@* ]]; then
        local day_hour="${schedule#weekly@}"
        day="${day_hour%:*}"
        hour="${day_hour#*:}"
      fi
      echo "0 $hour * * $day"
      ;;
    *)
      # Assume cron syntax
      echo "$schedule"
      ;;
  esac
}

# ============================================================================
# macOS launchd
# ============================================================================

launchd_plist_path() {
  local job_name="$1"
  echo "$LAUNCHD_DIR/${job_name}.plist"
}

launchd_create() {
  local host="$1"
  local database="$2"
  local schedule="$3"

  local job_name
  job_name=$(make_job_name "$host" "$database")
  local plist_path
  plist_path=$(launchd_plist_path "$job_name")

  # Parse schedule to get hour/minute
  local cron_schedule
  cron_schedule=$(parse_schedule "$schedule")
  local minute hour day_of_month month day_of_week
  read -r minute hour day_of_month month day_of_week <<< "$cron_schedule"

  # Get dbx path
  local dbx_path
  dbx_path=$(command -v dbx 2>/dev/null || echo "$HOME/.local/bin/dbx")

  mkdir -p "$LAUNCHD_DIR"

  # Generate plist
  cat > "$plist_path" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$job_name</string>
    <key>ProgramArguments</key>
    <array>
        <string>$dbx_path</string>
        <string>schedule</string>
        <string>run-job</string>
        <string>$host</string>
        <string>$database</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Minute</key>
        <integer>$minute</integer>
        <key>Hour</key>
        <integer>$hour</integer>
EOF

  # Add day of week if specified (not *)
  if [[ "$day_of_week" != "*" ]]; then
    cat >> "$plist_path" << EOF
        <key>Weekday</key>
        <integer>$day_of_week</integer>
EOF
  fi

  cat >> "$plist_path" << EOF
    </dict>
    <key>StandardOutPath</key>
    <string>$HOME/.local/share/dbx/logs/${job_name}.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.local/share/dbx/logs/${job_name}.error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:$HOME/.nix-profile/bin</string>
    </dict>
    <key>DbxScheduleExpression</key>
    <string>$schedule</string>
</dict>
</plist>
EOF

  # Create log directory
  mkdir -p "$HOME/.local/share/dbx/logs"

  log_success "Created launchd job: $job_name"
  echo "  Plist: $plist_path"
}

launchd_load() {
  local job_name="$1"
  local plist_path
  plist_path=$(launchd_plist_path "$job_name")

  if [[ ! -f "$plist_path" ]]; then
    die "Plist not found: $plist_path"
  fi

  launchctl load "$plist_path" 2>/dev/null || true
  log_success "Loaded launchd job: $job_name"
}

launchd_unload() {
  local job_name="$1"
  local plist_path
  plist_path=$(launchd_plist_path "$job_name")

  launchctl unload "$plist_path" 2>/dev/null || true
  log_success "Unloaded launchd job: $job_name"
}

launchd_remove() {
  local job_name="$1"
  local plist_path
  plist_path=$(launchd_plist_path "$job_name")

  launchd_unload "$job_name"
  rm -f "$plist_path"
  log_success "Removed launchd job: $job_name"
}

launchd_list() {
  echo -e "${BOLD}Scheduled Backups (launchd):${NC}"
  echo ""

  local found=false
  for plist in "$LAUNCHD_DIR"/${SCHEDULE_PREFIX}.*.plist; do
    [[ -f "$plist" ]] || continue
    found=true

    local job_name
    job_name=$(basename "$plist" .plist)
    local loaded="inactive"
    if launchctl list 2>/dev/null | grep -q "$job_name"; then
      loaded="active"
    fi

    # Extract schedule from plist
    local hour minute
    hour=$(/usr/libexec/PlistBuddy -c "Print :StartCalendarInterval:Hour" "$plist" 2>/dev/null || echo "?")
    minute=$(/usr/libexec/PlistBuddy -c "Print :StartCalendarInterval:Minute" "$plist" 2>/dev/null || echo "?")

    printf "  %-50s %s @ %02d:%02d\n" "$job_name" "$loaded" "$hour" "$minute"
  done

  if ! $found; then
    echo "  No scheduled backups found"
  fi
}

# ============================================================================
# Linux systemd
# ============================================================================

systemd_service_path() {
  local job_name="$1"
  echo "$SYSTEMD_DIR/${job_name}.service"
}

systemd_timer_path() {
  local job_name="$1"
  echo "$SYSTEMD_DIR/${job_name}.timer"
}

systemd_create() {
  local host="$1"
  local database="$2"
  local schedule="$3"

  local job_name
  job_name=$(make_job_name "$host" "$database")
  local service_path timer_path
  service_path=$(systemd_service_path "$job_name")
  timer_path=$(systemd_timer_path "$job_name")

  # Parse schedule
  local cron_schedule
  cron_schedule=$(parse_schedule "$schedule")

  # Convert cron to systemd OnCalendar format
  local oncalendar
  case "$schedule" in
    hourly)
      oncalendar="hourly"
      ;;
    daily|daily@*)
      local hour=2
      [[ "$schedule" == daily@* ]] && hour="${schedule#daily@}"
      oncalendar="*-*-* ${hour}:00:00"
      ;;
    weekly|weekly@*)
      local day="Sun" hour=2
      if [[ "$schedule" == weekly@* ]]; then
        local day_hour="${schedule#weekly@}"
        day="${day_hour%:*}"
        hour="${day_hour#*:}"
      fi
      # systemd OnCalendar wants day names (Mon..Sun); cron syntax accepts
      # 0-6 (or 7) for Sun..Sat. Translate numeric input.
      case "$day" in
        0|7) day="Sun" ;;
        1)   day="Mon" ;;
        2)   day="Tue" ;;
        3)   day="Wed" ;;
        4)   day="Thu" ;;
        5)   day="Fri" ;;
        6)   day="Sat" ;;
      esac
      oncalendar="${day} *-*-* ${hour}:00:00"
      ;;
    *)
      # Try to use cron syntax directly with systemd-analyze
      oncalendar="$cron_schedule"
      ;;
  esac

  # Get dbx path
  local dbx_path
  dbx_path=$(command -v dbx 2>/dev/null || echo "$HOME/.local/bin/dbx")

  mkdir -p "$SYSTEMD_DIR"
  mkdir -p "$HOME/.local/share/dbx/logs"

  # Create service unit
  cat > "$service_path" << EOF
[Unit]
Description=DBX backup: $database@$host

[Service]
Type=oneshot
ExecStart=$dbx_path schedule run-job $host $database
StandardOutput=append:$HOME/.local/share/dbx/logs/${job_name}.log
StandardError=append:$HOME/.local/share/dbx/logs/${job_name}.error.log

[Install]
WantedBy=default.target
EOF

  # Create timer unit. The DbxScheduleExpression header lets
  # `dbx schedule sync` read back the friendly form without
  # reverse-parsing the OnCalendar field.
  cat > "$timer_path" << EOF
# DbxScheduleExpression: $schedule
[Unit]
Description=DBX backup timer: $database@$host

[Timer]
OnCalendar=$oncalendar
Persistent=true

[Install]
WantedBy=timers.target
EOF

  log_success "Created systemd units: $job_name"
  echo "  Service: $service_path"
  echo "  Timer: $timer_path"
}

systemd_enable() {
  local job_name="$1"

  systemctl --user daemon-reload
  systemctl --user enable "${job_name}.timer"
  systemctl --user start "${job_name}.timer"
  log_success "Enabled systemd timer: $job_name"
}

systemd_disable() {
  local job_name="$1"

  systemctl --user stop "${job_name}.timer" 2>/dev/null || true
  systemctl --user disable "${job_name}.timer" 2>/dev/null || true
  log_success "Disabled systemd timer: $job_name"
}

systemd_remove() {
  local job_name="$1"
  local service_path timer_path
  service_path=$(systemd_service_path "$job_name")
  timer_path=$(systemd_timer_path "$job_name")

  systemd_disable "$job_name"
  rm -f "$service_path" "$timer_path"
  systemctl --user daemon-reload
  log_success "Removed systemd units: $job_name"
}

systemd_list() {
  echo -e "${BOLD}Scheduled Backups (systemd):${NC}"
  echo ""

  local found=false
  for timer in "$SYSTEMD_DIR"/${SCHEDULE_PREFIX}.*.timer; do
    [[ -f "$timer" ]] || continue
    found=true

    local job_name
    job_name=$(basename "$timer" .timer)
    local status
    status=$(systemctl --user is-active "${job_name}.timer" 2>/dev/null || echo "inactive")

    # Extract schedule from timer
    local oncalendar
    oncalendar=$(grep "^OnCalendar=" "$timer" 2>/dev/null | cut -d= -f2 || echo "?")

    printf "  %-50s %s @ %s\n" "$job_name" "$status" "$oncalendar"
  done

  if ! $found; then
    echo "  No scheduled backups found"
  fi
}

# ============================================================================
# Declarative-config interface (#39, read path)
#
# Config is canonical: `config.schedules[]` describes the desired state;
# installed launchd/systemd units are derived. The friendly schedule
# expression is stamped into the unit at install time (DbxScheduleExpression
# in the plist; `# DbxScheduleExpression:` header in the timer) so we can
# read it back without reverse-parsing cron.
# ============================================================================

# Emit one TSV line per `.schedules[]` entry in config.json:
#   host TAB database TAB when
# Returns 0 with no output if `.schedules` is missing or empty.
schedule_config_read() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  # Disabled schedules (enabled:false) are intentionally excluded so the sync
  # plan treats them as "not desired" — their installed unit then shows as an
  # orphan. The wizard reads enabled/keep straight from config.json for
  # display; only the sync side filters here.
  jq -r '
    (.schedules // []) | .[] | select(.enabled != false) |
    [.host, .database, .when] | @tsv
  ' "$CONFIG_FILE" 2>/dev/null
}

# Echo the `keep` retention value for a host/database schedule, or empty if it
# has none. Used by `dbx schedule run-job` to prune that pair after a backup.
schedule_keep_for() {
  local host="$1" database="$2"
  [[ -f "$CONFIG_FILE" ]] || return 0
  jq -r --arg h "$host" --arg d "$database" '
    ((.schedules // []) | map(select(.host == $h and .database == $d)) | .[0] // {} | .keep) // empty
  ' "$CONFIG_FILE" 2>/dev/null
}

# Upsert a schedule entry into config.schedules[] so the imperative
# `dbx schedule add` keeps config canonical (config is the source of truth;
# installed units are derived). Matches on host+database: updates `.when` in
# place — preserving any `enabled`/`keep` on the existing entry — if the pair
# is already present, otherwise appends a new {host, database, when}. Atomic
# write, then re-secures the file. No-op if config.json is absent.
schedule_config_upsert() {
  local host="$1" database="$2" when="$3"
  [[ -f "$CONFIG_FILE" ]] || return 0
  local tmp; tmp=$(mktemp)
  jq --arg h "$host" --arg d "$database" --arg w "$when" '
    .schedules = ((.schedules // []) as $s
      | if any($s[]; .host == $h and .database == $d)
        then ($s | map(if .host == $h and .database == $d then .when = $w else . end))
        else ($s + [{host: $h, database: $d, when: $w}])
        end)
  ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
  secure_file "$CONFIG_FILE"
}

# Remove a schedule entry (matched on host+database) from config.schedules[].
# Inverse of schedule_config_upsert; leaves an empty array if it was the last
# entry. No-op if config.json is absent.
schedule_config_delete() {
  local host="$1" database="$2"
  [[ -f "$CONFIG_FILE" ]] || return 0
  local tmp; tmp=$(mktemp)
  jq --arg h "$host" --arg d "$database" '
    .schedules = ((.schedules // []) | map(select((.host == $h and .database == $d) | not)))
  ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
  secure_file "$CONFIG_FILE"
}

# Emit one TSV line per installed unit:
#   host TAB database TAB when
# Units installed before this feature (no marker) emit "?" for `when`.
# Job name shape is "<PREFIX>.<host>.<database>"; the host/db split is the
# inverse of make_job_name.
schedule_installed_read() {
  if is_macos; then
    local plist
    for plist in "$LAUNCHD_DIR"/${SCHEDULE_PREFIX}.*.plist; do
      [[ -f "$plist" ]] || continue
      local job_name rest host database expr
      job_name=$(basename "$plist" .plist)
      rest="${job_name#${SCHEDULE_PREFIX}.}"
      host="${rest%%.*}"
      database="${rest#*.}"
      expr=$(/usr/libexec/PlistBuddy -c "Print :DbxScheduleExpression" "$plist" 2>/dev/null || echo "?")
      [[ -z "$expr" ]] && expr="?"
      printf '%s\t%s\t%s\n' "$host" "$database" "$expr"
    done
  else
    local timer
    for timer in "$SYSTEMD_DIR"/${SCHEDULE_PREFIX}.*.timer; do
      [[ -f "$timer" ]] || continue
      local job_name rest host database expr
      job_name=$(basename "$timer" .timer)
      rest="${job_name#${SCHEDULE_PREFIX}.}"
      host="${rest%%.*}"
      database="${rest#*.}"
      expr=$(grep -m1 '^# DbxScheduleExpression: ' "$timer" 2>/dev/null \
        | sed 's/^# DbxScheduleExpression: //' || true)
      [[ -z "$expr" ]] && expr="?"
      printf '%s\t%s\t%s\n' "$host" "$database" "$expr"
    done
  fi
}

# Compute the sync plan as TSV lines:
#   action TAB host TAB database TAB when
# Action values: install | update | orphan | nochange
# Used by `dbx schedule sync` and `--dry-run`. Pure function over the
# output of schedule_config_read and schedule_installed_read — no side
# effects, fully unit-testable.
# Args: $1 = config TSV (multiline), $2 = installed TSV (multiline)
schedule_sync_plan() {
  local cfg="$1" inst="$2"
  # Stream both inputs into awk via stdin so multi-line content works
  # under BSD awk (macOS) too — `-v` won't accept embedded newlines.
  # CFG/INST sentinel lines disambiguate which side each row came from.
  {
    printf '%s\n' "CFG_START"
    [[ -n "$cfg" ]] && printf '%s\n' "$cfg"
    printf '%s\n' "INST_START"
    [[ -n "$inst" ]] && printf '%s\n' "$inst"
  } | awk -F'\t' '
    /^CFG_START$/  { side = "cfg"; next }
    /^INST_START$/ { side = "inst"; next }
    {
      if ($0 == "") next
      key = $1 "\t" $2
      if (side == "cfg")  { cfg_when[key] = $3; cfg_keys[key] = 1 }
      else                { inst_when[key] = $3; inst_keys[key] = 1 }
    }
    END {
      for (k in cfg_keys) {
        if (!(k in inst_keys))                  print "install\t"  k "\t" cfg_when[k]
        else if (inst_when[k] != cfg_when[k])   print "update\t"   k "\t" cfg_when[k]
        else                                    print "nochange\t" k "\t" cfg_when[k]
      }
      for (k in inst_keys) {
        if (!(k in cfg_keys)) print "orphan\t" k "\t" inst_when[k]
      }
    }
  '
}

# Print the plan in human-friendly form. Returns:
#   0 if there is anything actionable (install/update/orphan)
#   1 if everything is nochange or the plan is empty
# Args: $1 = plan TSV (multiline, as emitted by schedule_sync_plan)
schedule_sync_print_plan() {
  local plan="$1" total=0 actionable=0
  local action host database when
  echo "${BOLD}Schedule sync plan${NC}"
  echo ""
  while IFS=$'\t' read -r action host database when; do
    [[ -z "$action" ]] && continue
    total=$((total + 1))
    case "$action" in
      install)  printf "  ${GREEN}+ install${NC}  %s/%s @ %s\n" "$host" "$database" "$when"; actionable=$((actionable + 1)) ;;
      update)   printf "  ${YELLOW}~ update${NC}   %s/%s → %s\n" "$host" "$database" "$when"; actionable=$((actionable + 1)) ;;
      orphan)   printf "  ${RED}! orphan${NC}   %s/%s @ %s (installed but not in config)\n" "$host" "$database" "$when"; actionable=$((actionable + 1)) ;;
      nochange) printf "  ${CYAN}= same${NC}     %s/%s @ %s\n" "$host" "$database" "$when" ;;
    esac
  done <<< "$plan"
  if [[ "$total" -eq 0 ]]; then
    echo "  (config.schedules is empty and no units are installed)"
    return 1
  fi
  echo ""
  [[ "$actionable" -gt 0 ]] && return 0 || return 1
}

# Execute a sync plan: install / update / orphan the platform units, reusing
# the same primitives as schedule_add / schedule_remove. `update` is an
# orphan-then-install so the reload is unconditional and platform-uniform.
# Args: $1 = plan TSV (action TAB host TAB database TAB when).
schedule_sync_apply() {
  local plan="$1"
  local action host database when job_name applied=0
  while IFS=$'\t' read -r action host database when; do
    [[ -z "$action" ]] && continue
    job_name=$(make_job_name "$host" "$database")
    case "$action" in
      install)
        if is_macos; then launchd_create "$host" "$database" "$when"; launchd_load "$job_name"
        else systemd_create "$host" "$database" "$when"; systemd_enable "$job_name"; fi
        log_info "installed $host/$database @ $when"
        applied=$((applied + 1))
        ;;
      update)
        if is_macos; then launchd_remove "$job_name"; launchd_create "$host" "$database" "$when"; launchd_load "$job_name"
        else systemd_remove "$job_name"; systemd_create "$host" "$database" "$when"; systemd_enable "$job_name"; fi
        log_info "updated $host/$database → $when"
        applied=$((applied + 1))
        ;;
      orphan)
        if is_macos; then launchd_remove "$job_name"; else systemd_remove "$job_name"; fi
        log_info "orphaned $host/$database"
        applied=$((applied + 1))
        ;;
      nochange) ;;
    esac
  done <<< "$plan"
  if [[ "$applied" -eq 0 ]]; then
    log_info "Nothing to apply — units already match config"
  else
    log_success "Applied $applied schedule change(s)"
  fi
  return 0
}

# ============================================================================
# Unified Interface
# ============================================================================

schedule_add() {
  local host="$1"
  local database="$2"
  local schedule="${3:-daily}"

  log_step "Adding scheduled backup: $database@$host ($schedule)"

  if is_macos; then
    launchd_create "$host" "$database" "$schedule"
    local job_name
    job_name=$(make_job_name "$host" "$database")
    launchd_load "$job_name"
  else
    systemd_create "$host" "$database" "$schedule"
    local job_name
    job_name=$(make_job_name "$host" "$database")
    systemd_enable "$job_name"
  fi

  # Mirror into config.schedules[] so config stays the canonical source of
  # truth (sync reconciles from it). Stores the friendly expression as `.when`.
  schedule_config_upsert "$host" "$database" "$schedule"

  log_info "Schedule: $schedule"
  log_info "Logs: $HOME/.local/share/dbx/logs/"
}

schedule_remove() {
  local host="$1"
  local database="$2"

  local job_name
  job_name=$(make_job_name "$host" "$database")

  log_step "Removing scheduled backup: $job_name"

  if is_macos; then
    launchd_remove "$job_name"
  else
    systemd_remove "$job_name"
  fi

  # Keep config canonical: drop the matching entry from config.schedules[].
  schedule_config_delete "$host" "$database"
}

schedule_list() {
  if is_macos; then
    launchd_list
  else
    systemd_list
  fi
}

schedule_run() {
  local host="$1"
  local database="$2"

  local job_name
  job_name=$(make_job_name "$host" "$database")

  log_step "Running scheduled backup manually: $job_name"

  if is_macos; then
    launchctl start "$job_name"
  else
    systemctl --user start "${job_name}.service"
  fi
}
