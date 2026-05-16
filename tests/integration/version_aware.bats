#!/usr/bin/env bats
load '../helpers/integration'

setup_file() {
  require_docker
  ensure_postgres_container   # the postgres-dbx restore target
  ensure_pg13_source
  ensure_pgvector_source
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

@test "restoring a backup with pgvector extension uses pgvector image" {
  ensure_pgvector_source

  local pgvec_ip
  pgvec_ip=$(docker inspect dbx-pgvector-source \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "pgvec": {
      "type": "postgres",
      "host": "$pgvec_ip",
      "port": 5432,
      "user": "postgres",
      "password_cmd": "echo devpassword"
    }
  },
  "defaults": { "compression_level": 1, "keep_backups": 10 }
}
EOF

  # Ensure postgres-dbx is running a pg16-compatible image before backing up.
  # After the preceding test it may be postgres:13-alpine, which cannot dump
  # a PG 16 source. Recreate it with the pgvector image so the client version
  # matches; the restore step will confirm it stays on that image.
  ensure_container_image postgres-dbx pgvector/pgvector:pg16 "true"

  local vec_db="vec_test_$$"
  docker exec -e PGPASSWORD=devpassword dbx-pgvector-source \
    psql -U postgres -c "CREATE DATABASE \"$vec_db\"" >/dev/null
  docker exec -e PGPASSWORD=devpassword dbx-pgvector-source \
    psql -U postgres -d "$vec_db" -c "CREATE EXTENSION vector;" >/dev/null

  dbx_run backup pgvec "$vec_db"
  [ "$status" -eq 0 ]

  local meta
  meta=$(ls "$DBX_DATA_DIR/pgvec/$vec_db"/*.sql.zst.meta.json | head -1)
  [ "$(jq -r '.source_extensions | join(",")' "$meta")" = "vector" ]

  dbx_run restore "pgvec/$vec_db/latest" --name "${vec_db}_r" --recreate-container
  [ "$status" -eq 0 ]

  result=$(container_image postgres-dbx)
  [ "$result" = "pgvector/pgvector:pg16" ]

  pg_drop_db "${vec_db}_r"
  docker exec -e PGPASSWORD=devpassword dbx-pgvector-source \
    psql -U postgres -c "DROP DATABASE IF EXISTS \"$vec_db\"" >/dev/null 2>&1 || true
}

@test "unknown extension during restore fails with override hint" {
  # Take a normal backup against a regular postgres source, then inject an
  # unsupported extension into the meta to simulate a backup from a source
  # that uses (e.g.) pg_partman.
  ensure_postgres_container

  local pg_dbx_ip
  pg_dbx_ip=$(docker inspect postgres-dbx \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-pg": {
      "type": "postgres",
      "host": "$pg_dbx_ip",
      "port": 5432,
      "user": "postgres",
      "password_cmd": "echo devpassword"
    }
  },
  "defaults": { "compression_level": 1, "keep_backups": 10 }
}
EOF

  seed_postgres_db "$TEST_DB"

  dbx_run backup local-pg "$TEST_DB"
  [ "$status" -eq 0 ]

  # Inject an unsupported extension into the meta
  local meta
  meta=$(ls "$DBX_DATA_DIR/local-pg/$TEST_DB"/*.sql.zst.meta.json | head -1)
  jq '.source_extensions = ["pg_partman"]' "$meta" > "$meta.tmp" && mv "$meta.tmp" "$meta"

  dbx_run restore "local-pg/$TEST_DB/latest" --name "$RESTORE_DB"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "pg_partman"
  echo "$output" | grep -q "DBX_POSTGRES_IMAGE"

  # Source DB cleanup happens via teardown (drops TEST_DB on dbx-pg13-source,
  # but seed_postgres_db just created it on postgres-dbx — clean that too).
  docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -c "DROP DATABASE IF EXISTS \"$TEST_DB\"" >/dev/null 2>&1 || true
}

@test "backups missing source fields restore using default image" {
  ensure_postgres_container

  local pg_dbx_ip
  pg_dbx_ip=$(docker inspect postgres-dbx \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-pg": {
      "type": "postgres",
      "host": "$pg_dbx_ip",
      "port": 5432,
      "user": "postgres",
      "password_cmd": "echo devpassword"
    }
  },
  "defaults": { "compression_level": 1, "keep_backups": 10 }
}
EOF

  seed_postgres_db "$TEST_DB"
  dbx_run backup local-pg "$TEST_DB"
  [ "$status" -eq 0 ]

  # Strip the new fields from meta to simulate a pre-feature backup
  local meta
  meta=$(ls "$DBX_DATA_DIR/local-pg/$TEST_DB"/*.sql.zst.meta.json | head -1)
  jq 'del(.source_flavor, .source_major_version, .source_extensions)' "$meta" \
    > "$meta.tmp" && mv "$meta.tmp" "$meta"

  dbx_run restore "local-pg/$TEST_DB/latest" --name "$RESTORE_DB" --recreate-container
  [ "$status" -eq 0 ]
  # Should use the default image (postgres:17-alpine)
  result=$(container_image postgres-dbx)
  [ "$result" = "postgres:17-alpine" ]

  docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -c "DROP DATABASE IF EXISTS \"$TEST_DB\"" >/dev/null 2>&1 || true
}
