#!/usr/bin/env bats
#
# Tests for the pure/near-pure helpers in lib/tunnel.sh (#148): tunnel config
# lookup, the effective host/port a dump command is pointed at, control-socket
# path derivation, control-dir hardening, and the cleanup_tunnel branches.
#
# create_ssh_tunnel itself (reuse, retry, teardown) is covered in tunnel.bats
# with `ssh`/`lsof` stubbed on PATH. Here the libs are sourced directly into
# the test shell, so `ssh` and `lsof` are stubbed as shell functions instead —
# no PATH manipulation, and nothing to accidentally match a tmpdir path.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
  export DBX_RUNTIME_DIR="$BATS_TEST_TMPDIR/runtime"
  SSH_CALLS="$BATS_TEST_TMPDIR/ssh.calls"; : > "$SSH_CALLS"
  LSOF_CALLS="$BATS_TEST_TMPDIR/lsof.calls"; : > "$LSOF_CALLS"
}

ssh() { printf '%s\n' "$*" >> "$SSH_CALLS"; return 0; }
lsof() { printf '%s\n' "$*" >> "$LSOF_CALLS"; return "${LSOF_RC:-0}"; }

file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

TUNNELED='{"hosts":{"prod":{"host":"db.example.com","port":5432,
  "ssh_tunnel":{"jump_host":"bastion","target_host":"db.internal","target_port":"5432"}},
  "local":{"host":"127.0.0.1","port":15432}}}'

# ---------------------------------------------------------------------------
# has_ssh_tunnel / get_tunnel_config
# ---------------------------------------------------------------------------

@test "has_ssh_tunnel: true when the host declares one" {
  write_config "$TUNNELED"
  run has_ssh_tunnel prod
  [ "$status" -eq 0 ]
}

@test "has_ssh_tunnel: false when the host has no ssh_tunnel key" {
  write_config "$TUNNELED"
  run has_ssh_tunnel local
  [ "$status" -ne 0 ]
}

@test "has_ssh_tunnel: an explicit null is treated as no tunnel" {
  write_config '{"hosts":{"prod":{"host":"db","ssh_tunnel":null}}}'
  run has_ssh_tunnel prod
  [ "$status" -ne 0 ]
}

@test "has_ssh_tunnel: an unknown host is false, not an error" {
  write_config '{"hosts":{}}'
  run has_ssh_tunnel nope
  [ "$status" -ne 0 ]
}

@test "get_tunnel_config: reads a named field" {
  write_config "$TUNNELED"
  [ "$(get_tunnel_config prod jump_host)" = "bastion" ]
  [ "$(get_tunnel_config prod target_host)" = "db.internal" ]
  [ "$(get_tunnel_config prod target_port)" = "5432" ]
}

@test "get_tunnel_config: an absent field is empty" {
  write_config "$TUNNELED"
  [ -z "$(get_tunnel_config prod identity_file)" ]
}

# ---------------------------------------------------------------------------
# get_effective_host / get_effective_port — where pg_dump actually connects
# ---------------------------------------------------------------------------

@test "get_effective_host: a tunnelled host resolves to the container's host gateway" {
  write_config "$TUNNELED"
  [ "$(get_effective_host prod)" = "host.docker.internal" ]
}

@test "get_effective_host: a direct host resolves to its configured address" {
  write_config "$TUNNELED"
  [ "$(get_effective_host local)" = "127.0.0.1" ]
}

@test "get_effective_port: a tunnelled host uses the live local forward port" {
  write_config "$TUNNELED"
  TUNNEL_LOCAL_PORT=54321
  [ "$(get_effective_port prod)" = "54321" ]
}

@test "get_effective_port: a tunnelled host falls back to config before the tunnel is up" {
  write_config "$TUNNELED"
  TUNNEL_LOCAL_PORT=""
  [ "$(get_effective_port prod)" = "5432" ]
}

@test "get_effective_port: a direct host ignores a leftover TUNNEL_LOCAL_PORT" {
  # A multi-host run can reach a direct host with TUNNEL_LOCAL_PORT still set
  # from a previous tunnelled one; the direct host must use its own port.
  write_config "$TUNNELED"
  TUNNEL_LOCAL_PORT=54321
  [ "$(get_effective_port local)" = "15432" ]
}

# ---------------------------------------------------------------------------
# _tunnel_control_path — deterministic, target-keyed socket names
# ---------------------------------------------------------------------------

@test "_tunnel_control_path: same target yields the same path" {
  a=$(_tunnel_control_path bastion db.internal 5432)
  b=$(_tunnel_control_path bastion db.internal 5432)
  [ "$a" = "$b" ]
}

@test "_tunnel_control_path: lives in the control dir as a 32-hex .sock name" {
  p=$(_tunnel_control_path bastion db.internal 5432)
  [[ "$p" == "$DBX_RUNTIME_DIR/dbx-tunnels/"* ]]
  base=$(basename "$p")
  [[ "$base" =~ ^[0-9a-f]{32}\.sock$ ]]
}

@test "_tunnel_control_path: each of the three target parts changes the key" {
  base=$(_tunnel_control_path bastion db.internal 5432)
  [ "$(_tunnel_control_path other db.internal 5432)" != "$base" ]
  [ "$(_tunnel_control_path bastion other.internal 5432)" != "$base" ]
  [ "$(_tunnel_control_path bastion db.internal 5433)" != "$base" ]
}

@test "_tunnel_control_path: fails when the control dir is unusable" {
  mkdir -p "$DBX_RUNTIME_DIR/dbx-tunnels"
  chmod 755 "$DBX_RUNTIME_DIR/dbx-tunnels"
  run _tunnel_control_path bastion db.internal 5432
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# _tunnel_control_dir — per-user 0700 dir, self-authenticating (#128)
# ---------------------------------------------------------------------------

@test "_tunnel_control_dir: creates the dir at mode 0700" {
  run _tunnel_control_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$DBX_RUNTIME_DIR/dbx-tunnels" ]
  [ -d "$output" ]
  [ "$(file_mode "$output")" = "700" ]
}

@test "_tunnel_control_dir: an existing 0700 dir is accepted as-is" {
  mkdir -p "$DBX_RUNTIME_DIR/dbx-tunnels"
  chmod 700 "$DBX_RUNTIME_DIR/dbx-tunnels"
  run _tunnel_control_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$DBX_RUNTIME_DIR/dbx-tunnels" ]
}

@test "_tunnel_control_dir: a group/world-accessible dir is refused, not chmod-ed" {
  mkdir -p "$DBX_RUNTIME_DIR/dbx-tunnels"
  chmod 750 "$DBX_RUNTIME_DIR/dbx-tunnels"
  run _tunnel_control_dir
  [ "$status" -ne 0 ]
  [[ "$output" == *"mode 0700"* ]]
  # The hostile dir keeps its permissions — refusing must not repair it.
  [ "$(file_mode "$DBX_RUNTIME_DIR/dbx-tunnels")" = "750" ]
}

@test "_tunnel_control_dir: DBX_RUNTIME_DIR wins over XDG_RUNTIME_DIR" {
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$XDG_RUNTIME_DIR"
  run _tunnel_control_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$DBX_RUNTIME_DIR/dbx-tunnels" ]
}

@test "_tunnel_control_dir: falls back to XDG_RUNTIME_DIR when DBX_RUNTIME_DIR is unset" {
  unset DBX_RUNTIME_DIR
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$XDG_RUNTIME_DIR"
  run _tunnel_control_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$XDG_RUNTIME_DIR/dbx-tunnels" ]
}

@test "_tunnel_control_dir: falls back to DATA_DIR when neither runtime dir is set" {
  unset DBX_RUNTIME_DIR XDG_RUNTIME_DIR
  run _tunnel_control_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$DATA_DIR/dbx-tunnels" ]
}

# ---------------------------------------------------------------------------
# _tunnel_port_listening
# ---------------------------------------------------------------------------

@test "_tunnel_port_listening: asks lsof for a LISTEN socket on that port" {
  LSOF_RC=0 _tunnel_port_listening 54321
  grep -q -- '-i :54321' "$LSOF_CALLS"
  grep -q -- '-sTCP:LISTEN' "$LSOF_CALLS"
}

@test "_tunnel_port_listening: propagates lsof's verdict" {
  LSOF_RC=0 run _tunnel_port_listening 54321
  [ "$status" -eq 0 ]
  LSOF_RC=1 run _tunnel_port_listening 54321
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# cleanup_tunnel — the three branches
# ---------------------------------------------------------------------------

# Lay down a socket + port sidecar as create_ssh_tunnel would leave them.
_prime_owned_tunnel() {
  mkdir -p "$DBX_RUNTIME_DIR/dbx-tunnels"
  chmod 700 "$DBX_RUNTIME_DIR/dbx-tunnels"
  TUNNEL_CONTROL_PATH="$DBX_RUNTIME_DIR/dbx-tunnels/deadbeef.sock"
  TUNNEL_JUMP_HOST="bastion"
  : > "$TUNNEL_CONTROL_PATH"
  echo 54321 > "${TUNNEL_CONTROL_PATH%.sock}.port"
}

@test "cleanup_tunnel: an owned tunnel is closed via ssh -O exit and its files removed" {
  _prime_owned_tunnel
  TUNNEL_REUSED=false
  cleanup_tunnel
  grep -q -- "-O exit -S $DBX_RUNTIME_DIR/dbx-tunnels/deadbeef.sock bastion" "$SSH_CALLS"
  [ ! -e "$DBX_RUNTIME_DIR/dbx-tunnels/deadbeef.sock" ]
  [ ! -e "$DBX_RUNTIME_DIR/dbx-tunnels/deadbeef.port" ]
  [ -z "$TUNNEL_CONTROL_PATH" ]
}

@test "cleanup_tunnel: a reused tunnel is left alone for the run that owns it" {
  _prime_owned_tunnel
  TUNNEL_REUSED=true
  run cleanup_tunnel
  [ "$status" -eq 0 ]
  [ ! -s "$SSH_CALLS" ]
  [ -e "$DBX_RUNTIME_DIR/dbx-tunnels/deadbeef.sock" ]
  [ -e "$DBX_RUNTIME_DIR/dbx-tunnels/deadbeef.port" ]
}

@test "cleanup_tunnel: no tunnel was opened → nothing happens" {
  TUNNEL_REUSED=false
  TUNNEL_CONTROL_PATH=""
  run cleanup_tunnel
  [ "$status" -eq 0 ]
  [ ! -s "$SSH_CALLS" ]
}

@test "cleanup_tunnel: is idempotent — a second call is a no-op" {
  _prime_owned_tunnel
  TUNNEL_REUSED=false
  cleanup_tunnel
  : > "$SSH_CALLS"
  cleanup_tunnel
  [ ! -s "$SSH_CALLS" ]
}
