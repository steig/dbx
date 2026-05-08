#!/usr/bin/env bats
#
# Tests for lib/storage.sh — config detection (no network).

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
}

# ----------------------------------------------------------------------------
# is_storage_configured — set/none/missing
# ----------------------------------------------------------------------------

@test "is_storage_configured false when missing" {
  write_config '{}'
  ! is_storage_configured
}

@test "is_storage_configured false when type=none" {
  write_config '{"storage":{"type":"none"}}'
  ! is_storage_configured
}

@test "is_storage_configured true when type=s3" {
  write_config '{"storage":{"type":"s3"}}'
  is_storage_configured
}

# ----------------------------------------------------------------------------
# get_storage_config — accessor with default empty
# ----------------------------------------------------------------------------

@test "get_storage_config reads nested keys" {
  write_config '{"storage":{"s3":{"bucket":"my-bucket"}}}'
  [ "$(get_storage_config s3.bucket)" = "my-bucket" ]
}

@test "get_storage_config returns empty for missing keys" {
  write_config '{}'
  [ -z "$(get_storage_config s3.bucket)" ]
}
