#!/usr/bin/env bats
#
# `dbx clean` retention semantics: --keep N, --dry-run, --older-than D.

load '../helpers/integration'

setup() {
  setup_dbx_env
  write_local_config
  # Build a fake backup directory tree with timestamped placeholders so
  # we don't need to run real backups for retention tests.
  BACKUP_DIR="$DBX_DATA_DIR/local-pg/cleantest"
  mkdir -p "$BACKUP_DIR"
}

# Create N fake backup files with stable timestamps.
make_fake_backups() {
  local count="$1"
  local age_days="${2:-0}"
  local base
  base=$(date -d "$age_days days ago" +%s 2>/dev/null || date -v "-${age_days}d" +%s)
  for i in $(seq 1 "$count"); do
    local ts
    ts=$(date -u -d "@$((base - i * 86400))" +"%Y%m%d_%H%M%S" 2>/dev/null \
         || date -u -r "$((base - i * 86400))" +"%Y%m%d_%H%M%S")
    local f="$BACKUP_DIR/cleantest_${ts}.sql.zst"
    : > "$f"
    cat > "$f.meta.json" <<EOF
{"host":"local-pg","database":"cleantest","timestamp":"${ts}","size":0,"checksums":{"sha256":""},"encryption":"none","dbx_version":"test"}
EOF
    # Backdate the file mtime to match the timestamp
    touch -d "@$((base - i * 86400))" "$f" 2>/dev/null \
      || touch -t "$(date -r $((base - i * 86400)) +%Y%m%d%H%M.%S)" "$f"
  done
}

@test "clean --keep N retains exactly N newest backups" {
  make_fake_backups 7

  dbx_run clean --keep 3
  [ "$status" -eq 0 ]

  local remaining
  remaining=$(ls "$BACKUP_DIR"/*.sql.zst 2>/dev/null | wc -l)
  [ "$remaining" = "3" ]
}

@test "clean --dry-run reports without deleting" {
  make_fake_backups 5

  dbx_run clean --keep 2 --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "Would remove"

  local remaining
  remaining=$(ls "$BACKUP_DIR"/*.sql.zst 2>/dev/null | wc -l)
  [ "$remaining" = "5" ]
}

@test "clean removes the matching .meta.json alongside the backup" {
  make_fake_backups 3

  dbx_run clean --keep 1
  [ "$status" -eq 0 ]

  # Same number of .sql.zst and .meta.json files (no orphans)
  local zst meta
  zst=$(ls "$BACKUP_DIR"/*.sql.zst 2>/dev/null | wc -l)
  meta=$(ls "$BACKUP_DIR"/*.meta.json 2>/dev/null | wc -l)
  [ "$zst" = "1" ]
  [ "$meta" = "1" ]
}

@test "clean rejects unknown flags" {
  make_fake_backups 1
  dbx_run clean --bogus-flag
  [ "$status" -ne 0 ]
}
