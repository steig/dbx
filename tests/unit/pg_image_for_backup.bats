#!/usr/bin/env bats
#
# Tests for pg_ensure_image_for_backup (lib/postgres.sh, #148) — the
# restore-time image match for postgres, mirroring mysql_image_for_backup.bats.
# The two docker-touching tails are stubbed (ensure_container_image echoes the
# image it was asked for; pg_ensure_custom_image records its arguments), so
# these exercise meta-file discovery, the override precedence and the
# extension-driven image pick without docker.
#
# pick_postgres_image's own classification table lives in image_selection.bats;
# what is tested here is the wiring from a backup file to that call.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
  write_config '{"hosts":{}}'

  BUILD_LOG="$BATS_TEST_TMPDIR/build.log"
  : > "$BUILD_LOG"

  # Stub the docker-touching tail: echo the image it was asked to ensure.
  ensure_container_image() { echo "$2"; }
  # Record the custom-image build request instead of running docker build.
  pg_ensure_custom_image() {
    { printf 'major=%s\ntag=%s\n' "$1" "$2"; printf 'tuple=%s\n' $3; } >> "$BUILD_LOG"
    return "${STUB_BUILD_RC:-0}"
  }
}

# Create a fake backup file + sibling .meta.json (real layout: <file>.meta.json).
_mk_backup() {
  local name="$1" meta_json="$2"
  local f="$DBX_DATA_DIR/$name"
  : > "$f"
  printf '%s\n' "$meta_json" > "${f}.meta.json"
  echo "$f"
}

@test "pg_ensure_image_for_backup: PG 15 source with no extensions → postgres:15-alpine" {
  f=$(_mk_backup "app_20260101.sql.zst" '{"source_major_version":"15","source_extensions":[]}')
  run pg_ensure_image_for_backup "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "postgres:15-alpine" ]
}

@test "pg_ensure_image_for_backup: legacy backup with no meta → default major" {
  local f="$DBX_DATA_DIR/legacy.sql.zst"
  : > "$f"   # no sibling .meta.json
  run pg_ensure_image_for_backup "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "postgres:17-alpine" ]
}

@test "pg_ensure_image_for_backup: meta with an unknown major falls back to the default" {
  f=$(_mk_backup "app_20260101.sql.zst" '{"source_major_version":"unknown","source_extensions":[]}')
  run pg_ensure_image_for_backup "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "postgres:17-alpine" ]
}

@test "pg_ensure_image_for_backup: finds meta through .age suffix layering" {
  local f="$DBX_DATA_DIR/app_20260101.sql.zst.age"
  : > "$f"
  # Encrypted backups write meta as <file>.zst.meta.json (probe via %.age).
  printf '%s\n' '{"source_major_version":"14","source_extensions":[]}' \
    > "$DBX_DATA_DIR/app_20260101.sql.zst.meta.json"
  run pg_ensure_image_for_backup "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "postgres:14-alpine" ]
}

@test "pg_ensure_image_for_backup: finds meta through .gpg suffix layering" {
  local f="$DBX_DATA_DIR/app_20260101.sql.zst.gpg"
  : > "$f"
  printf '%s\n' '{"source_major_version":"13","source_extensions":[]}' \
    > "$DBX_DATA_DIR/app_20260101.sql.zst.meta.json"
  run pg_ensure_image_for_backup "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "postgres:13-alpine" ]
}

@test "pg_ensure_image_for_backup: DBX_POSTGRES_IMAGE override wins, with {major} substitution" {
  f=$(_mk_backup "app_20260101.sql.zst" '{"source_major_version":"16","source_extensions":["postgis"]}')
  DBX_POSTGRES_IMAGE='myrepo/pg:{major}' run pg_ensure_image_for_backup "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "myrepo/pg:16" ]
}

@test "pg_ensure_image_for_backup: defaults.postgres_image config override is honoured" {
  write_config '{"defaults":{"postgres_image":"registry.local/pg:{major}"}}'
  f=$(_mk_backup "app_20260101.sql.zst" '{"source_major_version":"16","source_extensions":[]}')
  run pg_ensure_image_for_backup "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "registry.local/pg:16" ]
}

@test "pg_ensure_image_for_backup: a specialized extension picks its purpose-built image" {
  f=$(_mk_backup "app_20260101.sql.zst" '{"source_major_version":"16","source_extensions":["vector"]}')
  run pg_ensure_image_for_backup "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "pgvector/pgvector:pg16" ]
}

@test "pg_ensure_image_for_backup: a buildable extension yields a dbx tag and requests the build" {
  f=$(_mk_backup "app_20260101.sql.zst" '{"source_major_version":"16","source_extensions":["pg_partman"]}')
  run pg_ensure_image_for_backup "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == dbx-pg16:* ]]
  grep -q '^major=16$' "$BUILD_LOG"
  grep -q "^tag=$output\$" "$BUILD_LOG"
  grep -q '^tuple=pg_partman:partman:$' "$BUILD_LOG"
}

@test "pg_ensure_image_for_backup: the build request carries the normalized major" {
  # An unknown source major still has to produce a buildable base tag.
  f=$(_mk_backup "app_20260101.sql.zst" '{"source_major_version":"unknown","source_extensions":["pg_cron"]}')
  run pg_ensure_image_for_backup "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == dbx-pg17:* ]]
  grep -q '^major=17$' "$BUILD_LOG"
  grep -q '^tuple=pg_cron:cron:pg_cron$' "$BUILD_LOG"
}

@test "pg_ensure_image_for_backup: a failed custom build fails the whole call" {
  f=$(_mk_backup "app_20260101.sql.zst" '{"source_major_version":"16","source_extensions":["pg_partman"]}')
  STUB_BUILD_RC=1 run pg_ensure_image_for_backup "$f"
  [ "$status" -ne 0 ]
  # ensure_container_image must not have run — nothing was echoed.
  [ -z "$output" ]
}

@test "pg_ensure_image_for_backup: an unknown extension fails with a hint" {
  f=$(_mk_backup "app_20260101.sql.zst" '{"source_major_version":"16","source_extensions":["frobnicate"]}')
  run pg_ensure_image_for_backup "$f"
  [ "$status" -ne 0 ]
  [[ "$output" == *"frobnicate"* ]]
  [[ "$output" == *"extension_packages"* ]]
}

@test "pg_ensure_image_for_backup: defaults.extension_packages rescues an unknown extension" {
  # The config escape hatch is read by pg_config_extension_registry and passed
  # to pick_postgres_image, turning a hard failure into a buildable image.
  write_config '{"defaults":{"extension_packages":{"frobnicate":"frob"}}}'
  f=$(_mk_backup "app_20260101.sql.zst" '{"source_major_version":"16","source_extensions":["frobnicate"]}')
  run pg_ensure_image_for_backup "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == dbx-pg16:* ]]
  grep -q '^tuple=frobnicate:frob:$' "$BUILD_LOG"
}
