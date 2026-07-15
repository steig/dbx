#!/usr/bin/env bash
#
# db-lib/tunnel.sh - SSH tunnel management for remote database connections
#
# Requires: core.sh to be sourced first
#

# SSH tunnel tracking (global state)
TUNNEL_LOCAL_PORT=""
TUNNEL_REUSED=false
TUNNEL_CONTROL_PATH=""   # ssh ControlMaster socket for this run's target
TUNNEL_JUMP_HOST=""      # destination for `ssh -O exit` at teardown

# ============================================================================
# SSH Tunnel Functions
# ============================================================================

has_ssh_tunnel() {
  local host="$1"
  local tunnel_config
  tunnel_config=$(get_config_value ".hosts[\"$host\"].ssh_tunnel")
  [[ -n "$tunnel_config" && "$tunnel_config" != "null" ]]
}

get_tunnel_config() {
  local host="$1"
  local field="$2"
  get_config_value ".hosts[\"$host\"].ssh_tunnel.$field"
}

# Per-user directory (0700) holding ControlMaster sockets and their sidecar
# .port files. A socket living in a uid-owned 0700 dir is self-authenticating:
# only this user could have created it, so reuse can trust it without parsing
# `ps` (which any local user can spoof, #128). Prefers a tmpfs runtime dir.
_tunnel_control_dir() {
  local base dir owner mode
  base="${DBX_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-$DATA_DIR}}"
  dir="$base/dbx-tunnels"
  # Only create + lock down when absent; an existing dir is verified AS-IS below
  # (chmod-ing it first would mask a hostile pre-created dir).
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir" 2>/dev/null || { log_error "Cannot create tunnel control dir: $dir"; return 1; }
    chmod 700 "$dir" 2>/dev/null || true
  fi
  # Refuse a dir we don't own or that isn't 0700 — defends against a pre-created
  # attacker dir. Returns non-zero (the caller die()s) rather than die()ing here:
  # this runs inside $(...), where a die/exit would only kill the subshell.
  # stat: GNU (-c) then BSD (-f).
  owner=$(stat -c '%u' "$dir" 2>/dev/null || stat -f '%u' "$dir" 2>/dev/null || echo "")
  mode=$(stat -c '%a' "$dir" 2>/dev/null || stat -f '%Lp' "$dir" 2>/dev/null || echo "")
  [[ "$owner" == "$(id -u)" ]] || { log_error "Tunnel control dir not owned by current user: $dir"; return 1; }
  [[ "$mode" == "700" ]] || { log_error "Tunnel control dir must be mode 0700: $dir (got ${mode:-?})"; return 1; }
  printf '%s' "$dir"
}

# Deterministic control-socket path for a target, keyed by a hash of the tunnel
# parameters (not a guessable name). Reuses the portable _sha256_stdin helper.
_tunnel_control_path() {
  local jump_host="$1" target_host="$2" target_port="$3" dir key
  dir=$(_tunnel_control_dir) || return 1
  key=$(printf '%s' "${jump_host}|${target_host}|${target_port}" | _sha256_stdin | cut -c1-32)
  printf '%s/%s.sock' "$dir" "$key"
}

# True if something is listening on the given local TCP port.
_tunnel_port_listening() {
  lsof -i ":$1" -sTCP:LISTEN &>/dev/null
}

# Open an SSH tunnel for the given host using an ssh ControlMaster socket as the
# authoritative reuse + teardown handle (no `ps` parsing). Reuses a live master
# we own for the same target so concurrent dbx runs share one forward. Sets:
#   TUNNEL_LOCAL_PORT   — port to use as the effective DB port
#   TUNNEL_REUSED       — true if an existing master was reused; cleanup then
#                         leaves it alone so a concurrent run isn't cut off
#   TUNNEL_CONTROL_PATH — the control socket (teardown handle)
# Returns 0 on success; die()s on unrecoverable failure (the established
# contract — callers either ignore the return or treat non-success as fatal).
# Installs an EXIT/INT/TERM trap calling cleanup_tunnel (chained with
# cleanup_secrets so tunneled runs still scrub credentials on exit).
create_ssh_tunnel() {
  local host="$1"

  local jump_host target_host target_port
  jump_host=$(get_tunnel_config "$host" "jump_host")
  target_host=$(get_tunnel_config "$host" "target_host")
  target_port=$(get_tunnel_config "$host" "target_port")
  target_host="${target_host:-localhost}"

  local ctl portfile
  ctl=$(_tunnel_control_path "$jump_host" "$target_host" "$target_port") \
    || die "Cannot prepare SSH tunnel control directory"
  portfile="${ctl%.sock}.port"
  TUNNEL_CONTROL_PATH="$ctl"
  TUNNEL_JUMP_HOST="$jump_host"

  # Reuse: a live master we own, whose forward is still listening?
  if ssh -O check -S "$ctl" "$jump_host" 2>/dev/null; then
    local port
    port=$(cat "$portfile" 2>/dev/null || echo "")
    if [[ -n "$port" ]] && _tunnel_port_listening "$port"; then
      TUNNEL_LOCAL_PORT="$port"
      TUNNEL_REUSED=true
      log_info "Reusing SSH tunnel: localhost:$port -> $target_host:$target_port (control: $ctl)"
      return 0
    fi
    # Master alive but the forward is gone/unknown — drop it and recreate so we
    # never route DB traffic at a port that isn't actually forwarded.
    ssh -O exit -S "$ctl" "$jump_host" 2>/dev/null || true
    rm -f "$portfile"
  fi

  # A leftover socket file from a crashed run blocks `ssh -M` creation; clear it.
  if [[ -e "$ctl" ]]; then
    ssh -O exit -S "$ctl" "$jump_host" 2>/dev/null || true
    rm -f "$ctl"
  fi

  # Pick a local port and start the master. ExitOnForwardFailure makes ssh's own
  # bind the authoritative check (closes the lsof TOCTOU): a bind clash returns
  # non-zero and we try the next port. ControlPersist keeps the master briefly
  # alive after this run so a follow-up dbx command reuses it.
  local max_attempts=5 i port
  for ((i=1; i<=max_attempts; i++)); do
    port=$((RANDOM % 50000 + 10000))
    if lsof -i ":$port" &>/dev/null; then
      continue
    fi
    log_info "Creating SSH tunnel: localhost:$port -> $target_host:$target_port (via $jump_host)"
    if ssh -fN -M -S "$ctl" \
        -o ControlPersist=60 \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=60 \
        -o ServerAliveCountMax=3 \
        -L "${port}:${target_host}:${target_port}" \
        "$jump_host"; then
      TUNNEL_LOCAL_PORT="$port"
      ( umask 077; printf '%s\n' "$port" > "$portfile" )
      TUNNEL_REUSED=false
      log_success "Tunnel established (control: $ctl)"
      trap 'cleanup_tunnel; cleanup_secrets' EXIT INT TERM
      return 0
    fi
    # bind/forward failure — try another port
  done
  die "Failed to create SSH tunnel after $max_attempts attempts"
}

cleanup_tunnel() {
  # Don't tear down a master another run is reusing.
  if [[ "$TUNNEL_REUSED" == "true" ]]; then
    return 0
  fi
  if [[ -n "$TUNNEL_CONTROL_PATH" ]]; then
    log_info "Closing SSH tunnel (control: $TUNNEL_CONTROL_PATH)"
    ssh -O exit -S "$TUNNEL_CONTROL_PATH" "${TUNNEL_JUMP_HOST:-x}" 2>/dev/null || true
    rm -f "$TUNNEL_CONTROL_PATH" "${TUNNEL_CONTROL_PATH%.sock}.port"
    TUNNEL_CONTROL_PATH=""
  fi
}

# Hostname to point pg_dump / mysqldump at. Echoes either:
#   - host.docker.internal — when an SSH tunnel is active; the tunnel
#     bound to the dbx host can be reached from inside the
#     postgres-dbx / mysql-dbx containers via the host-gateway alias
#     (added on container creation, see require_container in core.sh).
#   - .hosts[host].host — direct connection, no tunnel.
get_effective_host() {
  local host="$1"
  if has_ssh_tunnel "$host"; then
    # Containers reach the host at host.docker.internal — added via
    # --add-host=...:host-gateway when require_container creates them.
    # Works on Docker Desktop (mac/win), rootful and rootless Docker,
    # and Podman, regardless of which network the container is on.
    echo "host.docker.internal"
  else
    get_config_value ".hosts[\"$host\"].host"
  fi
}

get_effective_port() {
  local host="$1"
  if has_ssh_tunnel "$host" && [[ -n "$TUNNEL_LOCAL_PORT" ]]; then
    echo "$TUNNEL_LOCAL_PORT"
  else
    get_config_value ".hosts[\"$host\"].port"
  fi
}
