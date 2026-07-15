#!/usr/bin/env bats
#
# Tests for the postgres globals (roles/grants/tablespaces) helpers added in
# #130: sidecar path derivation and the backup-enable precedence resolver.
# Pure functions only — no docker required.

load '../helpers/common'
setup() { setup_dbx_env; source_dbx_libs; }

# Rewrite the isolated config.json (CONFIG_FILE is set by source_dbx_libs).
write_config() { printf '%s\n' "$1" > "$CONFIG_FILE"; }

@test "pg_globals_sidecar_path: appends .globals.sql to plain backup" {
  result=$(pg_globals_sidecar_path "/data/prod/app/app_20240101.sql.zst")
  [ "$result" = "/data/prod/app/app_20240101.sql.zst.globals.sql" ]
}

@test "pg_globals_sidecar_path: keeps the full encryption suffix" {
  result=$(pg_globals_sidecar_path "/data/prod/app/app_20240101.sql.zst.age")
  [ "$result" = "/data/prod/app/app_20240101.sql.zst.age.globals.sql" ]
}

@test "pg_globals_backup_enabled: explicit flag true wins over config" {
  write_config '{"defaults":{"backup_globals":false}}'
  [ "$(pg_globals_backup_enabled prod true)" = "true" ]
}

@test "pg_globals_backup_enabled: explicit flag false wins over config" {
  write_config '{"defaults":{"backup_globals":true}}'
  [ "$(pg_globals_backup_enabled prod false)" = "false" ]
}

@test "pg_globals_backup_enabled: empty flag defers to per-host config" {
  write_config '{"hosts":{"prod":{"backup_globals":true}}}'
  [ "$(pg_globals_backup_enabled prod '')" = "true" ]
}

@test "pg_globals_backup_enabled: per-host overrides global default" {
  write_config '{"defaults":{"backup_globals":true},"hosts":{"prod":{"backup_globals":false}}}'
  [ "$(pg_globals_backup_enabled prod '')" = "false" ]
}

@test "pg_globals_backup_enabled: falls back to global default when host unset" {
  write_config '{"defaults":{"backup_globals":true},"hosts":{"prod":{}}}'
  [ "$(pg_globals_backup_enabled prod '')" = "true" ]
}

@test "pg_globals_backup_enabled: defaults to false when nothing configured" {
  write_config '{}'
  [ "$(pg_globals_backup_enabled prod '')" = "false" ]
}

@test "pg_apply_globals: missing sidecar is a no-op that returns 0" {
  run pg_apply_globals "$BATS_TEST_TMPDIR/does-not-exist.globals.sql" true
  [ "$status" -eq 0 ]
}
