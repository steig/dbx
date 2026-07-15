#!/usr/bin/env bats
#
# End-to-end test for postgres globals capture/apply (#130): `dbx backup
# --globals` writes a roles/grants sidecar, and `dbx restore --with-globals`
# replays it into the target cluster.

load '../helpers/integration'

setup_file() {
  require_docker
  ensure_postgres_container
}

setup() {
  setup_dbx_env
  write_local_config
  TEST_DB="dbx_pg_glob_$$_${BATS_TEST_NUMBER}"
  RESTORE_DB="${TEST_DB}_restored"
  TEST_ROLE="dbx_glob_role_$$_${BATS_TEST_NUMBER}"
}

teardown() {
  pg_drop_db "$TEST_DB"
  pg_drop_db "$RESTORE_DB"
  docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -c "DROP ROLE IF EXISTS \"$TEST_ROLE\"" >/dev/null 2>&1 || true
}

pg_role_exists() {
  docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$1'" 2>/dev/null
}

@test "postgres: backup --globals writes a .globals.sql sidecar and records it in meta" {
  seed_postgres_db "$TEST_DB"
  docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -c "CREATE ROLE \"$TEST_ROLE\" LOGIN" >/dev/null

  dbx_run backup local-pg "$TEST_DB" --globals
  [ "$status" -eq 0 ]

  local backup
  backup=$(ls "$DBX_DATA_DIR/local-pg/$TEST_DB"/*.sql.zst | head -1)
  local sidecar="${backup}.globals.sql"
  [ -f "$sidecar" ]
  # The captured role should appear in the sidecar.
  grep -q "$TEST_ROLE" "$sidecar"

  # meta.json records globals: true
  [ "$(jq -r '.globals' "${backup}.meta.json")" = "true" ]
}

@test "postgres: backup without --globals records globals:false and writes no sidecar" {
  seed_postgres_db "$TEST_DB"

  dbx_run backup local-pg "$TEST_DB"
  [ "$status" -eq 0 ]

  local backup
  backup=$(ls "$DBX_DATA_DIR/local-pg/$TEST_DB"/*.sql.zst | head -1)
  [ ! -f "${backup}.globals.sql" ]
  [ "$(jq -r '.globals' "${backup}.meta.json")" = "false" ]
}

@test "postgres: restore --with-globals recreates a dropped role" {
  seed_postgres_db "$TEST_DB" "CREATE TABLE t(id int); INSERT INTO t VALUES (1),(2);"
  docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -c "CREATE ROLE \"$TEST_ROLE\" LOGIN" >/dev/null

  dbx_run backup local-pg "$TEST_DB" --globals
  [ "$status" -eq 0 ]

  # Drop the role to simulate restoring into a cluster that lacks it.
  docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -c "DROP ROLE \"$TEST_ROLE\"" >/dev/null
  [ -z "$(pg_role_exists "$TEST_ROLE")" ]

  dbx_run restore "local-pg/$TEST_DB/latest" --name "$RESTORE_DB" --with-globals
  [ "$status" -eq 0 ]

  # Role is back, and the data restored too.
  [ "$(pg_role_exists "$TEST_ROLE")" = "1" ]
  [ "$(pg_row_count "$RESTORE_DB" "t")" = "2" ]
}

@test "postgres: restore --with-globals is idempotent when the role already exists" {
  seed_postgres_db "$TEST_DB" "CREATE TABLE t(id int); INSERT INTO t VALUES (1);"
  docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -c "CREATE ROLE \"$TEST_ROLE\" LOGIN" >/dev/null

  dbx_run backup local-pg "$TEST_DB" --globals
  [ "$status" -eq 0 ]

  # Role still present — applying globals must not abort the restore.
  dbx_run restore "local-pg/$TEST_DB/latest" --name "$RESTORE_DB" --with-globals
  [ "$status" -eq 0 ]
  [ "$(pg_row_count "$RESTORE_DB" "t")" = "1" ]
}
