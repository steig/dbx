#!/usr/bin/env bats
#
# Tests for `dbx scrub init/check local/<db>` — running scrub commands
# against a database that lives inside a managed container instead of a
# configured host.
#
# These are HELPER-LEVEL unit tests. The actual container detection is
# stubbed; what we verify is:
#   1. scrub_is_local_host detects `local` / `localhost`
#   2. _parse_scrub_target accepts `local/<db>`
#   3. scrub_local_schema_tsv dies cleanly when the db isn't anywhere
#   4. scrub_local_schema_tsv picks postgres when the db is there
#   5. scrub_local_schema_tsv picks mysql when only mysql has it
#   6. scrub_local_schema_tsv prefers postgres when both have it
#   7. _cmd_scrub_init rejects non-local hosts without config
#   8. _cmd_scrub_init runs against local/<db> with no host config
#   9. _cmd_scrub_check local/<db> requires --manifest
#  10. _cmd_scrub_check local/<db> with --manifest reads from that path

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
}

# ----------------------------------------------------------------------------
# scrub_is_local_host
# ----------------------------------------------------------------------------

@test "scrub_is_local_host: matches 'local'" {
  scrub_is_local_host "local"
}

@test "scrub_is_local_host: matches 'localhost'" {
  scrub_is_local_host "localhost"
}

@test "scrub_is_local_host: rejects other hosts" {
  ! scrub_is_local_host "prod"
  ! scrub_is_local_host "stage"
  ! scrub_is_local_host ""
  ! scrub_is_local_host "Local"  # case-sensitive on purpose
}

# ----------------------------------------------------------------------------
# scrub_local_schema_tsv dispatch — fakes scrub_local_db_engine and the
# downstream local schema-query helpers.
# ----------------------------------------------------------------------------

@test "scrub_local_schema_tsv: dies when db is in neither container" {
  scrub_local_db_engine() { printf ""; }
  scrub_schema_query_pg_local()    { echo "PG-CALLED $*"; }
  scrub_schema_query_mysql_local() { echo "MYSQL-CALLED $*"; }
  export -f scrub_local_db_engine scrub_schema_query_pg_local scrub_schema_query_mysql_local

  run scrub_local_schema_tsv "missing"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "scrub_local_schema_tsv: routes to postgres when engine=postgres" {
  scrub_local_db_engine() { printf "postgres\n"; }
  scrub_schema_query_pg_local()    { echo "PG-CALLED $*"; }
  scrub_schema_query_mysql_local() { echo "MYSQL-CALLED $*"; }
  export -f scrub_local_db_engine scrub_schema_query_pg_local scrub_schema_query_mysql_local

  result=$(scrub_local_schema_tsv "myapp_v1")
  [ "$result" = "PG-CALLED myapp_v1" ]
}

@test "scrub_local_schema_tsv: routes to mysql when engine=mysql" {
  scrub_local_db_engine() { printf "mysql\n"; }
  scrub_schema_query_pg_local()    { echo "PG-CALLED $*"; }
  scrub_schema_query_mysql_local() { echo "MYSQL-CALLED $*"; }
  export -f scrub_local_db_engine scrub_schema_query_pg_local scrub_schema_query_mysql_local

  result=$(scrub_local_schema_tsv "myapp_v1")
  [ "$result" = "MYSQL-CALLED myapp_v1" ]
}

# ----------------------------------------------------------------------------
# _parse_scrub_target accepts local/<db>
# ----------------------------------------------------------------------------

# _parse_scrub_target lives in `dbx` (top-level script). Source it via the
# DBX_NO_AUTO_MAIN gate.
@test "_parse_scrub_target: accepts local/<db>" {
  DBX_NO_AUTO_MAIN=1 source "$DBX_BIN"
  { read -r host; read -r db; } < <(_parse_scrub_target "local/myapp_v1")
  [ "$host" = "local" ]
  [ "$db" = "myapp_v1" ]
}

@test "_parse_scrub_target: accepts localhost/<db>" {
  DBX_NO_AUTO_MAIN=1 source "$DBX_BIN"
  { read -r host; read -r db; } < <(_parse_scrub_target "localhost/mydb")
  [ "$host" = "localhost" ]
  [ "$db" = "mydb" ]
}

# ----------------------------------------------------------------------------
# _cmd_scrub_init local/<db> — runs without host config
# ----------------------------------------------------------------------------

# Run _cmd_scrub_init in a subshell with stubs.
scrub_init_subshell() {
  bash -c '
    set -uo pipefail
    export DBX_DATA_DIR="'"$DBX_DATA_DIR"'"
    export DBX_CONFIG_DIR="'"$DBX_CONFIG_DIR"'"
    export DBX_AUDIT_DIR="'"$DBX_AUDIT_DIR"'"
    export DBX_NO_AUTO_MAIN=1
    # shellcheck source=/dev/null
    source "'"$DBX_BIN"'"
    require_docker() { :; }
    require_jq()     { :; }
    require_config() { :; }
    # Capture which engine path the helpers think we should take, then
    # fake the schema query. Tests can override these.
    scrub_local_db_engine()          { printf "%s\n" "${FAKE_ENGINE-postgres}"; }
    scrub_schema_query_pg_local()    { printf "users\temail\ttext\tYES\nusers\tid\tinteger\tNO\n"; }
    scrub_schema_query_mysql_local() { printf "users\temail\tvarchar(255)\tYES\nusers\tid\tint\tNO\n"; }
    scrub_schema_query_pg()          { echo "REMOTE-PG NOT EXPECTED"; return 1; }
    scrub_schema_query_mysql()       { echo "REMOTE-MYSQL NOT EXPECTED"; return 1; }
    _cmd_scrub_init "$@"
  ' bash "$@"
}

@test "_cmd_scrub_init local/<db>: produces a draft manifest (postgres-routed)" {
  # No config.json is created — local mode must not require it.
  out_path="$BATS_TEST_TMPDIR/draft.scrub.json"
  FAKE_ENGINE=postgres run scrub_init_subshell local/myapp_v1 --output "$out_path"
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  [ -f "$out_path" ]
  [ "$(jq -r '.tables.users.columns.email.strategy' "$out_path")" = "fake_email" ]
}

@test "_cmd_scrub_init local/<db>: produces a draft manifest (mysql-routed)" {
  out_path="$BATS_TEST_TMPDIR/draft.scrub.json"
  FAKE_ENGINE=mysql run scrub_init_subshell local/myapp_v1 --output "$out_path"
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  [ -f "$out_path" ]
  [ "$(jq -r '.tables.users.columns.email.strategy' "$out_path")" = "fake_email" ]
}

@test "_cmd_scrub_init local/<db>: dies clearly when db isn't in any container" {
  FAKE_ENGINE="" run scrub_init_subshell local/missing --output "$BATS_TEST_TMPDIR/x.json"
  echo "OUT: $output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

# ----------------------------------------------------------------------------
# _cmd_scrub_check local/<db>
# ----------------------------------------------------------------------------

scrub_check_subshell() {
  bash -c '
    set -uo pipefail
    export DBX_DATA_DIR="'"$DBX_DATA_DIR"'"
    export DBX_CONFIG_DIR="'"$DBX_CONFIG_DIR"'"
    export DBX_AUDIT_DIR="'"$DBX_AUDIT_DIR"'"
    export DBX_NO_AUTO_MAIN=1
    # shellcheck source=/dev/null
    source "'"$DBX_BIN"'"
    require_docker() { :; }
    require_jq()     { :; }
    require_config() { :; }
    scrub_local_db_engine()          { printf "%s\n" "${FAKE_ENGINE-postgres}"; }
    scrub_schema_query_pg_local()    { printf "users\temail\ttext\tYES\n"; }
    scrub_schema_query_mysql_local() { printf "users\temail\tvarchar(255)\tYES\n"; }
    _cmd_scrub_check "$@"
  ' bash "$@"
}

@test "_cmd_scrub_check local/<db>: rejects when --manifest is missing" {
  run scrub_check_subshell local/myapp_v1
  echo "OUT: $output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--manifest"* ]]
}

@test "_cmd_scrub_check local/<db>: rejects when --manifest file is missing" {
  run scrub_check_subshell local/myapp_v1 --manifest "$BATS_TEST_TMPDIR/missing.json"
  echo "OUT: $output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "_cmd_scrub_check local/<db>: clean when manifest covers schema" {
  # Schema = one matching column. Manifest declares it with a strategy →
  # check should be clean (exit 0).
  mf="$BATS_TEST_TMPDIR/dbx.scrub.json"
  cat > "$mf" <<'EOF'
{
  "version": 1,
  "tables": {
    "users": {
      "columns": {
        "email": { "strategy": "fake_email" }
      }
    }
  }
}
EOF

  FAKE_ENGINE=postgres run scrub_check_subshell local/myapp_v1 --manifest "$mf"
  echo "OUT: $output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no drift"* ]]
}

@test "_cmd_scrub_check local/<db>: drift exit code on undeclared PII" {
  # Manifest declares no tables → email column is undeclared drift.
  mf="$BATS_TEST_TMPDIR/dbx.scrub.json"
  printf '{"version":1,"tables":{}}\n' > "$mf"

  FAKE_ENGINE=postgres run scrub_check_subshell local/myapp_v1 --manifest "$mf"
  echo "OUT: $output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"DRIFT"* ]]
}

# ----------------------------------------------------------------------------
# scrub help mentions local/<db>
# ----------------------------------------------------------------------------

@test "dbx scrub --help mentions local/<db>" {
  run "$DBX_BIN" scrub --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"local"* ]]
  [[ "$output" == *"local/myapp_v1"* ]] || [[ "$output" == *"'local'"* ]]
}
