#!/usr/bin/env bats
#
# Tests for the pure helpers in lib/postgres.sh (#148) — the ones that need
# neither a live database nor docker: psql `-v` flag assembly, the
# exclude_dependents precedence resolver, and the config-driven extension
# package escape hatch.
#
# The FK closure helpers, the globals helpers and pg_parse_server_version_num
# already have their own files (fk_closure.bats, pg_globals.bats,
# version_parsing.bats) and are not repeated here.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
}

# ---------------------------------------------------------------------------
# pg_build_psql_var_flags — kv pairs to psql -v flags, one arg per line
# ---------------------------------------------------------------------------

@test "pg_build_psql_var_flags: no args emits nothing" {
  run pg_build_psql_var_flags
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pg_build_psql_var_flags: a kv pair becomes two lines (-v, then key=value)" {
  run pg_build_psql_var_flags "target_db=app_stage"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "-v" ]
  [ "${lines[1]}" = "target_db=app_stage" ]
}

@test "pg_build_psql_var_flags: pairs keep input order" {
  run pg_build_psql_var_flags "a=1" "b=2" "c=3"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 6 ]
  [ "${lines[1]}" = "a=1" ]
  [ "${lines[3]}" = "b=2" ]
  [ "${lines[5]}" = "c=3" ]
}

@test "pg_build_psql_var_flags: args without '=' are skipped" {
  run pg_build_psql_var_flags "bare" "a=1" "also-bare"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "a=1" ]
}

@test "pg_build_psql_var_flags: a value containing '=' passes through whole" {
  run pg_build_psql_var_flags "dsn=host=db port=5432"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "dsn=host=db port=5432" ]
}

@test "pg_build_psql_var_flags: an empty value still yields a flag" {
  run pg_build_psql_var_flags "quiet="
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "quiet=" ]
}

@test "pg_build_psql_var_flags: a value with spaces survives as one argv entry" {
  # pg_run_sql_stream reads this output line-by-line into an array, so a
  # backup path with a space must not split into two psql arguments.
  local -a flags=()
  local line
  while IFS= read -r line; do flags+=("$line"); done \
    < <(pg_build_psql_var_flags "backup_file=/data/my backups/app.sql.zst")
  [ "${#flags[@]}" -eq 2 ]
  [ "${flags[1]}" = "backup_file=/data/my backups/app.sql.zst" ]
}

# ---------------------------------------------------------------------------
# get_exclude_dependents — cascade exclude_data to FK dependents?
# ---------------------------------------------------------------------------

@test "get_exclude_dependents: unset anywhere defaults to false (warn-only)" {
  write_config '{"hosts":{"prod":{"databases":{"app":{}}}}}'
  [ "$(get_exclude_dependents prod app)" = "false" ]
}

@test "get_exclude_dependents: per-database true enables the cascade" {
  write_config '{"hosts":{"prod":{"databases":{"app":{"exclude_dependents":true}}}}}'
  [ "$(get_exclude_dependents prod app)" = "true" ]
}

@test "get_exclude_dependents: global default applies when the database is unset" {
  write_config '{"defaults":{"exclude_dependents":true},"hosts":{"prod":{"databases":{"app":{}}}}}'
  [ "$(get_exclude_dependents prod app)" = "true" ]
}

@test "get_exclude_dependents: per-database true wins over a global false" {
  write_config '{"defaults":{"exclude_dependents":false},"hosts":{"prod":{"databases":{"app":{"exclude_dependents":true}}}}}'
  [ "$(get_exclude_dependents prod app)" = "true" ]
}

@test "get_exclude_dependents: BUG — per-database false cannot override a global true" {
  # Documents current behaviour, which contradicts the function's own comment
  # ("Per-database override wins over the global default"). get_config_value
  # runs `jq -r '<path> // empty'`, and jq's `//` treats a literal `false` as
  # empty — so an explicit per-database `false` reads back as unset and falls
  # through to .defaults, silently cascading exclusions the operator turned
  # off. pg_globals_backup_enabled works around exactly this by asking jq
  # `has("backup_globals")`; get_exclude_dependents does not.
  # Expect this assertion to flip to "false" when that is fixed.
  write_config '{"defaults":{"exclude_dependents":true},"hosts":{"prod":{"databases":{"app":{"exclude_dependents":false}}}}}'
  [ "$(get_exclude_dependents prod app)" = "true" ]
}

@test "get_exclude_dependents: an unknown host/database is false, not an error" {
  write_config '{"hosts":{}}'
  run get_exclude_dependents nope nothing
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

# ---------------------------------------------------------------------------
# pg_config_extension_registry — defaults.extension_packages escape hatch
# ---------------------------------------------------------------------------

@test "pg_config_extension_registry: string value becomes ext:package: (no preload)" {
  write_config '{"defaults":{"extension_packages":{"pg_foo":"foo"}}}'
  run pg_config_extension_registry
  [ "$status" -eq 0 ]
  [ "$output" = "pg_foo:foo:" ]
}

@test "pg_config_extension_registry: object value carries package and preload" {
  write_config '{"defaults":{"extension_packages":{"pg_foo":{"package":"foo","preload":"pg_foo"}}}}'
  run pg_config_extension_registry
  [ "$status" -eq 0 ]
  [ "$output" = "pg_foo:foo:pg_foo" ]
}

@test "pg_config_extension_registry: object without preload yields a trailing empty field" {
  write_config '{"defaults":{"extension_packages":{"pg_foo":{"package":"foo"}}}}'
  run pg_config_extension_registry
  [ "$status" -eq 0 ]
  [ "$output" = "pg_foo:foo:" ]
}

@test "pg_config_extension_registry: one line per entry" {
  write_config '{"defaults":{"extension_packages":{"a_ext":"a","b_ext":{"package":"b","preload":"b"}}}}'
  run pg_config_extension_registry
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" == *"a_ext:a:"* ]]
  [[ "$output" == *"b_ext:b:b"* ]]
}

@test "pg_config_extension_registry: no extension_packages key emits nothing" {
  write_config '{"defaults":{}}'
  run pg_config_extension_registry
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pg_config_extension_registry: a missing config file is silently empty" {
  CONFIG_FILE="$BATS_TEST_TMPDIR/absent.json"
  run pg_config_extension_registry
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pg_config_extension_registry: malformed JSON is swallowed, not fatal" {
  write_config '{ this is not json'
  run pg_config_extension_registry
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
