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

  local token port done_marker html_template form_fragment
  token=$(wizard_make_token)
  port=$(wizard_find_free_port)
  done_marker=$(mktemp -t dbx-wizard.XXXXXX)
  html_template="$LIB_DIR/wizard.html"
  form_fragment="$LIB_DIR/wizard-form.html"

  [[ -f "$html_template" ]] || die "Wizard HTML missing: $html_template (re-run install.sh to repair)"
  [[ -f "$form_fragment" ]] || die "Wizard form fragment missing: $form_fragment (re-run install.sh to repair)"

  mkdir -p "$(dirname "$CONFIG_FILE")"

  local server_log
  server_log=$(mktemp -t dbx-wizard-srv.XXXXXX)
  DBX_WIZARD_TOKEN="$token" \
  DBX_WIZARD_PORT="$port" \
  DBX_WIZARD_HTML="$html_template" \
  DBX_WIZARD_FRAGMENT="$form_fragment" \
  DBX_WIZARD_OUTPUT="$CONFIG_FILE" \
  DBX_WIZARD_DONE="$done_marker" \
  python3 - <<'PY' >"$server_log" 2>&1 &
import http.server, json, os, sys, urllib.parse

TOKEN    = os.environ["DBX_WIZARD_TOKEN"]
PORT     = int(os.environ["DBX_WIZARD_PORT"])
HTML     = os.environ["DBX_WIZARD_HTML"]
FRAGMENT = os.environ["DBX_WIZARD_FRAGMENT"]
OUTPUT   = os.environ["DBX_WIZARD_OUTPUT"]
DONE     = os.environ["DBX_WIZARD_DONE"]

def parse_query(path):
    q = urllib.parse.urlparse(path).query
    return urllib.parse.parse_qs(q)

def valid_token(path):
    qs = parse_query(path)
    return qs.get("token", [None])[0] == TOKEN

def compose_html():
    with open(HTML) as f: shell = f.read()
    with open(FRAGMENT) as f: frag = f.read()
    save_url = f"http://127.0.0.1:{PORT}/save?token={TOKEN}"
    return shell.replace("<!-- __DBX_FORM_FRAGMENT__ -->", frag) \
                .replace("__DBX_SAVE_URL__", save_url)

class H(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body=b"", ctype="text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if body: self.wfile.write(body if isinstance(body, bytes) else body.encode())

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/" and valid_token(self.path):
            try: html = compose_html()
            except Exception as e:
                self._send(500, f"compose failed: {e}"); return
            self._send(200, html, "text/html; charset=utf-8")
            return
        if path == "/":
            self._send(403, "missing or bad token"); return
        self._send(404, "not found")

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if path != "/save" or not valid_token(self.path):
            self._send(403, "forbidden"); return
        length = int(self.headers.get("Content-Length", 0))
        if length <= 0 or length > 1_000_000:
            self._send(400, "bad length"); return
        raw = self.rfile.read(length)
        try:
            cfg = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as e:
            self._send(400, f"invalid json: {e}"); return
        try:
            os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
            with open(OUTPUT, "w") as f:
                json.dump(cfg, f, indent=2)
                f.write("\n")
            os.chmod(OUTPUT, 0o600)
        except OSError as e:
            self._send(500, f"write failed: {e}"); return
        with open(DONE, "w") as f: f.write("ok\n")
        self._send(200, '{"ok":true}', "application/json")

    def log_message(self, *args, **kwargs): pass

httpd = http.server.HTTPServer(("127.0.0.1", PORT), H)
try: httpd.serve_forever()
except KeyboardInterrupt: pass
PY
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
