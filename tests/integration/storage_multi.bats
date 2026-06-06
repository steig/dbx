#!/usr/bin/env bats
#
# Integration: multiple named storage backends. Two buckets on the local
# MinIO (minio-dbx, :9100) wired as backends "a" and "b"; verifies that
# `--upload=<name>` routes to the right bucket, `storage list --storage <name>`
# targets it, and `restore --storage <name> --from-remote` pulls from it.

load '../helpers/integration'

setup_file() {
  require_docker
  ensure_postgres_container
}

setup() {
  command -v mc >/dev/null 2>&1 || skip "mc not installed (S3 client)"
  setup_dbx_env
  write_local_config
  ensure_minio_container
  ensure_minio_bucket "msa"
  ensure_minio_bucket "msb"

  # Two named backends on the same MinIO, different buckets. A plaintext
  # secret_key is fine here — the engine falls back to it when there's no
  # secret_key_cmd / vault entry.
  local tmp; tmp=$(mktemp)
  jq '.storages = {
        "a": {"type":"s3","s3":{"endpoint":"http://127.0.0.1:9100","bucket":"msa","access_key":"minioadmin","secret_key":"minioadmin"}},
        "b": {"type":"s3","s3":{"endpoint":"http://127.0.0.1:9100","bucket":"msb","access_key":"minioadmin","secret_key":"minioadmin"}}
      } | .defaults.storage = "a"' \
     "$DBX_CONFIG_DIR/config.json" > "$tmp" && mv "$tmp" "$DBX_CONFIG_DIR/config.json"

  TEST_DB="dbx_ms_test_$$_${BATS_TEST_NUMBER}"
  RESTORE_DB="${TEST_DB}_restored"
  # Start each test with empty buckets so residue can't skew assertions.
  mc rm --recursive --force "dbxtest/msa" >/dev/null 2>&1 || true
  mc rm --recursive --force "dbxtest/msb" >/dev/null 2>&1 || true
}

teardown() {
  pg_drop_db "$TEST_DB" 2>/dev/null || true
  pg_drop_db "$RESTORE_DB" 2>/dev/null || true
}

@test "multi-storage: --upload=<name> routes to the named backend's bucket" {
  seed_postgres_db "$TEST_DB"

  dbx_run backup --upload=a local-pg "$TEST_DB"
  [ "$status" -eq 0 ]
  run mc ls --recursive "dbxtest/msa"
  [[ "$output" == *"$TEST_DB"* ]]
  run mc ls --recursive "dbxtest/msb"
  [[ "$output" != *"$TEST_DB"* ]]

  dbx_run backup --upload=b local-pg "$TEST_DB"
  [ "$status" -eq 0 ]
  run mc ls --recursive "dbxtest/msb"
  [[ "$output" == *"$TEST_DB"* ]]
}

@test "multi-storage: storage list --storage <name> targets that backend" {
  seed_postgres_db "$TEST_DB"
  dbx_run backup --upload=a local-pg "$TEST_DB"
  [ "$status" -eq 0 ]

  dbx_run storage list "local-pg" --storage a
  [ "$status" -eq 0 ]
  [[ "$output" == *"$TEST_DB"* ]]

  # Backend b has nothing for this db.
  dbx_run storage list "local-pg" --storage b
  [[ "$output" != *"$TEST_DB"* ]]
}

@test "multi-storage: restore --storage <name> fetches from the named backend" {
  seed_postgres_db "$TEST_DB"
  dbx_run backup --upload=a local-pg "$TEST_DB"
  [ "$status" -eq 0 ]

  # Backend b is empty → resolution must fail (proves --storage targets b).
  dbx_run restore --storage b --from-remote "local-pg/$TEST_DB/latest" --name "${RESTORE_DB}_b"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No backups found"* || "$output" == *"resolve remote backup"* ]]

  # Backend a has it → resolves + downloads from a. We assert the fetch routed
  # to the right backend; the subsequent restore step is exercised by the
  # postgres/mysql round-trip suites (and decoupled from --storage here).
  dbx_run restore --storage a --from-remote "local-pg/$TEST_DB/latest" --name "${RESTORE_DB}_a"
  [[ "$output" == *"Fetching remote backup"* ]]
  [[ "$output" == *"Download complete"* ]]
}
