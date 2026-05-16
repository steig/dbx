#!/usr/bin/env bats
load '../helpers/integration'

setup_file() {
  require_docker
  ensure_postgres_container   # the postgres-dbx restore target
  ensure_pg13_source
}

setup() {
  setup_dbx_env
  source_dbx_libs
  # Resolve PG 13 source IP for cross-container connectivity.
  local pg13_ip
  pg13_ip=$(docker inspect dbx-pg13-source \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "pg13": {
      "type": "postgres",
      "host": "$pg13_ip",
      "port": 5432,
      "user": "postgres",
      "password_cmd": "echo devpassword"
    }
  },
  "defaults": { "compression_level": 1, "keep_backups": 10 }
}
EOF
  export TEST_DB="dbx_va_test_$$_${BATS_TEST_NUMBER}"
  export RESTORE_DB="${TEST_DB}_restored"
}

teardown() {
  docker exec -e PGPASSWORD=devpassword dbx-pg13-source \
    psql -U postgres -c "DROP DATABASE IF EXISTS \"$TEST_DB\"" >/dev/null 2>&1 || true
  pg_drop_db "$RESTORE_DB"
}

@test "restoring a PG 13 backup recreates postgres-dbx as postgres:13-alpine" {
  # Seed PG 13 source
  docker exec -e PGPASSWORD=devpassword dbx-pg13-source \
    psql -U postgres -c "CREATE DATABASE \"$TEST_DB\"" >/dev/null
  docker exec -e PGPASSWORD=devpassword dbx-pg13-source \
    psql -U postgres -d "$TEST_DB" -c "CREATE TABLE t(id int); INSERT INTO t VALUES (1),(2),(3);" >/dev/null

  dbx_run backup pg13 "$TEST_DB"
  [ "$status" -eq 0 ]

  # The postgres-dbx target may have leftover user DBs from other tests. If so,
  # restore should fail without --recreate-container. Either way, restore with
  # --recreate-container should succeed.
  if pg_container_has_user_dbs postgres-dbx; then
    dbx_run restore "pg13/$TEST_DB/latest" --name "$RESTORE_DB"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q -- "--recreate-container"
  fi

  dbx_run restore "pg13/$TEST_DB/latest" --name "$RESTORE_DB" --recreate-container
  [ "$status" -eq 0 ]

  result=$(container_image postgres-dbx)
  [ "$result" = "postgres:13-alpine" ]
}
