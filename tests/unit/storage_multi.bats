#!/usr/bin/env bats
#
# Tests for lib/storage.sh — multiple named backends (.storages.<name>),
# backend resolution, and per-backend vault/alias derivation. No network.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
}

CFG_MULTI='{"storages":{"r2":{"type":"s3","s3":{"bucket":"rb","endpoint":"https://r2"}},"minio":{"type":"s3","s3":{"bucket":"mb","endpoint":"http://m:9000"}}},"defaults":{"storage":"r2"}}'

# ----------------------------------------------------------------------------
# resolve_storage_name — precedence
# ----------------------------------------------------------------------------

@test "resolve_storage_name: explicit name wins" {
  write_config "$CFG_MULTI"
  [ "$(resolve_storage_name minio)" = "minio" ]
}

@test "resolve_storage_name: falls back to .defaults.storage" {
  write_config "$CFG_MULTI"
  [ "$(resolve_storage_name '')" = "r2" ]
}

@test "resolve_storage_name: single named backend with no default -> that one" {
  write_config '{"storages":{"only":{"type":"s3","s3":{"bucket":"b"}}}}'
  [ "$(resolve_storage_name '')" = "only" ]
}

@test "resolve_storage_name: multiple backends, no default -> error" {
  write_config '{"storages":{"a":{"type":"s3"},"b":{"type":"s3"}}}'
  run resolve_storage_name ''
  [ "$status" -ne 0 ]
}

@test "resolve_storage_name: legacy .storage -> empty sentinel (success)" {
  write_config '{"storage":{"type":"s3","s3":{"bucket":"legacy"}}}'
  run resolve_storage_name ''
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "resolve_storage_name: nothing configured -> error" {
  write_config '{}'
  run resolve_storage_name ''
  [ "$status" -ne 0 ]
}

# ----------------------------------------------------------------------------
# get_storage_config — reads the active backend
# ----------------------------------------------------------------------------

@test "get_storage_config: reads named backend via _STORAGE_NAME" {
  write_config "$CFG_MULTI"
  [ "$(_STORAGE_NAME=minio get_storage_config s3.bucket)" = "mb" ]
  [ "$(_STORAGE_NAME=r2 get_storage_config s3.bucket)" = "rb" ]
}

@test "get_storage_config: legacy .storage when _STORAGE_NAME empty" {
  write_config '{"storage":{"s3":{"bucket":"legacy"}}}'
  [ "$(get_storage_config s3.bucket)" = "legacy" ]
}

# ----------------------------------------------------------------------------
# Per-backend vault key + mc alias derivation
# ----------------------------------------------------------------------------

@test "storage_vault_key + mc_alias_name are per-backend (named vs legacy)" {
  [ "$(_STORAGE_NAME=r2 storage_vault_key)" = "s3-secret-key-r2" ]
  [ "$(storage_vault_key)" = "s3-secret-key" ]
  [ "$(_STORAGE_NAME=r2 mc_alias_name)" = "dbx-storage-r2" ]
  [ "$(mc_alias_name)" = "dbx-storage" ]
}

@test "storage_root_jq targets the named map vs legacy" {
  [ "$(_STORAGE_NAME=r2 storage_root_jq)" = '.storages["r2"]' ]
  [ "$(storage_root_jq)" = '.storage' ]
}

# ----------------------------------------------------------------------------
# Backend enumeration + is_storage_configured (name-aware)
# ----------------------------------------------------------------------------

@test "storage_list_backends lists configured named backends" {
  write_config "$CFG_MULTI"
  run storage_list_backends
  [[ "$output" == *minio* ]]
  [[ "$output" == *r2* ]]
}

@test "is_storage_configured: name-aware + any" {
  write_config "$CFG_MULTI"
  is_storage_configured minio
  ! is_storage_configured nope
  is_storage_configured
}

@test "is_storage_configured: false when no storages and no legacy" {
  write_config '{}'
  ! is_storage_configured
}

# ----------------------------------------------------------------------------
# resolve_storage_name — extra edge cases
# ----------------------------------------------------------------------------

@test "resolve_storage_name: legacy type=none is not configured -> error" {
  write_config '{"storage":{"type":"none"}}'
  run resolve_storage_name ''
  [ "$status" -ne 0 ]
}

@test "resolve_storage_name: named backends take precedence over a legacy block" {
  write_config '{"storage":{"type":"s3"},"storages":{"r2":{"type":"s3"}}}'
  [ "$(resolve_storage_name '')" = "r2" ]
}

# ----------------------------------------------------------------------------
# storage_write_block / storage_delete_block — config mutators in `dbx`
# (sourced via the DBX_NO_AUTO_MAIN gate so the CLI dispatch doesn't run)
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
