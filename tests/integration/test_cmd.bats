#!/usr/bin/env bats
#
# `dbx test <host>` — connectivity diagnostic.

load '../helpers/integration'

setup_file() {
  require_docker
  ensure_postgres_container
}

setup() {
  setup_dbx_env
  write_local_config
}

@test "test: reports success against a reachable host" {
  dbx_run test local-pg
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "All connection tests passed for: local-pg"
}

@test "test: lists available databases" {
  # Seed a couple so the listing has something to report
  seed_postgres_db "dbx_test_listing_a"
  seed_postgres_db "dbx_test_listing_b"

  dbx_run test local-pg
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "dbx_test_listing_a"
  echo "$output" | grep -q "dbx_test_listing_b"

  # Cleanup
  pg_drop_db "dbx_test_listing_a"
  pg_drop_db "dbx_test_listing_b"
}

@test "test: works for a user with no same-named database (configured db)" {
  # Regression for #198: psql without -d defaults the database name to the
  # user. Dedicated backup users rarely have one, so the connection test
  # must pick a configured database instead.
  docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -c "DROP ROLE IF EXISTS dbx_test_nodb" >/dev/null
  docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -c "CREATE ROLE dbx_test_nodb LOGIN PASSWORD 'devpassword'" >/dev/null
  seed_postgres_db "dbx_test_nodb_target"

  cat > "$DBX_CONFIG_DIR/config.json" <<'EOF'
{
  "hosts": {
    "nodb-pg": {
      "type": "postgres",
      "host": "127.0.0.1",
      "port": 5432,
      "user": "dbx_test_nodb",
      "password_cmd": "echo devpassword",
      "databases": {
        "dbx_test_nodb_target": {}
      }
    }
  }
}
EOF
  dbx_run test nodb-pg
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "All connection tests passed for: nodb-pg"
  # The listing (list_remote_databases) must also work for this user
  echo "$output" | grep -q "dbx_test_nodb_target"

  pg_drop_db "dbx_test_nodb_target"
  docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -c "DROP ROLE IF EXISTS dbx_test_nodb" >/dev/null
}

@test "test: works for a user with no same-named database (no databases block, postgres fallback)" {
  docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -c "DROP ROLE IF EXISTS dbx_test_nodb" >/dev/null
  docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -c "CREATE ROLE dbx_test_nodb LOGIN PASSWORD 'devpassword'" >/dev/null

  cat > "$DBX_CONFIG_DIR/config.json" <<'EOF'
{
  "hosts": {
    "nodb-pg": {
      "type": "postgres",
      "host": "127.0.0.1",
      "port": 5432,
      "user": "dbx_test_nodb",
      "password_cmd": "echo devpassword"
    }
  }
}
EOF
  dbx_run test nodb-pg
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "All connection tests passed for: nodb-pg"

  docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -c "DROP ROLE IF EXISTS dbx_test_nodb" >/dev/null
}

@test "test: fails when host has no credentials" {
  cat > "$DBX_CONFIG_DIR/config.json" <<'EOF'
{
  "hosts": {
    "no-creds": {
      "type": "postgres",
      "host": "127.0.0.1",
      "port": 5432,
      "user": "postgres"
    }
  }
}
EOF
  dbx_run test no-creds
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "no credentials"
}

@test "test: fails for unknown host" {
  dbx_run test no-such-host
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "not found in config"
}
