#!/usr/bin/env bash
#
# db-lib/tunnel.sh - SSH tunnel management for remote database connections
#
# Requires: core.sh to be sourced first
#

# SSH tunnel tracking (global state)
TUNNEL_PID=""
TUNNEL_LOCAL_PORT=""
TUNNEL_REUSED=false

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

create_ssh_tunnel() {
  local host="$1"

  local jump_host target_host target_port
  jump_host=$(get_tunnel_config "$host" "jump_host")
  target_host=$(get_tunnel_config "$host" "target_host")
  target_port=$(get_tunnel_config "$host" "target_port")

  # Default target_host to localhost if not specified
  target_host="${target_host:-localhost}"

  # Check if a tunnel to this target already exists
  # Use ps instead of pgrep -a for macOS compatibility
  local existing_tunnel
  existing_tunnel=$(ps -eo pid,command | grep -E "ssh.*-L.*:${target_host}:${target_port}.*${jump_host}" | grep -v grep | head -1 || true)

  if [[ -n "$existing_tunnel" ]]; then
    # Extract the local port from existing tunnel
    TUNNEL_LOCAL_PORT=$(echo "$existing_tunnel" | grep -oE '\-L [0-9]+:' | grep -oE '[0-9]+')
    TUNNEL_PID=$(echo "$existing_tunnel" | awk '{print $1}')
    TUNNEL_REUSED=true
    log_info "Reusing existing tunnel: localhost:$TUNNEL_LOCAL_PORT -> $target_host:$target_port (PID: $TUNNEL_PID)"
    return 0
  fi

  # Pick a random high port, retry if in use
  local max_attempts=5
  for ((i=1; i<=max_attempts; i++)); do
    TUNNEL_LOCAL_PORT=$((RANDOM % 50000 + 10000))
    if ! lsof -i ":$TUNNEL_LOCAL_PORT" &>/dev/null; then
      break
    fi
    [[ $i -eq $max_attempts ]] && die "Could not find available port after $max_attempts attempts"
  done

  log_info "Creating SSH tunnel: localhost:$TUNNEL_LOCAL_PORT -> $target_host:$target_port (via $jump_host)"

  # Create tunnel in background
  ssh -fN -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval=60 \
      -o ServerAliveCountMax=3 \
      -L "${TUNNEL_LOCAL_PORT}:${target_host}:${target_port}" \
      "$jump_host"

  # Find the SSH process - use ps for macOS compatibility, fallback to lsof
  sleep 1
  TUNNEL_PID=$(ps -eo pid,command | grep -E "ssh.*-L.*${TUNNEL_LOCAL_PORT}:" | grep -v grep | awk '{print $1}' | tail -1)

  # Fallback: use lsof to find process listening on our port
  if [[ -z "$TUNNEL_PID" ]]; then
    sleep 1
    TUNNEL_PID=$(lsof -ti ":$TUNNEL_LOCAL_PORT" 2>/dev/null | head -1)
  fi

  if [[ -z "$TUNNEL_PID" ]]; then
    die "Failed to create SSH tunnel (could not find tunnel process)"
  fi

  TUNNEL_REUSED=false
  log_success "Tunnel established (PID: $TUNNEL_PID)"

  # Set trap to cleanup tunnel on exit (only if we created it)
  trap cleanup_tunnel EXIT INT TERM
}

cleanup_tunnel() {
  # Don't kill tunnels we didn't create (reused from another process)
  if [[ "$TUNNEL_REUSED" == "true" ]]; then
    return 0
  fi
  if [[ -n "$TUNNEL_PID" ]]; then
    log_info "Closing SSH tunnel (PID: $TUNNEL_PID)"
    kill "$TUNNEL_PID" 2>/dev/null || true
    TUNNEL_PID=""
  fi
}

get_effective_host() {
  local host="$1"
  if has_ssh_tunnel "$host"; then
    # Docker containers can't reach localhost on host - use host.docker.internal on macOS
    if [[ "$(uname)" == "Darwin" ]]; then
      echo "host.docker.internal"
    else
      echo "172.17.0.1"  # Docker bridge gateway on Linux
    fi
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
