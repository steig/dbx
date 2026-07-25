#!/usr/bin/env bats
#
# Regression tests for #210: storage backends read their S3 secret from the
# vault (lib/storage.sh:storage_vault_key), but `dbx vault set` validated every
# name against `.hosts[]` and so refused to write it — read path and write path
# disagreed. `vault set` now also accepts a storage-secret key whose backend is
# configured, while still rejecting names that match neither.
#
# The CLI tests force DBX_VAULT_BACKEND=none so a successful validation stops at
# "no credential storage available" instead of writing to the real keychain.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
}

CFG_R2='{"hosts":{"prod":{"type":"postgres","host":"db","port":5432,"user":"u"}},"storages":{"r2":{"type":"s3","s3":{"bucket":"backups","endpoint":"https://r2","access_key":"ak"}}}}'
CFG_LEGACY='{"storage":{"type":"s3","s3":{"bucket":"legacy","endpoint":"http://m:9000","access_key":"ak"}}}'

# ----------------------------------------------------------------------------
# vault_storage_key_name — shape parsing
# ----------------------------------------------------------------------------

@test "vault_storage_key_name: named backend key yields the backend name" {
  [ "$(vault_storage_key_name s3-secret-key-r2)" = "r2" ]
  [ "$(vault_storage_key_name s3-secret-key-my_minio-2)" = "my_minio-2" ]
}

@test "vault_storage_key_name: legacy key succeeds with an empty name" {
  run vault_storage_key_name s3-secret-key
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "vault_storage_key_name: rejects names that aren't storage keys" {
  run vault_storage_key_name production
  [ "$status" -ne 0 ]
  run vault_storage_key_name ""
  [ "$status" -ne 0 ]
  run vault_storage_key_name s3-secret
  [ "$status" -ne 0 ]
  run vault_storage_key_name s3-secret-key-
  [ "$status" -ne 0 ]
}

@test "vault_storage_key_name: rejects backend names that aren't identifiers" {
  run vault_storage_key_name 's3-secret-key-a b'
  [ "$status" -ne 0 ]
  run vault_storage_key_name 's3-secret-key-../etc'
  [ "$status" -ne 0 ]
  run vault_storage_key_name 's3-secret-key-"] | .x'
  [ "$status" -ne 0 ]
}

# ----------------------------------------------------------------------------
# dbx vault set — write path
# ----------------------------------------------------------------------------

@test "dbx vault set: accepts a configured backend's storage-secret key" {
  write_config "$CFG_R2"
  run bash -c "echo sekret | DBX_VAULT_BACKEND=none '$DBX_BIN' vault set s3-secret-key-r2"
  [[ "$output" != *"not found in config"* ]]
  [[ "$output" == *"Setting S3 secret key for: storage 'r2'"* ]]
  # Validation passed and the prompt was answered; only the stubbed-out vault
  # backend stops the write.
  [[ "$output" == *"No credential storage available"* ]]
}

@test "dbx vault set: accepts the legacy .storage block's key" {
  write_config "$CFG_LEGACY"
  run bash -c "echo sekret | DBX_VAULT_BACKEND=none '$DBX_BIN' vault set s3-secret-key"
  [[ "$output" != *"not found in config"* ]]
  [[ "$output" == *"Setting S3 secret key for: the default storage backend"* ]]
  [[ "$output" == *"No credential storage available"* ]]
}

@test "dbx vault set: rejects an empty secret" {
  write_config "$CFG_R2"
  run bash -c "echo '' | DBX_VAULT_BACKEND=none '$DBX_BIN' vault set s3-secret-key-r2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Secret key cannot be empty"* ]]
}

@test "dbx vault set: rejects a storage key whose backend isn't configured" {
  write_config "$CFG_R2"
  run bash -c "echo sekret | DBX_VAULT_BACKEND=none '$DBX_BIN' vault set s3-secret-key-typo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Storage 'typo' not found in config"* ]]
  [[ "$output" == *"Configured backends: r2"* ]]
}

@test "dbx vault set: rejects the legacy key when there is no .storage block" {
  write_config "$CFG_R2"
  run bash -c "echo sekret | DBX_VAULT_BACKEND=none '$DBX_BIN' vault set s3-secret-key"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No default storage block"* ]]
}

@test "dbx vault set: still rejects an unknown host (typo protection)" {
  write_config "$CFG_R2"
  run bash -c "echo sekret | DBX_VAULT_BACKEND=none '$DBX_BIN' vault set prodd"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Host 'prodd' not found in config"* ]]
}

@test "dbx vault set: no argument prints usage" {
  write_config "$CFG_R2"
  run "$DBX_BIN" vault set
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage: dbx vault set"* ]]
}
