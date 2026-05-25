#!/usr/bin/env bash
# lib/wizard.sh - Browser-driven config wizard for `dbx wizard`.
#
# Requires: core.sh (for log_*, die, require_jq, CONFIG_FILE, LIB_DIR).
# python3 is a runtime dep for browser mode; absence triggers gum fallback.

# Detect whether we can plausibly open a GUI browser AND run the local
# server. Echoes "ok" on success, or a one-word reason ("ssh",
# "no-python3", "no-display", "no-launcher") on failure. Always returns 0.
wizard_detect_browser() {
  [[ -n "${SSH_TTY:-}" ]] && { echo "ssh"; return 0; }
  command -v python3 >/dev/null 2>&1 || { echo "no-python3"; return 0; }
  case "$(uname -s)" in
    Darwin) command -v open >/dev/null 2>&1 || { echo "no-launcher"; return 0; } ;;
    Linux)
      [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && { echo "no-display"; return 0; }
      command -v xdg-open >/dev/null 2>&1 || { echo "no-launcher"; return 0; }
      ;;
    *)
      command -v xdg-open >/dev/null 2>&1 || command -v open >/dev/null 2>&1 \
        || { echo "no-launcher"; return 0; }
      ;;
  esac
  echo "ok"
}

# Find a free local port via Python's socket library.
wizard_find_free_port() {
  python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1]); s.close()"
}

# 32-hex-char random token for the URL.
wizard_make_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    head -c 16 /dev/urandom | od -An -vtx1 | tr -d ' \n'
  fi
}

# OS-aware browser launcher (best-effort; fork-and-forget).
wizard_open_browser() {
  local url="$1"
  case "$(uname -s)" in
    Darwin) open "$url" >/dev/null 2>&1 & ;;
    Linux)  xdg-open "$url" >/dev/null 2>&1 & ;;
    *)
      if command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 &
      elif command -v open >/dev/null 2>&1; then open "$url" >/dev/null 2>&1 &
      fi ;;
  esac
}

cmd_wizard() {
  local mode="auto"  # auto | browser | no-browser
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-browser) mode="no-browser"; shift ;;
      --browser)    mode="browser";    shift ;;
      -h|--help)
        cat <<EOF
Usage: dbx wizard [--no-browser | --browser]

Opens a browser-based config builder at http://127.0.0.1:<port> and writes
the result to ~/.config/dbx/config.json. Falls back to the gum-driven
'dbx host add' wizard when no GUI browser is available.

Flags:
  --no-browser   Force the gum wizard (skip browser detection).
  --browser      Require browser mode (exit non-zero if unavailable).
EOF
        return 0
        ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  if [[ "$mode" == "no-browser" ]]; then
    log_info "Browser mode skipped (--no-browser); using gum wizard."
    host_add
    return $?
  fi

  local detect
  detect=$(wizard_detect_browser)
  if [[ "$detect" != "ok" ]]; then
    if [[ "$mode" == "browser" ]]; then
      die "Browser mode unavailable: $detect. Install python3 + a GUI browser, or drop --browser."
    fi
    log_info "Browser mode unavailable ($detect); using gum wizard."
    host_add
    return $?
  fi

  require_jq

  local token port done_marker html_template form_fragment backups_fragment restore_fragment schedule_fragment dbx_bin
  token=$(wizard_make_token)
  port=$(wizard_find_free_port)
  done_marker=$(mktemp -t dbx-wizard.XXXXXX)
  html_template="$LIB_DIR/wizard.html"
  form_fragment="$LIB_DIR/wizard-form.html"
  backups_fragment="$LIB_DIR/wizard-backups.html"
  restore_fragment="$LIB_DIR/wizard-restore.html"
  schedule_fragment="$LIB_DIR/wizard-schedule.html"
  # Resolve the dbx binary so the wizard server can spawn `dbx restore` even
  # when this clone isn't on PATH (common in dev: `./dbx wizard`). SCRIPT_DIR
  # is set at the top of the dbx script and is always absolute.
  dbx_bin="$SCRIPT_DIR/dbx"

  [[ -f "$html_template"     ]] || die "Wizard HTML missing: $html_template (re-run install.sh to repair)"
  [[ -f "$form_fragment"     ]] || die "Wizard form fragment missing: $form_fragment (re-run install.sh to repair)"
  [[ -f "$backups_fragment"  ]] || die "Wizard backups fragment missing: $backups_fragment (re-run install.sh to repair)"
  [[ -f "$restore_fragment"  ]] || die "Wizard restore fragment missing: $restore_fragment (re-run install.sh to repair)"
  [[ -f "$schedule_fragment" ]] || die "Wizard schedule fragment missing: $schedule_fragment (re-run install.sh to repair)"

  mkdir -p "$(dirname "$CONFIG_FILE")"

  local server_log server_script
  server_log=$(mktemp -t dbx-wizard-srv.XXXXXX)
  server_script="$LIB_DIR/wizard-server.py"
  [[ -f "$server_script" ]] || die "Wizard server missing: $server_script (re-run install.sh to repair)"

  python3 "$server_script" \
    --port "$port" \
    --token "$token" \
    --html "$html_template" \
    --form-fragment "$form_fragment" \
    --backups-fragment "$backups_fragment" \
    --restore-fragment "$restore_fragment" \
    --schedule-fragment "$schedule_fragment" \
    --config-path "$CONFIG_FILE" \
    --data-dir "$DATA_DIR" \
    --dbx-bin "$dbx_bin" \
    --lib-dir "$LIB_DIR" \
    --done-marker "$done_marker" \
    >"$server_log" 2>&1 &
  local srv_pid=$!

  trap 'kill '"$srv_pid"' 2>/dev/null; rm -f '"$done_marker"' '"$server_log"'' EXIT INT TERM

  local ready=false
  local _
  for _ in $(seq 1 20); do
    if kill -0 "$srv_pid" 2>/dev/null; then
      if python3 -c "import socket; s=socket.socket(); s.settimeout(0.2); s.connect(('127.0.0.1', $port)); s.close()" 2>/dev/null; then
        ready=true; break
      fi
    fi
    sleep 0.1
  done
  if [[ "$ready" != "true" ]]; then
    log_error "Wizard server failed to start. Output:"
    cat "$server_log" >&2 || true
    return 1
  fi

  local url="http://127.0.0.1:$port/?token=$token"
  log_step "Config wizard ready"
  log_info "  URL:     $url"
  log_info "  Output:  $CONFIG_FILE"
  log_info "  Timeout: 10 minutes"
  log_info "Opening browser..."
  wizard_open_browser "$url"
  log_info "Waiting for you to submit the form (Ctrl-C to cancel)..."

  local elapsed=0
  while [[ ! -s "$done_marker" ]]; do
    if ! kill -0 "$srv_pid" 2>/dev/null; then
      log_error "Wizard server exited unexpectedly. Output:"
      cat "$server_log" >&2 || true
      return 1
    fi
    sleep 0.5
    elapsed=$((elapsed + 1))
    if [[ "$elapsed" -ge 1200 ]]; then
      log_warn "Timed out after 10 minutes with no form submission."
      return 1
    fi
  done

  echo ""
  log_success "Config written to $CONFIG_FILE"
  log_info "Next steps:"
  log_info "  • Set passwords:    dbx vault set <alias>"
  log_info "  • Validate config:  dbx config validate"
  log_info "  • Test connection:  dbx test <alias>"
}
