#!/usr/bin/env bats
#
# Tests for mysql_ensure_image_for_backup (lib/mysql.sh) — the restore-time
# image match. ensure_container_image is stubbed to echo the desired image,
# so these exercise the meta-reading + pick logic without docker.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
  write_config '{"hosts":{}}'
  # Stub the docker-touching tail: echo the image it was asked to ensure.
  ensure_container_image() { echo "$2"; }
}

# Create a fake backup file + sibling .meta.json (real layout: <file>.meta.json).
_mk_backup() {
  local name="$1" meta_json="$2"
  local f="$DBX_DATA_DIR/$name"
  : > "$f"
  printf '%s\n' "$meta_json" > "${f}.meta.json"
  echo "$f"
}

@test "mysql_ensure_image_for_backup: mysql 5.7 source → mysql:5.7" {
  f=$(_mk_backup "db_20260101.sql.zst" '{"source_flavor":"mysql","source_major_version":"5","source_minor_version":"7"}')
  run mysql_ensure_image_for_backup "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "mysql:5.7" ]
}

@test "mysql_ensure_image_for_backup: mariadb 11.4 source → mariadb:11.4" {
  f=$(_mk_backup "db_20260101.sql.zst" '{"source_flavor":"mariadb","source_major_version":"11","source_minor_version":"4"}')
  run mysql_ensure_image_for_backup "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "mariadb:11.4" ]
}

@test "mysql_ensure_image_for_backup: legacy backup with no meta → default mysql:8.0" {
  f="$DBX_DATA_DIR/legacy.sql.zst"
  : > "$f"   # no sibling .meta.json
  run mysql_ensure_image_for_backup "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "mysql:8.0" ]
}

@test "mysql_ensure_image_for_backup: DBX_MYSQL_IMAGE override wins, with {version} substitution" {
  f=$(_mk_backup "db_20260101.sql.zst" '{"source_flavor":"mysql","source_major_version":"8","source_minor_version":"4"}')
  DBX_MYSQL_IMAGE='myrepo/mysql:{version}' run mysql_ensure_image_for_backup "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "myrepo/mysql:8.4" ]
}

@test "mysql_ensure_image_for_backup: finds meta through .age suffix layering" {
  local f="$DBX_DATA_DIR/db_20260101.sql.zst.age"
  : > "$f"
  # Encrypted backups write meta as <file>.zst.meta.json (probe via %.age).
  printf '%s\n' '{"source_flavor":"mariadb","source_major_version":"10","source_minor_version":"11"}' \
    > "$DBX_DATA_DIR/db_20260101.sql.zst.meta.json"
  run mysql_ensure_image_for_backup "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "mariadb:10.11" ]
}
