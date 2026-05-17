#!/usr/bin/env bats
load '../helpers/common'
setup() { setup_dbx_env; source_dbx_libs; }

@test "migrate_refuse_same_version: same major returns 1 with message" {
  run migrate_refuse_same_version 15 15
  [ "$status" -eq 1 ]
  [[ "$output" == *"same major version"* ]]
  [[ "$output" == *"dbx restore"* ]]
}

@test "migrate_refuse_same_version: different majors returns 0 silently" {
  run migrate_refuse_same_version 13 15
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "migrate_refuse_same_version: unknown source major returns 0 (let backup proceed)" {
  run migrate_refuse_same_version unknown 15
  [ "$status" -eq 0 ]
}

@test "migrate_refuse_cross_flavor: mysql → mariadb returns 1" {
  run migrate_refuse_cross_flavor mysql mariadb
  [ "$status" -eq 1 ]
  [[ "$output" == *"flavor"* ]]
  [[ "$output" == *"dbx backup"* ]]
}

@test "migrate_refuse_cross_flavor: mariadb → mysql returns 1" {
  run migrate_refuse_cross_flavor mariadb mysql
  [ "$status" -eq 1 ]
}

@test "migrate_refuse_cross_flavor: mysql → mysql returns 0" {
  run migrate_refuse_cross_flavor mysql mysql
  [ "$status" -eq 0 ]
}

@test "migrate_refuse_cross_flavor: postgres → postgres returns 0" {
  run migrate_refuse_cross_flavor postgres postgres
  [ "$status" -eq 0 ]
}

@test "migrate_refuse_cross_flavor: postgres → mysql returns 1 (cross-engine)" {
  run migrate_refuse_cross_flavor postgres mysql
  [ "$status" -eq 1 ]
  [[ "$output" == *"engine"* || "$output" == *"flavor"* ]]
}
