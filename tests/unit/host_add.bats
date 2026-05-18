#!/usr/bin/env bats
load '../helpers/common'
setup() { setup_dbx_env; source_dbx_libs; }

@test "host_alias_valid: accepts typical aliases" {
  host_alias_valid "production"
  host_alias_valid "prod-east-1"
  host_alias_valid "db_2"
  host_alias_valid "MixedCase"
  host_alias_valid "a"
}

@test "host_alias_valid: accepts trailing dash or underscore (documenting intent)" {
  host_alias_valid "prod-"
  host_alias_valid "prod_"
}

@test "host_alias_valid: rejects empty string" {
  run host_alias_valid ""
  [ "$status" -ne 0 ]
}

@test "host_alias_valid: rejects leading dash" {
  run host_alias_valid "-prod"
  [ "$status" -ne 0 ]
}

@test "host_alias_valid: rejects leading underscore" {
  run host_alias_valid "_prod"
  [ "$status" -ne 0 ]
}

@test "host_alias_valid: rejects whitespace" {
  run host_alias_valid "with space"
  [ "$status" -ne 0 ]
}

@test "host_alias_valid: rejects slash" {
  run host_alias_valid "with/slash"
  [ "$status" -ne 0 ]
}

@test "host_alias_valid: rejects dot" {
  run host_alias_valid "prod.east"
  [ "$status" -ne 0 ]
}

@test "host_alias_valid: rejects shell metachars" {
  run host_alias_valid "prod;rm"
  [ "$status" -ne 0 ]
  run host_alias_valid 'prod$x'
  [ "$status" -ne 0 ]
  run host_alias_valid 'prod`x`'
  [ "$status" -ne 0 ]
}

@test "host_exists: false when config has no such host" {
  cat > "$CONFIG_FILE" <<'JSON'
{"hosts": {"alpha": {"type": "postgres", "user": "u"}}}
JSON
  run host_exists "beta"
  [ "$status" -ne 0 ]
}

@test "host_exists: true when host is present" {
  cat > "$CONFIG_FILE" <<'JSON'
{"hosts": {"alpha": {"type": "postgres", "user": "u"}}}
JSON
  run host_exists "alpha"
  [ "$status" -eq 0 ]
}

@test "host_exists: false when hosts key missing entirely" {
  echo '{}' > "$CONFIG_FILE"
  run host_exists "alpha"
  [ "$status" -ne 0 ]
}

@test "dbx host (no action) prints usage" {
  run "$DBX_BIN" host
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Usage: dbx host" ]]
}

@test "dbx host bogus errors with unknown-action" {
  run "$DBX_BIN" host bogus
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Unknown host action: bogus" ]]
}

@test "dbx host remove errors with not-yet-implemented" {
  run "$DBX_BIN" host remove
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not yet implemented" ]]
}

@test "dbx host add: empty alias aborts cleanly" {
  command -v gum >/dev/null 2>&1 || skip "gum not installed"
  echo '{"hosts":{}}' > "$CONFIG_FILE"
  run bash -c "echo '' | '$DBX_BIN' host add"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Aborted" ]]
}

@test "dbx help mentions host add" {
  run "$DBX_BIN" help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "host add" ]]
}
