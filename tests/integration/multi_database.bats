#!/usr/bin/env bats
#
# `dbx backup <host>` (no database arg) backs up every configured DB.

load '../helpers/integration'

setup_file() {
  require_docker
  ensure_postgres_container
}

setup() {
  setup_dbx_env
  DB_A="dbx_multi_a_$$"
  DB_B="dbx_multi_b_$$"
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-pg": {
      "type": "postgres", "host": "127.0.0.1", "port": 5432,
      "user": "postgres", "password_cmd": "echo devpassword",
      "databases": {
        "$DB_A": {},
        "$DB_B": {}
      }
    }
  },
  "defaults": {"compression_level": 1}
}
EOF
}

teardown() {
  pg_drop_db "$DB_A"
  pg_drop_db "$DB_B"
}

@test "backup <host> with no db arg backs up every configured database" {
  seed_postgres_db "$DB_A"
  seed_postgres_db "$DB_B"

  dbx_run backup local-pg
  [ "$status" -eq 0 ]

  # Both databases produced backup files
  local a_count b_count
  a_count=$(ls "$DBX_DATA_DIR/local-pg/$DB_A"/*.sql.zst 2>/dev/null | wc -l)
  b_count=$(ls "$DBX_DATA_DIR/local-pg/$DB_B"/*.sql.zst 2>/dev/null | wc -l)
  [ "$a_count" = "1" ]
  [ "$b_count" = "1" ]
}

@test "backup <host> aborts cleanly if no databases are configured" {
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "empty-host": {
      "type": "postgres", "host": "127.0.0.1", "port": 5432,
      "user": "postgres", "password_cmd": "echo devpassword"
    }
  }
}
EOF
  dbx_run backup empty-host
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "no databases configured"
}
