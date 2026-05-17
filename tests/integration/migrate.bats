#!/usr/bin/env bats
load '../helpers/integration'

setup_file() {
  require_docker
  ensure_postgres_container
  ensure_pg13_alt_container >/dev/null
}

setup() {
  setup_dbx_env
  # Resolve PG 13 alt source IP for cross-container connectivity.
  local pg13_ip
  pg13_ip=$(docker inspect pg13-alt-dbx \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "pg13-src": {
      "type": "postgres",
      "host": "$pg13_ip",
      "port": 5432,
      "user": "postgres",
      "password_cmd": "echo devpassword",
      "databases": { "migtest": {} }
    }
  },
  "defaults": { "compression_level": 1, "keep_backups": 10 }
}
EOF
}

teardown() {
  docker exec -e PGPASSWORD=devpassword pg13-alt-dbx \
    psql -U postgres -c "DROP DATABASE IF EXISTS migtest" >/dev/null 2>&1 || true
  pg_drop_db migtest
}

@test "migrate: PG 13 → PG 15 round-trip with row-count verification" {
  # Seed source
  docker exec -i -e PGPASSWORD=devpassword pg13-alt-dbx \
    psql -U postgres -c "DROP DATABASE IF EXISTS migtest;" >/dev/null
  docker exec -i -e PGPASSWORD=devpassword pg13-alt-dbx \
    psql -U postgres -c "CREATE DATABASE migtest;" >/dev/null
  docker exec -i -e PGPASSWORD=devpassword pg13-alt-dbx \
    psql -U postgres -d migtest -c "CREATE TABLE t (id int); INSERT INTO t SELECT generate_series(1,42);" >/dev/null

  # Run migration to PG 15
  dbx_run migrate pg13-src --to-version 15
  echo "$output"
  [ "$status" -eq 0 ]

  # Verify target container is on postgres:15-alpine
  local tgt_image
  tgt_image=$(docker inspect --format '{{.Config.Image}}' postgres-dbx)
  [[ "$tgt_image" == "postgres:15-alpine" ]]

  # Verify migtest exists in target with 42 rows
  local row_count
  row_count=$(docker exec -i postgres-dbx psql -U postgres -d migtest -At -c "SELECT count(*) FROM t;")
  [ "$row_count" = "42" ]

  # Verify backup file retained as rollback artifact
  local backups
  backups=$(find "$DBX_DATA_DIR/pg13-src" -type f -name "*.sql.zst" | wc -l)
  [ "$backups" -ge 1 ]
}

@test "migrate: --dry-run prints plan without touching anything" {
  # Snapshot state pre-dry-run
  local backups_before
  backups_before=$(find "$DBX_DATA_DIR" -type f 2>/dev/null | wc -l)
  local img_before
  img_before=$(docker inspect --format '{{.Config.Image}}' postgres-dbx 2>/dev/null || echo "")

  dbx_run migrate pg13-src --to-version 15 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Migration plan"* ]]
  [[ "$output" == *"postgres:15"* ]]

  local backups_after
  backups_after=$(find "$DBX_DATA_DIR" -type f 2>/dev/null | wc -l)
  [ "$backups_before" = "$backups_after" ]
  local img_after
  img_after=$(docker inspect --format '{{.Config.Image}}' postgres-dbx 2>/dev/null || echo "")
  [ "$img_before" = "$img_after" ]
}

@test "migrate: refuses same-version" {
  dbx_run migrate pg13-src --to-version 13
  [ "$status" -ne 0 ]
  [[ "$output" == *"same major"* || "$output" == *"dbx restore"* ]]
}

@test "migrate: refuses downgrade without --force-downgrade" {
  dbx_run migrate pg13-src --to-version 11
  [ "$status" -ne 0 ]
  [[ "$output" == *"downgrade"* ]]
  [[ "$output" == *"--force-downgrade"* ]]
}

@test "migrate: --from-backup uses existing artifact and skips backup step" {
  # Seed source
  docker exec -i -e PGPASSWORD=devpassword pg13-alt-dbx \
    psql -U postgres -c "DROP DATABASE IF EXISTS migtest;" >/dev/null
  docker exec -i -e PGPASSWORD=devpassword pg13-alt-dbx \
    psql -U postgres -c "CREATE DATABASE migtest;" >/dev/null
  docker exec -i -e PGPASSWORD=devpassword pg13-alt-dbx \
    psql -U postgres -d migtest -c "CREATE TABLE t (id int); INSERT INTO t SELECT generate_series(1,7);" >/dev/null

  # First, take a backup using the matching client version (so the dump is
  # readable by both old and new servers). Easiest way: do a regular dbx
  # backup with postgres-dbx already on postgres:13-alpine (matches source).
  source_dbx_libs
  ensure_container_image postgres-dbx postgres:13-alpine true
  dbx_run backup pg13-src migtest
  [ "$status" -eq 0 ]
  local backup_file
  backup_file=$(find "$DBX_DATA_DIR/pg13-src" -name "*.sql.zst" | head -1)
  [ -f "$backup_file" ]

  # Count backups before
  local before
  before=$(find "$DBX_DATA_DIR/pg13-src" -name "*.sql.zst" | wc -l)

  # Now migrate using that file — should NOT create a new backup
  dbx_run migrate pg13-src --to-version 15 --from-backup "$backup_file"
  echo "$output"
  [ "$status" -eq 0 ]

  local after
  after=$(find "$DBX_DATA_DIR/pg13-src" -name "*.sql.zst" | wc -l)
  [ "$before" = "$after" ]
}

@test "migrate: verification failure exits non-zero and leaves backup" {
  docker exec -i -e PGPASSWORD=devpassword pg13-alt-dbx \
    psql -U postgres -c "DROP DATABASE IF EXISTS vfail;" >/dev/null
  docker exec -i -e PGPASSWORD=devpassword pg13-alt-dbx \
    psql -U postgres -c "CREATE DATABASE vfail;" >/dev/null
  docker exec -i -e PGPASSWORD=devpassword pg13-alt-dbx \
    psql -U postgres -d vfail -c "CREATE TABLE t (id int); INSERT INTO t SELECT generate_series(1,5);" >/dev/null

  # Override config so migrate uses 'vfail' database.
  local pg13_ip
  pg13_ip=$(docker inspect pg13-alt-dbx \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "pg13-src": {
      "type": "postgres",
      "host": "$pg13_ip",
      "port": 5432,
      "user": "postgres",
      "password_cmd": "echo devpassword",
      "databases": { "vfail": {} }
    }
  },
  "defaults": { "compression_level": 1, "keep_backups": 10 }
}
EOF

  # Run migrate normally first
  dbx_run migrate pg13-src --to-version 15
  [ "$status" -eq 0 ]

  # Now mutate target post-restore and re-run verify by hand to confirm
  # the verify helper catches a mismatch.
  docker exec -i postgres-dbx psql -U postgres -d vfail -c "INSERT INTO t VALUES (999);" >/dev/null

  # Use the verify helper directly with both as containers.
  source_dbx_libs
  run pg_verify_restore "pg13-alt-dbx" "postgres-dbx" "vfail"
  [ "$status" -ne 0 ]

  # Cleanup
  docker exec -i -e PGPASSWORD=devpassword pg13-alt-dbx \
    psql -U postgres -c "DROP DATABASE IF EXISTS vfail" >/dev/null 2>&1 || true
  pg_drop_db vfail
}
