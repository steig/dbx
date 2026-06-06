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
