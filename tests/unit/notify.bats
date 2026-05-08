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
