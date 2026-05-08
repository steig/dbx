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
