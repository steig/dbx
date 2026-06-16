#!/usr/bin/env bats
#
# Tests for lib/encrypt.sh — encryption type detection and helpers.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
}

# ----------------------------------------------------------------------------
# get_encryption_type — config field with legacy fallback
# ----------------------------------------------------------------------------

@test "get_encryption_type returns 'none' when nothing configured" {
  write_config '{}'
  [ "$(get_encryption_type)" = "none" ]
}

@test "get_encryption_type respects encryption_type=age" {
  write_config '{"defaults":{"encryption_type":"age"}}'
  [ "$(get_encryption_type)" = "age" ]
}

@test "get_encryption_type respects encryption_type=gpg" {
  write_config '{"defaults":{"encryption_type":"gpg"}}'
  [ "$(get_encryption_type)" = "gpg" ]
}

@test "legacy encryption=true with no type defaults to gpg" {
  write_config '{"defaults":{"encryption":true}}'
  [ "$(get_encryption_type)" = "gpg" ]
}

@test "legacy encryption=false with no type returns none" {
  write_config '{"defaults":{"encryption":false}}'
  [ "$(get_encryption_type)" = "none" ]
}

# ----------------------------------------------------------------------------
# get_encryption_extension — used to suffix backup filenames
# ----------------------------------------------------------------------------

@test "get_encryption_extension returns .age for age" {
  write_config '{"defaults":{"encryption_type":"age"}}'
  [ "$(get_encryption_extension)" = ".age" ]
}

@test "get_encryption_extension returns .gpg for gpg" {
  write_config '{"defaults":{"encryption_type":"gpg"}}'
  [ "$(get_encryption_extension)" = ".gpg" ]
}

@test "get_encryption_extension returns empty for none" {
  write_config '{}'
  [ -z "$(get_encryption_extension)" ]
}

# ----------------------------------------------------------------------------
# is_file_encrypted — pattern match
# ----------------------------------------------------------------------------

@test "is_file_encrypted true for .age" { is_file_encrypted "x.sql.zst.age"; }
@test "is_file_encrypted true for .gpg" { is_file_encrypted "x.sql.zst.gpg"; }
@test "is_file_encrypted false for .zst" { ! is_file_encrypted "x.sql.zst"; }
@test "is_file_encrypted false for .sql" { ! is_file_encrypted "x.sql"; }
