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

# Generate a safe job name from host and database
make_job_name() {
  local host="$1"
  local database="$2"
  echo "${SCHEDULE_PREFIX}.${host}.${database}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9.' '-'
}

# Parse cron-like schedule to components
# Supports: "daily", "hourly", "weekly", or cron syntax "0 2 * * *"
parse_schedule() {
  local schedule="$1"

  case "$schedule" in
    hourly)
      echo "0 * * * *"
      ;;
    daily|daily@*)
      local hour="${schedule#daily@}"
      hour="${hour:-2}"  # Default 2 AM
      echo "0 $hour * * *"
      ;;
    weekly|weekly@*)
      local day_hour="${schedule#weekly@}"
      local day="${day_hour%:*}"
      local hour="${day_hour#*:}"
      day="${day:-0}"    # Default Sunday
      hour="${hour:-2}"  # Default 2 AM
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
        <string>backup</string>
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
      local hour="${schedule#daily@}"
      hour="${hour:-2}"
      oncalendar="*-*-* ${hour}:00:00"
      ;;
    weekly|weekly@*)
      local day_hour="${schedule#weekly@}"
      local day="${day_hour%:*}"
      local hour="${day_hour#*:}"
      day="${day:-Sun}"
      hour="${hour:-2}"
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
ExecStart=$dbx_path backup $host $database
StandardOutput=append:$HOME/.local/share/dbx/logs/${job_name}.log
StandardError=append:$HOME/.local/share/dbx/logs/${job_name}.error.log

[Install]
WantedBy=default.target
EOF

  # Create timer unit
  cat > "$timer_path" << EOF
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
