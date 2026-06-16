#!/usr/bin/env bats
#
# Tests for multi-storage support in lib/storage.sh (named backends) and the
# storage_write_block/storage_delete_block config mutators in `dbx`.
# All config-logic only — no network, no S3 client.

load '../helpers/common'

setup() { setup_dbx_env; source_dbx_libs; }

# ----------------------------------------------------------------------------
# Active-backend helpers — driven by the dynamically-scoped _STORAGE_NAME
# ----------------------------------------------------------------------------

@test "storage_root_jq: legacy sentinel targets .storage" {
  _STORAGE_NAME=""
  [ "$(storage_root_jq)" = ".storage" ]
}

@test "storage_root_jq: named backend targets .storages[name]" {
  _STORAGE_NAME="r2"
  [ "$(storage_root_jq)" = '.storages["r2"]' ]
}

@test "storage_vault_key: legacy vs named" {
  _STORAGE_NAME=""  ; [ "$(storage_vault_key)" = "s3-secret-key" ]
  _STORAGE_NAME="r2"; [ "$(storage_vault_key)" = "s3-secret-key-r2" ]
}

@test "mc_alias_name: distinct alias per backend" {
  _STORAGE_NAME=""  ; [ "$(mc_alias_name)" = "dbx-storage" ]
  _STORAGE_NAME="r2"; [ "$(mc_alias_name)" = "dbx-storage-r2" ]
}

@test "get_storage_config reads from the active named backend" {
  write_config '{"storages":{"r2":{"type":"s3","s3":{"bucket":"r2-bucket"}}}}'
  _STORAGE_NAME="r2"
  [ "$(get_storage_config s3.bucket)" = "r2-bucket" ]
}

@test "get_storage_config reads legacy block when name is empty" {
  write_config '{"storage":{"s3":{"bucket":"legacy-bucket"}}}'
  _STORAGE_NAME=""
  [ "$(get_storage_config s3.bucket)" = "legacy-bucket" ]
}

# ----------------------------------------------------------------------------
# storage_list_backends
# ----------------------------------------------------------------------------

@test "storage_list_backends: empty when none configured" {
  write_config '{}'
  [ -z "$(storage_list_backends)" ]
}

@test "storage_list_backends: lists named backends, ignores legacy .storage" {
  write_config '{"storage":{"type":"s3"},"storages":{"r2":{"type":"s3"},"aws":{"type":"s3"}}}'
  run storage_list_backends
  [[ "$output" == *"r2"* ]]
  [[ "$output" == *"aws"* ]]
}

# ----------------------------------------------------------------------------
# resolve_storage_name — selection precedence
# ----------------------------------------------------------------------------

@test "resolve_storage_name: explicit arg wins over everything" {
  write_config '{"defaults":{"storage":"aws"},"storages":{"r2":{"type":"s3"},"aws":{"type":"s3"}}}'
  run resolve_storage_name "r2"
  [ "$status" -eq 0 ]
  [ "$output" = "r2" ]
}

@test "resolve_storage_name: falls back to .defaults.storage" {
  write_config '{"defaults":{"storage":"aws"},"storages":{"r2":{"type":"s3"},"aws":{"type":"s3"}}}'
  run resolve_storage_name
  [ "$status" -eq 0 ]
  [ "$output" = "aws" ]
}

@test "resolve_storage_name: single named backend wins when no default" {
  write_config '{"storages":{"r2":{"type":"s3"}}}'
  run resolve_storage_name
  [ "$status" -eq 0 ]
  [ "$output" = "r2" ]
}

@test "resolve_storage_name: multiple backends + no default -> error" {
  write_config '{"storages":{"r2":{"type":"s3"},"aws":{"type":"s3"}}}'
  run resolve_storage_name
  [ "$status" -ne 0 ]
  [[ "$output" == *"Multiple storage backends"* ]]
}

@test "resolve_storage_name: legacy .storage returns empty sentinel" {
  write_config '{"storage":{"type":"s3"}}'
  run resolve_storage_name
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "resolve_storage_name: legacy type=none is not configured -> error" {
  write_config '{"storage":{"type":"none"}}'
  run resolve_storage_name
  [ "$status" -ne 0 ]
  [[ "$output" == *"No storage configured"* ]]
}

@test "resolve_storage_name: nothing configured -> error" {
  write_config '{}'
  run resolve_storage_name
  [ "$status" -ne 0 ]
  [[ "$output" == *"No storage configured"* ]]
}

@test "resolve_storage_name: named backends take precedence over legacy block" {
  write_config '{"storage":{"type":"s3"},"storages":{"r2":{"type":"s3"}}}'
  run resolve_storage_name
  [ "$status" -eq 0 ]
  [ "$output" = "r2" ]
}

# ----------------------------------------------------------------------------
# is_storage_configured — named-aware
# ----------------------------------------------------------------------------

@test "is_storage_configured: named backend present -> true" {
  write_config '{"storages":{"r2":{"type":"s3"}}}'
  is_storage_configured "r2"
}

@test "is_storage_configured: named backend absent -> false" {
  write_config '{"storages":{"r2":{"type":"s3"}}}'
  ! is_storage_configured "aws"
}

@test "is_storage_configured: named type=none -> false" {
  write_config '{"storages":{"r2":{"type":"none"}}}'
  ! is_storage_configured "r2"
}

@test "is_storage_configured: true when any named backend exists (no arg)" {
  write_config '{"storages":{"r2":{"type":"s3"}}}'
  is_storage_configured
}

# ----------------------------------------------------------------------------
# storage_write_block / storage_delete_block — config mutators in `dbx`
# ----------------------------------------------------------------------------

@test "storage_write_block: creates .storages[name] and sets default when unset" {
  write_config '{}'
  DBX_NO_AUTO_MAIN=1 source "$DBX_BIN"
  storage_write_block "r2" "https://r2.example" "auto" "backups" "prod" "AKIA"
  [ "$(jq -r '.storages.r2.type' "$CONFIG_FILE")" = "s3" ]
  [ "$(jq -r '.storages.r2.s3.bucket' "$CONFIG_FILE")" = "backups" ]
  [ "$(jq -r '.defaults.storage' "$CONFIG_FILE")" = "r2" ]
}

@test "storage_write_block: does not clobber an existing default" {
  write_config '{"defaults":{"storage":"aws"},"storages":{"aws":{"type":"s3"}}}'
  DBX_NO_AUTO_MAIN=1 source "$DBX_BIN"
  storage_write_block "r2" "https://r2.example" "" "backups" "" "AKIA"
  [ "$(jq -r '.defaults.storage' "$CONFIG_FILE")" = "aws" ]
}

@test "storage_write_block: drops empty s3 fields" {
  write_config '{}'
  DBX_NO_AUTO_MAIN=1 source "$DBX_BIN"
  storage_write_block "r2" "https://r2.example" "" "backups" "" "AKIA"
  [ "$(jq -r '.storages.r2.s3 | has("region")' "$CONFIG_FILE")" = "false" ]
  [ "$(jq -r '.storages.r2.s3 | has("prefix")' "$CONFIG_FILE")" = "false" ]
  [ "$(jq -r '.storages.r2.s3.endpoint' "$CONFIG_FILE")" = "https://r2.example" ]
}

@test "storage_delete_block: removes backend and clears default pointing at it" {
  write_config '{"defaults":{"storage":"r2"},"storages":{"r2":{"type":"s3"}}}'
  DBX_NO_AUTO_MAIN=1 source "$DBX_BIN"
  storage_delete_block "r2"
  [ "$(jq -r '.storages | has("r2")' "$CONFIG_FILE")" = "false" ]
  [ "$(jq -r '.defaults | has("storage")' "$CONFIG_FILE")" = "false" ]
}

@test "storage_delete_block: leaves an unrelated default intact" {
  write_config '{"defaults":{"storage":"aws"},"storages":{"r2":{"type":"s3"},"aws":{"type":"s3"}}}'
  DBX_NO_AUTO_MAIN=1 source "$DBX_BIN"
  storage_delete_block "r2"
  [ "$(jq -r '.storages | has("r2")' "$CONFIG_FILE")" = "false" ]
  [ "$(jq -r '.storages | has("aws")' "$CONFIG_FILE")" = "true" ]
  [ "$(jq -r '.defaults.storage' "$CONFIG_FILE")" = "aws" ]
}
