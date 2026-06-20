#!/usr/bin/env bats
#
# Tests for `dbx containers` (#177) — the managed-container group command.
# Each test runs in a subshell that sources dbx with DBX_NO_AUTO_MAIN=1 and
# stubs `docker` so no real containers are touched. The mock simulates two
# managed containers (postgres-dbx, mysql-dbx) plus an unrelated "other".

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
  CALLS_LOG="$BATS_TEST_TMPDIR/calls.log"
  : > "$CALLS_LOG"
}

containers_subshell() {
  CALLS_LOG="$CALLS_LOG" bash -c '
    set -uo pipefail
    export DBX_NO_AUTO_MAIN=1
    # shellcheck source=/dev/null
    source "'"$DBX_BIN"'"
    require_docker() { :; }
    docker() {
      local args="$*"
      case "$args" in
        *"--filter label="*)             printf "%s\n" postgres-dbx ;;
        *"--filter name=^/postgres-dbx"*) echo "postgres-dbx|Up 1 hour|postgres:17-alpine" ;;
        *"--filter name=^/mysql-dbx"*)    echo "mysql-dbx|Up 2 hours|mysql:8.0" ;;
        *"--filter name=^/"*)            echo "" ;;
        "ps -a --format "*)              printf "%s\n" postgres-dbx mysql-dbx other ;;
        "restart "*|"start "*|"stop "*)  echo "docker $args" >> "$CALLS_LOG"; return 0 ;;
        "rm -f "*)                       echo "docker $args" >> "$CALLS_LOG"; return 0 ;;
        *) return 0 ;;
      esac
    }
    cmd_containers "$@"
  ' bash "$@"
}

@test "containers list shows managed containers, excludes unrelated ones" {
  run containers_subshell list
  [ "$status" -eq 0 ]
  [[ "$output" == *"postgres-dbx"* ]]
  [[ "$output" == *"mysql-dbx"* ]]
  [[ "$output" != *"other"* ]]
}

@test "containers (no action) defaults to list" {
  run containers_subshell
  [ "$status" -eq 0 ]
  [[ "$output" == *"postgres-dbx"* ]]
}

@test "containers restart restarts each managed container" {
  run containers_subshell restart
  [ "$status" -eq 0 ]
  grep -q "docker restart postgres-dbx" "$CALLS_LOG"
  grep -q "docker restart mysql-dbx" "$CALLS_LOG"
  ! grep -q "other" "$CALLS_LOG"
}

@test "containers stop maps to docker stop" {
  run containers_subshell stop
  [ "$status" -eq 0 ]
  grep -q "docker stop postgres-dbx" "$CALLS_LOG"
}

@test "containers down -y removes each managed container without prompting" {
  run containers_subshell down -y
  [ "$status" -eq 0 ]
  grep -q "docker rm -f postgres-dbx" "$CALLS_LOG"
  grep -q "docker rm -f mysql-dbx" "$CALLS_LOG"
}

@test "containers with unknown action errors" {
  run containers_subshell bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown containers action"* ]]
}

@test "containers --help works without docker and lists actions" {
  run containers_subshell --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"restart"* ]]
  [[ "$output" == *"down"* ]]
}
