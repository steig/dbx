#!/usr/bin/env bats
#
# Tests for lib/update.sh — version comparison, opt-out gating, cache.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
  # Sandbox the update cache under the test tmpdir so nothing leaks
  # into ~/.cache/dbx during local runs.
  UPDATE_CACHE_DIR="$BATS_TEST_TMPDIR/cache"
  UPDATE_CACHE_FILE="$UPDATE_CACHE_DIR/latest-release"
  unset DBX_NO_UPDATE_CHECK
}

# ----------------------------------------------------------------------------
# version_gt — semver-aware comparison via sort -V
# ----------------------------------------------------------------------------

@test "version_gt: 0.7.1 > 0.7.0" { version_gt "0.7.1" "0.7.0"; }
@test "version_gt: 0.7.0 > 0.7.0 is false" { ! version_gt "0.7.0" "0.7.0"; }
@test "version_gt: 0.7.0 > 0.7.1 is false" { ! version_gt "0.7.0" "0.7.1"; }
@test "version_gt: 1.0.0 > 0.99.99" { version_gt "1.0.0" "0.99.99"; }
@test "version_gt: 0.7.10 > 0.7.2 (numeric, not lex)" { version_gt "0.7.10" "0.7.2"; }
# Note: `sort -V` treats "0.7.0-rc1" as *later* than "0.7.0" (suffix
# sorts after). Strict semver would say the opposite. We don't bother
# fixing this because the GitHub /releases/latest endpoint excludes
# pre-releases by default, so this case never reaches the comparator
# in practice.
@test "version_gt: 0.7.0-rc2 > 0.7.0-rc1" { version_gt "0.7.0-rc2" "0.7.0-rc1"; }

# ----------------------------------------------------------------------------
# update_check_enabled — opt-out gates
# ----------------------------------------------------------------------------

@test "update_check_enabled: false when DBX_NO_UPDATE_CHECK=1" {
  DBX_NO_UPDATE_CHECK=1
  ! update_check_enabled
}

@test "update_check_enabled: false when stdout is not a TTY" {
  # bats already runs without a real TTY on stdout, so this is the
  # default state; no env mutation needed.
  ! update_check_enabled
}

# ----------------------------------------------------------------------------
# Cache: read_update_cache / write_update_cache freshness
# ----------------------------------------------------------------------------

@test "read_update_cache: miss when file absent" {
  ! read_update_cache
}

@test "write+read round-trip returns the cached version" {
  write_update_cache "0.7.5"
  result=$(read_update_cache)
  [ "$result" = "0.7.5" ]
}

@test "read_update_cache: miss when file older than interval" {
  write_update_cache "0.7.5"
  # Backdate the cache file beyond the default 24h window.
  local two_days_ago
  two_days_ago=$(($(date +%s) - 172800))
  touch -d "@$two_days_ago" "$UPDATE_CACHE_FILE" 2>/dev/null \
    || touch -t "$(date -r $two_days_ago +%Y%m%d%H%M.%S)" "$UPDATE_CACHE_FILE"
  ! read_update_cache
}

@test "read_update_cache: hit when file is recent" {
  write_update_cache "0.7.5"
  result=$(read_update_cache)
  [ "$result" = "0.7.5" ]
}

# ----------------------------------------------------------------------------
# maybe_notify_update — end-to-end against a cached value
# ----------------------------------------------------------------------------

@test "maybe_notify_update: silent when DBX_NO_UPDATE_CHECK=1" {
  DBX_NO_UPDATE_CHECK=1
  write_update_cache "99.99.99"
  result=$(maybe_notify_update 2>&1)
  [ -z "$result" ]
}

# Regression: maybe_notify_update runs as the LAST statement of main(), so its
# return value becomes `dbx <cmd>`'s exit code. When you're already on the
# latest release the version_gt comparison is false (1); leaking that made every
# command exit non-zero once up to date (caught by the LXC auto-updater).
@test "maybe_notify_update: exits 0 when already on the latest version" {
  update_check_enabled() { return 0; }   # bats has no TTY; force the check on
  write_update_cache "$VERSION"          # cache == current => version_gt false
  maybe_notify_update
}

@test "maybe_notify_update: exits 0 when a newer version is available" {
  update_check_enabled() { return 0; }
  write_update_cache "99.99.99"
  run maybe_notify_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"99.99.99 is available"* ]]
}
