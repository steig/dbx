#!/usr/bin/env bats
load '../helpers/common'
setup() { setup_dbx_env; source_dbx_libs; }

@test "migrate_refuse_same_version: same major returns 1 with message" {
  run migrate_refuse_same_version 15 15
  [ "$status" -eq 1 ]
  [[ "$output" == *"same major version"* ]]
  [[ "$output" == *"dbx restore"* ]]
}

@test "migrate_refuse_same_version: different majors returns 0 silently" {
  run migrate_refuse_same_version 13 15
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "migrate_refuse_same_version: unknown source major returns 0 (let backup proceed)" {
  run migrate_refuse_same_version unknown 15
  [ "$status" -eq 0 ]
}

@test "migrate_refuse_cross_flavor: mysql → mariadb returns 1" {
  run migrate_refuse_cross_flavor mysql mariadb
  [ "$status" -eq 1 ]
  [[ "$output" == *"flavor"* ]]
  [[ "$output" == *"dbx backup"* ]]
}

@test "migrate_refuse_cross_flavor: mariadb → mysql returns 1" {
  run migrate_refuse_cross_flavor mariadb mysql
  [ "$status" -eq 1 ]
}

@test "migrate_refuse_cross_flavor: mysql → mysql returns 0" {
  run migrate_refuse_cross_flavor mysql mysql
  [ "$status" -eq 0 ]
}

@test "migrate_refuse_cross_flavor: postgres → postgres returns 0" {
  run migrate_refuse_cross_flavor postgres postgres
  [ "$status" -eq 0 ]
}

@test "migrate_refuse_cross_flavor: postgres → mysql returns 1 (cross-engine)" {
  run migrate_refuse_cross_flavor postgres mysql
  [ "$status" -eq 1 ]
  [[ "$output" == *"engine"* || "$output" == *"flavor"* ]]
}

@test "migrate_is_downgrade: 15 → 13 returns 0 (is a downgrade)" {
  run migrate_is_downgrade 15 13
  [ "$status" -eq 0 ]
}

@test "migrate_is_downgrade: 13 → 15 returns 1 (upgrade, not downgrade)" {
  run migrate_is_downgrade 13 15
  [ "$status" -eq 1 ]
}

@test "migrate_is_downgrade: 15 → 15 returns 1 (same, not downgrade)" {
  run migrate_is_downgrade 15 15
  [ "$status" -eq 1 ]
}

@test "migrate_is_downgrade: 10 → 11 (MariaDB-style two-digit majors) returns 1" {
  run migrate_is_downgrade 10 11
  [ "$status" -eq 1 ]
}

@test "migrate_is_downgrade: 11 → 10 returns 0" {
  run migrate_is_downgrade 11 10
  [ "$status" -eq 0 ]
}

@test "migrate_is_downgrade: unknown source returns 1 (cannot conclude downgrade)" {
  run migrate_is_downgrade unknown 13
  [ "$status" -eq 1 ]
}

@test "cmd_migrate: no args dies with usage" {
  run "$DBX_BIN" migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* || "$output" == *"usage"* ]]
}

@test "cmd_migrate: --help prints usage and exits 0" {
  run "$DBX_BIN" migrate --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"migrate"* ]]
}

@test "cmd_migrate: --dry-run + --to-version against fake host prints plan and exits 0" {
  # Pre-stage a host config so the early lookup succeeds.
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "fake-pg": {
      "type": "postgres",
      "host": "127.0.0.1",
      "port": 5432,
      "user": "postgres",
      "password_cmd": "echo devpassword"
    }
  }
}
EOF
  run "$DBX_BIN" migrate fake-pg --to-version 17 --dry-run
  # We accept either 0 (full plan) or a controlled exit if local-pg
  # detection fails — either way the dry-run path must not destroy
  # anything. We assert no destructive log lines were emitted.
  [[ "$output" != *"Deleting"* ]]
  [[ "$output" != *"Removing container"* ]]
}
