#!/usr/bin/env bats
load '../helpers/common'
setup() { setup_dbx_env; source_dbx_libs; }

@test "migrate_print_plan: in-place upgrade prints all steps" {
  run migrate_print_plan \
    "source_host=pg13-prod" \
    "source_flavor=postgres" \
    "source_major=13" \
    "target_image=postgres:17-alpine" \
    "target_major=17" \
    "backup_path=/tmp/backup.sql.zst" \
    "from_backup=false" \
    "keep_source=false" \
    "skip_verify=false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pg13-prod"* ]]
  [[ "$output" == *"postgres:17-alpine"* ]]
  [[ "$output" == *"backup"* ]]
  [[ "$output" == *"restore"* ]]
  [[ "$output" == *"verify"* ]]
}

@test "migrate_print_plan: --from-backup omits the backup step" {
  run migrate_print_plan \
    "source_host=pg13-prod" \
    "source_flavor=postgres" \
    "source_major=13" \
    "target_image=postgres:17-alpine" \
    "target_major=17" \
    "backup_path=/tmp/existing.sql.zst" \
    "from_backup=true" \
    "keep_source=false" \
    "skip_verify=false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"existing.sql.zst"* ]]
  [[ "$output" != *"Step: backup source"* ]]
}

@test "migrate_print_plan: --skip-verify announces it" {
  run migrate_print_plan \
    "source_host=pg13-prod" \
    "source_flavor=postgres" \
    "source_major=13" \
    "target_image=postgres:17-alpine" \
    "target_major=17" \
    "backup_path=/tmp/backup.sql.zst" \
    "from_backup=false" \
    "keep_source=false" \
    "skip_verify=true"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verification SKIPPED"* ]]
}
