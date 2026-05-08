#!/usr/bin/env bats
#
# Tests for lib/schedule.sh — schedule parsing and unit-file generation.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
  # Redirect schedule output paths to the test tmpdir so we don't write
  # plists/timers into the user's real LaunchAgents / systemd dirs.
  LAUNCHD_DIR="$BATS_TEST_TMPDIR/LaunchAgents"
  SYSTEMD_DIR="$BATS_TEST_TMPDIR/systemd-user"
  mkdir -p "$LAUNCHD_DIR" "$SYSTEMD_DIR"
}

# ----------------------------------------------------------------------------
# parse_schedule — preset string → cron expression
# ----------------------------------------------------------------------------

@test "parse_schedule hourly → 0 * * * *" {
  result=$(parse_schedule "hourly")
  [ "$result" = "0 * * * *" ]
}

@test "parse_schedule daily defaults to 2am" {
  result=$(parse_schedule "daily")
  [ "$result" = "0 2 * * *" ]
}

@test "parse_schedule daily@N respects hour" {
  result=$(parse_schedule "daily@5")
  [ "$result" = "0 5 * * *" ]
}

@test "parse_schedule weekly defaults to Sunday 2am" {
  result=$(parse_schedule "weekly")
  [ "$result" = "0 2 * * 0" ]
}

@test "parse_schedule weekly@D:H respects day and hour" {
  result=$(parse_schedule "weekly@3:5")
  [ "$result" = "0 5 * * 3" ]
}

@test "parse_schedule passes through raw cron syntax" {
  result=$(parse_schedule "*/15 4 * * 1-5")
  [ "$result" = "*/15 4 * * 1-5" ]
}

# ----------------------------------------------------------------------------
# make_job_name — sanitization
# ----------------------------------------------------------------------------

@test "make_job_name composes prefix.host.database" {
  result=$(make_job_name "prod" "myapp")
  [ "$result" = "com.dbx.backup.prod.myapp" ]
}

@test "make_job_name lowercases uppercase input" {
  result=$(make_job_name "PROD" "MyApp")
  [ "$result" = "com.dbx.backup.prod.myapp" ]
}

@test "make_job_name replaces unsafe chars with dash" {
  result=$(make_job_name "prod-east" "my_app")
  [ "$result" = "com.dbx.backup.prod-east.my-app" ]
}

# ----------------------------------------------------------------------------
# systemd_create — weekday translation (regression for #4)
# ----------------------------------------------------------------------------

@test "systemd weekly@0:3 produces OnCalendar=Sun *-*-* 3:00:00" {
  # Needs is_macos to return false so SYSTEMD_DIR is set
  if is_macos; then skip "systemd path only on Linux"; fi
  systemd_create "h" "d" "weekly@0:3" >/dev/null
  local timer_path
  timer_path="$SYSTEMD_DIR/com.dbx.backup.h.d.timer"
  [ -f "$timer_path" ]
  grep -qE '^OnCalendar=Sun \*-\*-\* 3:00:00$' "$timer_path"
}

@test "systemd weekly@6:5 produces OnCalendar=Sat *-*-* 5:00:00" {
  if is_macos; then skip "systemd path only on Linux"; fi
  systemd_create "h" "d" "weekly@6:5" >/dev/null
  grep -qE '^OnCalendar=Sat \*-\*-\* 5:00:00$' "$SYSTEMD_DIR/com.dbx.backup.h.d.timer"
}

@test "systemd weekly@Wed:4 (alphabetic) passes through" {
  if is_macos; then skip "systemd path only on Linux"; fi
  systemd_create "h" "d" "weekly@Wed:4" >/dev/null
  grep -qE '^OnCalendar=Wed \*-\*-\* 4:00:00$' "$SYSTEMD_DIR/com.dbx.backup.h.d.timer"
}

@test "systemd daily@N produces *-*-* N:00:00" {
  if is_macos; then skip "systemd path only on Linux"; fi
  systemd_create "h" "d" "daily@7" >/dev/null
  grep -qE '^OnCalendar=\*-\*-\* 7:00:00$' "$SYSTEMD_DIR/com.dbx.backup.h.d.timer"
}
