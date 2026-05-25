#!/usr/bin/env bats
#
# Tests for the PII pre-scan helpers used by `dbx analyze`:
#   - scrub_pii_summary_tsv   (pure: schema JSON → TSV of pii candidates)
#   - scrub_pii_for_table     (pure: TSV lookup helper)
#
# These exercise PR-E end-to-end. The cmd_analyze integration runs in a
# subshell with the dbx script sourced (DBX_NO_AUTO_MAIN=1), with heavy
# external functions stubbed.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
}

# Run cmd_analyze in a fresh subshell with stubs for the docker / tunnel /
# password layers. The fake _scrub_query_live_schema_tsv returns a TSV the
# caller embeds via $1 SCHEMA_TSV.
analyze_subshell() {
  local schema_tsv="$1"; shift
  SCHEMA_TSV="$schema_tsv" bash -c '
    set -uo pipefail
    export DBX_DATA_DIR="'"$DBX_DATA_DIR"'"
    export DBX_CONFIG_DIR="'"$DBX_CONFIG_DIR"'"
    export DBX_AUDIT_DIR="'"$DBX_AUDIT_DIR"'"
    export DBX_NO_AUTO_MAIN=1
    # shellcheck source=/dev/null
    source "'"$DBX_BIN"'"
    # Replace heavy deps with stubs. Define AFTER sourcing so they win.
    require_docker() { :; }
    has_ssh_tunnel() { return 1; }
    create_ssh_tunnel() { :; }
    get_password() { printf ""; }
    analyze_postgres() { :; }
    analyze_mysql()    { :; }
    _scrub_query_live_schema_tsv() { printf "%s" "$SCHEMA_TSV"; }
    cmd_analyze "$@"
  ' bash "$@"
}

# ----------------------------------------------------------------------------
# scrub_pii_summary_tsv
# ----------------------------------------------------------------------------

@test "scrub_pii_summary_tsv: empty schema → empty output" {
  schema='{"tables":{}}'
  result=$(scrub_pii_summary_tsv "$schema")
  [ -z "$result" ]
}

@test "scrub_pii_summary_tsv: table with no PII candidates is omitted" {
  schema=$(printf 'orders\tid\tinteger\tNO\norders\ttotal\tnumeric\tNO\n' \
    | scrub_schema_tsv_to_json)
  result=$(scrub_pii_summary_tsv "$schema")
  [ -z "$result" ]
}

@test "scrub_pii_summary_tsv: flags dictionary-matching columns" {
  schema=$(printf 'users\temail\ttext\tYES\nusers\tid\tinteger\tNO\nusers\tphone\ttext\tYES\n' \
    | scrub_schema_tsv_to_json)
  result=$(scrub_pii_summary_tsv "$schema")
  [ "$result" = $'users\temail,phone' ]
}

@test "scrub_pii_summary_tsv: only matching tables appear" {
  schema=$(printf 'users\temail\ttext\tYES\norders\tid\tinteger\tNO\n' \
    | scrub_schema_tsv_to_json)
  result=$(scrub_pii_summary_tsv "$schema")
  line_count=$(printf '%s\n' "$result" | grep -c $'\t' || true)
  [ "$line_count" = "1" ]
  [[ "$result" == users$'\t'email ]]
}

@test "scrub_pii_summary_tsv: honors manifest dictionary.exclude" {
  schema=$(printf 'users\temail\ttext\tYES\n' | scrub_schema_tsv_to_json)
  manifest='{"dictionary":{"exclude":["mail","email"]}}'
  result=$(scrub_pii_summary_tsv "$schema" "$manifest")
  [ -z "$result" ]
}

@test "scrub_pii_summary_tsv: respects manifest dictionary.extend" {
  schema=$(printf 'users\tinternalcode\ttext\tYES\n' | scrub_schema_tsv_to_json)
  manifest='{"dictionary":{"extend":["internalcode"]}}'
  result=$(scrub_pii_summary_tsv "$schema" "$manifest")
  [ "$result" = $'users\tinternalcode' ]
}

# ----------------------------------------------------------------------------
# scrub_pii_for_table
# ----------------------------------------------------------------------------

@test "scrub_pii_for_table: returns candidates for matching row" {
  tsv=$'users\temail,phone\norders\taddress\n'
  result=$(scrub_pii_for_table "$tsv" "users")
  [ "$result" = "email,phone" ]
}

@test "scrub_pii_for_table: empty when table not present" {
  tsv=$'users\temail\n'
  result=$(scrub_pii_for_table "$tsv" "orders")
  [ -z "$result" ]
}

# ----------------------------------------------------------------------------
# cmd_analyze integration — exercises the PII summary surface.
# ----------------------------------------------------------------------------

@test "cmd_analyze: PII summary names the right tables and columns" {
  write_config '{"hosts":{"prod":{"type":"postgres","host":"127.0.0.1","port":5432,"user":"u"}}}'
  schema_tsv=$'users\temail\ttext\tYES\nusers\tid\tinteger\tNO\norders\tship_address\ttext\tYES\norders\ttotal\tnumeric\tNO\nproducts\tname\ttext\tYES\n'

  run analyze_subshell "$schema_tsv" prod app
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"users"*"email"* ]]
  [[ "$output" == *"orders"*"ship_address"* ]]
  # `products` has no dictionary match → no candidate line.
  [[ "$output" != *"products"*"candidate"* ]]
}

@test "cmd_analyze: no PII candidates → 'no dictionary matches' line" {
  write_config '{"hosts":{"prod":{"type":"postgres","host":"127.0.0.1","port":5432,"user":"u"}}}'
  schema_tsv=$'orders\tid\tinteger\tNO\norders\ttotal\tnumeric\tNO\n'

  run analyze_subshell "$schema_tsv" prod app
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no dictionary matches"* ]]
}

@test "cmd_analyze: --no-pii-scan suppresses the PII block" {
  write_config '{"hosts":{"prod":{"type":"postgres","host":"127.0.0.1","port":5432,"user":"u"}}}'
  schema_tsv=$'users\temail\ttext\tYES\n'

  run analyze_subshell "$schema_tsv" prod app --no-pii-scan
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"PII candidates"* ]]
  [[ "$output" != *"PII pre-scan"* ]]
}

@test "cmd_analyze: --suggest-scrub writes a draft manifest" {
  write_config '{"hosts":{"prod":{"type":"postgres","host":"127.0.0.1","port":5432,"user":"u"}}}'
  schema_tsv=$'users\temail\ttext\tYES\nusers\tid\tinteger\tNO\n'

  out_path="$BATS_TEST_TMPDIR/draft.scrub.json"
  run analyze_subshell "$schema_tsv" prod app --suggest-scrub --manifest-output "$out_path"
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  [ -f "$out_path" ]
  [ "$(jq -r '.version' "$out_path")" = "1" ]
  [ "$(jq -r '.tables.users.columns.email.strategy' "$out_path")" = "fake_email" ]
}
