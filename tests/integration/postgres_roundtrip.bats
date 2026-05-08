#!/usr/bin/env bats
#
# End-to-end postgres backup → list → verify → restore round-trip.

load '../helpers/integration'

setup_file() {
  require_docker
  ensure_postgres_container
}

setup() {
  setup_dbx_env
  write_local_config
  TEST_DB="dbx_pg_test_$$_${BATS_TEST_NUMBER}"
  RESTORE_DB="${TEST_DB}_restored"
}

teardown() {
  pg_drop_db "$TEST_DB"
  pg_drop_db "$RESTORE_DB"
}

@test "postgres: backup creates .sql.zst + .meta.json with matching checksum" {
  seed_postgres_db "$TEST_DB"

  dbx_run backup local-pg "$TEST_DB"
  [ "$status" -eq 0 ]

  # Backup file exists
  local files
  files=("$DBX_DATA_DIR/local-pg/$TEST_DB"/*.sql.zst)
  [ -f "${files[0]}" ]

  # Metadata file exists at the writer's path: <full>.meta.json
  local meta="${files[0]}.meta.json"
  [ -f "$meta" ]

  # Checksum in metadata matches actual file
  local expected actual
  expected=$(jq -r '.checksums.sha256' "$meta")
  actual=$(sha256sum "${files[0]}" | cut -d' ' -f1)
  [ "$expected" = "$actual" ]
}

@test "postgres: list shows the real on-disk filename (regression for #1)" {
  seed_postgres_db "$TEST_DB"
  dbx_run backup local-pg "$TEST_DB"
  [ "$status" -eq 0 ]

  # Find the real backup filename
  local real_name
  real_name=$(basename "$DBX_DATA_DIR/local-pg/$TEST_DB"/*.sql.zst)

  dbx_run list local-pg "$TEST_DB"
  [ "$status" -eq 0 ]

  # The listed name must include the full timestamp, not just the date
  echo "$output" | grep -qF "$real_name"
}

@test "postgres: verify confirms checksum" {
  seed_postgres_db "$TEST_DB"
  dbx_run backup local-pg "$TEST_DB"
  [ "$status" -eq 0 ]

  local backup_file
  backup_file=$(ls "$DBX_DATA_DIR/local-pg/$TEST_DB"/*.sql.zst | head -1)

  dbx_run verify "$backup_file"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Checksum verified"
}

@test "postgres: restore round-trips data correctly" {
  seed_postgres_db "$TEST_DB" "CREATE TABLE widgets(id int PRIMARY KEY, name text);
  INSERT INTO widgets VALUES (1,'a'),(2,'b'),(3,'c'),(4,'d'),(5,'e');"

  dbx_run backup local-pg "$TEST_DB"
  [ "$status" -eq 0 ]

  dbx_run restore "local-pg/$TEST_DB/latest" --name "$RESTORE_DB"
  [ "$status" -eq 0 ]

  # Restored DB has same row count
  local rows
  rows=$(pg_row_count "$RESTORE_DB" "widgets")
  [ "$rows" = "5" ]
}

@test "postgres: restore reads .meta.json for plain backups (regression for #3)" {
  seed_postgres_db "$TEST_DB"
  dbx_run backup local-pg "$TEST_DB"
  [ "$status" -eq 0 ]

  # Confirm meta is at <full>.meta.json (not <stripped>.meta.json)
  local meta
  meta=$(ls "$DBX_DATA_DIR/local-pg/$TEST_DB"/*.sql.zst.meta.json 2>/dev/null | head -1)
  [ -f "$meta" ]

  # Ensure restore succeeds (it would log "Unknown database type: null" if
  # the strip-bug regressed and jq returned a literal null)
  dbx_run restore "local-pg/$TEST_DB/latest" --name "$RESTORE_DB"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qi "unknown database type"
}
