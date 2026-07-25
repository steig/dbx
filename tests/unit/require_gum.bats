#!/usr/bin/env bats
#
# Regression tests for #209: `require_gum` was called by `storage add` and
# `host add` but defined nowhere, so both wizards died with
# "require_gum: command not found" instead of a dependency error.
#
# None of these tests need gum on PATH.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
}

@test "require_gum is defined" {
  declare -F require_gum >/dev/null
}

@test "every require_* helper called by dbx or lib/ is defined" {
  local missing=""
  local name
  for name in $(grep -rhoE '\brequire_[a-z0-9_]+' "$DBX_REPO_ROOT/dbx" "$DBX_REPO_ROOT"/lib/*.sh | sort -u); do
    declare -F "$name" >/dev/null || missing="$missing $name"
  done
  [ -z "$missing" ] || {
    echo "undefined require_* helpers:$missing"
    false
  }
}

@test "require_gum: dies with an install hint when gum is not on PATH" {
  # Source with the real PATH (core.sh needs its own tools), then blank PATH so
  # the `command -v gum` lookup fails deterministically even where gum exists.
  run bash -c "CONFIG_FILE='$CONFIG_FILE'; source '$DBX_REPO_ROOT/lib/core.sh'; PATH=''; require_gum"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gum is required"* ]]
  [[ "$output" == *"install gum"* ]]
  [[ "$output" != *"command not found"* ]]
}

@test "require_gum: succeeds when gum is on PATH" {
  local stub="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/gum"
  chmod +x "$stub/gum"

  PATH="$stub:$PATH" run require_gum
  [ "$status" -eq 0 ]
}

@test "dbx storage add: reports the missing dependency instead of crashing" {
  command -v gum >/dev/null 2>&1 && skip "gum installed — the no-gum path can't be exercised here"
  write_config '{"hosts":{}}'
  run "$DBX_BIN" storage add
  [ "$status" -ne 0 ]
  [[ "$output" == *"gum is required"* ]]
  [[ "$output" != *"command not found"* ]]
}
