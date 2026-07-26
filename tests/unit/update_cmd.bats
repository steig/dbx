#!/usr/bin/env bats
#
# Tests for `dbx update` (cmd_update) — the no-op-when-current gate.
# Each test runs in a subshell that sources dbx with DBX_NO_AUTO_MAIN=1,
# stubs the release resolvers and `curl` so nothing hits the network, and
# calls cmd_update directly.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
  CALLS_LOG="$BATS_TEST_TMPDIR/calls.log"
  : > "$CALLS_LOG"
}

# Run cmd_update with the latest-release resolvers pinned to $LATEST (empty
# means "could not resolve"). Every curl invocation is logged instead of run,
# so a test can assert whether an install was attempted.
update_subshell() {
  local latest="$1"; shift
  CALLS_LOG="$CALLS_LOG" LATEST="$latest" bash -c '
    set -uo pipefail
    export DBX_NO_AUTO_MAIN=1
    # shellcheck source=/dev/null
    source "'"$DBX_BIN"'"
    VERSION="1.2.3"
    fetch_latest_release_gh() { [[ -n "$LATEST" ]] && printf "%s" "$LATEST"; }
    fetch_latest_release()    { return 1; }
    fetch_latest_tag_git()    { return 1; }
    curl() { echo "curl $*" >> "$CALLS_LOG"; return 0; }
    cmd_update "$@"
  ' bash "$@"
}

@test "cmd_update: no-op when already on the latest release" {
  run update_subshell "1.2.3"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already the latest"* ]]
  [ ! -s "$CALLS_LOG" ]
}

@test "cmd_update: no-op when running ahead of the latest release" {
  run update_subshell "1.2.2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already the latest"* ]]
  [ ! -s "$CALLS_LOG" ]
}

@test "cmd_update: installs when a newer release exists" {
  run update_subshell "1.3.0"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installing v1.3.0"* ]]
  grep -q "v1.3.0/install.sh" "$CALLS_LOG"
}

@test "cmd_update: --force re-installs the current version" {
  run update_subshell "1.2.3" --force
  [ "$status" -eq 0 ]
  [[ "$output" != *"already the latest"* ]]
  grep -q "v1.2.3/install.sh" "$CALLS_LOG"
}

@test "cmd_update: falls back to main when no tag resolves" {
  run update_subshell ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"falling back to main"* ]]
  grep -q "main/install.sh" "$CALLS_LOG"
}

@test "cmd_update: rejects an unknown argument" {
  run update_subshell "1.2.3" --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown update argument"* ]]
}

@test "cmd_update: --help prints usage without touching the network" {
  run update_subshell "1.3.0" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: dbx update"* ]]
  [ ! -s "$CALLS_LOG" ]
}
