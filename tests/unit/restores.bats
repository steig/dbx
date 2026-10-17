#!/usr/bin/env bats
#
# Tests for `dbx restores` — classifying restored databases against the
# audit log, and the prune flow. restores_classify is pure; the command
# tests stub `docker` so no real containers are touched.

load '../helpers/common'

DAY=86400
NOW=2000000000

setup() {
  setup_dbx_env
  source_dbx_libs
  AUDIT="$BATS_TEST_TMPDIR/audit.tsv"
  LIVE="$BATS_TEST_TMPDIR/live.tsv"
  : > "$AUDIT"
  : > "$LIVE"
}

# audit row: name, days-ago, file, [db_host], [database]
audit_row() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$((NOW - $2 * DAY))" "$3" "${4:-}" "${5:-}" >> "$AUDIT"
}
live_row() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$LIVE"; }

status_of() {
  restores_classify "$AUDIT" "$LIVE" "$NOW" 30 | awk -F'\t' -v n="$1" '$2 == n {print $6}'
}

@test "classify: newest restore of a source is kept even when old" {
  audit_row h_old 90 /d/prod/house/a.sql
  audit_row h_new 60 /d/prod/house/b.sql
  live_row postgres h_old 10
  live_row postgres h_new 10
  [ "$(status_of h_new)" = "keep" ]
  [ "$(status_of h_old)" = "prune" ]
}

@test "classify: superseded but younger than threshold is kept" {
  audit_row h_old 10 /d/prod/house/a.sql
  audit_row h_new 5 /d/prod/house/b.sql
  live_row postgres h_old 10
  live_row postgres h_new 10
  [ "$(status_of h_old)" = "keep" ]
}

@test "classify: database with no restore record is untracked" {
  live_row postgres scratch 10
  [ "$(status_of scratch)" = "untracked" ]
}

@test "classify: dropped newer restore does not supersede the live one" {
  audit_row h_old 90 /d/prod/house/a.sql
  audit_row h_gone 60 /d/prod/house/b.sql
  live_row postgres h_old 10
  [ "$(status_of h_old)" = "keep" ]
}

@test "classify: different sources never supersede each other" {
  audit_row h 90 /d/prod/house/a.sql
  audit_row f 10 /d/prod/fupm/a.sql
  live_row postgres h 10
  live_row postgres f 10
  [ "$(status_of h)" = "keep" ]
}

@test "classify: audit db_host/database win over the file path" {
  audit_row a 90 /tmp/.remote/dl.1/x.sql prod house
  audit_row b 10 /tmp/.remote/dl.2/y.sql prod house
  live_row postgres a 10
  live_row postgres b 10
  [ "$(status_of a)" = "prune" ]
  restores_classify "$AUDIT" "$LIVE" "$NOW" 30 | grep -q $'\tprod/house\t'
}

@test "classify: re-restore under the same name uses the latest record" {
  audit_row h 90 /d/prod/house/a.sql
  audit_row h2 60 /d/prod/house/b.sql
  audit_row h 5 /d/prod/house/c.sql
  live_row postgres h 10
  live_row postgres h2 10
  [ "$(status_of h)" = "keep" ]
  [ "$(status_of h2)" = "prune" ]
}

@test "audit index: reads restore rows, skips failures and bad lines" {
  cat > "$AUDIT_LOG_FILE" <<'EOF'
{"timestamp":"2026-01-01T00:00:00Z","action":"restore","outcome":"success","file":"/d/p/h/a.sql","target_db":"a"}
not json
{"timestamp":"2026-01-02T00:00:00Z","action":"restore","outcome":"failure","file":"/d/p/h/b.sql","target_db":"b"}
{"timestamp":"2026-01-03T00:00:00Z","action":"backup","outcome":"success","db_host":"p","database":"h"}
EOF
  run restores_audit_index
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == a$'\t'1767225600$'\t'/d/p/h/a.sql* ]]
}

# Runs cmd_restores with docker stubbed: postgres-dbx is running and holds
# old_db (superseded) and new_db; DROPs are recorded in $CALLS_LOG.
restores_subshell() {
  CALLS_LOG="$CALLS_LOG" bash -c '
    set -uo pipefail
    export DBX_NO_AUTO_MAIN=1
    # shellcheck source=/dev/null
    source "'"$DBX_BIN"'"
    require_docker() { :; }
    docker() {
      case "$*" in
        "ps --format "*) echo postgres-dbx ;;
        *"DROP DATABASE"*) echo "docker $*" >> "$CALLS_LOG" ;;
        *"FROM pg_database"*) printf "old_db\t100\nnew_db\t200\n" ;;
        *) return 0 ;;
      esac
    }
    cmd_restores "$@"
  ' bash "$@" </dev/null
}

seed_audit_log() {
  CALLS_LOG="$BATS_TEST_TMPDIR/calls.log"
  : > "$CALLS_LOG"
  mkdir -p "$(dirname "$AUDIT_LOG_FILE")"
  cat > "$AUDIT_LOG_FILE" <<'EOF'
{"timestamp":"2020-01-01T00:00:00Z","action":"restore","outcome":"success","file":"/d/prod/house/a.sql","target_db":"old_db"}
{"timestamp":"2020-02-01T00:00:00Z","action":"restore","outcome":"success","file":"/d/prod/house/b.sql","target_db":"new_db"}
EOF
}

@test "restores list marks the superseded restore as prune" {
  seed_audit_log
  run restores_subshell list
  [ "$status" -eq 0 ]
  [[ "$output" == *"prune"*"old_db"* ]]
  [[ "$output" == *"keep"*"new_db"* ]]
}

@test "restores prune without a terminal refuses unless -y" {
  seed_audit_log
  run restores_subshell prune
  [ "$status" -ne 0 ]
  [[ "$output" == *"-y"* ]]
  [ ! -s "$CALLS_LOG" ]
}

@test "restores prune -y drops only the superseded database" {
  seed_audit_log
  run restores_subshell prune -y
  [ "$status" -eq 0 ]
  grep -q 'DROP DATABASE "old_db"' "$CALLS_LOG"
  ! grep -q new_db "$CALLS_LOG"
}

@test "restores rejects a non-numeric --older-than" {
  run restores_subshell list --older-than soon
  [ "$status" -ne 0 ]
  [[ "$output" == *"whole number"* ]]
}
