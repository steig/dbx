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

# Probe whether a specific port is bindable on 127.0.0.1. Echoes nothing on
# success; on failure echoes a reason and returns non-zero. Used by --port.
wizard_port_available() {
  local port="$1"
  python3 -c "
import socket, sys
try:
    s = socket.socket()
    s.bind(('127.0.0.1', $port))
    s.close()
except OSError as e:
    print(f'port $port unavailable: {e}', file=sys.stderr)
    sys.exit(1)
"
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
  local mode="auto"  # auto | browser | no-browser | remote
  local user_port=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-browser) mode="no-browser"; shift ;;
      --browser)    mode="browser";    shift ;;
      --remote)     mode="remote";     shift ;;
      --port)       user_port="${2:-}"; shift 2 ;;
      --port=*)     user_port="${1#--port=}"; shift ;;
      -h|--help)
        cat <<EOF
Usage: dbx wizard [--no-browser | --browser | --remote] [--port N]

Opens a browser-based config builder + control panel at
http://127.0.0.1:<port> and writes the result to ~/.config/dbx/config.json.
Falls back to the gum-driven 'dbx host add' wizard when no GUI browser is
available locally.

Flags:
  --no-browser   Force the gum wizard (skip browser detection).
  --browser      Require browser mode (exit non-zero if unavailable).
  --remote       Server-only mode for SSH-tunneled access: skips the
                 SSH/no-display fallback and does NOT try to launch a
                 browser. Prints the URL + a sample 'ssh -L' command so
                 you can forward the port from your laptop. Bind stays
                 on 127.0.0.1; use SSH for transport.
  --port N       Pin the local port (default: OS-assigned free port).
                 Useful with --remote so the SSH tunnel command is stable.
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

  # --remote needs python3 but not a GUI launcher and ignores SSH_TTY.
  if [[ "$mode" == "remote" ]]; then
    command -v python3 >/dev/null 2>&1 \
      || die "Remote mode requires python3 on the host."
  else
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
  fi

  require_jq

  local token port done_marker html_template form_fragment backups_fragment backup_fragment restore_fragment schedule_fragment runs_fragment dashboard_fragment vault_fragment storage_fragment scrub_fragment analyze_fragment dbx_bin audit_dir
  token=$(wizard_make_token)
  if [[ -n "$user_port" ]]; then
    [[ "$user_port" =~ ^[0-9]+$ ]] || die "Invalid --port value: $user_port"
    (( user_port >= 1 && user_port <= 65535 )) || die "Port out of range: $user_port"
    wizard_port_available "$user_port" || die "Cannot bind 127.0.0.1:$user_port — already in use?"
    port="$user_port"
  else
    port=$(wizard_find_free_port)
  fi
  done_marker=$(mktemp -t dbx-wizard.XXXXXX)
  html_template="$LIB_DIR/wizard.html"
  form_fragment="$LIB_DIR/wizard-form.html"
  backups_fragment="$LIB_DIR/wizard-backups.html"
  backup_fragment="$LIB_DIR/wizard-backup.html"
  restore_fragment="$LIB_DIR/wizard-restore.html"
  schedule_fragment="$LIB_DIR/wizard-schedule.html"
  runs_fragment="$LIB_DIR/wizard-runs.html"
  dashboard_fragment="$LIB_DIR/wizard-dashboard.html"
  vault_fragment="$LIB_DIR/wizard-vault.html"
  storage_fragment="$LIB_DIR/wizard-storage.html"
  scrub_fragment="$LIB_DIR/wizard-scrub.html"
  analyze_fragment="$LIB_DIR/wizard-analyze.html"
  # AUDIT_LOG_DIR is exported by core.sh (line 646) and already respects
  # $DBX_AUDIT_DIR, so it's the single source of truth for the audit-log
  # location across the CLI and the wizard server.
  audit_dir="${AUDIT_LOG_DIR:-${DBX_AUDIT_DIR:-$HOME/.local/share/dbx}}"
  # Resolve the dbx binary so the wizard server can spawn `dbx restore` even
  # when this clone isn't on PATH (common in dev: `./dbx wizard`). SCRIPT_DIR
  # is set at the top of the dbx script and is always absolute.
  dbx_bin="$SCRIPT_DIR/dbx"

  [[ -f "$html_template"     ]] || die "Wizard HTML missing: $html_template (re-run install.sh to repair)"
  [[ -f "$form_fragment"     ]] || die "Wizard form fragment missing: $form_fragment (re-run install.sh to repair)"
  [[ -f "$backups_fragment"  ]] || die "Wizard backups fragment missing: $backups_fragment (re-run install.sh to repair)"
  [[ -f "$backup_fragment"   ]] || die "Wizard backup fragment missing: $backup_fragment (re-run install.sh to repair)"
  [[ -f "$restore_fragment"  ]] || die "Wizard restore fragment missing: $restore_fragment (re-run install.sh to repair)"
  [[ -f "$schedule_fragment" ]] || die "Wizard schedule fragment missing: $schedule_fragment (re-run install.sh to repair)"
  [[ -f "$runs_fragment"     ]] || die "Wizard runs fragment missing: $runs_fragment (re-run install.sh to repair)"
  [[ -f "$dashboard_fragment" ]] || die "Wizard dashboard fragment missing: $dashboard_fragment (re-run install.sh to repair)"
  [[ -f "$vault_fragment"     ]] || die "Wizard vault fragment missing: $vault_fragment (re-run install.sh to repair)"
  [[ -f "$storage_fragment"   ]] || die "Wizard storage fragment missing: $storage_fragment (re-run install.sh to repair)"
  [[ -f "$scrub_fragment"    ]] || die "Wizard scrub fragment missing: $scrub_fragment (re-run install.sh to repair)"
  [[ -f "$analyze_fragment"  ]] || die "Wizard analyze fragment missing: $analyze_fragment (re-run install.sh to repair)"

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
    --backup-fragment "$backup_fragment" \
    --restore-fragment "$restore_fragment" \
    --schedule-fragment "$schedule_fragment" \
    --runs-fragment "$runs_fragment" \
    --dashboard-fragment "$dashboard_fragment" \
    --vault-fragment "$vault_fragment" \
    --storage-fragment "$storage_fragment" \
    --scrub-fragment "$scrub_fragment" \
    --analyze-fragment "$analyze_fragment" \
    --config-path "$CONFIG_FILE" \
    --data-dir "$DATA_DIR" \
    --audit-dir "$audit_dir" \
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
  if [[ "$mode" == "remote" ]]; then
    log_step "Wizard ready (remote mode)"
    log_info "  URL:        $url"
    log_info "  Output:     $CONFIG_FILE"
    log_info "  Tunnel via: ssh -L $port:127.0.0.1:$port <this-host>"
    log_info "  Then open:  http://localhost:$port/?token=$token"
    log_info "  Timeout:    10 minutes  (Ctrl-C to cancel)"
  else
    log_step "Config wizard ready"
    log_info "  URL:     $url"
    log_info "  Output:  $CONFIG_FILE"
    log_info "  Timeout: 10 minutes"
    log_info "Opening browser..."
    wizard_open_browser "$url"
    log_info "Waiting for you to submit the form (Ctrl-C to cancel)..."
  fi

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
