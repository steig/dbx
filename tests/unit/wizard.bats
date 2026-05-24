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
