#!/usr/bin/env bats
#
# Tests for lib/notify.sh — event matching and config gating.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
}

# ----------------------------------------------------------------------------
# is_notifications_enabled
# ----------------------------------------------------------------------------

@test "notifications disabled by default" {
  write_config '{}'
  ! is_notifications_enabled
}

@test "notifications enabled when set" {
  write_config '{"notifications":{"enabled":true}}'
  is_notifications_enabled
}

# ----------------------------------------------------------------------------
# should_notify_on — matches event to configured filter
# ----------------------------------------------------------------------------

@test "should_notify_on failure matches on=failure" {
  write_config '{"notifications":{"on":"failure"}}'
  should_notify_on failure
}

@test "should_notify_on success skips when on=failure" {
  write_config '{"notifications":{"on":"failure"}}'
  ! should_notify_on success
}

@test "should_notify_on success matches on=success" {
  write_config '{"notifications":{"on":"success"}}'
  should_notify_on success
}

@test "should_notify_on failure skips when on=success" {
  write_config '{"notifications":{"on":"success"}}'
  ! should_notify_on failure
}

@test "should_notify_on=all matches success" {
  write_config '{"notifications":{"on":"all"}}'
  should_notify_on success
}

@test "should_notify_on=all matches failure" {
  write_config '{"notifications":{"on":"all"}}'
  should_notify_on failure
}

@test "should_notify_on defaults to failure-only when unset" {
  write_config '{}'
  should_notify_on failure
  ! should_notify_on success
}

# ----------------------------------------------------------------------------
# notify_restore_failure — convenience wrapper around notify()
# ----------------------------------------------------------------------------

@test "notify_restore_failure returns 0 silently when notifications disabled" {
  write_config '{}'
  run notify_restore_failure "/var/backups/db.sql.gz" "mydb" "boom"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "notify_restore_failure returns 0 silently when no backends configured and on=success" {
  # enabled, but filter excludes failure events
  write_config '{"notifications":{"enabled":true,"on":"success"}}'
  run notify_restore_failure "/var/backups/db.sql.gz" "mydb" "boom"
  [ "$status" -eq 0 ]
}

@test "notify_restore_failure command backend receives title, message, status" {
  local sink="$BATS_TEST_TMPDIR/notify.out"
  write_config "$(jq -n --arg sink "$sink" '{
    notifications: {
      enabled: true,
      on: "failure",
      backends: ["command"],
      command: {
        on_failure: ("printf \"%s|%s|%s\\n\" \"{title}\" \"{message}\" \"{status}\" >> " + $sink)
      }
    }
  }')"

  run notify_restore_failure "/var/backups/2026-05-23/payments.sql.gz" "payments" "permission denied"
  [ "$status" -eq 0 ]
  [ -f "$sink" ]

  local line
  line=$(cat "$sink")
  [[ "$line" == *"dbx restore failed"* ]]
  [[ "$line" == *"payments"* ]]
  [[ "$line" == *"payments.sql.gz"* ]]
  # full path should NOT leak — only basename
  [[ "$line" != *"/var/backups/2026-05-23/"* ]]
  [[ "$line" == *"permission denied"* ]]
  [[ "$line" == *"|failure"* ]]
}

@test "notify_restore_failure uses 'Unknown error' default when error_msg omitted" {
  local sink="$BATS_TEST_TMPDIR/notify.out"
  write_config "$(jq -n --arg sink "$sink" '{
    notifications: {
      enabled: true,
      on: "failure",
      backends: ["command"],
      command: {
        on_failure: ("printf \"%s\\n\" \"{message}\" >> " + $sink)
      }
    }
  }')"

  run notify_restore_failure "/tmp/db.sql" "mydb"
  [ "$status" -eq 0 ]
  [[ "$(cat "$sink")" == *"Unknown error"* ]]
}
