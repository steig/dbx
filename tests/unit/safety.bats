#!/usr/bin/env bats
#
# Tests for the per-host safety flag — host_safety / require_writable_host
# helpers in lib/core.sh, and the `dbx config validate` shape check.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
}

# ----------------------------------------------------------------------------
# host_safety — read the safety field
# ----------------------------------------------------------------------------

@test "host_safety: returns 'local' when field absent" {
  write_config '{"hosts":{"dev":{"type":"postgres","user":"x"}}}'
  [ "$(host_safety dev)" = "local" ]
}

@test "host_safety: returns 'prod' when set to prod" {
  write_config '{"hosts":{"production":{"type":"postgres","user":"x","safety":"prod"}}}'
  [ "$(host_safety production)" = "prod" ]
}

@test "host_safety: returns 'stage' when set to stage" {
  write_config '{"hosts":{"staging":{"type":"postgres","user":"x","safety":"stage"}}}'
  [ "$(host_safety staging)" = "stage" ]
}

@test "host_safety: returns 'local' when set to local" {
  write_config '{"hosts":{"dev":{"type":"postgres","user":"x","safety":"local"}}}'
  [ "$(host_safety dev)" = "local" ]
}

@test "host_safety: defaults to 'local' for malformed value (defense in depth)" {
  # `production` is a typo that we never want to silently treat as prod —
  # but we also don't want to crash. Fall back to the safest default that
  # preserves existing behavior, then `config validate` flags the typo.
  write_config '{"hosts":{"prod":{"type":"postgres","user":"x","safety":"production"}}}'
  [ "$(host_safety prod)" = "local" ]
}

@test "host_safety: defaults to 'local' for empty alias" {
  write_config '{"hosts":{}}'
  [ "$(host_safety "")" = "local" ]
}

@test "host_safety: defaults to 'local' for unknown host" {
  write_config '{"hosts":{}}'
  [ "$(host_safety nope)" = "local" ]
}

# ----------------------------------------------------------------------------
# require_writable_host — the enforcement helper
# ----------------------------------------------------------------------------

@test "require_writable_host: succeeds silently on local host" {
  write_config '{"hosts":{"dev":{"type":"postgres","user":"x"}}}'
  run require_writable_host "dev" "restore"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "require_writable_host: succeeds silently on stage host" {
  write_config '{"hosts":{"staging":{"type":"postgres","user":"x","safety":"stage"}}}'
  run require_writable_host "staging" "restore"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "require_writable_host: dies on prod host with the action name in the message" {
  write_config '{"hosts":{"production":{"type":"postgres","user":"x","safety":"prod"}}}'
  run require_writable_host "production" "restore --into prod-container"
  [ "$status" -ne 0 ]
  [[ "$output" == *"safety=prod"* ]]
  [[ "$output" == *"production"* ]]
  [[ "$output" == *"restore --into prod-container"* ]]
}

@test "require_writable_host: default action description is 'write'" {
  write_config '{"hosts":{"production":{"type":"postgres","user":"x","safety":"prod"}}}'
  run require_writable_host "production"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing write"* ]]
}

@test "require_writable_host: succeeds silently on empty alias (no host context)" {
  write_config '{"hosts":{}}'
  run require_writable_host "" "restore"
  [ "$status" -eq 0 ]
}

# ----------------------------------------------------------------------------
# require_writable_host_for_restore_into — prod-source --into gate + opt-out
# ----------------------------------------------------------------------------

@test "restore-into gate: dies on prod source and points at DBX_ALLOW_PROD_RESTORE" {
  write_config '{"hosts":{"production":{"type":"postgres","user":"x","safety":"prod"}}}'
  run require_writable_host_for_restore_into "production"
  [ "$status" -ne 0 ]
  [[ "$output" == *"safety=prod"* ]]
  [[ "$output" == *"DBX_ALLOW_PROD_RESTORE=1"* ]]
}

@test "restore-into gate: DBX_ALLOW_PROD_RESTORE=1 bypasses with a loud warning" {
  write_config '{"hosts":{"production":{"type":"postgres","user":"x","safety":"prod"}}}'
  export DBX_ALLOW_PROD_RESTORE=1
  run require_writable_host_for_restore_into "production"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DBX_ALLOW_PROD_RESTORE=1"* ]]
}

@test "restore-into gate: succeeds silently on a non-prod source host" {
  write_config '{"hosts":{"staging":{"type":"postgres","user":"x","safety":"stage"}}}'
  run require_writable_host_for_restore_into "staging"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "restore-into gate: succeeds silently on empty alias" {
  write_config '{"hosts":{}}'
  run require_writable_host_for_restore_into ""
  [ "$status" -eq 0 ]
}

# ----------------------------------------------------------------------------
# dbx config validate — shape check on the safety field
# ----------------------------------------------------------------------------

@test "dbx config validate: accepts safety=prod" {
  write_config '{"hosts":{"production":{"type":"postgres","user":"x","safety":"prod"}}}'
  run "$DBX_REPO_ROOT/dbx" config validate
  [ "$status" -eq 0 ]
  [[ "$output" != *"invalid 'safety' value"* ]]
}

@test "dbx config validate: accepts safety=stage" {
  write_config '{"hosts":{"staging":{"type":"postgres","user":"x","safety":"stage"}}}'
  run "$DBX_REPO_ROOT/dbx" config validate
  [ "$status" -eq 0 ]
  [[ "$output" != *"invalid 'safety' value"* ]]
}

@test "dbx config validate: accepts safety=local" {
  write_config '{"hosts":{"dev":{"type":"postgres","user":"x","safety":"local"}}}'
  run "$DBX_REPO_ROOT/dbx" config validate
  [ "$status" -eq 0 ]
  [[ "$output" != *"invalid 'safety' value"* ]]
}

@test "dbx config validate: accepts hosts with no safety field" {
  write_config '{"hosts":{"dev":{"type":"postgres","user":"x"}}}'
  run "$DBX_REPO_ROOT/dbx" config validate
  [ "$status" -eq 0 ]
  [[ "$output" != *"invalid 'safety' value"* ]]
}

@test "dbx config validate: flags safety=bogus" {
  write_config '{"hosts":{"oops":{"type":"postgres","user":"x","safety":"bogus"}}}'
  run "$DBX_REPO_ROOT/dbx" config validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid 'safety' value 'bogus'"* ]]
  [[ "$output" == *"prod, stage, local"* ]]
}

@test "dbx config validate: flags safety=production (typo, not 'prod')" {
  # The most likely typo. Hardcoded test because this is the exact
  # accident-mode we want to catch.
  write_config '{"hosts":{"oops":{"type":"postgres","user":"x","safety":"production"}}}'
  run "$DBX_REPO_ROOT/dbx" config validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid 'safety' value 'production'"* ]]
}

@test "dbx config validate: flags safety set to a non-string" {
  # JSON-shape oddity: someone hand-edits true/false or a number.
  write_config '{"hosts":{"oops":{"type":"postgres","user":"x","safety":true}}}'
  run "$DBX_REPO_ROOT/dbx" config validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid 'safety'"* ]]
}

# ----------------------------------------------------------------------------
# dbx restore --into refuses against prod-source backup
# ----------------------------------------------------------------------------

@test "dbx restore --into against prod-source backup is refused with a clear error" {
  # CLI integration test for the safety gate. Runs on both Linux and
  # macOS: `dbx`'s DATA_DIR-prefix check normalizes both sides via
  # `cd … && pwd -P` so the macOS `/tmp -> /private/tmp` symlink chain
  # no longer short-circuits the host/database extraction (and
  # therefore the safety check) when the source is given as an
  # absolute file path.
  mkdir -p "$DBX_DATA_DIR/production/myapp"
  : > "$DBX_DATA_DIR/production/myapp/myapp_20260524_120000.sql.zst"
  write_config '{"hosts":{"production":{"type":"postgres","user":"x","safety":"prod"}}}'

  run "$DBX_REPO_ROOT/dbx" restore production/myapp/latest --into some-sidecar-container
  [ "$status" -ne 0 ]
  [[ "$output" == *"safety=prod"* ]]
}

@test "dbx restore --into refuses prod-source backup via an absolute file path (regression: macOS BATS_TEST_TMPDIR symlinks)" {
  # The path-shape that used to short-circuit on macOS: source is an
  # absolute file path under DATA_DIR. Before the cd/pwd -P
  # normalization, the literal-string prefix check `$source ==
  # "$DATA_DIR"/*` failed because bats' BATS_TEST_TMPDIR resolves
  # through `/tmp -> /private/tmp`, so host/database parse skipped,
  # and the safety check (guarded by `-n "$host"`) never fired.
  mkdir -p "$DBX_DATA_DIR/production/myapp"
  local fake="$DBX_DATA_DIR/production/myapp/myapp_20260524_120000.sql.zst"
  : > "$fake"
  write_config '{"hosts":{"production":{"type":"postgres","user":"x","safety":"prod"}}}'

  run "$DBX_REPO_ROOT/dbx" restore "$fake" --into some-sidecar-container
  [ "$status" -ne 0 ]
  [[ "$output" == *"safety=prod"* ]]
}

@test "dbx restore --into against stage-source backup is allowed (gets past safety check)" {
  # We won't actually let the restore run (no docker / no real backup
  # content), so check that the failure is NOT the safety check — the
  # safety message is the distinguishing signal.
  mkdir -p "$DBX_DATA_DIR/staging/myapp"
  local fake="$DBX_DATA_DIR/staging/myapp/myapp_20260524_120000.sql.zst"
  : > "$fake"
  write_config '{"hosts":{"staging":{"type":"postgres","user":"x","safety":"stage"}}}'

  run "$DBX_REPO_ROOT/dbx" restore "$fake" --into some-sidecar-container
  # Failure expected (no docker / no real backup), but NOT the safety
  # refusal. Negative assertion is what's load-bearing here.
  [[ "$output" != *"safety=prod"* ]]
}
