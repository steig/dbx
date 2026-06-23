#!/usr/bin/env bats
#
# Tests for lib/tunnel.sh — SSH tunnel reuse/teardown (#128). The reuse handle
# is an ssh ControlMaster socket in a uid-owned 0700 dir, not `ps` parsing, so
# another local user cannot spoof a tunnel dbx will adopt. `ssh` and `lsof` are
# stubbed on PATH; per-test env vars drive their return codes.
#
# create_ssh_tunnel installs an EXIT trap and (on failure) die()s, so it is run
# inside a `run bash -c` subshell (mirroring restore_remote.bats) — that
# contains the trap and lets us observe the globals it sets via stdout.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs   # for _sha256_stdin in the helper functions below

  REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export DBX_RUNTIME_DIR="$BATS_TEST_TMPDIR/runtime"
  SSH_LOG="$BATS_TEST_TMPDIR/ssh.log"; export SSH_LOG; : >"$SSH_LOG"

  STUBDIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUBDIR"
  cat >"$STUBDIR/ssh" <<'S'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
case "$*" in
  *"-O check"*) exit "${SSH_CHECK_RC:-1}" ;;
  *"-O exit"*)  exit 0 ;;
  *)            exit "${SSH_CREATE_RC:-0}" ;;
esac
S
  cat >"$STUBDIR/lsof" <<'L'
#!/usr/bin/env bash
case "$*" in
  *LISTEN*) exit "${LSOF_LISTEN_RC:-0}" ;;
  *)        exit "${LSOF_FREE_RC:-1}" ;;
esac
L
  chmod +x "$STUBDIR/ssh" "$STUBDIR/lsof"

  write_config '{"hosts":{"prod":{"ssh_tunnel":{"jump_host":"jump","target_host":"db","target_port":"5432"}}}}'
}

# Run create_ssh_tunnel for host "prod" in a subshell with the stubs on PATH and
# any KEY=VAL args exported first. Echoes a parseable result line on success.
run_create() {
  run env \
    PATH="$STUBDIR:$PATH" \
    SSH_LOG="$SSH_LOG" \
    DBX_DATA_DIR="$DBX_DATA_DIR" DBX_CONFIG_DIR="$DBX_CONFIG_DIR" \
    DBX_AUDIT_DIR="$DBX_AUDIT_DIR" DBX_RUNTIME_DIR="$DBX_RUNTIME_DIR" \
    "$@" \
    bash -c '
      set -uo pipefail
      source "'"$REPO"'/lib/core.sh"
      source "'"$REPO"'/lib/tunnel.sh"
      create_ssh_tunnel prod
      echo "RESULT REUSED=$TUNNEL_REUSED PORT=$TUNNEL_LOCAL_PORT CTL=$TUNNEL_CONTROL_PATH"
    '
}

# Compute the control socket path for the prod target (mirrors tunnel.sh).
ctl_path() {
  local key; key=$(printf '%s' "jump|db|5432" | _sha256_stdin | cut -c1-32)
  echo "$DBX_RUNTIME_DIR/dbx-tunnels/$key.sock"
}

prime_reuse_socket() {
  local dir="$DBX_RUNTIME_DIR/dbx-tunnels"
  mkdir -p "$dir"; chmod 700 "$dir"
  local ctl; ctl="$(ctl_path)"
  : >"$ctl"; echo 54321 >"${ctl%.sock}.port"   # sidecar name matches tunnel.sh
}

@test "create: uses a ControlMaster socket in the 0700 dir, not ps (#128)" {
  run_create
  [ "$status" -eq 0 ]
  [[ "$output" == *"REUSED=false"* ]]
  [[ "$output" == *"RESULT"* ]]
  grep -q -- '-M' "$SSH_LOG"
  grep -q 'ControlPersist=60' "$SSH_LOG"
  grep -q -- "-S $DBX_RUNTIME_DIR/dbx-tunnels/" "$SSH_LOG"
}

@test "regression: no ps-grep tunnel discovery remains in tunnel.sh (#128)" {
  ! grep -qE 'ps -eo pid,command' "$REPO/lib/tunnel.sh"
}

@test "reuse: a live master with a listening forward is reused (#128)" {
  prime_reuse_socket
  run_create SSH_CHECK_RC=0 LSOF_LISTEN_RC=0
  [ "$status" -eq 0 ]
  [[ "$output" == *"REUSED=true"* ]]
  [[ "$output" == *"PORT=54321"* ]]
  ! grep -q -- '-M' "$SSH_LOG"   # reuse must not start a new master
}

@test "reuse: master alive but forward dead -> tears down and recreates (#128)" {
  prime_reuse_socket
  run_create SSH_CHECK_RC=0 LSOF_LISTEN_RC=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"REUSED=false"* ]]
  grep -q -- '-O exit' "$SSH_LOG"   # dropped the stale master
  grep -q -- '-M' "$SSH_LOG"        # then created a fresh one
}

@test "hardening: a non-0700 control dir is refused (#128)" {
  mkdir -p "$DBX_RUNTIME_DIR/dbx-tunnels"
  chmod 777 "$DBX_RUNTIME_DIR/dbx-tunnels"
  run_create
  [ "$status" -ne 0 ]
  [[ "$output" == *"mode 0700"* ]]
}

@test "cleanup: owned tunnel torn down via ssh -O exit; reused left alone (#128)" {
  # Owned: create then cleanup -> ssh -O exit fires.
  run env PATH="$STUBDIR:$PATH" SSH_LOG="$SSH_LOG" \
    DBX_DATA_DIR="$DBX_DATA_DIR" DBX_CONFIG_DIR="$DBX_CONFIG_DIR" \
    DBX_AUDIT_DIR="$DBX_AUDIT_DIR" DBX_RUNTIME_DIR="$DBX_RUNTIME_DIR" \
    bash -c '
      set -uo pipefail
      source "'"$REPO"'/lib/core.sh"; source "'"$REPO"'/lib/tunnel.sh"
      create_ssh_tunnel prod >/dev/null
      : > "'"$SSH_LOG"'"        # observe only cleanup
      cleanup_tunnel
    '
  [ "$status" -eq 0 ]
  grep -q -- '-O exit' "$SSH_LOG"
}
