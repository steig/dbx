#!/usr/bin/env bats
#
# Tests for lib/core.sh — utilities and config accessors.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
}

# ----------------------------------------------------------------------------
# human_size — bytes → human-readable
# ----------------------------------------------------------------------------

@test "human_size 0 → 0B" { [ "$(human_size 0)" = "0B" ]; }
@test "human_size 1023 → 1023B" { [ "$(human_size 1023)" = "1023B" ]; }
@test "human_size 1024 → 1KB" { [ "$(human_size 1024)" = "1KB" ]; }
@test "human_size 524288 → 512KB" { [ "$(human_size 524288)" = "512KB" ]; }
@test "human_size 1048576 → 1MB" { [ "$(human_size 1048576)" = "1MB" ]; }
@test "human_size 1073741824 → 1GB" { [ "$(human_size 1073741824)" = "1GB" ]; }

# ----------------------------------------------------------------------------
# strip_definer — sed pipeline for MySQL DEFINER clauses
# ----------------------------------------------------------------------------

@test "strip_definer strip removes DEFINER clause" {
  result=$(echo 'CREATE DEFINER=`u`@`%` VIEW v AS SELECT 1;' | strip_definer strip)
  [ "$result" = "CREATE VIEW v AS SELECT 1;" ]
}

@test "strip_definer current_user replaces with CURRENT_USER" {
  result=$(echo 'CREATE DEFINER=`u`@`%` VIEW v AS SELECT 1;' | strip_definer current_user)
  [ "$result" = "CREATE DEFINER=CURRENT_USER VIEW v AS SELECT 1;" ]
}

@test "strip_definer keep passes through unchanged" {
  result=$(echo 'CREATE DEFINER=`u`@`%` VIEW v AS SELECT 1;' | strip_definer keep)
  [ "$result" = 'CREATE DEFINER=`u`@`%` VIEW v AS SELECT 1;' ]
}

@test "strip_definer with no arg defaults to strip" {
  result=$(echo 'CREATE DEFINER=`u`@`%` VIEW v AS SELECT 1;' | strip_definer)
  [ "$result" = "CREATE VIEW v AS SELECT 1;" ]
}

# ----------------------------------------------------------------------------
# Platform helpers
# ----------------------------------------------------------------------------

@test "is_macos and is_linux are mutually exclusive" {
  if is_macos; then
    ! is_linux
  elif is_linux; then
    ! is_macos
  else
    skip "neither macOS nor Linux"
  fi
}

# ----------------------------------------------------------------------------
# timestamp — format
# ----------------------------------------------------------------------------

@test "timestamp returns YYYYMMDD_HHMMSS" {
  result=$(timestamp)
  [[ "$result" =~ ^[0-9]{8}_[0-9]{6}$ ]]
}

# ----------------------------------------------------------------------------
# Config accessors — read fields out of a JSON config
# ----------------------------------------------------------------------------

@test "get_db_type reads .hosts[host].type" {
  write_config '{"hosts":{"prod":{"type":"postgres","user":"x"}}}'
  [ "$(get_db_type prod)" = "postgres" ]
}

@test "get_db_type returns empty for unknown host" {
  write_config '{"hosts":{}}'
  [ -z "$(get_db_type prod)" ]
}

@test "get_excluded_tables returns table list" {
  write_config '{"hosts":{"prod":{"databases":{"app":{"exclude_data":["sessions","logs"]}}}}}'
  result=$(get_excluded_tables prod app | tr '\n' ',')
  [ "$result" = "sessions,logs," ]
}

@test "get_excluded_tables returns empty when unset" {
  write_config '{"hosts":{"prod":{"databases":{"app":{}}}}}'
  result=$(get_excluded_tables prod app)
  [ -z "$result" ]
}

@test "get_definer_handling defaults to strip" {
  write_config '{"hosts":{"prod":{}}}'
  [ "$(get_definer_handling prod)" = "strip" ]
}

@test "get_definer_handling reads configured value" {
  write_config '{"hosts":{"prod":{"definer_handling":"keep"}}}'
  [ "$(get_definer_handling prod)" = "keep" ]
}

@test "get_parallel_jobs defaults to 4" {
  write_config '{"hosts":{"prod":{"databases":{"app":{}}}}}'
  [ "$(get_parallel_jobs prod app)" = "4" ]
}

@test "get_parallel_jobs reads database-level override" {
  write_config '{"hosts":{"prod":{"databases":{"app":{"parallel_jobs":8}}}}}'
  [ "$(get_parallel_jobs prod app)" = "8" ]
}

@test "get_parallel_jobs reads defaults.parallel_jobs" {
  write_config '{"defaults":{"parallel_jobs":2},"hosts":{"prod":{"databases":{"app":{}}}}}'
  [ "$(get_parallel_jobs prod app)" = "2" ]
}

# ----------------------------------------------------------------------------
# transform_exec_argv — --transform subprocess argv builder
# ----------------------------------------------------------------------------

@test "transform_exec_argv default (env clean): emits env -i + allowlist + script" {
  PATH=/usr/bin HOME=/h LANG=C.UTF-8 TZ=UTC USER=u SHELL=/bin/sh \
    run transform_exec_argv "false" "/path/to/script.sh"
  [ "$status" -eq 0 ]
  # First line is `env`, second is `-i`
  first=$(echo "$output" | sed -n 1p)
  second=$(echo "$output" | sed -n 2p)
  [ "$first" = "env" ]
  [ "$second" = "-i" ]
  # Allowlisted vars appear as KEY=VALUE lines
  echo "$output" | grep -q '^PATH=/usr/bin$'
  echo "$output" | grep -q '^HOME=/h$'
  echo "$output" | grep -q '^LANG=C.UTF-8$'
  # Last line is the script path
  last=$(echo "$output" | tail -1)
  [ "$last" = "/path/to/script.sh" ]
}

@test "transform_exec_argv default: PGPASSWORD is NOT passed through" {
  export PGPASSWORD="secret123"
  run transform_exec_argv "false" "/path/to/script.sh"
  ! echo "$output" | grep -q "PGPASSWORD"
  ! echo "$output" | grep -q "secret123"
  unset PGPASSWORD
}

@test "transform_exec_argv default: DBX_SCRUB_SEED is NOT passed through" {
  export DBX_SCRUB_SEED="salty"
  run transform_exec_argv "false" "/path/to/script.sh"
  ! echo "$output" | grep -q "DBX_SCRUB_SEED"
  ! echo "$output" | grep -q "salty"
  unset DBX_SCRUB_SEED
}

@test "transform_exec_argv default: DBX_TRANSFORM_* prefix IS passed through" {
  export DBX_TRANSFORM_PROJECT="myapp"
  export DBX_TRANSFORM_SEED="abc"
  run transform_exec_argv "false" "/path/to/script.sh"
  echo "$output" | grep -q '^DBX_TRANSFORM_PROJECT=myapp$'
  echo "$output" | grep -q '^DBX_TRANSFORM_SEED=abc$'
  unset DBX_TRANSFORM_PROJECT DBX_TRANSFORM_SEED
}

@test "transform_exec_argv inherit=true: emits just the script (no env -i)" {
  run transform_exec_argv "true" "/path/to/script.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "/path/to/script.sh" ]
}

@test "transform_exec_argv default: missing allowlist var is skipped (no empty value)" {
  unset TMPDIR
  run transform_exec_argv "false" "/path/to/script.sh"
  ! echo "$output" | grep -q "^TMPDIR=$"
}
