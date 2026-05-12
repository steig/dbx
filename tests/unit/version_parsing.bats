#!/usr/bin/env bats
load '../helpers/common'
setup() { setup_dbx_env; source_dbx_libs; }

@test "pg_parse_server_version_num: 130000 → 13" {
  [ "$(pg_parse_server_version_num 130000)" = "13" ]
}

@test "pg_parse_server_version_num: 150004 → 15" {
  [ "$(pg_parse_server_version_num 150004)" = "15" ]
}

@test "pg_parse_server_version_num: 170001 → 17" {
  [ "$(pg_parse_server_version_num 170001)" = "17" ]
}

@test "pg_parse_server_version_num: empty input → unknown" {
  [ "$(pg_parse_server_version_num '')" = "unknown" ]
}

@test "pg_parse_server_version_num: non-numeric → unknown" {
  [ "$(pg_parse_server_version_num 'NaN')" = "unknown" ]
}
