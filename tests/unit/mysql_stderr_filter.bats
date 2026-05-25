#!/usr/bin/env bats
#
# Tests for lib/mysql.sh:mysql_stderr_filter — drops the cosmetic
# "Using a password on the command line" warning while preserving real
# errors. Replaces the old `2>/dev/null` pattern that was swallowing
# legitimate restore failures (user-reported, PR #56 follow-up).

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
}

@test "mysql_stderr_filter drops the mysql warning line" {
  local out
  out=$(echo "mysql: [Warning] Using a password on the command line interface can be insecure." | mysql_stderr_filter 2>&1)
  [ -z "$out" ]
}

@test "mysql_stderr_filter drops the bare 'Warning: Using a password' variant" {
  local out
  out=$(echo "Warning: Using a password on the command line interface can be insecure." | mysql_stderr_filter 2>&1)
  [ -z "$out" ]
}

@test "mysql_stderr_filter preserves real errors (ERROR …)" {
  local out
  out=$(echo "ERROR 1064 (42000): You have an error in your SQL syntax" | mysql_stderr_filter 2>&1)
  [[ "$out" == *"ERROR 1064"* ]]
}

@test "mysql_stderr_filter preserves 'Got error' messages" {
  local out
  out=$(echo "Got error: connection refused" | mysql_stderr_filter 2>&1)
  [[ "$out" == *"connection refused"* ]]
}

@test "mysql_stderr_filter mixed input: warnings dropped, errors kept" {
  local out
  out=$(printf "%s\n" \
    "mysql: [Warning] Using a password on the command line interface can be insecure." \
    "ERROR 1146: Table not found" \
    "Warning: Using a password" \
    "ERROR 1064: SQL syntax" \
    | mysql_stderr_filter 2>&1)
  [[ "$out" == *"ERROR 1146"* ]]
  [[ "$out" == *"ERROR 1064"* ]]
  [[ "$out" != *"Using a password"* ]]
}

@test "mysql_stderr_filter exits 0 even when all lines match (no broken pipe)" {
  # grep -v exits 1 when no non-matching lines exist. The `|| true` in the
  # helper handles that — without it, `set -e` callers would die.
  echo "mysql: [Warning] Using a password" | mysql_stderr_filter
  [ "$?" -eq 0 ]
}

@test "mysql_stderr_filter exits 0 on empty input" {
  local out
  out=$(: | mysql_stderr_filter 2>&1)
  [ "$?" -eq 0 ]
  [ -z "$out" ]
}
