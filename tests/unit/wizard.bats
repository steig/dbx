#!/usr/bin/env bats
#
# Tests for the browser-detection + helper layer of `dbx wizard`.
# Server orchestration (Python subprocess, real port-binding, browser launch)
# is out of scope for unit tests — covered by manual smoke testing.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
}

# ----------------------------------------------------------------------------
# wizard_detect_browser
# ----------------------------------------------------------------------------

@test "wizard_detect_browser: SSH session returns 'ssh'" {
  SSH_TTY="/dev/pts/0" run wizard_detect_browser
  [ "$status" -eq 0 ]
  [ "$output" = "ssh" ]
}

@test "wizard_detect_browser: missing python3 returns 'no-python3'" {
  # Construct a PATH that has no python3.
  local tmpbin="$BATS_TEST_TMPDIR/bin-no-py"
  mkdir -p "$tmpbin"
  # Copy ALL of /usr/bin and /bin into tmpbin EXCEPT anything python-related,
  # OR cheaper: just put a do-nothing 'open'/'xdg-open' and nothing else.
  cat > "$tmpbin/open"     <<<'#!/bin/sh' && chmod +x "$tmpbin/open"
  cat > "$tmpbin/xdg-open" <<<'#!/bin/sh' && chmod +x "$tmpbin/xdg-open"
  PATH="$tmpbin" SSH_TTY="" run wizard_detect_browser
  [ "$status" -eq 0 ]
  [ "$output" = "no-python3" ]
}

@test "wizard_detect_browser: Linux without DISPLAY returns 'no-display'" {
  # Only meaningful when we can fake uname; skip on macOS since it always
  # passes the DISPLAY check.
  [[ "$(uname -s)" == "Linux" ]] || skip "Linux-only branch"
  SSH_TTY="" DISPLAY="" WAYLAND_DISPLAY="" run wizard_detect_browser
  [ "$status" -eq 0 ]
  [ "$output" = "no-display" ]
}

@test "wizard_detect_browser: happy path returns 'ok'" {
  # Use the real environment. Skip if python3 isn't actually available
  # (would be a different test failure, not what we're checking).
  command -v python3 >/dev/null 2>&1 || skip "python3 not on PATH"
  case "$(uname -s)" in
    Darwin) command -v open >/dev/null 2>&1 || skip "open not on PATH" ;;
    Linux)  [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] || skip "no display set" ;;
  esac
  SSH_TTY="" run wizard_detect_browser
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

# ----------------------------------------------------------------------------
# wizard_find_free_port
# ----------------------------------------------------------------------------

@test "wizard_find_free_port: returns a usable port number" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not on PATH"
  run wizard_find_free_port
  [ "$status" -eq 0 ]
  # Should be a positive integer in the dynamic/private range (1024–65535).
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -ge 1024 ]
  [ "$output" -le 65535 ]
}

# ----------------------------------------------------------------------------
# wizard_make_token
# ----------------------------------------------------------------------------

@test "wizard_make_token: returns 32 hex characters" {
  run wizard_make_token
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{32}$ ]]
}

@test "wizard_make_token: two consecutive calls produce different values" {
  local a b
  a=$(wizard_make_token)
  b=$(wizard_make_token)
  [ "$a" != "$b" ]
}

# ----------------------------------------------------------------------------
# wizard_port_available
# ----------------------------------------------------------------------------

@test "wizard_port_available: succeeds on a free port" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not on PATH"
  local port
  port=$(wizard_find_free_port)
  run wizard_port_available "$port"
  [ "$status" -eq 0 ]
}

@test "wizard_port_available: fails on a port currently bound" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not on PATH"
  # Bind a port in a background python process, then assert the helper fails.
  python3 -c "
import socket, sys, time
s = socket.socket(); s.bind(('127.0.0.1', 0)); s.listen()
print(s.getsockname()[1], flush=True)
time.sleep(5)
" > "$BATS_TEST_TMPDIR/port.out" 2>&1 &
  local bg_pid=$!
  # Wait for the bind to actually happen (poll the output file).
  local port=""
  local _
  for _ in $(seq 1 30); do
    port=$(cat "$BATS_TEST_TMPDIR/port.out" 2>/dev/null | head -1)
    [[ -n "$port" && "$port" =~ ^[0-9]+$ ]] && break
    sleep 0.1
  done
  [ -n "$port" ]

  run wizard_port_available "$port"
  [ "$status" -ne 0 ]

  kill "$bg_pid" 2>/dev/null
  wait "$bg_pid" 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# cmd_wizard argument handling (smoke-test for the new --remote / --port flags)
# ----------------------------------------------------------------------------

@test "dbx wizard --help advertises --remote and --port" {
  run "$DBX_BIN" wizard --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--remote"* ]]
  [[ "$output" == *"--port"* ]]
  [[ "$output" == *"ssh -L"* ]]
}

@test "dbx wizard --help advertises -v/--verbose" {
  run "$DBX_BIN" wizard --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--verbose"* ]]
  [[ "$output" == *"-v"* ]]
  # Description should mention what verbose actually does, not just exist.
  [[ "$output" == *"server"*"log"* ]] || [[ "$output" == *"stream"* ]]
}

@test "dbx wizard --port with non-numeric value errors with 'Invalid --port'" {
  # --no-browser short-circuits before port validation, so we use --remote
  # to force the path into server-mode where the numeric check fires.
  run "$DBX_BIN" wizard --remote --port abc
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid --port"* ]] || [[ "$output" == *"Port out of range"* ]]
}

@test "dbx wizard --port out-of-range errors clearly" {
  run "$DBX_BIN" wizard --remote --port 99999
  [ "$status" -ne 0 ]
  [[ "$output" == *"out of range"* ]]
}

# ----------------------------------------------------------------------------
# cmd_serve — #126: loopback-by-default + --allow-host
# ----------------------------------------------------------------------------

@test "dbx serve --help: loopback is the default, expose is opt-in (#126)" {
  run "$DBX_BIN" serve --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"127.0.0.1"* ]]
  [[ "$output" == *"--bind"* ]]
}

@test "dbx serve --help advertises --allow-host + DBX_SERVE_ALLOW_HOST (#126)" {
  run "$DBX_BIN" serve --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--allow-host"* ]]
  [[ "$output" == *"DBX_SERVE_ALLOW_HOST"* ]]
}
