#!/usr/bin/env bats
#
# Tests for the pre-import SHA-256 checksum gate in `dbx restore` (#116).
#
# Mirrors tests/unit/restore_remote.bats: each cmd_restore test runs in a
# subshell that sources dbx with DBX_NO_AUTO_MAIN=1, stubs the heavy/external
# functions, then calls cmd_restore directly. The real verify_backup_checksum
# runs (not stubbed), so these exercise the actual gate.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
  require_cmd jq

  CALLS_LOG="$BATS_TEST_TMPDIR/calls.log"
  : > "$CALLS_LOG"
}

# Portable sha256 of a file's contents.
sha256_of() {
  _sha256_stdin < "$1"
}

# Create a local backup file under DATA_DIR with optional meta.json.
# Args: $1=relpath (under data), $2=content, $3=checksum-for-meta (or "" to skip meta)
make_backup() {
  local rel="$1" content="$2" checksum="${3:-}"
  local path="$DBX_DATA_DIR/$rel"
  mkdir -p "$(dirname "$path")"
  printf '%s' "$content" > "$path"
  if [[ -n "$checksum" ]]; then
    printf '{"checksums":{"sha256":"%s"}}\n' "$checksum" > "$path.meta.json"
  fi
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
    notify_restore_success() { :; }
    require_docker() { :; }
    require_jq()     { :; }
    require_config() { :; }
    docker() { return 1; }
    '"${EXTRA_STUBS:-}"'
    cmd_restore "$@"
  ' bash "$@"
}

# ----------------------------------------------------------------------------
# verify_backup_checksum — direct unit tests on the helper.
# ----------------------------------------------------------------------------

@test "verify_backup_checksum passes on matching checksum" {
  local f; f=$(make_backup "h/d/d_20260101_000000.sql.zst" "PostgreSQL fake dump" "")
  local sum; sum=$(sha256_of "$f")
  printf '{"checksums":{"sha256":"%s"}}\n' "$sum" > "$f.meta.json"
  run verify_backup_checksum "$f"
  [ "$status" -eq 0 ]
}

@test "verify_backup_checksum fails on mismatch" {
  local f; f=$(make_backup "h/d/d_20260101_000000.sql.zst" "PostgreSQL fake dump" "deadbeef")
  run verify_backup_checksum "$f"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mismatch"* ]]
}

@test "verify_backup_checksum is non-fatal when meta is missing" {
  local f; f=$(make_backup "h/d/d_20260101_000000.sql.zst" "PostgreSQL fake dump" "")
  run verify_backup_checksum "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping checksum verification"* ]]
}

@test "verify_backup_checksum is non-fatal when meta has no checksum" {
  local f; f=$(make_backup "h/d/d_20260101_000000.sql.zst" "PostgreSQL fake dump" "")
  printf '{}\n' > "$f.meta.json"
  run verify_backup_checksum "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping checksum verification"* ]]
}

# ----------------------------------------------------------------------------
# cmd_restore — gate behavior on the local-file path.
# ----------------------------------------------------------------------------

@test "restore: matching checksum passes and imports" {
  write_config '{}'
  local f; f=$(make_backup "myhost/mydb/mydb_20260101_000000.sql.zst" "PostgreSQL fake dump" "")
  local sum; sum=$(sha256_of "$f")
  printf '{"checksums":{"sha256":"%s"}}\n' "$sum" > "$f.meta.json"

  run restore_subshell "$f" --name ok_restore
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  grep -qE "(pg|mysql)_restore_backup .* ok_restore" "$CALLS_LOG"
}

@test "restore: checksum mismatch aborts before any import" {
  write_config '{}'
  local f; f=$(make_backup "myhost/mydb/mydb_20260101_000000.sql.zst" "PostgreSQL fake dump" "deadbeef")

  run restore_subshell "$f" --name should_not_run
  echo "OUT: $output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"verification failed"* ]]
  [ ! -s "$CALLS_LOG" ]
}

@test "restore: missing meta warns but proceeds" {
  write_config '{}'
  local f; f=$(make_backup "myhost/mydb/mydb_20260101_000000.sql.zst" "PostgreSQL fake dump" "")

  run restore_subshell "$f" --name no_meta
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping checksum verification"* ]]
  grep -qE "(pg|mysql)_restore_backup .* no_meta" "$CALLS_LOG"
}

@test "restore: --skip-verify bypasses a mismatched checksum" {
  write_config '{}'
  local f; f=$(make_backup "myhost/mydb/mydb_20260101_000000.sql.zst" "PostgreSQL fake dump" "deadbeef")

  run restore_subshell "$f" --skip-verify --name bypassed
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--skip-verify"* ]]
  grep -qE "(pg|mysql)_restore_backup .* bypassed" "$CALLS_LOG"
}

# ----------------------------------------------------------------------------
# cmd_restore --from-remote — gate runs AFTER download.
# ----------------------------------------------------------------------------

@test "restore --from-remote: verifies downloaded file and aborts on mismatch" {
  write_config '{"storage":{"type":"s3","s3":{"bucket":"b","endpoint":"http://x","access_key":"a","secret_key":"s"}}}'
  # storage_download writes content + a meta.json whose checksum won't match.
  EXTRA_STUBS='
    storage_download() {
      echo "storage_download $*" >> "$CALLS_LOG"
      printf "PostgreSQL fake" > "$2"
      printf "{\"checksums\":{\"sha256\":\"deadbeef\"}}\n" > "$2.meta.json"
      echo "$2"
    }
    storage_list() { :; }
  '

  run restore_subshell --from-remote "prod/users/users_20260510_120000.sql.zst" --name remote_bad
  echo "OUT: $output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"verification failed"* ]]
  grep -q "storage_download" "$CALLS_LOG"
  ! grep -qE "(pg|mysql)_restore_backup" "$CALLS_LOG"
}
