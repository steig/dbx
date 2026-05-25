#!/usr/bin/env bats
#
# Regression test for the audit log format. Each `audit_log` call must
# produce exactly ONE line in the log file — the file is JSONL and is
# read line-by-line by the wizard's Runs view + the bash-side
# last-successful-run baseline (lib/core.sh:809). When jq runs without
# `-c`, it pretty-prints across ~5 lines and breaks every reader.

load '../helpers/common'

setup() {
  setup_dbx_env
  # audit_log writes to $AUDIT_LOG_FILE under $AUDIT_LOG_DIR. Use the
  # scratch tree so we don't touch the developer's real ~/.local/share/dbx.
  export AUDIT_LOG_DIR="$BATS_TEST_TMPDIR/audit"
  export AUDIT_LOG_FILE="$AUDIT_LOG_DIR/audit.log"
  mkdir -p "$AUDIT_LOG_DIR"
}

@test "audit_log writes exactly one line per entry" {
  source "$BATS_TEST_DIRNAME/../../lib/core.sh"
  audit_log "backup" "success" "db_host" "prod" "database" "myapp" "size" "12345"
  local lines
  lines=$(wc -l < "$AUDIT_LOG_FILE")
  [ "$lines" -eq 1 ]
}

@test "audit_log emits parseable JSON on that single line" {
  source "$BATS_TEST_DIRNAME/../../lib/core.sh"
  audit_log "restore" "success" "db_host" "prod" "database" "myapp"
  run jq -e '.action == "restore" and .outcome == "success" and .db_host == "prod"' "$AUDIT_LOG_FILE"
  [ "$status" -eq 0 ]
}

@test "audit_log keeps one-line-per-entry across multiple calls" {
  source "$BATS_TEST_DIRNAME/../../lib/core.sh"
  audit_log "backup"  "success" "db_host" "prod" "database" "a"
  audit_log "backup"  "failure" "db_host" "prod" "database" "b" "error" "timeout"
  audit_log "restore" "success" "db_host" "stage" "database" "c"
  local lines
  lines=$(wc -l < "$AUDIT_LOG_FILE")
  [ "$lines" -eq 3 ]
  # Each line parses cleanly as JSON on its own.
  while IFS= read -r line; do
    echo "$line" | jq -e '.action' >/dev/null
  done < "$AUDIT_LOG_FILE"
}
