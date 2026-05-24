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

# ----------------------------------------------------------------------------
# #39: DbxScheduleExpression marker stamped at install time
# ----------------------------------------------------------------------------

@test "systemd_create stamps DbxScheduleExpression header into timer" {
  if is_macos; then skip "systemd path only on Linux"; fi
  systemd_create "prod" "myapp" "daily@5" >/dev/null
  local timer="$SYSTEMD_DIR/com.dbx.backup.prod.myapp.timer"
  grep -qE '^# DbxScheduleExpression: daily@5$' "$timer"
}

@test "launchd_create stamps DbxScheduleExpression key into plist" {
  if ! is_macos; then skip "launchd path only on macOS"; fi
  launchd_create "prod" "myapp" "weekly@1:3" >/dev/null
  local plist="$LAUNCHD_DIR/com.dbx.backup.prod.myapp.plist"
  grep -q '<key>DbxScheduleExpression</key>' "$plist"
  grep -q '<string>weekly@1:3</string>' "$plist"
}

# ----------------------------------------------------------------------------
# #39: schedule_sync_plan — pure data diff between config and installed
# ----------------------------------------------------------------------------

@test "schedule_sync_plan empty config + empty installed → empty plan" {
  result=$(schedule_sync_plan "" "")
  [ -z "$result" ]
}

@test "schedule_sync_plan config-only → install action" {
  cfg=$'prod\tmyapp\tdaily@5'
  result=$(schedule_sync_plan "$cfg" "")
  [ "$result" = $'install\tprod\tmyapp\tdaily@5' ]
}

@test "schedule_sync_plan installed-only → orphan action" {
  inst=$'prod\tmyapp\tdaily@5'
  result=$(schedule_sync_plan "" "$inst")
  [ "$result" = $'orphan\tprod\tmyapp\tdaily@5' ]
}

@test "schedule_sync_plan same on both sides → nochange action" {
  cfg=$'prod\tmyapp\tdaily@5'
  inst=$'prod\tmyapp\tdaily@5'
  result=$(schedule_sync_plan "$cfg" "$inst")
  [ "$result" = $'nochange\tprod\tmyapp\tdaily@5' ]
}

@test "schedule_sync_plan different when → update action" {
  cfg=$'prod\tmyapp\tdaily@7'
  inst=$'prod\tmyapp\tdaily@5'
  result=$(schedule_sync_plan "$cfg" "$inst")
  [ "$result" = $'update\tprod\tmyapp\tdaily@7' ]
}

@test "schedule_sync_plan mixed: install + update + orphan + nochange" {
  cfg=$'prod\tapp1\tdaily@5\nprod\tapp2\tdaily@7\nstaging\tx\tweekly@1:3'
  inst=$'prod\tapp1\tdaily@5\nprod\tapp2\tdaily@5\nlegacy\told\thourly'
  result=$(schedule_sync_plan "$cfg" "$inst")
  # Each action appears exactly once; order isn't fixed (awk for-in is
  # unordered) but the action label per key is deterministic.
  echo "$result" | grep -qE $'^nochange\tprod\tapp1\tdaily@5$'
  echo "$result" | grep -qE $'^update\tprod\tapp2\tdaily@7$'
  echo "$result" | grep -qE $'^install\tstaging\tx\tweekly@1:3$'
  echo "$result" | grep -qE $'^orphan\tlegacy\told\thourly$'
}

# ----------------------------------------------------------------------------
# #39: schedule_config_read reads .schedules[] from config.json
# ----------------------------------------------------------------------------

@test "schedule_config_read with empty .schedules → no output" {
  write_config '{"hosts":{},"schedules":[]}'
  result=$(schedule_config_read)
  [ -z "$result" ]
}

@test "schedule_config_read missing .schedules → no output" {
  write_config '{"hosts":{}}'
  result=$(schedule_config_read)
  [ -z "$result" ]
}

@test "schedule_config_read emits TSV one row per entry" {
  write_config '{"hosts":{},"schedules":[{"host":"prod","database":"app","when":"daily@5"},{"host":"staging","database":"x","when":"weekly@1:3"}]}'
  result=$(schedule_config_read)
  [ "$(echo "$result" | wc -l | tr -d '[:space:]')" = "2" ]
  echo "$result" | grep -qE $'^prod\tapp\tdaily@5$'
  echo "$result" | grep -qE $'^staging\tx\tweekly@1:3$'
}
