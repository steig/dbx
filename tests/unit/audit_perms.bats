#!/usr/bin/env bats
#
# Regression tests for #150: the audit log must never exist at a permissive
# mode, not even briefly. The old code appended the first entry and *then*
# ran `chmod 600`, so on a multi-user host another local user could open the
# world-readable log in that window and hold the descriptor across the chmod.
# The log records hosts, databases and outcomes, so that descriptor leaks
# every future entry.

load '../helpers/common'

setup() {
  setup_dbx_env
  export AUDIT_LOG_DIR="$BATS_TEST_TMPDIR/audit"
  export AUDIT_LOG_FILE="$AUDIT_LOG_DIR/audit.log"
  mkdir -p "$AUDIT_LOG_DIR"

  # Probe: a `jq` wrapper that records the state of the audit log at the
  # moment the entry is built, then hands off to the real jq. audit_log
  # builds the entry *before* it writes, so this observes the log exactly in
  # the window the old code left open — deterministically, without racing it.
  PROBE_LOG="$BATS_TEST_TMPDIR/probe.log"
  REAL_JQ="$(command -v jq)"
  export PROBE_LOG REAL_JQ
  local stubdir="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$stubdir"
  cat >"$stubdir/jq" <<'STUB'
#!/usr/bin/env bash
if [ -e "$AUDIT_LOG_FILE" ]; then
  mode=$(stat -c '%a' "$AUDIT_LOG_FILE" 2>/dev/null || stat -f '%Lp' "$AUDIT_LOG_FILE" 2>/dev/null)
  printf 'exists %s\n' "$mode" >> "$PROBE_LOG"
else
  printf 'absent\n' >> "$PROBE_LOG"
fi
exec "$REAL_JQ" "$@"
STUB
  chmod +x "$stubdir/jq"
  PATH="$stubdir:$PATH"
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

@test "audit log is 600 even when created under a permissive umask" {
  source "$BATS_TEST_DIRNAME/../../lib/core.sh"
  umask 000
  audit_log "backup" "success" "db_host" "prod"
  [ "$(file_mode "$AUDIT_LOG_FILE")" = "600" ]
}

@test "audit log exists at 600 before the first entry is written" {
  source "$BATS_TEST_DIRNAME/../../lib/core.sh"
  umask 000
  : >"$PROBE_LOG"
  audit_log "backup" "success" "db_host" "prod"
  # First jq call of the run = entry construction, before any append.
  local first
  first=$(head -1 "$PROBE_LOG")
  [ "$first" = "exists 600" ]
}

@test "existing audit log keeps its contents and gets repaired to 600" {
  source "$BATS_TEST_DIRNAME/../../lib/core.sh"
  echo '{"action":"old"}' > "$AUDIT_LOG_FILE"
  chmod 644 "$AUDIT_LOG_FILE"
  audit_log "backup" "success" "db_host" "prod"
  [ "$(file_mode "$AUDIT_LOG_FILE")" = "600" ]
  [ "$(wc -l < "$AUDIT_LOG_FILE")" -eq 2 ]
  run head -1 "$AUDIT_LOG_FILE"
  [ "$output" = '{"action":"old"}' ]
}
