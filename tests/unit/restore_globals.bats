#!/usr/bin/env bats
#
# CLI-level tests for `dbx restore --with-globals` (#130). Mirrors
# restore_verify.bats: cmd_restore runs in a subshell with the heavy/external
# functions stubbed, so we can assert how the flag flows into the engine
# restore call and that incompatible flag combinations are rejected.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
  require_cmd jq
  CALLS_LOG="$BATS_TEST_TMPDIR/calls.log"
  : > "$CALLS_LOG"
}

write_config() { printf '%s\n' "$1" > "$CONFIG_FILE"; }

# Postgres host config so cmd_restore dispatches to the postgres branch.
write_pg_config() {
  write_config '{"hosts":{"myhost":{"type":"postgres","databases":{"mydb":{}}}}}'
}

make_backup() {
  local rel="$1" content="$2"
  local path="$DBX_DATA_DIR/$rel"
  mkdir -p "$(dirname "$path")"
  printf '%s' "$content" > "$path"
  echo "$path"
}

restore_subshell() {
  bash -c '
    set -uo pipefail
    export DBX_DATA_DIR="'"$DBX_DATA_DIR"'"
    export DBX_CONFIG_DIR="'"$DBX_CONFIG_DIR"'"
    export DBX_AUDIT_DIR="'"$DBX_AUDIT_DIR"'"
    export CALLS_LOG="'"$CALLS_LOG"'"
    export DBX_NO_AUTO_MAIN=1
    # shellcheck source=/dev/null
    source "'"$DBX_BIN"'"
    pg_restore_backup()    { echo "pg_restore_backup $*" >> "$CALLS_LOG"; return 0; }
    mysql_restore_backup() { echo "mysql_restore_backup $*" >> "$CALLS_LOG"; return 0; }
    run_post_restore_hooks() { return 0; }
    scrub_gate_active()      { return 1; }
    notify_restore_success() { :; }
    require_docker() { :; }
    docker() { return 1; }
    '"${EXTRA_STUBS:-}"'
    cmd_restore "$@"
  ' bash "$@"
}

@test "restore --with-globals passes through to pg_restore_backup" {
  write_pg_config
  local f; f=$(make_backup "myhost/mydb/mydb_20260101_000000.sql.zst" "fake dump")

  run restore_subshell "$f" --name gtest --skip-verify --with-globals
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  grep -qE "pg_restore_backup .* gtest true" "$CALLS_LOG"
}

@test "restore without --with-globals passes false to pg_restore_backup" {
  write_pg_config
  local f; f=$(make_backup "myhost/mydb/mydb_20260101_000000.sql.zst" "fake dump")

  run restore_subshell "$f" --name gtest --skip-verify
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  grep -qE "pg_restore_backup .* gtest false" "$CALLS_LOG"
}

@test "restore --with-globals is rejected together with --into" {
  write_pg_config
  local f; f=$(make_backup "myhost/mydb/mydb_20260101_000000.sql.zst" "fake dump")

  run restore_subshell "$f" --name gtest --with-globals --into some-container
  echo "OUT: $output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"incompatible with --transform / --into"* ]]
  [ ! -s "$CALLS_LOG" ]
}

@test "restore --globals is accepted as an alias for --with-globals" {
  write_pg_config
  local f; f=$(make_backup "myhost/mydb/mydb_20260101_000000.sql.zst" "fake dump")

  run restore_subshell "$f" --name gtest --skip-verify --globals
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  grep -qE "pg_restore_backup .* gtest true" "$CALLS_LOG"
}
