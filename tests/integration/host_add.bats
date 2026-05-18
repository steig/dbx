#!/usr/bin/env bats
# Integration tests for `dbx host add` wizard.
load '../helpers/integration'

setup() {
  setup_dbx_env
  require_docker
  command -v gum >/dev/null 2>&1 || skip "gum not installed"
  ensure_postgres_container
  # Fresh config; the wizard requires it to exist.
  echo '{"hosts": {}}' > "$DBX_CONFIG_DIR/config.json"
}

# Helper: drive the wizard with a multi-line stdin script.
# Args: each arg is one line of input (newline-separated when piped).
run_wizard() {
  local input
  input=$(printf '%s\n' "$@")
  echo "$input" | "$DBX_BIN" host add
}

@test "host add: postgres happy path, direct connection, one database" {
  docker exec postgres-dbx createdb -U postgres itdb1 >/dev/null 2>&1 || true

  run run_wizard \
    "ithappy1" \
    "postgres" \
    "postgres" \
    "Direct connection" \
    "127.0.0.1" \
    "5432" \
    "devpassword" \
    "itdb1" \
    "" \
    ""
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Connection validated" ]]
  [[ "$output" =~ "Host 'ithappy1' added" ]]

  # Config now contains the host
  result=$(jq -r '.hosts.ithappy1.type' "$DBX_CONFIG_DIR/config.json")
  [ "$result" = "postgres" ]
  result=$(jq -r '.hosts.ithappy1.databases.itdb1 | type' "$DBX_CONFIG_DIR/config.json")
  [ "$result" = "object" ]

  # Cleanup
  docker exec postgres-dbx dropdb -U postgres itdb1 >/dev/null 2>&1 || true
}

@test "host add: postgres bad password, abort, rolls back" {
  run run_wizard \
    "itabort1" \
    "postgres" \
    "postgres" \
    "Direct connection" \
    "127.0.0.1" \
    "5432" \
    "WRONG_PASSWORD" \
    "Abort and roll back"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Rolling back" ]]

  # Config has no record of the alias
  result=$(jq -r '.hosts | has("itabort1")' "$DBX_CONFIG_DIR/config.json")
  [ "$result" = "false" ]
}

@test "host add: postgres bad password, retry creds, succeeds" {
  docker exec postgres-dbx createdb -U postgres itretrydb1 >/dev/null 2>&1 || true

  run run_wizard \
    "itretry1" \
    "postgres" \
    "postgres" \
    "Direct connection" \
    "127.0.0.1" \
    "5432" \
    "WRONG_PASSWORD" \
    "Re-enter credentials and retry" \
    "devpassword" \
    "itretrydb1" \
    "" \
    ""
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Host 'itretry1' added" ]]

  # Cleanup
  docker exec postgres-dbx dropdb -U postgres itretrydb1 >/dev/null 2>&1 || true
}

@test "host add: collision with existing alias re-prompts" {
  # Pre-populate a host
  jq '.hosts.existing = {type: "postgres", user: "postgres"}' \
    "$DBX_CONFIG_DIR/config.json" > "$DBX_CONFIG_DIR/c" \
    && mv "$DBX_CONFIG_DIR/c" "$DBX_CONFIG_DIR/config.json"

  # First-attempt alias collides, second is unique → wizard proceeds
  # past identity step. We abort early at the network choice by sending
  # empty input.
  run run_wizard \
    "existing" \
    "freshalias" \
    "postgres" \
    "postgres" \
    ""
  # Empty input at network choice should abort cleanly.
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already exists" ]]
  [[ "$output" =~ "Aborted" ]]
}

@test "host add: auto-upload prompt when storage already configured" {
  # Pre-populate storage
  jq '.storage = {type: "s3", s3: {endpoint: "http://127.0.0.1:9100", bucket: "x", access_key: "k", prefix: ""}}' \
    "$DBX_CONFIG_DIR/config.json" > "$DBX_CONFIG_DIR/c" \
    && mv "$DBX_CONFIG_DIR/c" "$DBX_CONFIG_DIR/config.json"

  docker exec postgres-dbx createdb -U postgres chaindb1 >/dev/null 2>&1 || true
  run run_wizard \
    "chainalias1" \
    "postgres" \
    "postgres" \
    "Direct connection" \
    "127.0.0.1" \
    "5432" \
    "devpassword" \
    "chaindb1" \
    "" \
    "y"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "auto-upload enabled for chainalias1" ]]

  result=$(jq -r '.hosts.chainalias1.auto_upload' "$DBX_CONFIG_DIR/config.json")
  [ "$result" = "true" ]

  docker exec postgres-dbx dropdb -U postgres chaindb1 >/dev/null 2>&1 || true
}
