#!/usr/bin/env bats
#
# Tests for lib/scrub.sh — pure helpers (manifest accessors, dictionary
# matching, manifest validation). No docker, no engine queries.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
}

# ----------------------------------------------------------------------------
# scrub_manifest_path / scrub_manifest_exists / scrub_read_manifest
# ----------------------------------------------------------------------------

@test "scrub_manifest_path: empty when host has no scrub block" {
  write_config '{"hosts":{"prod":{"type":"postgres"}}}'
  result=$(scrub_manifest_path "prod")
  [ -z "$result" ]
}

@test "scrub_manifest_path: absolute path returned unchanged" {
  write_config '{"hosts":{"prod":{"scrub":{"manifest":"/tmp/foo.json"}}}}'
  result=$(scrub_manifest_path "prod")
  [ "$result" = "/tmp/foo.json" ]
}

@test "scrub_manifest_path: relative path resolved against config dir" {
  write_config '{"hosts":{"prod":{"scrub":{"manifest":"dbx.scrub.json"}}}}'
  result=$(scrub_manifest_path "prod")
  [ "$result" = "$DBX_CONFIG_DIR/dbx.scrub.json" ]
}

@test "scrub_manifest_exists: false when not configured" {
  write_config '{"hosts":{"prod":{}}}'
  ! scrub_manifest_exists "prod"
}

@test "scrub_manifest_exists: false when configured but file missing" {
  write_config '{"hosts":{"prod":{"scrub":{"manifest":"missing.json"}}}}'
  ! scrub_manifest_exists "prod"
}

@test "scrub_manifest_exists: true when configured and file present" {
  echo '{"version":1,"tables":{}}' > "$DBX_CONFIG_DIR/dbx.scrub.json"
  write_config '{"hosts":{"prod":{"scrub":{"manifest":"dbx.scrub.json"}}}}'
  scrub_manifest_exists "prod"
}

@test "scrub_read_manifest: returns {} when missing" {
  write_config '{"hosts":{"prod":{}}}'
  result=$(scrub_read_manifest "prod")
  [ "$result" = "{}" ]
}

@test "scrub_read_manifest: returns parsed JSON when present" {
  printf '{"version":1,"tables":{"users":{"no_pii":true,"reason":"none"}}}\n' \
    > "$DBX_CONFIG_DIR/dbx.scrub.json"
  write_config '{"hosts":{"prod":{"scrub":{"manifest":"dbx.scrub.json"}}}}'
  result=$(scrub_read_manifest "prod")
  [ "$(jq -r '.version' <<<"$result")" = "1" ]
  [ "$(jq -r '.tables.users.no_pii' <<<"$result")" = "true" ]
}

# ----------------------------------------------------------------------------
# scrub_get_strategy / scrub_table_no_pii
# ----------------------------------------------------------------------------

@test "scrub_get_strategy: returns strategy entry for declared column" {
  printf '{"version":1,"tables":{"users":{"columns":{"email":{"strategy":"fake_email"}}}}}\n' \
    > "$DBX_CONFIG_DIR/dbx.scrub.json"
  write_config '{"hosts":{"prod":{"scrub":{"manifest":"dbx.scrub.json"}}}}'
  result=$(scrub_get_strategy "prod" "users" "email")
  [ "$(jq -r '.strategy' <<<"$result")" = "fake_email" ]
}

@test "scrub_get_strategy: empty for undeclared column" {
  printf '{"version":1,"tables":{"users":{"columns":{"email":{"strategy":"fake_email"}}}}}\n' \
    > "$DBX_CONFIG_DIR/dbx.scrub.json"
  write_config '{"hosts":{"prod":{"scrub":{"manifest":"dbx.scrub.json"}}}}'
  result=$(scrub_get_strategy "prod" "users" "phone")
  [ -z "$result" ]
}

@test "scrub_table_no_pii: true when marked" {
  printf '{"version":1,"tables":{"audit":{"no_pii":true,"reason":"FKs only"}}}\n' \
    > "$DBX_CONFIG_DIR/dbx.scrub.json"
  write_config '{"hosts":{"prod":{"scrub":{"manifest":"dbx.scrub.json"}}}}'
  scrub_table_no_pii "prod" "audit"
}

@test "scrub_table_no_pii: false when not marked" {
  printf '{"version":1,"tables":{"users":{"columns":{"email":{"strategy":"fake_email"}}}}}\n' \
    > "$DBX_CONFIG_DIR/dbx.scrub.json"
  write_config '{"hosts":{"prod":{"scrub":{"manifest":"dbx.scrub.json"}}}}'
  ! scrub_table_no_pii "prod" "users"
}

@test "scrub_table_no_pii: false when table not in manifest" {
  printf '{"version":1,"tables":{}}\n' > "$DBX_CONFIG_DIR/dbx.scrub.json"
  write_config '{"hosts":{"prod":{"scrub":{"manifest":"dbx.scrub.json"}}}}'
  ! scrub_table_no_pii "prod" "nope"
}

# ----------------------------------------------------------------------------
# scrub_seed_value
# ----------------------------------------------------------------------------

@test "scrub_seed_value: empty when manifest has no seed_env" {
  printf '{"version":1,"tables":{}}\n' > "$DBX_CONFIG_DIR/dbx.scrub.json"
  write_config '{"hosts":{"prod":{"scrub":{"manifest":"dbx.scrub.json"}}}}'
  result=$(scrub_seed_value "prod")
  [ -z "$result" ]
}

@test "scrub_seed_value: reads from declared env var" {
  printf '{"version":1,"seed_env":"DBX_TEST_SEED_42","tables":{}}\n' \
    > "$DBX_CONFIG_DIR/dbx.scrub.json"
  write_config '{"hosts":{"prod":{"scrub":{"manifest":"dbx.scrub.json"}}}}'
  DBX_TEST_SEED_42="my-secret-salt" result=$(DBX_TEST_SEED_42="my-secret-salt" scrub_seed_value "prod")
  [ "$result" = "my-secret-salt" ]
}

@test "scrub_seed_value: empty when env var unset" {
  printf '{"version":1,"seed_env":"DBX_TEST_SEED_UNSET","tables":{}}\n' \
    > "$DBX_CONFIG_DIR/dbx.scrub.json"
  write_config '{"hosts":{"prod":{"scrub":{"manifest":"dbx.scrub.json"}}}}'
  unset DBX_TEST_SEED_UNSET
  result=$(scrub_seed_value "prod")
  [ -z "$result" ]
}

# ----------------------------------------------------------------------------
# scrub_required_for / scrub_destination_required
# ----------------------------------------------------------------------------

@test "scrub_required_for: empty when no required_for set" {
  write_config '{"hosts":{"prod":{"scrub":{"manifest":"x.json"}}}}'
  result=$(scrub_required_for "prod")
  [ -z "$result" ]
}

@test "scrub_required_for: lists each destination" {
  write_config '{"hosts":{"prod":{"scrub":{"required_for":["staging","local"]}}}}'
  result=$(scrub_required_for "prod")
  expected="staging
local"
  [ "$result" = "$expected" ]
}

@test "scrub_destination_required: true when in list" {
  write_config '{"hosts":{"prod":{"scrub":{"required_for":["staging","local"]}}}}'
  scrub_destination_required "prod" "staging"
}

@test "scrub_destination_required: false when not in list" {
  write_config '{"hosts":{"prod":{"scrub":{"required_for":["staging","local"]}}}}'
  ! scrub_destination_required "prod" "replica"
}

@test "scrub_destination_required: false when nothing configured" {
  write_config '{"hosts":{"prod":{}}}'
  ! scrub_destination_required "prod" "staging"
}

# ----------------------------------------------------------------------------
# scrub_normalize_col
# ----------------------------------------------------------------------------

@test "scrub_normalize_col: lowercases" {
  result=$(scrub_normalize_col "Email")
  [ "$result" = "email" ]
}

@test "scrub_normalize_col: strips underscores" {
  result=$(scrub_normalize_col "first_name")
  [ "$result" = "firstname" ]
}

@test "scrub_normalize_col: strips dashes" {
  result=$(scrub_normalize_col "first-name")
  [ "$result" = "firstname" ]
}

@test "scrub_normalize_col: combined: case + underscores + dashes" {
  result=$(scrub_normalize_col "Backup_Email-Address")
  [ "$result" = "backupemailaddress" ]
}

@test "scrub_normalize_col: digits pass through" {
  result=$(scrub_normalize_col "address_line_1")
  [ "$result" = "addressline1" ]
}

# ----------------------------------------------------------------------------
# scrub_dict_default_patterns / scrub_dict_effective
# ----------------------------------------------------------------------------

@test "scrub_dict_default_patterns: contains common email/phone patterns" {
  result=$(scrub_dict_default_patterns)
  echo "$result" | grep -q "^email:fake_email$"
  echo "$result" | grep -q "^phone:fake_phone$"
  echo "$result" | grep -q "^ssn:redact$"
  echo "$result" | grep -q "^dob:shift_date:30$"
}

@test "scrub_dict_effective: default patterns flow through when no extend/exclude" {
  result=$(scrub_dict_effective "{}")
  echo "$result" | grep -q "^email:fake_email$"
  echo "$result" | grep -q "^phone:fake_phone$"
}

@test "scrub_dict_effective: extend adds patterns (bare pattern defaults to redact)" {
  result=$(scrub_dict_effective '{"dictionary":{"extend":["mrn","custom:fake_email"]}}')
  echo "$result" | grep -q "^mrn:redact$"
  echo "$result" | grep -q "^custom:fake_email$"
}

@test "scrub_dict_effective: exclude removes patterns" {
  result=$(scrub_dict_effective '{"dictionary":{"exclude":["address"]}}')
  ! echo "$result" | grep -q "^address:"
  # but other patterns survive
  echo "$result" | grep -q "^email:fake_email$"
}

# ----------------------------------------------------------------------------
# scrub_dict_matches / scrub_dict_suggested
# ----------------------------------------------------------------------------

@test "scrub_dict_matches: exact match (email)" {
  result=$(scrub_dict_matches "email" "{}")
  [ "$result" = "email" ]
}

@test "scrub_dict_matches: case-insensitive (EMAIL)" {
  result=$(scrub_dict_matches "EMAIL" "{}")
  [ "$result" = "email" ]
}

@test "scrub_dict_matches: substring match (backup_email)" {
  result=$(scrub_dict_matches "backup_email" "{}")
  [ "$result" = "email" ]
}

@test "scrub_dict_matches: substring match (recovery-phone)" {
  result=$(scrub_dict_matches "recovery-phone" "{}")
  [ "$result" = "phone" ]
}

@test "scrub_dict_matches: dob shift_date" {
  result=$(scrub_dict_matches "date_of_birth" "{}")
  [ "$result" = "dateofbirth" ]
}

@test "scrub_dict_matches: no match returns empty" {
  result=$(scrub_dict_matches "widget_count" "{}")
  [ -z "$result" ]
}

@test "scrub_dict_matches: excluded pattern no longer matches" {
  # The default dictionary has both `address` and `addr` (so the
  # short-form column name `addr_line_1` is detected). Excluding only
  # `address` still leaves `addr` available to fire. Suppressing the
  # match on `shipping_address` requires excluding both — this is the
  # observable contract for `dictionary.exclude`.
  result=$(scrub_dict_matches "shipping_address" '{"dictionary":{"exclude":["address","addr"]}}')
  [ -z "$result" ]
}

@test "scrub_dict_matches: excluding one of two overlapping patterns still matches the other" {
  # Documenting the partial-exclude behavior: excluding `address` alone
  # falls through to `addr`. Catches accidental complacency.
  result=$(scrub_dict_matches "shipping_address" '{"dictionary":{"exclude":["address"]}}')
  [ "$result" = "addr" ]
}

@test "scrub_dict_matches: extended pattern matches" {
  result=$(scrub_dict_matches "patient_mrn_id" '{"dictionary":{"extend":["mrn"]}}')
  [ "$result" = "mrn" ]
}

@test "scrub_dict_suggested: returns strategy for known pattern" {
  result=$(scrub_dict_suggested "email" "{}")
  [ "$(jq -r '.strategy' <<<"$result")" = "fake_email" ]
}

@test "scrub_dict_suggested: shift_date includes max_days param" {
  result=$(scrub_dict_suggested "dob" "{}")
  [ "$(jq -r '.strategy' <<<"$result")" = "shift_date" ]
  [ "$(jq -r '.max_days' <<<"$result")" = "30" ]
}

@test "scrub_dict_suggested: unknown pattern returns empty" {
  result=$(scrub_dict_suggested "nope" "{}")
  [ -z "$result" ]
}

# ----------------------------------------------------------------------------
# scrub_strategy_known
# ----------------------------------------------------------------------------

@test "scrub_strategy_known: accepts all canonical names" {
  for s in fake_email fake_phone fake_ip fake_name redact truncate shift_date passthrough jsonb_scrub_paths; do
    scrub_strategy_known "$s"
  done
}

@test "scrub_strategy_known: rejects unknown name" {
  ! scrub_strategy_known "fake_widget"
}

@test "scrub_strategy_known: rejects empty" {
  ! scrub_strategy_known ""
}

# ----------------------------------------------------------------------------
# scrub_validate_manifest — happy path + each error path
# ----------------------------------------------------------------------------

# Helper: write a manifest, return path.
_write_manifest() {
  local content="$1"
  local path="$DBX_CONFIG_DIR/dbx.scrub.json"
  printf '%s\n' "$content" > "$path"
  printf '%s' "$path"
}

@test "scrub_validate_manifest: happy path (no_pii table + columns table)" {
  mf=$(_write_manifest '{
    "version": 1,
    "seed_env": "DBX_SCRUB_SEED",
    "tables": {
      "users": { "columns": { "email": {"strategy":"fake_email"} } },
      "audit": { "no_pii": true, "reason": "no PII" }
    }
  }')
  run scrub_validate_manifest "$mf"
  [ "$status" -eq 0 ]
}

@test "scrub_validate_manifest: missing file is an error" {
  run scrub_validate_manifest "/tmp/does-not-exist-$$.json"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "not found"
}

@test "scrub_validate_manifest: invalid JSON is an error" {
  mf="$DBX_CONFIG_DIR/dbx.scrub.json"
  printf 'not-json\n' > "$mf"
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "not valid JSON"
}

@test "scrub_validate_manifest: missing version is an error" {
  mf=$(_write_manifest '{"tables":{"users":{"no_pii":true,"reason":"x"}}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "missing required field 'version'"
}

@test "scrub_validate_manifest: unsupported version is an error" {
  mf=$(_write_manifest '{"version":"2","tables":{}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "unsupported version"
}

@test "scrub_validate_manifest: missing tables is an error" {
  mf=$(_write_manifest '{"version":1}')
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "missing required field 'tables'"
}

@test "scrub_validate_manifest: empty seed_env is an error" {
  mf=$(_write_manifest '{"version":1,"seed_env":"","tables":{}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "seed_env is set but empty"
}

@test "scrub_validate_manifest: malformed seed_env (lowercase) is an error" {
  mf=$(_write_manifest '{"version":1,"seed_env":"bad-name","tables":{}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "not a valid env-var name"
}

@test "scrub_validate_manifest: dictionary.extend non-array is an error" {
  mf=$(_write_manifest '{"version":1,"dictionary":{"extend":"oops"},"tables":{}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "dictionary.extend must be an array"
}

@test "scrub_validate_manifest: no_pii table without reason is an error" {
  mf=$(_write_manifest '{"version":1,"tables":{"audit":{"no_pii":true}}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "no_pii=true but no 'reason'"
}

@test "scrub_validate_manifest: no_pii table with columns is an error" {
  mf=$(_write_manifest '{"version":1,"tables":{"users":{"no_pii":true,"reason":"x","columns":{"email":{"strategy":"fake_email"}}}}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "mutually exclusive"
}

@test "scrub_validate_manifest: table with neither no_pii nor columns is an error" {
  mf=$(_write_manifest '{"version":1,"tables":{"users":{}}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "neither no_pii=true nor a 'columns'"
}

@test "scrub_validate_manifest: column missing strategy is an error" {
  mf=$(_write_manifest '{"version":1,"tables":{"users":{"columns":{"email":{"reason":"x"}}}}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "missing 'strategy'"
}

@test "scrub_validate_manifest: unknown strategy is an error" {
  mf=$(_write_manifest '{"version":1,"tables":{"users":{"columns":{"email":{"strategy":"hocus_pocus"}}}}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "unknown strategy"
}

@test "scrub_validate_manifest: truncate without length is an error" {
  mf=$(_write_manifest '{"version":1,"tables":{"t":{"columns":{"body":{"strategy":"truncate"}}}}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "truncate.*requires positive integer 'length'"
}

@test "scrub_validate_manifest: truncate with zero length is an error" {
  mf=$(_write_manifest '{"version":1,"tables":{"t":{"columns":{"body":{"strategy":"truncate","length":0}}}}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
}

@test "scrub_validate_manifest: shift_date without max_days is an error" {
  mf=$(_write_manifest '{"version":1,"tables":{"u":{"columns":{"dob":{"strategy":"shift_date"}}}}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "shift_date.*requires positive integer 'max_days'"
}

@test "scrub_validate_manifest: jsonb_scrub_paths without paths object is an error" {
  mf=$(_write_manifest '{"version":1,"tables":{"u":{"columns":{"prefs":{"strategy":"jsonb_scrub_paths"}}}}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "requires 'paths' object"
}

@test "scrub_validate_manifest: jsonb_scrub_paths with empty paths is an error" {
  mf=$(_write_manifest '{"version":1,"tables":{"u":{"columns":{"prefs":{"strategy":"jsonb_scrub_paths","paths":{}}}}}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "empty 'paths' object"
}

@test "scrub_validate_manifest: jsonb_scrub_paths with unknown sub-strategy is an error" {
  mf=$(_write_manifest '{"version":1,"tables":{"u":{"columns":{"prefs":{"strategy":"jsonb_scrub_paths","paths":{"$.x":"hocus_pocus"}}}}}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "unknown sub-strategy"
}

@test "scrub_validate_manifest: jsonb_scrub_paths nested is an error" {
  mf=$(_write_manifest '{"version":1,"tables":{"u":{"columns":{"prefs":{"strategy":"jsonb_scrub_paths","paths":{"$.x":"jsonb_scrub_paths"}}}}}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "cannot nest jsonb_scrub_paths"
}

@test "scrub_validate_manifest: passthrough without reason is an error" {
  mf=$(_write_manifest '{"version":1,"tables":{"u":{"columns":{"password_hash":{"strategy":"passthrough"}}}}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "passthrough.*requires 'reason'"
}

@test "scrub_validate_manifest: passthrough WITH reason is OK" {
  mf=$(_write_manifest '{"version":1,"tables":{"u":{"columns":{"password_hash":{"strategy":"passthrough","reason":"opaque"}}}}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -eq 0 ]
}

@test "scrub_validate_manifest: redact with optional string replacement is OK" {
  mf=$(_write_manifest '{"version":1,"tables":{"u":{"columns":{"name":{"strategy":"redact","replacement":""}}}}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -eq 0 ]
}

@test "scrub_validate_manifest: redact with non-string replacement is an error" {
  mf=$(_write_manifest '{"version":1,"tables":{"u":{"columns":{"name":{"strategy":"redact","replacement":123}}}}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "non-string 'replacement'"
}

@test "scrub_validate_manifest: jsonb_scrub_paths path with SQL injection is rejected" {
  # A malicious manifest editor could try to escape the SQL string literal
  # via a path key like `$.x'); DROP TABLE users; --`. The path-key
  # regex must reject anything outside `$.identifier.identifier...`.
  mf=$(_write_manifest "$(cat <<'EOF'
{"version":1,"tables":{"u":{"columns":{"p":{"strategy":"jsonb_scrub_paths","paths":{"$.x'); DROP TABLE users; --":"redact"}}}}}}
EOF
)")
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "invalid path"
}

@test "scrub_validate_manifest: jsonb_scrub_paths path with array index is rejected" {
  mf=$(_write_manifest '{"version":1,"tables":{"u":{"columns":{"p":{"strategy":"jsonb_scrub_paths","paths":{"$.x[0].y":"redact"}}}}}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "invalid path"
}

@test "scrub_validate_manifest: jsonb_scrub_paths path missing leading \$ is rejected" {
  mf=$(_write_manifest '{"version":1,"tables":{"u":{"columns":{"p":{"strategy":"jsonb_scrub_paths","paths":{".foo.bar":"redact"}}}}}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -ne 0 ]
}

@test "scrub_validate_manifest: jsonb_scrub_paths happy path" {
  mf=$(_write_manifest '{"version":1,"tables":{"u":{"columns":{"prefs":{"strategy":"jsonb_scrub_paths","paths":{"$.contact.email":"fake_email","$.contact.phone":"fake_phone"}}}}}}')
  run scrub_validate_manifest "$mf"
  [ "$status" -eq 0 ]
}

# ----------------------------------------------------------------------------
# scrub_gate_active — host-wide gate activation
# ----------------------------------------------------------------------------

@test "scrub_gate_active: false when no manifest configured" {
  write_config '{"hosts":{"prod":{"scrub":{"required":true}}}}'
  ! scrub_gate_active "prod"
}

@test "scrub_gate_active: false when manifest present but neither required nor required_for set" {
  echo '{"version":1,"tables":{}}' > "$DBX_CONFIG_DIR/dbx.scrub.json"
  write_config '{"hosts":{"prod":{"scrub":{"manifest":"dbx.scrub.json"}}}}'
  ! scrub_gate_active "prod"
}

@test "scrub_gate_active: true when scrub.required is true" {
  echo '{"version":1,"tables":{}}' > "$DBX_CONFIG_DIR/dbx.scrub.json"
  write_config '{"hosts":{"prod":{"scrub":{"manifest":"dbx.scrub.json","required":true}}}}'
  scrub_gate_active "prod"
}

@test "scrub_gate_active: true when required_for is a non-empty array (no required)" {
  echo '{"version":1,"tables":{}}' > "$DBX_CONFIG_DIR/dbx.scrub.json"
  write_config '{"hosts":{"prod":{"scrub":{"manifest":"dbx.scrub.json","required_for":["staging"]}}}}'
  scrub_gate_active "prod"
}

@test "scrub_gate_active: false when required_for is an empty array and required absent" {
  echo '{"version":1,"tables":{}}' > "$DBX_CONFIG_DIR/dbx.scrub.json"
  write_config '{"hosts":{"prod":{"scrub":{"manifest":"dbx.scrub.json","required_for":[]}}}}'
  ! scrub_gate_active "prod"
}
