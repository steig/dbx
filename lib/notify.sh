#!/usr/bin/env bash
#
# lib/notify.sh - Notification backends for dbx
#
# Requires: core.sh to be sourced first
#

# ============================================================================
# Configuration
# ============================================================================

# Check if notifications are enabled
is_notifications_enabled() {
  local enabled
  enabled=$(get_config_value ".notifications.enabled" 2>/dev/null || echo "")
  [[ "$enabled" == "true" ]]
}

# Check if we should notify on specific event
should_notify_on() {
  local event="$1"  # success, failure, all
  local notify_on
  notify_on=$(get_config_value ".notifications.on" 2>/dev/null || echo "failure")

  case "$notify_on" in
    all)
      return 0
      ;;
    failure)
      [[ "$event" == "failure" ]]
      ;;
    success)
      [[ "$event" == "success" ]]
      ;;
    *)
      [[ "$event" == "failure" ]]
      ;;
  esac
}

# ============================================================================
# Slack Notifications
# ============================================================================

get_slack_webhook_url() {
  # Try webhook_url_cmd first (secure)
  local url_cmd
  url_cmd=$(get_config_value ".notifications.slack.webhook_url_cmd" 2>/dev/null || echo "")
  if [[ -n "$url_cmd" ]]; then
    eval "$url_cmd"
    return
  fi

  # Try vault
  local vault_url
  vault_url=$(keychain_get "slack-webhook" 2>/dev/null || true)
  if [[ -n "$vault_url" ]]; then
    echo "$vault_url"
    return
  fi

  # Fallback to plain config (not recommended)
  get_config_value ".notifications.slack.webhook_url" 2>/dev/null || echo ""
}

notify_slack() {
  local title="$1"
  local message="$2"
  local status="${3:-info}"  # info, success, failure

  local webhook_url
  webhook_url=$(get_slack_webhook_url)

  if [[ -z "$webhook_url" ]]; then
    log_warn "Slack webhook URL not configured"
    return 1
  fi

  # Color based on status
  local color
  case "$status" in
    success) color="good" ;;
    failure) color="danger" ;;
    *)       color="#439FE0" ;;
  esac

  # Build payload
  local payload
  payload=$(jq -n \
    --arg title "$title" \
    --arg message "$message" \
    --arg color "$color" \
    --arg host "${HOSTNAME:-$(hostname)}" \
    --arg ts "$(date +%s)" \
    '{
      attachments: [{
        color: $color,
        title: $title,
        text: $message,
        footer: ("dbx on " + $host),
        ts: ($ts | tonumber)
      }]
    }')

  # Send
  if curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$webhook_url" >/dev/null; then
    return 0
  else
    log_warn "Failed to send Slack notification"
    return 1
  fi
}

# ============================================================================
# Desktop Notifications
# ============================================================================

notify_desktop() {
  local title="$1"
  local message="$2"
  local status="${3:-info}"

  if is_macos; then
    # macOS - use osascript or terminal-notifier
    if command -v terminal-notifier &>/dev/null; then
      local sound=""
      [[ "$status" == "failure" ]] && sound="-sound Basso"
      terminal-notifier -title "$title" -message "$message" $sound 2>/dev/null
    else
      osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null
    fi
  elif is_linux; then
    # Linux - use notify-send
    if command -v notify-send &>/dev/null; then
      local urgency="normal"
      [[ "$status" == "failure" ]] && urgency="critical"
      notify-send -u "$urgency" "$title" "$message" 2>/dev/null
    fi
  fi
}

# ============================================================================
# Email Notifications (via SMTP)
# ============================================================================

get_smtp_config() {
  local key="$1"
  get_config_value ".notifications.email.$key" 2>/dev/null || echo ""
}

notify_email() {
  local subject="$1"
  local body="$2"
  local status="${3:-info}"

  local smtp_host smtp_port smtp_user smtp_pass from_addr to_addr

  smtp_host=$(get_smtp_config "smtp_host")
  smtp_port=$(get_smtp_config "smtp_port")
  smtp_user=$(get_smtp_config "smtp_user")
  from_addr=$(get_smtp_config "from")
  to_addr=$(get_smtp_config "to")

  # Get password from vault or cmd
  local pass_cmd
  pass_cmd=$(get_smtp_config "smtp_password_cmd")
  if [[ -n "$pass_cmd" ]]; then
    smtp_pass=$(eval "$pass_cmd")
  else
    smtp_pass=$(keychain_get "smtp-password" 2>/dev/null || true)
  fi

  if [[ -z "$smtp_host" || -z "$to_addr" ]]; then
    log_warn "Email notification not configured (missing smtp_host or to)"
    return 1
  fi

  # Default port
  smtp_port="${smtp_port:-587}"

  # Build email
  local email_content
  email_content=$(cat << EOF
Subject: $subject
From: ${from_addr:-dbx@localhost}
To: $to_addr
Content-Type: text/plain; charset=utf-8

$body

--
Sent by dbx on ${HOSTNAME:-$(hostname)} at $(date)
EOF
)

  # Send via curl (supports TLS)
  if [[ -n "$smtp_user" && -n "$smtp_pass" ]]; then
    echo "$email_content" | curl -s --ssl-reqd \
      --url "smtp://${smtp_host}:${smtp_port}" \
      --user "${smtp_user}:${smtp_pass}" \
      --mail-from "${from_addr:-dbx@localhost}" \
      --mail-rcpt "$to_addr" \
      -T - 2>/dev/null
  else
    # Try without auth (local SMTP)
    echo "$email_content" | curl -s \
      --url "smtp://${smtp_host}:${smtp_port}" \
      --mail-from "${from_addr:-dbx@localhost}" \
      --mail-rcpt "$to_addr" \
      -T - 2>/dev/null
  fi
}

# ============================================================================
# Command Notifications
# ============================================================================

notify_command() {
  local title="$1"
  local message="$2"
  local status="${3:-info}"

  local cmd_template
  case "$status" in
    success)
      cmd_template=$(get_config_value ".notifications.command.on_success" 2>/dev/null || echo "")
      ;;
    failure)
      cmd_template=$(get_config_value ".notifications.command.on_failure" 2>/dev/null || echo "")
      ;;
    *)
      cmd_template=$(get_config_value ".notifications.command.default" 2>/dev/null || echo "")
      ;;
  esac

  if [[ -z "$cmd_template" ]]; then
    return 0
  fi

  # Replace placeholders
  local cmd
  cmd="${cmd_template//\{title\}/$title}"
  cmd="${cmd//\{message\}/$message}"
  cmd="${cmd//\{status\}/$status}"

  # Execute
  eval "$cmd" 2>/dev/null || true
}

# ============================================================================
# Unified Notification Interface
# ============================================================================

# Send notification through all configured backends
notify() {
  local title="$1"
  local message="$2"
  local status="${3:-info}"  # info, success, failure

  # Check if notifications are enabled
  if ! is_notifications_enabled; then
    return 0
  fi

  # Check if we should notify for this event
  if ! should_notify_on "$status"; then
    return 0
  fi

  # Get enabled backends
  local backends
  backends=$(get_config_value ".notifications.backends" 2>/dev/null || echo "")

  # If no backends specified, try desktop as default
  if [[ -z "$backends" ]]; then
    notify_desktop "$title" "$message" "$status"
    return 0
  fi

  # Send to each backend
  echo "$backends" | jq -r '.[]?' 2>/dev/null | while read -r backend; do
    case "$backend" in
      slack)
        notify_slack "$title" "$message" "$status" &
        ;;
      desktop)
        notify_desktop "$title" "$message" "$status"
        ;;
      email)
        notify_email "$title" "$message" "$status" &
        ;;
      command)
        notify_command "$title" "$message" "$status"
        ;;
    esac
  done

  # Wait for background jobs
  wait 2>/dev/null || true
}

# ============================================================================
# Convenience Functions
# ============================================================================

notify_backup_success() {
  local host="$1"
  local database="$2"
  local file="$3"
  local size="$4"

  local human_size
  human_size=$(human_size "$size")

  notify \
    "Backup Complete: $database" \
    "Database $database@$host backed up successfully ($human_size)" \
    "success"
}

notify_backup_failure() {
  local host="$1"
  local database="$2"
  local error="${3:-Unknown error}"

  notify \
    "Backup Failed: $database" \
    "Failed to backup $database@$host: $error" \
    "failure"
}

notify_restore_success() {
  local file="$1"
  local target_db="$2"

  notify \
    "Restore Complete: $target_db" \
    "Database $target_db restored successfully from $file" \
    "success"
}

notify_restore_failure() {
  local file="$1"
  local target_db="$2"
  local error="${3:-Unknown error}"

  notify \
    "Restore Failed: $target_db" \
    "Failed to restore $target_db from $file: $error" \
    "failure"
}
