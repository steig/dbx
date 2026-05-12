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

@test "mysql_parse_version_string: 8.0.35 → mysql 8 0" {
  result=$(mysql_parse_version_string "8.0.35")
  [ "$result" = "mysql 8 0" ]
}

@test "mysql_parse_version_string: 8.4.2 → mysql 8 4" {
  result=$(mysql_parse_version_string "8.4.2")
  [ "$result" = "mysql 8 4" ]
}

@test "mysql_parse_version_string: 10.11.6-MariaDB-1:10.11 → mariadb 10 11" {
  result=$(mysql_parse_version_string "10.11.6-MariaDB-1:10.11.6+maria~ubu2204")
  [ "$result" = "mariadb 10 11" ]
}

@test "mysql_parse_version_string: 11.4.2-MariaDB → mariadb 11 4" {
  result=$(mysql_parse_version_string "11.4.2-MariaDB")
  [ "$result" = "mariadb 11 4" ]
}

@test "mysql_parse_version_string: empty → unknown 0 0" {
  result=$(mysql_parse_version_string "")
  [ "$result" = "unknown 0 0" ]
}
