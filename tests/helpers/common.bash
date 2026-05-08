#!/usr/bin/env bash
# Shared helpers for dbx bats tests.
#
# Usage in a .bats file:
#   load '../helpers/common'
#   setup() { setup_dbx_env; source_dbx_libs; }

DBX_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
DBX_BIN="$DBX_REPO_ROOT/dbx"

# Isolate this test's data/config/audit dirs under BATS_TEST_TMPDIR.
# Call from setup() before invoking dbx or sourcing libs.
setup_dbx_env() {
  export DBX_DATA_DIR="$BATS_TEST_TMPDIR/data"
  export DBX_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  export DBX_AUDIT_DIR="$BATS_TEST_TMPDIR/audit"
  mkdir -p "$DBX_DATA_DIR" "$DBX_CONFIG_DIR" "$DBX_AUDIT_DIR"
  # Don't let the developer's shell env (DEV_SERVICES_MODE in particular)
  # change dbx's restore code path. Tests always run in local mode.
  unset DEV_SERVICES_MODE DEV_PG_HOST DEV_PG_PORT DEV_PG_PASSWORD \
        DEV_MYSQL_HOST DEV_MYSQL_PORT DEV_MYSQL_PASSWORD
}

# Source all dbx libs in the same order dbx itself does, so unit tests can
# call internal functions directly. Requires setup_dbx_env first.
source_dbx_libs() {
  CONFIG_FILE="$DBX_CONFIG_DIR/config.json"
  [[ -f "$CONFIG_FILE" ]] || echo '{}' > "$CONFIG_FILE"
  # shellcheck source=/dev/null
  source "$DBX_REPO_ROOT/lib/core.sh"
  # shellcheck source=/dev/null
  source "$DBX_REPO_ROOT/lib/tunnel.sh"
  # shellcheck source=/dev/null
  source "$DBX_REPO_ROOT/lib/encrypt.sh"
  # shellcheck source=/dev/null
  source "$DBX_REPO_ROOT/lib/postgres.sh"
  # shellcheck source=/dev/null
  source "$DBX_REPO_ROOT/lib/mysql.sh"
  # shellcheck source=/dev/null
  source "$DBX_REPO_ROOT/lib/notify.sh"
  # shellcheck source=/dev/null
  source "$DBX_REPO_ROOT/lib/schedule.sh"
  # shellcheck source=/dev/null
  source "$DBX_REPO_ROOT/lib/storage.sh"
}

# Write a config.json with the given content.
write_config() {
  local content="$1"
  printf '%s\n' "$content" > "$DBX_CONFIG_DIR/config.json"
}

# Skip the test if a command isn't on PATH.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || skip "$1 not installed"
}
