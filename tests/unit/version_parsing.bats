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

@test "mysql_parse_version_string: bytes-only / malformed → unknown 0 0" {
  # The wire shape we actually see when `2>/dev/null` was hiding an
  # auth/connection failure: the stderr was the real error, stdout
  # was the empty string or just a "ERROR" prefix line. The parser
  # returns the sentinel rather than treating "ERROR" as a version.
  result=$(mysql_parse_version_string "ERROR 1045 (28000): Access denied")
  [ "$result" = "unknown 0 0" ]
}

# ---------------------------------------------------------------------------
# mysql_detect_server_version: verbose diagnostic logging
# ---------------------------------------------------------------------------
#
# The function can't really be unit-tested for the happy path without a
# live mysql container, but we CAN test that under DBX_VERBOSE=1 it
# emits diagnostic log lines and still returns a parsable sentinel
# when the underlying docker exec fails. The diagnostic logging is the
# load-bearing change in this PR (PR-J).

@test "mysql_detect_server_version under -v logs the docker exec exit, raw stdout, and stderr when docker is missing" {
  # No docker on PATH (or mysql-dbx container) → docker exec fails fast.
  # We expect:
  #   (a) the function to return the `unknown 0 0` sentinel cleanly
  #   (b) under DBX_VERBOSE=1, log_info lines describing what was seen
  PATH="/usr/bin:/bin" DBX_VERBOSE=1 run mysql_detect_server_version \
    "host.example" "3306" "backup_user" "secret"
  [ "$status" -eq 0 ]
  # The function still emits the parser sentinel on its stdout.
  [[ "$output" == *"unknown 0 0"* ]]
  # ...and the verbose diagnostics fire.
  [[ "$output" == *"mysql_detect_server_version: querying SELECT VERSION()"* ]]
  [[ "$output" == *"docker exec exit="* ]]
}

@test "mysql_detect_server_version without -v stays quiet" {
  # No DBX_VERBOSE → no diagnostic lines, only the sentinel.
  PATH="/usr/bin:/bin" run mysql_detect_server_version \
    "host.example" "3306" "backup_user" "secret"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unknown 0 0"* ]]
  [[ "$output" != *"mysql_detect_server_version: querying"* ]]
}
