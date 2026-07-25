#!/usr/bin/env bats
#
# Tests for register_exit_handler (lib/core.sh, #149). Bash has one trap slot
# per signal, so a second `trap ... EXIT` silently replaces the first — the
# bug these tests pin down. Snippets run in a fresh `bash` (with `set -euo
# pipefail`, as dbx itself does) so the traps under test are contained.

load '../helpers/common'

setup() {
  setup_dbx_env
  REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  OUT="$BATS_TEST_TMPDIR/out"; export OUT
  READY="$BATS_TEST_TMPDIR/ready"; export READY
  export REPO
}

# Run the snippet on stdin as a script with core.sh sourced.
run_script() {
  local script="$BATS_TEST_TMPDIR/script.sh"
  {
    echo 'set -euo pipefail'
    echo "source '$REPO/lib/core.sh'"
    cat
  } > "$script"
  run bash "$script"
}

@test "regression: a second raw 'trap ... EXIT' clobbers the first (#149)" {
  # The bug register_exit_handler exists to fix. If this ever stops failing
  # to run FIRST, bash changed and the helper's premise is worth revisiting.
  run_script <<'EOF'
trap 'echo FIRST' EXIT
trap 'echo SECOND' EXIT
EOF
  [ "$status" -eq 0 ]
  [[ "$output" != *FIRST* ]]
  [[ "$output" == *SECOND* ]]
}

@test "regression: only core.sh's registry installs EXIT/INT/TERM traps (#149)" {
  # A new hand-rolled `trap … EXIT` anywhere else would replace the dispatcher
  # and drop every registered handler. RETURN traps are function-scoped and
  # cannot clobber each other, so they are not covered here.
  local offenders
  offenders=$(grep -rnE 'trap .*(EXIT|INT|TERM)' "$REPO/dbx" "$REPO"/lib/*.sh \
    | grep -v '/lib/core.sh:' || true)
  [ -z "$offenders" ]
}

@test "register: a second handler does not clobber the first (#149)" {
  run_script <<'EOF'
register_exit_handler 'echo FIRST'
register_exit_handler 'echo SECOND'
EOF
  [ "$status" -eq 0 ]
  [[ "$output" == *FIRST* ]]
  [[ "$output" == *SECOND* ]]
}

@test "register: handlers run LIFO (#149)" {
  run_script <<'EOF'
register_exit_handler 'echo one'
register_exit_handler 'echo two'
register_exit_handler 'echo three'
EOF
  [ "${lines[0]}" = "three" ]
  [ "${lines[1]}" = "two" ]
  [ "${lines[2]}" = "one" ]
}

@test "register: a failing handler does not stop the others (#149)" {
  run_script <<'EOF'
register_exit_handler 'echo bottom'
register_exit_handler 'false'
register_exit_handler 'nosuchcommand-149'
register_exit_handler 'echo top'
EOF
  [[ "$output" == *top* ]]
  [[ "$output" == *bottom* ]]
}

@test "register: a failing handler does not change the exit status (#149)" {
  run_script <<'EOF'
register_exit_handler 'false'
exit 7
EOF
  [ "$status" -eq 7 ]
}

@test "register: a clean exit stays 0 even with handlers registered (#149)" {
  run_script <<'EOF'
register_exit_handler 'true'
register_exit_handler 'echo done'
EOF
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]
}

@test "register: exit status from a failing command is preserved (#149)" {
  run_script <<'EOF'
register_exit_handler 'echo cleanup'
exit 42
EOF
  [ "$status" -eq 42 ]
  [ "$output" = "cleanup" ]
}

@test "ordering: tunnel teardown runs before the credential scrub (#149)" {
  # Why LIFO: setup_security_trap registers first (at dbx startup) so its
  # scrub runs last — later handlers can still read the credentials.
  run_script <<'EOF'
cleanup_tunnel() { echo "TUNNEL db_pass=${db_pass:-unset}"; }
db_pass=secret
setup_security_trap
register_exit_handler 'cleanup_tunnel'
EOF
  [ "${lines[0]}" = "TUNNEL db_pass=secret" ]
}

@test "subshell: a handler registered in a subshell does not reach the parent (#149)" {
  run_script <<'EOF'
register_exit_handler 'echo PARENT'
( register_exit_handler 'echo CHILD' )
echo AFTER
EOF
  [ "$(grep -c CHILD <<<"$output")" -eq 1 ]
  [ "${lines[${#lines[@]}-1]}" = "PARENT" ]
}

# Send $1 to a script that has a handler registered; assert the exit status is
# $2 and that the handler ran exactly once.
#
# The target is exec'd through a python3 shim that resets SIGINT/SIGTERM to
# SIG_DFL first. Bash sets SIGINT to SIG_IGN in asynchronous children of a
# non-interactive shell, and a disposition ignored on entry cannot be trapped
# — under `bats -j` (where the test itself is async) the target would never
# see the signal and would spin forever. The watchdog turns any such hang
# into a failure rather than a stuck run.
run_signal_test() {
  local sig="$1" expected="$2"
  require_cmd python3
  cat > "$BATS_TEST_TMPDIR/target.sh" <<'EOF'
set -euo pipefail
source "$REPO/lib/core.sh"
register_exit_handler 'echo HANDLER >> "$OUT"'
: > "$READY"
while true; do sleep 0.1; done
EOF
  cat > "$BATS_TEST_TMPDIR/driver.sh" <<'EOF'
python3 -c '
import signal, os, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
signal.signal(signal.SIGTERM, signal.SIG_DFL)
os.execv(sys.argv[1], sys.argv[1:])
' /bin/bash "$TARGET" &
p=$!
for _ in $(seq 1 300); do [[ -f "$READY" ]] && break; sleep 0.1; done
[[ -f "$READY" ]] || { kill -9 "$p" 2>/dev/null; echo "target never became ready"; exit 99; }
( sleep 30; kill -9 "$p" 2>/dev/null ) &
watchdog=$!
kill -s "$SIG" "$p"
rc=0; wait "$p" || rc=$?
kill "$watchdog" 2>/dev/null
exit "$rc"
EOF
  run env TARGET="$BATS_TEST_TMPDIR/target.sh" SIG="$sig" \
    bash "$BATS_TEST_TMPDIR/driver.sh"
  [ "$status" -eq "$expected" ]
  [ "$(grep -c HANDLER "$OUT")" -eq 1 ]
}

@test "signals: SIGTERM runs handlers once and exits 143 (#149)" {
  run_signal_test TERM 143
}

@test "signals: SIGINT runs handlers once and exits 130 (#149)" {
  run_signal_test INT 130
}
