#!/usr/bin/env bats
load '../helpers/common'
setup() { setup_dbx_env; source_dbx_libs; }

@test "host_alias_valid: accepts typical aliases" {
  host_alias_valid "production"
  host_alias_valid "prod-east-1"
  host_alias_valid "db_2"
  host_alias_valid "MixedCase"
  host_alias_valid "a"
}

@test "host_alias_valid: accepts trailing dash or underscore (documenting intent)" {
  host_alias_valid "prod-"
  host_alias_valid "prod_"
}

@test "host_alias_valid: rejects empty string" {
  run host_alias_valid ""
  [ "$status" -ne 0 ]
}

@test "host_alias_valid: rejects leading dash" {
  run host_alias_valid "-prod"
  [ "$status" -ne 0 ]
}

@test "host_alias_valid: rejects leading underscore" {
  run host_alias_valid "_prod"
  [ "$status" -ne 0 ]
}

@test "host_alias_valid: rejects whitespace" {
  run host_alias_valid "with space"
  [ "$status" -ne 0 ]
}

@test "host_alias_valid: rejects slash" {
  run host_alias_valid "with/slash"
  [ "$status" -ne 0 ]
}

@test "host_alias_valid: rejects dot" {
  run host_alias_valid "prod.east"
  [ "$status" -ne 0 ]
}

@test "host_alias_valid: rejects shell metachars" {
  run host_alias_valid "prod;rm"
  [ "$status" -ne 0 ]
  run host_alias_valid 'prod$x'
  [ "$status" -ne 0 ]
  run host_alias_valid 'prod`x`'
  [ "$status" -ne 0 ]
}
