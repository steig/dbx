#!/usr/bin/env bats
#
# Tests for format_duration / audit_last_duration / audit_last_size in
# lib/core.sh.  These power the per-run "Backup complete in Xs" summary
# and the "Last backup of …" baseline that prints before backup/restore.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
}

# ----------------------------------------------------------------------------
# format_duration
# ----------------------------------------------------------------------------

@test "format_duration 0 → 0s" {
  [ "$(format_duration 0)" = "0s" ]
}

@test "format_duration 5 → 5s" {
  [ "$(format_duration 5)" = "5s" ]
}

@test "format_duration 59 → 59s (boundary)" {
  [ "$(format_duration 59)" = "59s" ]
}

@test "format_duration 60 → 1m 0s (boundary)" {
  [ "$(format_duration 60)" = "1m 0s" ]
}

@test "format_duration 65 → 1m 5s" {
  [ "$(format_duration 65)" = "1m 5s" ]
}

@test "format_duration 102 → 1m 42s (example from task brief)" {
  [ "$(format_duration 102)" = "1m 42s" ]
}

@test "format_duration 3599 → 59m 59s (just under 1h)" {
  [ "$(format_duration 3599)" = "59m 59s" ]
}

@test "format_duration 3600 → 1h 0m 0s (1h boundary)" {
  [ "$(format_duration 3600)" = "1h 0m 0s" ]
}

@test "format_duration 3725 → 1h 2m 5s" {
  [ "$(format_duration 3725)" = "1h 2m 5s" ]
}

@test "format_duration accepts non-numeric input gracefully (returns 0s)" {
  [ "$(format_duration "")" = "0s" ]
  [ "$(format_duration "abc")" = "0s" ]
  [ "$(format_duration "-5")" = "0s" ]
}

# ----------------------------------------------------------------------------
# audit_last_duration / audit_last_size — fixture-based
# ----------------------------------------------------------------------------

# Helper: write a JSON-lines fixture to the test audit log.
write_audit_fixture() {
  AUDIT_LOG_DIR="$DBX_AUDIT_DIR"
  AUDIT_LOG_FILE="$AUDIT_LOG_DIR/audit.log"
  mkdir -p "$AUDIT_LOG_DIR"
  cat > "$AUDIT_LOG_FILE"
  # Re-export so the helpers under test see the same vars.
  export AUDIT_LOG_DIR AUDIT_LOG_FILE
}

@test "audit_last_duration: no audit log → empty output" {
  AUDIT_LOG_FILE="$DBX_AUDIT_DIR/audit.log"
  rm -f "$AUDIT_LOG_FILE"
  result=$(audit_last_duration backup prod myapp)
  [ -z "$result" ]
}

@test "audit_last_duration: matches most recent successful backup row" {
  write_audit_fixture <<'EOF'
{"timestamp":"2026-05-01T10:00:00Z","action":"backup","outcome":"success","db_host":"prod","database":"myapp","duration_sec":"60","size":"100"}
{"timestamp":"2026-05-02T10:00:00Z","action":"backup","outcome":"success","db_host":"prod","database":"myapp","duration_sec":"75","size":"110"}
{"timestamp":"2026-05-03T10:00:00Z","action":"backup","outcome":"success","db_host":"prod","database":"myapp","duration_sec":"101","size":"228000000"}
EOF
  result=$(audit_last_duration backup prod myapp)
  [ "$result" = "101" ]
}

@test "audit_last_duration: matches most recent successful restore row (no host/db filter)" {
  write_audit_fixture <<'EOF'
{"timestamp":"2026-05-01T10:00:00Z","action":"restore","outcome":"success","duration_sec":"30"}
{"timestamp":"2026-05-02T10:00:00Z","action":"restore","outcome":"success","duration_sec":"45"}
EOF
  result=$(audit_last_duration restore "" "")
  [ "$result" = "45" ]
}

@test "audit_last_duration: ignores failure entries" {
  write_audit_fixture <<'EOF'
{"timestamp":"2026-05-01T10:00:00Z","action":"backup","outcome":"success","db_host":"prod","database":"myapp","duration_sec":"60"}
{"timestamp":"2026-05-02T10:00:00Z","action":"backup","outcome":"failure","db_host":"prod","database":"myapp","duration_sec":"9999"}
{"timestamp":"2026-05-03T10:00:00Z","action":"backup","outcome":"success","db_host":"prod","database":"myapp","duration_sec":"75"}
EOF
  result=$(audit_last_duration backup prod myapp)
  [ "$result" = "75" ]
}

@test "audit_last_duration: ignores entries for a different host" {
  write_audit_fixture <<'EOF'
{"timestamp":"2026-05-01T10:00:00Z","action":"backup","outcome":"success","db_host":"prod","database":"myapp","duration_sec":"60"}
{"timestamp":"2026-05-02T10:00:00Z","action":"backup","outcome":"success","db_host":"staging","database":"myapp","duration_sec":"99"}
EOF
  result=$(audit_last_duration backup prod myapp)
  [ "$result" = "60" ]
}

@test "audit_last_duration: ignores entries for a different database" {
  write_audit_fixture <<'EOF'
{"timestamp":"2026-05-01T10:00:00Z","action":"backup","outcome":"success","db_host":"prod","database":"myapp","duration_sec":"60"}
{"timestamp":"2026-05-02T10:00:00Z","action":"backup","outcome":"success","db_host":"prod","database":"other","duration_sec":"99"}
EOF
  result=$(audit_last_duration backup prod myapp)
  [ "$result" = "60" ]
}

@test "audit_last_duration: no matching rows → empty output" {
  write_audit_fixture <<'EOF'
{"timestamp":"2026-05-01T10:00:00Z","action":"backup","outcome":"success","db_host":"staging","database":"other","duration_sec":"60"}
EOF
  result=$(audit_last_duration backup prod myapp)
  [ -z "$result" ]
}

@test "audit_last_duration: empty action → empty output" {
  write_audit_fixture <<'EOF'
{"timestamp":"2026-05-01T10:00:00Z","action":"backup","outcome":"success","db_host":"prod","database":"myapp","duration_sec":"60"}
EOF
  result=$(audit_last_duration "" prod myapp)
  [ -z "$result" ]
}

@test "audit_last_size: returns size field of most recent successful row" {
  write_audit_fixture <<'EOF'
{"timestamp":"2026-05-01T10:00:00Z","action":"backup","outcome":"success","db_host":"prod","database":"myapp","duration_sec":"60","size":"100"}
{"timestamp":"2026-05-02T10:00:00Z","action":"backup","outcome":"success","db_host":"prod","database":"myapp","duration_sec":"75","size":"228000000"}
EOF
  result=$(audit_last_size backup prod myapp)
  [ "$result" = "228000000" ]
}

# ----------------------------------------------------------------------------
# log_step_elapsed — sanity check
# ----------------------------------------------------------------------------

@test "log_step_elapsed prints +<duration> prefix and the message" {
  # Force a known start time 65 seconds before "now". The format is
  # checked loosely (we can't pin `date +%s` in this process) but the
  # leading "+" and trailing message must always be there.
  local start
  start=$(($(date +%s) - 65))
  run log_step_elapsed "$start" "pg_dump started"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^\[INFO\].* \+'
  echo "$output" | grep -q "pg_dump started"
}

@test "log_step_elapsed with bogus start falls back to +0s" {
  run log_step_elapsed "not-a-number" "x"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "+0s"
}
