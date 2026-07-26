#!/usr/bin/env bats
#
# Tests for the argument/derivation layer of `dbx restore`: flag parsing,
# incompatible-flag guards, target-name derivation and db-type sniffing.
#
# Mirrors tests/unit/restore_verify.bats: each test runs cmd_restore in a
# subshell that sources dbx with DBX_NO_AUTO_MAIN=1 and stubs the engine
# restore calls, so the assertions are about what the CLI decided, not about
# what an engine did. The guards under test all fire before require_config /
# require_docker, so no docker is involved.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
  require_cmd jq

  CALLS_LOG="$BATS_TEST_TMPDIR/calls.log"
  : > "$CALLS_LOG"
}

write_config() { printf '%s\n' "$1" > "$CONFIG_FILE"; }

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
    pg_restore_backup()      { echo "pg_restore_backup $*" >> "$CALLS_LOG"; return 0; }
    mysql_restore_backup()   { echo "mysql_restore_backup $*" >> "$CALLS_LOG"; return 0; }
    run_post_restore_hooks() { return 0; }
    scrub_gate_active()      { return 1; }
    notify_restore_success() { :; }
    require_docker() { :; }
    docker() { return 1; }
    '"${EXTRA_STUBS:-}"'
    cmd_restore "$@"
  ' bash "$@"
}

# ----------------------------------------------------------------------------
# Flag parsing
# ----------------------------------------------------------------------------

@test "restore: unknown option is rejected" {
  run restore_subshell --bogus-flag
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown option: --bogus-flag"* ]]
  [ ! -s "$CALLS_LOG" ]
}

@test "restore: a second positional argument is rejected" {
  run restore_subshell one two
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unexpected extra argument: two"* ]]
  [ ! -s "$CALLS_LOG" ]
}

@test "restore: -n is an alias for --name" {
  write_config '{"hosts":{"myhost":{"type":"postgres","databases":{"mydb":{}}}}}'
  local f; f=$(make_backup "myhost/mydb/mydb_20260101_000000.sql" "PostgreSQL fake dump")

  run restore_subshell "$f" -n aliased --skip-verify
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  grep -qE "pg_restore_backup .* aliased" "$CALLS_LOG"
}

@test "restore: --storage=NAME equals-form is accepted by the parser" {
  write_config '{"hosts":{"myhost":{"type":"postgres","databases":{"mydb":{}}}}}'
  local f; f=$(make_backup "myhost/mydb/mydb_20260101_000000.sql" "PostgreSQL fake dump")

  run restore_subshell "$f" --name eqform --skip-verify --storage=somebackend
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Unknown option"* ]]
}

# ----------------------------------------------------------------------------
# Incompatible-flag guards
# ----------------------------------------------------------------------------

@test "restore: --hooks-only with --no-post-restore is rejected" {
  run restore_subshell host/db --hooks-only --no-post-restore --name x
  [ "$status" -ne 0 ]
  [[ "$output" == *"mutually exclusive"* ]]
  [ ! -s "$CALLS_LOG" ]
}

@test "restore: --hooks-only with --from-remote is rejected" {
  run restore_subshell --hooks-only --from-remote prod/db/latest --name x
  [ "$status" -ne 0 ]
  [[ "$output" == *"mutually exclusive"* ]]
  [[ "$output" == *"no backup is fetched"* ]]
  [ ! -s "$CALLS_LOG" ]
}

@test "restore: --hooks-only with --into is rejected" {
  run restore_subshell host/db --hooks-only --into some-container --name x
  [ "$status" -ne 0 ]
  [[ "$output" == *"incompatible with --transform / --into"* ]]
  [ ! -s "$CALLS_LOG" ]
}

@test "restore: --hooks-only with --transform is rejected" {
  run restore_subshell host/db --hooks-only --transform /bin/cat --name x
  [ "$status" -ne 0 ]
  [[ "$output" == *"incompatible with --transform / --into"* ]]
  [ ! -s "$CALLS_LOG" ]
}

@test "restore: --transform-inherit-env without --transform is rejected" {
  run restore_subshell host/db --transform-inherit-env --name x
  [ "$status" -ne 0 ]
  [[ "$output" == *"--transform-inherit-env requires --transform=PATH"* ]]
  [ ! -s "$CALLS_LOG" ]
}

@test "restore: --transform with a non-executable absolute path is rejected" {
  local script="$BATS_TEST_TMPDIR/not-exec.sh"
  printf '#!/bin/sh\n' > "$script"
  chmod 644 "$script"

  run restore_subshell host/db --transform "$script" --name x
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not an executable file"* ]]
  [ ! -s "$CALLS_LOG" ]
}

@test "restore: --transform with a bare name not on PATH is rejected" {
  run restore_subshell host/db --transform dbx-no-such-transform-xyz --name x
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not on PATH"* ]]
  [ ! -s "$CALLS_LOG" ]
}

@test "restore: --transform=PATH equals-form is validated too" {
  run restore_subshell host/db --transform=/nonexistent/dbx-transform --name x
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not an executable file"* ]]
  [ ! -s "$CALLS_LOG" ]
}

# ----------------------------------------------------------------------------
# Target-name derivation
# ----------------------------------------------------------------------------

@test "restore: target name defaults to <database>_v1_<date> when --name is omitted" {
  write_config '{"hosts":{"myhost":{"type":"postgres","databases":{"mydb":{}}}}}'
  local f; f=$(make_backup "myhost/mydb/mydb_20260101_000000.sql" "PostgreSQL fake dump")
  local today; today=$(date +"%Y%m%d")

  run restore_subshell "$f" --skip-verify
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  grep -qE "pg_restore_backup .* mydb_v1_${today} " "$CALLS_LOG"
}

@test "restore: derived target name strips the timestamp suffix of an ad-hoc file" {
  write_config '{}'
  local f="$BATS_TEST_TMPDIR/orders_20260101_000000.sql"
  printf 'PostgreSQL fake dump' > "$f"
  local today; today=$(date +"%Y%m%d")

  run restore_subshell "$f" --skip-verify
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  grep -qE "pg_restore_backup .* orders_v1_${today} " "$CALLS_LOG"
}

# ----------------------------------------------------------------------------
# Database-type resolution
# ----------------------------------------------------------------------------

@test "restore: db type comes from the host config when set" {
  write_config '{"hosts":{"myhost":{"type":"mysql","databases":{"mydb":{}}}}}'
  # Content sniffs as postgres; the host config must win over the sniff.
  local f; f=$(make_backup "myhost/mydb/mydb_20260101_000000.sql" "PostgreSQL fake dump")

  run restore_subshell "$f" --name typed --skip-verify
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  grep -q "mysql_restore_backup" "$CALLS_LOG"
}

@test "restore: db type comes from meta.json when present" {
  write_config '{"hosts":{"myhost":{"type":"mysql","databases":{"mydb":{}}}}}'
  local f; f=$(make_backup "myhost/mydb/mydb_20260101_000000.sql" "PostgreSQL fake dump")
  printf '{"type":"postgres"}\n' > "$f.meta.json"

  run restore_subshell "$f" --name metatyped --skip-verify
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  grep -q "pg_restore_backup" "$CALLS_LOG"
}

@test "restore: unknown host falls back to sniffing a PGDMP header as postgres" {
  write_config '{}'
  local f; f=$(make_backup "myhost/mydb/mydb_20260101_000000.sql" "PGDMP binary-ish header")

  run restore_subshell "$f" --name sniffpg --skip-verify
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  grep -q "pg_restore_backup" "$CALLS_LOG"
}

@test "restore: unknown host falls back to sniffing plain SQL as mysql" {
  write_config '{}'
  local f; f=$(make_backup "myhost/mydb/mydb_20260101_000000.sql" "-- MySQL dump 10.13")

  run restore_subshell "$f" --name sniffmy --skip-verify
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  grep -q "mysql_restore_backup" "$CALLS_LOG"
}
