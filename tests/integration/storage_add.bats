#!/usr/bin/env bats
# Integration tests for `dbx storage add` wizard.
load '../helpers/integration'

setup() {
  setup_dbx_env
  require_docker
  command -v gum >/dev/null 2>&1 || skip "gum not installed"
  command -v mc >/dev/null 2>&1 || skip "mc not installed (S3 client)"
  ensure_minio_container
  ensure_minio_bucket "dbxtest-bucket"
  echo '{"hosts": {}}' > "$DBX_CONFIG_DIR/config.json"
}

run_wizard() {
  local input
  input=$(printf '%s\n' "$@")
  echo "$input" | "$DBX_BIN" storage add
}

@test "storage add: happy path against local MinIO" {
  run run_wizard \
    "S3-compatible (MinIO, R2, B2, ...)" \
    "http://127.0.0.1:9100" \
    "" \
    "dbxtest-bucket" \
    "smoketest" \
    "minioadmin" \
    "minioadmin"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "round-trip OK" ]]
  [[ "$output" =~ "Remote storage configured" ]]

  result=$(jq -r '.storage.s3.bucket' "$DBX_CONFIG_DIR/config.json")
  [ "$result" = "dbxtest-bucket" ]
  result=$(jq -r '.storage.s3.endpoint' "$DBX_CONFIG_DIR/config.json")
  [ "$result" = "http://127.0.0.1:9100" ]
}

@test "storage add: wrong secret key, abort, rolls back" {
  run run_wizard \
    "S3-compatible (MinIO, R2, B2, ...)" \
    "http://127.0.0.1:9100" \
    "" \
    "dbxtest-bucket" \
    "" \
    "minioadmin" \
    "WRONG_SECRET" \
    "Abort and roll back"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Rolling back" ]]

  result=$(jq -r '.storage // "null"' "$DBX_CONFIG_DIR/config.json")
  [ "$result" = "null" ]
}

@test "storage add: wrong secret, retry, succeeds" {
  run run_wizard \
    "S3-compatible (MinIO, R2, B2, ...)" \
    "http://127.0.0.1:9100" \
    "" \
    "dbxtest-bucket" \
    "" \
    "minioadmin" \
    "WRONG_SECRET" \
    "Re-enter credentials and retry" \
    "minioadmin" \
    "minioadmin"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Remote storage configured" ]]
}

@test "storage add: replace-existing prompt declines, no change" {
  # Pre-populate a config
  jq '.storage = {type: "s3", s3: {endpoint: "http://old", bucket: "old", access_key: "oldkey"}}' \
    "$DBX_CONFIG_DIR/config.json" > "$DBX_CONFIG_DIR/c" \
    && mv "$DBX_CONFIG_DIR/c" "$DBX_CONFIG_DIR/config.json"

  # First prompt is the "Replace?" confirm — pick No
  run run_wizard "n"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Keeping existing" ]]

  result=$(jq -r '.storage.s3.bucket' "$DBX_CONFIG_DIR/config.json")
  [ "$result" = "old" ]
}
