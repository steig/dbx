#!/usr/bin/env bats
#
# Tests for `dbx restore --from-remote` and `s3://...` URI shorthand.
#
# Each test that exercises cmd_restore launches a subshell that sources
# the dbx script with DBX_NO_AUTO_MAIN=1 (so the CLI dispatch doesn't
# fire), stubs the heavy/external functions, then invokes cmd_restore
# directly. This keeps assertions focused on remote-fetch wiring without
# requiring docker/postgres/mysql to be present.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs

  CALLS_LOG="$BATS_TEST_TMPDIR/calls.log"
  : > "$CALLS_LOG"
}

# Run cmd_restore in a fresh subshell with the standard stubs.
# Caller may pre-define extra stubs by setting EXTRA_STUBS to a string
# of shell code that runs after the standard stubs.
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
    # Replace heavy deps with stubs. Define after sourcing so they win.
    pg_restore_backup()      { echo "pg_restore_backup $*" >> "$CALLS_LOG"; return 0; }
    mysql_restore_backup()   { echo "mysql_restore_backup $*" >> "$CALLS_LOG"; return 0; }
    notify_restore_success() { :; }
    require_docker() { :; }
    require_jq()     { :; }
    require_config() { :; }
    docker() { return 1; }
    # Default storage stubs — overridden by per-test EXTRA_STUBS if needed.
    storage_download() { echo "storage_download $*" >> "$CALLS_LOG"; printf "PostgreSQL fake" > "$2"; echo "$2"; }
    storage_list()     { echo "storage_list $*" >> "$CALLS_LOG"; }
    '"${EXTRA_STUBS:-}"'
    cmd_restore "$@"
  ' bash "$@"
}

configure_storage() {
  write_config '{"storage":{"type":"s3","s3":{"bucket":"b","endpoint":"http://x","access_key":"a","secret_key":"s"}}}'
}

# ----------------------------------------------------------------------------
# storage_resolve_remote_path — direct unit tests on resolver.
# ----------------------------------------------------------------------------

@test "storage_resolve_remote_path returns input when not /latest" {
  configure_storage
  storage_list() { echo "storage_list-called" >> "$CALLS_LOG"; }
  export -f storage_list

  result=$(storage_resolve_remote_path "prod/users/users_20260101_000000.sql.zst")
  [ "$result" = "prod/users/users_20260101_000000.sql.zst" ]
  [ ! -s "$CALLS_LOG" ]
}

@test "storage_resolve_remote_path picks lex-max for /latest" {
  configure_storage
  storage_list() {
    cat <<EOF
[2026-05-01 12:00:00 UTC]  500MiB STANDARD users_20260501_120000.sql.zst.age
[2026-05-10 12:00:00 UTC]  500MiB STANDARD users_20260510_120000.sql.zst.age
[2026-05-05 12:00:00 UTC]  500MiB STANDARD users_20260505_120000.sql.zst.age
EOF
  }
  export -f storage_list

  result=$(storage_resolve_remote_path "prod/users/latest")
  [ "$result" = "prod/users/users_20260510_120000.sql.zst.age" ]
}

@test "storage_resolve_remote_path rejects malformed paths" {
  configure_storage
  run storage_resolve_remote_path "no-slashes"
  [ "$status" -ne 0 ]
}

@test "storage_resolve_remote_path errors when /latest finds nothing" {
  configure_storage
  storage_list() { :; }
  export -f storage_list

  run storage_resolve_remote_path "prod/users/latest"
  [ "$status" -ne 0 ]
}

# ----------------------------------------------------------------------------
# cmd_restore --from-remote integration
# ----------------------------------------------------------------------------

@test "--from-remote requires storage configured" {
  write_config '{"storage":{"type":"none"}}'

  run restore_subshell --from-remote prod/users/latest
  [ "$status" -ne 0 ]
  [[ "$output" == *"storage"* || "$output" == *"Storage"* ]]
}

@test "--from-remote: custom-format (PGDMP) dump detected as postgres, not mysql" {
  configure_storage
  # Force the content sniff (no meta .type, unknown host) with a decompressed
  # header equal to pg_dump's custom-format binary magic "PGDMP" — which the
  # old text-only sniff (*PostgreSQL*) misclassified as mysql.
  EXTRA_STUBS='decompress_backup() { printf "PGDMP\000\001\015\000"; }'
  run restore_subshell --from-remote "prod/users/users_20260510_120000.sql.zst" --name target
  [ "$status" -eq 0 ]
  grep -q "pg_restore_backup" "$CALLS_LOG"
  ! grep -q "mysql_restore_backup" "$CALLS_LOG"
}

@test "--from-remote with explicit file path downloads via storage_download" {
  configure_storage

  run restore_subshell --from-remote "prod/users/users_20260510_120000.sql.zst" --name target
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  grep -q "storage_download prod/users/users_20260510_120000.sql.zst" "$CALLS_LOG"
  grep -qE "(pg|mysql)_restore_backup .* target" "$CALLS_LOG"
}

@test "--from-remote prod/db/latest resolves to the lex-max filename" {
  configure_storage
  EXTRA_STUBS='
    storage_list() {
      cat <<EOS
[2026-05-01 12:00:00 UTC]  500MiB STANDARD users_20260501_120000.sql.zst
[2026-05-10 12:00:00 UTC]  500MiB STANDARD users_20260510_120000.sql.zst
[2026-05-05 12:00:00 UTC]  500MiB STANDARD users_20260505_120000.sql.zst
EOS
    }
  '

  run restore_subshell --from-remote "prod/users/latest" --name picked
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  grep -q "storage_download prod/users/users_20260510_120000.sql.zst" "$CALLS_LOG"
}

@test "s3:// URI prefix is equivalent to --from-remote" {
  configure_storage

  run restore_subshell "s3://prod/users/users_20260510_120000.sql.zst" --name target
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  grep -q "storage_download prod/users/users_20260510_120000.sql.zst" "$CALLS_LOG"
}

@test "--keep-download preserves the file after success" {
  configure_storage
  EXTRA_STUBS='
    storage_download() {
      echo "storage_download $*" >> "$CALLS_LOG"
      printf "fake" > "$2"
      echo "$2" > "'"$BATS_TEST_TMPDIR"'/downloaded-path"
      echo "$2"
    }
  '

  run restore_subshell --from-remote "prod/users/users_20260510_120000.sql.zst" --keep-download --name target
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  local downloaded
  downloaded=$(cat "$BATS_TEST_TMPDIR/downloaded-path")
  [ -f "$downloaded" ]
}

@test "without --keep-download the file is removed after success" {
  configure_storage
  EXTRA_STUBS='
    storage_download() {
      echo "storage_download $*" >> "$CALLS_LOG"
      printf "fake" > "$2"
      echo "$2" > "'"$BATS_TEST_TMPDIR"'/downloaded-path"
      echo "$2"
    }
  '

  run restore_subshell --from-remote "prod/users/users_20260510_120000.sql.zst" --name target
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  local downloaded
  downloaded=$(cat "$BATS_TEST_TMPDIR/downloaded-path")
  [ ! -f "$downloaded" ]
}

@test "download failure surfaces non-zero exit" {
  configure_storage
  EXTRA_STUBS='
    storage_download() { return 7; }
  '

  run restore_subshell --from-remote "prod/users/users_20260510_120000.sql.zst" --name target
  [ "$status" -ne 0 ]
}

# ----------------------------------------------------------------------------
# Regression: existing local-file invocation still works without remote calls.
# ----------------------------------------------------------------------------

@test "existing local-file invocation still works (no remote calls)" {
  write_config '{}'
  local fake_dir="$DBX_DATA_DIR/myhost/mydb"
  mkdir -p "$fake_dir"
  local fake_backup="$fake_dir/mydb_20260101_000000.sql.zst"
  printf "PostgreSQL fake dump" > "$fake_backup"

  run restore_subshell "$fake_backup" --name local_restore
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  grep -qE "(pg|mysql)_restore_backup .* local_restore" "$CALLS_LOG"
  ! grep -q "storage_download" "$CALLS_LOG"
  ! grep -q "storage_list" "$CALLS_LOG"
}
