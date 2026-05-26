#!/usr/bin/env bats
#
# Tests for lib/wizard-server.py — the Python HTTP server backing `dbx
# wizard`. Spawns a real server against fixture HTML + a fake `dbx` shim,
# curls endpoints, asserts shape and status. No docker / no real dbx.

load '../helpers/common'

WIZ_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

setup() {
  setup_dbx_env

  WIZ_SCRATCH="$BATS_TEST_TMPDIR/wiz"
  # Sandbox HOME so /api/schedules' `schedule_installed_read` walks an
  # empty launchd/systemd dir under the scratch tree rather than the
  # developer's real ~/Library/LaunchAgents (which could contain real
  # com.dbx.backup.* plists and contaminate the test).
  mkdir -p "$WIZ_SCRATCH/home/Library/LaunchAgents" \
           "$WIZ_SCRATCH/home/.config/systemd/user"
  export HOME="$WIZ_SCRATCH/home"
  mkdir -p "$WIZ_SCRATCH/data/prod/myapp"
  touch    "$WIZ_SCRATCH/data/prod/myapp/myapp_20260520_120000.sql.zst"
  cat > "$WIZ_SCRATCH/data/prod/myapp/myapp_20260520_120000.sql.zst.meta.json" <<'JSON'
{"timestamp":"2026-05-20T12:00:00Z","source_flavor":"postgres","source_major_version":"17"}
JSON

  # Sandbox the age-recipients file under the scratch dir so the vault
  # endpoints don't read/write the developer's real ~/.config/dbx/.
  export DBX_AGE_RECIPIENTS="$WIZ_SCRATCH/age-recipients.txt"
  export DBX_CONFIG_DIR="$WIZ_SCRATCH"

  # Fake dbx that:
  #   * echoes argv for the standard restore/backup runs the existing tests
  #     already check ("[INFO] cmd=…")
  #   * mocks `vault list`, `vault info`, `vault get`, `vault set`, `vault
  #     delete` enough for the vault endpoint tests to assert on.
  # The vault store is a flat file at $WIZ_SCRATCH/vault.tsv (key\tvalue).
  cat > "$WIZ_SCRATCH/dbx" <<'SH'
#!/usr/bin/env bash
# Path to the fake vault store. Lives under the test scratch dir so each
# test gets a clean slate via setup_dbx_env + BATS_TEST_TMPDIR.
VAULT_STORE="${WIZ_SCRATCH:-${BATS_TEST_TMPDIR:-/tmp}/wiz}/vault.tsv"
mkdir -p "$(dirname "$VAULT_STORE")"
[[ -f "$VAULT_STORE" ]] || : > "$VAULT_STORE"

case "$1 $2" in
  "analyze"*|"analyze "*)
    # Real CLI takes positional host + db; here $1=analyze, $2=<host>, $3=<db>.
    # Tests set DBX_FAKE_ANALYZE_FAIL=1 to flip to a non-zero exit + stderr.
    # Tests set DBX_FAKE_ANALYZE_STDERR=<text> to add a log-step-style line
    # to stderr alongside a successful JSON, exercising the stderr-on-200
    # diagnostics path.
    if [[ "${DBX_FAKE_ANALYZE_FAIL:-}" == "1" ]]; then
      echo "could not connect: connection refused" >&2
      exit 1
    fi
    if [[ -n "${DBX_FAKE_ANALYZE_STDERR:-}" ]]; then
      printf '%s\n' "$DBX_FAKE_ANALYZE_STDERR" >&2
    fi
    cat <<JSON
{
  "host": "$2",
  "database": "$3",
  "engine": "mysql",
  "totals": { "tables": 2, "rows": 1200, "size_bytes": 1048576 },
  "tables": [
    { "name": "users",    "rows": 1000, "size_bytes": 786432, "excluded": false },
    { "name": "sessions", "rows":  200, "size_bytes": 262144, "excluded": true }
  ],
  "pii": [
    { "table": "users", "columns": ["email", "phone"] }
  ]
}
JSON
    exit 0
    ;;
  "scrub init")
    cat <<'JSON'
{
  "version": "1",
  "seed_env": "DBX_SCRUB_SEED",
  "tables": {
    "users": {
      "columns": {
        "email": { "strategy": "fake_email" },
        "id":    { "strategy": "passthrough", "reason": "primary key" }
      }
    }
  }
}
JSON
    exit 0
    ;;
  "scrub check")
    if [[ "${DBX_FAKE_SCRUB_CHECK_DRIFT:-}" == "1" ]]; then
      cat <<'JSON'
{
  "ok": false,
  "new_columns_with_dict_match": [
    { "table": "users", "column": "phone", "pattern": "phone",
      "suggested": { "strategy": "fake_phone" } }
  ],
  "new_tables_with_dict_matches": [],
  "missing_declared_columns": [],
  "json_columns_undeclared": []
}
JSON
      exit 2
    fi
    cat <<'JSON'
{
  "ok": true,
  "new_columns_with_dict_match": [],
  "new_tables_with_dict_matches": [],
  "missing_declared_columns": [],
  "json_columns_undeclared": []
}
JSON
    exit 0
    ;;
  "vault list")
    echo "Stored credentials:"
    if [[ -s "$VAULT_STORE" ]]; then
      while IFS=$'\t' read -r k _; do
        [[ -n "$k" ]] && echo "  $k"
      done < "$VAULT_STORE"
    else
      echo "  (none)"
    fi
    exit 0
    ;;
  "vault info")
    echo "Vault backend: keychain"
    echo "Location: macOS Keychain (service: test)"
    exit 0
    ;;
  "vault get")
    key="$3"
    val=$(awk -F'\t' -v k="$key" '$1==k {print $2; exit}' "$VAULT_STORE")
    if [[ -n "$val" ]]; then
      echo "$val"
      exit 0
    fi
    echo "No credentials found for: $key" >&2
    exit 1
    ;;
  "vault set")
    key="$3"
    read -rs val
    # remove any existing entry, append new
    tmp=$(mktemp)
    awk -F'\t' -v k="$key" '$1!=k' "$VAULT_STORE" > "$tmp" || true
    printf '%s\t%s\n' "$key" "$val" >> "$tmp"
    mv "$tmp" "$VAULT_STORE"
    exit 0
    ;;
  "vault delete")
    key="$3"
    tmp=$(mktemp)
    awk -F'\t' -v k="$key" '$1!=k' "$VAULT_STORE" > "$tmp" || true
    mv "$tmp" "$VAULT_STORE"
    exit 0
    ;;
esac

echo "[INFO] cmd=$*"
echo "[INFO] line 1"
echo "[OK] done"
SH
  chmod +x "$WIZ_SCRATCH/dbx"
  # The fake dbx reads $WIZ_SCRATCH at runtime via env; bats setup_dbx_env
  # exports it but make it explicit for clarity.
  export WIZ_SCRATCH

  WIZ_TOKEN="testtoken1234567890abcdef00000000"
  WIZ_PORT="$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()")"
  WIZ_DONE="$WIZ_SCRATCH/done"

  # Sandbox the audit dir under the scratch tree so /api/audit-log doesn't
  # read the developer's real ~/.local/share/dbx/audit.log.
  mkdir -p "$WIZ_SCRATCH/audit"
  WIZ_AUDIT_DIR="$WIZ_SCRATCH/audit"

  python3 "$WIZ_REPO_ROOT/lib/wizard-server.py" \
    --port "$WIZ_PORT" \
    --token "$WIZ_TOKEN" \
    --html             "$WIZ_REPO_ROOT/lib/wizard.html" \
    --form-fragment     "$WIZ_REPO_ROOT/lib/wizard-form.html" \
    --backups-fragment  "$WIZ_REPO_ROOT/lib/wizard-backups.html" \
    --backup-fragment   "$WIZ_REPO_ROOT/lib/wizard-backup.html" \
    --restore-fragment  "$WIZ_REPO_ROOT/lib/wizard-restore.html" \
    --schedule-fragment "$WIZ_REPO_ROOT/lib/wizard-schedule.html" \
    --runs-fragment     "$WIZ_REPO_ROOT/lib/wizard-runs.html" \
    --dashboard-fragment "$WIZ_REPO_ROOT/lib/wizard-dashboard.html" \
    --vault-fragment    "$WIZ_REPO_ROOT/lib/wizard-vault.html" \
    --storage-fragment   "$WIZ_REPO_ROOT/lib/wizard-storage.html" \
    --scrub-fragment    "$WIZ_REPO_ROOT/lib/wizard-scrub.html" \
    --analyze-fragment  "$WIZ_REPO_ROOT/lib/wizard-analyze.html" \
    --config-path       "$WIZ_SCRATCH/config.json" \
    --data-dir          "$WIZ_SCRATCH/data" \
    --audit-dir         "$WIZ_AUDIT_DIR" \
    --dbx-bin           "$WIZ_SCRATCH/dbx" \
    --lib-dir           "$WIZ_REPO_ROOT/lib" \
    --done-marker       "$WIZ_DONE" \
    >"$WIZ_SCRATCH/server.log" 2>&1 &
  WIZ_PID=$!

  # Wait for the server to bind (max ~2s).
  for _ in $(seq 1 20); do
    if curl -s -o /dev/null "http://127.0.0.1:$WIZ_PORT/?token=$WIZ_TOKEN"; then break; fi
    sleep 0.1
  done
}

teardown() {
  if [[ -n "${WIZ_PID:-}" ]] && kill -0 "$WIZ_PID" 2>/dev/null; then
    kill "$WIZ_PID" 2>/dev/null
    wait "$WIZ_PID" 2>/dev/null || true
  fi
}

api() { echo "http://127.0.0.1:$WIZ_PORT$1?token=$WIZ_TOKEN"; }

@test "GET / with valid token serves composed HTML" {
  run curl -s "$(api /)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<title>dbx</title>"* ]]
  [[ "$output" == *"dbxBackups()"* ]]      # backups fragment was composed in
  [[ "$output" == *"dbxRestore()"* ]]      # restore fragment was composed in
  [[ "$output" == *"dbxBuilder()"* ]]      # config form fragment was composed in
}

@test "GET / with bad token returns 403" {
  run curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$WIZ_PORT/?token=NOPE"
  [ "$status" -eq 0 ]
  [ "$output" = "403" ]
}

@test "GET / with no token returns 403" {
  run curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$WIZ_PORT/"
  [ "$status" -eq 0 ]
  [ "$output" = "403" ]
}

@test "GET /api/backups enumerates DATA_DIR and reads meta.json" {
  run curl -s "$(api /api/backups)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"host\": \"prod\""* ]]
  [[ "$output" == *"\"database\": \"myapp\""* ]]
  [[ "$output" == *"\"source_flavor\": \"postgres\""* ]]
  [[ "$output" == *"\"source_major_version\": \"17\""* ]]
}

@test "GET /api/backups carries safety='local' when host config has no safety field" {
  # No config.json file at all in the default setup → safety defaults to 'local'.
  run curl -s "$(api /api/backups)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"safety\": \"local\""* ]]
}

@test "GET /api/backups carries safety='prod' when source host is marked prod" {
  # Plant a config.json with prod marking for the `prod` host that the
  # fixture data already lives under.
  cat > "$WIZ_SCRATCH/config.json" <<'JSON'
{ "hosts": { "prod": { "type": "postgres", "user": "u", "safety": "prod" } } }
JSON
  run curl -s "$(api /api/backups)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"host\": \"prod\""* ]]
  [[ "$output" == *"\"safety\": \"prod\""* ]]
}

@test "GET /api/backups carries safety='local' when host has a malformed safety value" {
  # Mirrors the bash-side host_safety: any non-{prod,stage,local} value
  # falls back to 'local' so a typo can't silently promote a host.
  cat > "$WIZ_SCRATCH/config.json" <<'JSON'
{ "hosts": { "prod": { "type": "postgres", "user": "u", "safety": "production" } } }
JSON
  run curl -s "$(api /api/backups)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"safety\": \"local\""* ]]
}

@test "GET /api/backups with bad token returns 403" {
  run curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$WIZ_PORT/api/backups?token=NOPE"
  [ "$status" -eq 0 ]
  [ "$output" = "403" ]
}

@test "GET /api/containers returns a JSON array" {
  run curl -s "$(api /api/containers)"
  [ "$status" -eq 0 ]
  # Even with no docker, the endpoint returns [] (200) — never errors out.
  [[ "$output" == "["* ]]
  [[ "$output" == *"]" ]]
}

@test "POST /api/restore rejects missing source" {
  run curl -s -X POST -H "Content-Type: application/json" -d '{}' "$(api /api/restore)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"source is required"* ]]
}

@test "POST /api/restore rejects source outside data-dir" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"source":"/etc/passwd"}' "$(api /api/restore)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"data-dir"* ]] || [[ "$output" == *"host/db/latest"* ]]
}

@test "POST /api/restore rejects shell-metachar name" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"source":"prod/myapp/latest","name":"bad;rm -rf"}' "$(api /api/restore)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"name must match"* ]]
}

@test "POST /api/restore rejects non-boolean flag" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"source":"prod/myapp/latest","no_scrub":"yes"}' "$(api /api/restore)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no_scrub must be a boolean"* ]]
}

@test "POST /api/restore with valid input returns a job_id" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"source":"prod/myapp/latest"}' "$(api /api/restore)"
  [ "$status" -eq 0 ]
  [[ "$output" =~ \"job_id\":\ ?\"[0-9a-f]{32}\" ]]
}

@test "SSE /api/jobs/<id>/events streams lines + done event" {
  local body job_id
  body=$(curl -s -X POST -H "Content-Type: application/json" \
    -d '{"source":"prod/myapp/latest"}' "$(api /api/restore)")
  job_id=$(echo "$body" | python3 -c "import sys,json;print(json.load(sys.stdin)['job_id'])")
  [ -n "$job_id" ]
  # Read up to ~3s; the fake dbx exits almost immediately. `--max-time` is
  # curl's own timeout (portable; macOS doesn't have GNU `timeout`).
  run curl -s -N --max-time 3 "http://127.0.0.1:$WIZ_PORT/api/jobs/$job_id/events?token=$WIZ_TOKEN"
  [[ "$output" == *"line 1"* ]]
  [[ "$output" == *"[OK] done"* ]]
  [[ "$output" == *"event: done"* ]]
  [[ "$output" == *'"exit_code": 0'* ]]
}

@test "POST /api/backup rejects missing host" {
  echo '{"hosts":[{"alias":"prod"}]}' > "$WIZ_SCRATCH/config.json"
  run curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" -d '{}' "$(api /api/backup)"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

@test "POST /api/backup rejects host not in config.json" {
  echo '{"hosts":[{"alias":"prod"}]}' > "$WIZ_SCRATCH/config.json"
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"staging"}' "$(api /api/backup)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not configured"* ]]
}

@test "POST /api/backup rejects shell-metachar database" {
  echo '{"hosts":[{"alias":"prod"}]}' > "$WIZ_SCRATCH/config.json"
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"prod","database":"bad;rm -rf"}' "$(api /api/backup)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"invalid characters"* ]]
}

@test "POST /api/backup rejects non-boolean verbose" {
  echo '{"hosts":[{"alias":"prod"}]}' > "$WIZ_SCRATCH/config.json"
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"prod","verbose":"yes"}' "$(api /api/backup)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"must be a boolean"* ]]
}

@test "POST /api/backup rejects when no hosts are configured" {
  # No config.json at all → 400 with a useful error.
  rm -f "$WIZ_SCRATCH/config.json"
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"prod"}' "$(api /api/backup)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no hosts configured"* ]]
}

@test "POST /api/backup with valid host returns a job_id" {
  echo '{"hosts":[{"alias":"prod"}]}' > "$WIZ_SCRATCH/config.json"
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"prod"}' "$(api /api/backup)"
  [ "$status" -eq 0 ]
  [[ "$output" =~ \"job_id\":\ ?\"[0-9a-f]{32}\" ]]
}

@test "POST /api/backup forwards verbose + database into argv" {
  echo '{"hosts":[{"alias":"prod"}]}' > "$WIZ_SCRATCH/config.json"
  local body job_id
  body=$(curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"prod","database":"myapp","verbose":true}' "$(api /api/backup)")
  job_id=$(echo "$body" | python3 -c "import sys,json;print(json.load(sys.stdin)['job_id'])")
  [ -n "$job_id" ]
  run curl -s -N --max-time 3 "http://127.0.0.1:$WIZ_PORT/api/jobs/$job_id/events?token=$WIZ_TOKEN"
  # The fake dbx echoes its argv on the first line.
  [[ "$output" == *"cmd=backup -v prod myapp"* ]]
}

@test "POST /api/backup accepts real dict-shaped hosts (alias-keyed)" {
  # Production configs use hosts={"alias":{...}} (an object keyed by
  # alias), not an array of objects. The earlier array shape tests cover
  # the defensive fallback; this one exercises the actual shape we're
  # likely to see in $HOME/.config/dbx/config.json.
  cat > "$WIZ_SCRATCH/config.json" <<'JSON'
{"hosts":{"prod-mysql":{"type":"mysql","user":"u","databases":{"b2b":{},"b2c":{}}}}}
JSON
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"prod-mysql"}' "$(api /api/backup)"
  [ "$status" -eq 0 ]
  [[ "$output" =~ \"job_id\":\ ?\"[0-9a-f]{32}\" ]]
}

# ---------------------------------------------------------------------------
# /api/host-test (PR-Y4) — wraps `dbx test <host>` as a streaming job so the
# dashboard can show staged ssh/container/creds/query checks.
# ---------------------------------------------------------------------------

@test "POST /api/host-test rejects missing host" {
  echo '{"hosts":[{"alias":"prod"}]}' > "$WIZ_SCRATCH/config.json"
  run curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" -d '{}' "$(api /api/host-test)"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

@test "POST /api/host-test rejects host not in config.json" {
  echo '{"hosts":[{"alias":"prod"}]}' > "$WIZ_SCRATCH/config.json"
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"staging"}' "$(api /api/host-test)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not configured"* ]]
}

@test "POST /api/host-test rejects bad-shape host (shell metachar)" {
  echo '{"hosts":[{"alias":"prod"}]}' > "$WIZ_SCRATCH/config.json"
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"bad;rm -rf"}' "$(api /api/host-test)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"invalid characters"* ]]
}

@test "POST /api/host-test with valid configured host returns a job_id" {
  echo '{"hosts":[{"alias":"prod"}]}' > "$WIZ_SCRATCH/config.json"
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"prod"}' "$(api /api/host-test)"
  [ "$status" -eq 0 ]
  [[ "$output" =~ \"job_id\":\ ?\"[0-9a-f]{32}\" ]]
}

@test "POST /api/host-test job stream contains the host name in argv echo" {
  echo '{"hosts":[{"alias":"prod"}]}' > "$WIZ_SCRATCH/config.json"
  local body job_id
  body=$(curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"prod"}' "$(api /api/host-test)")
  job_id=$(echo "$body" | python3 -c "import sys,json;print(json.load(sys.stdin)['job_id'])")
  [ -n "$job_id" ]
  run curl -s -N --max-time 3 "http://127.0.0.1:$WIZ_PORT/api/jobs/$job_id/events?token=$WIZ_TOKEN"
  # The fake dbx echoes `cmd=$*` on its first line.
  [[ "$output" == *"cmd=test prod"* ]]
  [[ "$output" == *"event: done"* ]]
}

@test "POST /api/jobs/<bad-id>/cancel returns 404" {
  run curl -s -o /dev/null -w "%{http_code}" -X POST \
    "$(api /api/jobs/00000000000000000000000000000000/cancel)"
  [ "$status" -eq 0 ]
  [ "$output" = "404" ]
}

@test "POST /save still writes config.json (existing behavior preserved)" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"hosts":{},"defaults":{"encryption_type":"age"}}' "$(api /save)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
  [ -f "$WIZ_SCRATCH/config.json" ]
  run cat "$WIZ_SCRATCH/config.json"
  [[ "$output" == *"\"encryption_type\": \"age\""* ]]
}

@test "GET /api/schedules returns declarative + installed + plan from config.json" {
  cat > "$WIZ_SCRATCH/config.json" <<'JSON'
{
  "hosts": { "prod": { "type": "postgres" } },
  "schedules": [
    { "host": "prod", "database": "myapp",   "when": "daily@5" },
    { "host": "prod", "database": "billing", "when": "weekly@1:3" }
  ]
}
JSON
  run curl -s "$(api /api/schedules)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"declarative\":"* ]]
  [[ "$output" == *"\"installed\":"* ]]
  [[ "$output" == *"\"plan\":"* ]]
  [[ "$output" == *"\"daily@5\""* ]]
  [[ "$output" == *"\"weekly@1:3\""* ]]
  # Plan shows "install" for both (no installed units in this isolated test env).
  [[ "$output" == *"\"action\": \"install\""* ]]
}

@test "POST /api/schedules updates config.json schedules[] and preserves other keys" {
  cat > "$WIZ_SCRATCH/config.json" <<'JSON'
{ "hosts": { "prod": { "type": "postgres" } }, "schedules": [] }
JSON
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"schedules":[{"host":"prod","database":"myapp","when":"daily@5"}]}' \
    "$(api /api/schedules)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"ok\": true"* ]]
  # config.json now contains the new schedule…
  run cat "$WIZ_SCRATCH/config.json"
  [[ "$output" == *"\"when\": \"daily@5\""* ]]
  # …and the hosts block was preserved (not clobbered).
  [[ "$output" == *"\"prod\""* ]]
  [[ "$output" == *"\"postgres\""* ]]
}

@test "POST /api/schedules rejects shell-metachar host" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"schedules":[{"host":"bad;rm","database":"x","when":"daily"}]}' \
    "$(api /api/schedules)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"host must match"* ]]
}

@test "POST /api/schedules rejects missing 'when' field" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"schedules":[{"host":"prod","database":"x"}]}' \
    "$(api /api/schedules)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"when must be a string"* ]]
}

@test "POST /api/schedules rejects non-array body" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"schedules":"notalist"}' "$(api /api/schedules)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"must be a JSON array"* ]]
}

@test "POST /api/schedules rejects body without 'schedules' key" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"other":[]}' "$(api /api/schedules)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"body must be"* ]]
}

@test "GET / now composes the schedule fragment too" {
  run curl -s "$(api /)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dbxSchedule()"* ]]
}

@test "GET / now composes the backup fragment too" {
  run curl -s "$(api /)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dbxBackup()"* ]]
}

@test "GET /api/config returns existing config.json verbatim" {
  cat > "$WIZ_SCRATCH/config.json" <<'JSON'
{ "hosts": { "prod": { "type": "postgres", "user": "u" } },
  "defaults": { "encryption_type": "age", "keep_backups": 7 },
  "schedules": [{ "host": "prod", "database": "myapp", "when": "daily@5" }] }
JSON
  run curl -s "$(api /api/config)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"hosts\":"* ]]
  [[ "$output" == *"\"prod\""* ]]
  [[ "$output" == *"\"keep_backups\": 7"* ]]
  [[ "$output" == *"\"daily@5\""* ]]
}

@test "GET /api/config returns {} when config.json is missing" {
  # Default test setup doesn't create config.json — confirm clean state.
  [ ! -f "$WIZ_SCRATCH/config.json" ]
  run curl -s "$(api /api/config)"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "POST /save merges into existing config, preserving non-form keys" {
  cat > "$WIZ_SCRATCH/config.json" <<'JSON'
{ "hosts": { "previous-host": { "type": "postgres", "user": "u" } },
  "defaults": { "encryption_type": "age" },
  "schedules": [{ "host": "h", "database": "d", "when": "daily" }],
  "scrub": { "manifest": "/path/to/scrub.json" } }
JSON
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"hosts":{"new-host":{"type":"mysql","user":"u"}},"defaults":{"encryption_type":"none"}}' \
    "$(api /save)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"ok\":true"* ]]
  # Form-managed keys replaced.
  run cat "$WIZ_SCRATCH/config.json"
  [[ "$output" == *"\"new-host\""* ]]
  [[ "$output" != *"previous-host"* ]]
  [[ "$output" == *"\"encryption_type\": \"none\""* ]]
  # Non-form keys preserved.
  [[ "$output" == *"\"schedules\":"* ]]
  [[ "$output" == *"\"scrub\":"* ]]
  [[ "$output" == *"/path/to/scrub.json"* ]]
}

@test "POST /save omitting storage wipes existing storage but keeps schedules" {
  cat > "$WIZ_SCRATCH/config.json" <<'JSON'
{ "hosts": {},
  "storage": { "type": "s3", "s3": { "bucket": "old-bucket" } },
  "schedules": [{ "host": "h", "database": "d", "when": "daily" }] }
JSON
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"hosts":{"h":{"type":"postgres","user":"u"}},"defaults":{}}' \
    "$(api /save)"
  [ "$status" -eq 0 ]
  run cat "$WIZ_SCRATCH/config.json"
  # Storage form-managed but absent from payload → removed.
  [[ "$output" != *"old-bucket"* ]]
  [[ "$output" != *"\"storage\""* ]]
  # Schedules preserved (not form-managed).
  [[ "$output" == *"\"schedules\":"* ]]
}

@test "POST /save with non-object body errors with 400" {
  run curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '"justastring"' "$(api /save)"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

# ----------------------------------------------------------------------------
# /api/config-save  — Save without exiting (Save-without-exit UX split)
# ----------------------------------------------------------------------------

@test "POST /api/config-save writes config but does NOT touch the done-marker" {
  # Sanity: done-marker starts empty.
  [ ! -s "$WIZ_DONE" ]
  cat > "$WIZ_SCRATCH/config.json" <<'JSON'
{ "hosts": {}, "schedules": [{ "host": "h", "database": "d", "when": "daily" }] }
JSON
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"hosts":{"h":{"type":"postgres","user":"u"}},"defaults":{}}' \
    "$(api /api/config-save)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"ok\":true"* ]]
  # Config updated...
  run cat "$WIZ_SCRATCH/config.json"
  [[ "$output" == *"\"postgres\""* ]]
  [[ "$output" == *"\"schedules\":"* ]]
  # ...but the done-marker stays empty so the bash side doesn't exit.
  [ ! -s "$WIZ_DONE" ]
}

@test "POST /save still touches done-marker (existing behavior preserved)" {
  [ ! -s "$WIZ_DONE" ]
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"hosts":{},"defaults":{}}' "$(api /save)"
  [ "$status" -eq 0 ]
  [ -s "$WIZ_DONE" ]
}

# ----------------------------------------------------------------------------
# Backups: complete/incomplete flag + delete
# ----------------------------------------------------------------------------

@test "GET /api/backups marks complete=true when sidecar exists, false when missing" {
  # Existing fixture (from setup) has prod/myapp/myapp_20260520_120000 WITH meta.
  # Add a second backup WITHOUT a sidecar to exercise the "incomplete" path.
  mkdir -p "$WIZ_SCRATCH/data/staging/app"
  touch "$WIZ_SCRATCH/data/staging/app/app_20260601_000000.sql.zst"

  run curl -s "$(api /api/backups)"
  [ "$status" -eq 0 ]
  # Both rows present, with explicit complete flags.
  [[ "$output" == *"\"complete\": true"* ]]
  [[ "$output" == *"\"complete\": false"* ]]
}

@test "POST /api/backups/delete removes the file and its sidecar" {
  local backup="$WIZ_SCRATCH/data/prod/myapp/myapp_20260520_120000.sql.zst"
  local sidecar="$backup.meta.json"
  [ -f "$backup" ]
  [ -f "$sidecar" ]
  run curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"path\":\"$backup\"}" "$(api /api/backups/delete)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"ok\": true"* ]]
  [ ! -f "$backup" ]
  [ ! -f "$sidecar" ]
}

@test "POST /api/backups/delete handles an incomplete backup (no sidecar)" {
  mkdir -p "$WIZ_SCRATCH/data/staging/app"
  local backup="$WIZ_SCRATCH/data/staging/app/orphan.sql.zst"
  touch "$backup"
  [ -f "$backup" ]
  run curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"path\":\"$backup\"}" "$(api /api/backups/delete)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"ok\": true"* ]]
  [ ! -f "$backup" ]
}

@test "POST /api/backups/delete rejects paths outside data-dir" {
  # Create a file outside the scratch DATA_DIR and try to delete it.
  local outside="$BATS_TEST_TMPDIR/sneaky.sql.zst"
  touch "$outside"
  run curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"path\":\"$outside\"}" "$(api /api/backups/delete)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"data-dir"* ]] || [[ "$output" == *"inside"* ]]
  # File still there.
  [ -f "$outside" ]
}

@test "POST /api/backups/delete rejects non-backup file extensions" {
  local notbk="$WIZ_SCRATCH/data/prod/myapp/notes.txt"
  touch "$notbk"
  run curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"path\":\"$notbk\"}" "$(api /api/backups/delete)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup file"* ]] || [[ "$output" == *".sql.zst"* ]]
  [ -f "$notbk" ]
}

@test "POST /api/backups/delete rejects missing files" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"path\":\"$WIZ_SCRATCH/data/prod/myapp/does-not-exist.sql.zst\"}" \
    "$(api /api/backups/delete)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "POST /api/backups/delete rejects missing path field" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{}' "$(api /api/backups/delete)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"required"* ]]
}

# ----------------------------------------------------------------------------
# /api/audit-log  — recent audit-log entries for the Runs view
# ----------------------------------------------------------------------------

@test "GET / now composes the runs fragment too" {
  run curl -s "$(api /)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dbxRuns()"* ]]
}

@test "GET /api/audit-log returns [] when audit.log is missing" {
  # Default setup creates the dir but no file inside it.
  [ ! -f "$WIZ_AUDIT_DIR/audit.log" ]
  run curl -s "$(api /api/audit-log)"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "GET /api/audit-log returns parsed JSON entries newest first" {
  cat > "$WIZ_AUDIT_DIR/audit.log" <<'JSONL'
{"timestamp":"2026-05-01T10:00:00Z","action":"backup","outcome":"success","db_host":"prod","database":"app","duration_sec":"42","size":"1234567","file":"/data/prod/app/app_20260501.sql.zst"}
{"timestamp":"2026-05-02T11:00:00Z","action":"restore","outcome":"success","target_db":"app_restore","duration_sec":"30"}
{"timestamp":"2026-05-03T12:00:00Z","action":"backup","outcome":"failure","db_host":"prod","database":"app"}
JSONL
  run curl -s "$(api /api/audit-log)"
  [ "$status" -eq 0 ]
  # All three entries present.
  [[ "$output" == *"2026-05-01"* ]]
  [[ "$output" == *"2026-05-02"* ]]
  [[ "$output" == *"2026-05-03"* ]]
  # Newest first: 05-03 should appear before 05-01 in the response body.
  local pos03 pos01
  pos03=$(awk -v s="$output" 'BEGIN{print index(s, "2026-05-03")}')
  pos01=$(awk -v s="$output" 'BEGIN{print index(s, "2026-05-01")}')
  [ "$pos03" -lt "$pos01" ]
}

@test "GET /api/audit-log?action=backup filters to backup entries only" {
  cat > "$WIZ_AUDIT_DIR/audit.log" <<'JSONL'
{"timestamp":"2026-05-01T10:00:00Z","action":"backup","outcome":"success","db_host":"prod","database":"app"}
{"timestamp":"2026-05-02T11:00:00Z","action":"restore","outcome":"success","target_db":"app"}
{"timestamp":"2026-05-03T12:00:00Z","action":"vault_set","outcome":"success","account":"prod"}
JSONL
  run curl -s "$(api /api/audit-log)&action=backup"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"action\": \"backup\""* ]]
  # Other actions must not appear.
  [[ "$output" != *"\"restore\""* ]]
  [[ "$output" != *"vault_set"* ]]
}

@test "GET /api/audit-log?action=BOGUS returns 400" {
  run curl -s -o /dev/null -w "%{http_code}" "$(api /api/audit-log)&action=BOGUS"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

@test "GET /api/audit-log?limit=99999 returns 400" {
  run curl -s -o /dev/null -w "%{http_code}" "$(api /api/audit-log)&limit=99999"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

@test "GET /api/audit-log?limit=0 returns 400" {
  run curl -s -o /dev/null -w "%{http_code}" "$(api /api/audit-log)&limit=0"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

@test "GET /api/audit-log?limit=notanumber returns 400" {
  run curl -s -o /dev/null -w "%{http_code}" "$(api /api/audit-log)&limit=abc"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

@test "GET /api/audit-log honors the limit parameter" {
  # Write 10 entries; ask for 3; expect 3 newest.
  : > "$WIZ_AUDIT_DIR/audit.log"
  for i in 01 02 03 04 05 06 07 08 09 10; do
    echo "{\"timestamp\":\"2026-05-${i}T10:00:00Z\",\"action\":\"backup\",\"outcome\":\"success\",\"db_host\":\"prod\",\"database\":\"app\"}" >> "$WIZ_AUDIT_DIR/audit.log"
  done
  run curl -s "$(api /api/audit-log)&limit=3"
  [ "$status" -eq 0 ]
  # 3 newest = 08, 09, 10 — must include them and NOT include 01.
  [[ "$output" == *"2026-05-10"* ]]
  [[ "$output" == *"2026-05-09"* ]]
  [[ "$output" == *"2026-05-08"* ]]
  [[ "$output" != *"2026-05-01"* ]]
}

@test "GET /api/audit-log silently skips malformed lines" {
  cat > "$WIZ_AUDIT_DIR/audit.log" <<'JSONL'
{"timestamp":"2026-05-01T10:00:00Z","action":"backup","outcome":"success","db_host":"prod","database":"app"}
this is not json at all
{"timestamp":"2026-05-02T11:00:00Z","action":"backup","outcome":"success","db_host":"prod","database":"app"}
JSONL
  run curl -s "$(api /api/audit-log)"
  [ "$status" -eq 0 ]
  # The two good lines are returned; the bad line is silently dropped.
  [[ "$output" == *"2026-05-01"* ]]
  [[ "$output" == *"2026-05-02"* ]]
  [[ "$output" != *"not json"* ]]
}

@test "GET /api/audit-log with bad token returns 403" {
  run curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$WIZ_PORT/api/audit-log?token=NOPE"
  [ "$status" -eq 0 ]
  [ "$output" = "403" ]
}

# ----------------------------------------------------------------------------
# /api/dashboard  — composed landing-tab payload
# ----------------------------------------------------------------------------

@test "GET / now composes the dashboard fragment too" {
  run curl -s "$(api /)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dbxDashboard()"* ]]
}

@test "GET /api/dashboard with bad token returns 403" {
  run curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$WIZ_PORT/api/dashboard?token=NOPE"
  [ "$status" -eq 0 ]
  [ "$output" = "403" ]
}

@test "GET /api/dashboard returns empty cards when DATA_DIR is empty" {
  # Strip the fixture so DATA_DIR is bare. The dir itself still exists.
  rm -rf "$WIZ_SCRATCH/data"
  mkdir -p "$WIZ_SCRATCH/data"
  run curl -s "$(api /api/dashboard)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"cards\": []"* ]]
  [[ "$output" == *"\"total_backups\": 0"* ]]
  [[ "$output" == *"\"hosts\": 0"* ]]
  [[ "$output" == *"\"databases\": 0"* ]]
}

@test "GET /api/dashboard returns one card per host/db pair on disk" {
  # The default fixture has prod/myapp with one file.
  run curl -s "$(api /api/dashboard)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"host\": \"prod\""* ]]
  [[ "$output" == *"\"database\": \"myapp\""* ]]
  [[ "$output" == *"\"total_backups\": 1"* ]]
  [[ "$output" == *"\"databases\": 1"* ]]
}

@test "GET /api/dashboard reports status=fresh when audit-log success is <24h old" {
  # Touch the fixture file so its mtime is recent (some test environments
  # set mtime to the install time, which would already be stale).
  touch "$WIZ_SCRATCH/data/prod/myapp/myapp_20260520_120000.sql.zst"
  # Audit-log row within the last 24h.
  local recent_ts
  recent_ts=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=2)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  cat > "$WIZ_AUDIT_DIR/audit.log" <<JSONL
{"timestamp":"$recent_ts","action":"backup","outcome":"success","db_host":"prod","database":"myapp","size":"1234","file":"/data/prod/myapp/recent.sql.zst"}
JSONL
  run curl -s "$(api /api/dashboard)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"status\": \"fresh\""* ]]
  [[ "$output" == *"\"fresh\": 1"* ]]
}

@test "GET /api/dashboard reports status=stale when most recent backup is >7d old" {
  # The fixture's file is named myapp_20260520_120000 but its mtime is
  # whatever `touch` produced during setup (== now-ish). Force the mtime
  # to 10 days ago so the on-disk side reads stale even without an audit
  # row. Use python to avoid BSD vs GNU touch flag differences.
  python3 -c "
import os, time
p = '$WIZ_SCRATCH/data/prod/myapp/myapp_20260520_120000.sql.zst'
ten_days_ago = time.time() - 86400 * 10
os.utime(p, (ten_days_ago, ten_days_ago))
"
  # Audit-log row from 10 days ago so the timestamp also reads stale.
  local stale_ts
  stale_ts=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=10)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  cat > "$WIZ_AUDIT_DIR/audit.log" <<JSONL
{"timestamp":"$stale_ts","action":"backup","outcome":"success","db_host":"prod","database":"myapp","size":"1234","file":"/data/prod/myapp/old.sql.zst"}
JSONL
  run curl -s "$(api /api/dashboard)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"status\": \"stale\""* ]]
  [[ "$output" == *"\"stale\": 1"* ]]
}

@test "GET /api/dashboard surfaces next_scheduled from config.json schedules[]" {
  cat > "$WIZ_SCRATCH/config.json" <<'JSON'
{
  "hosts": { "prod": { "type": "postgres" } },
  "schedules": [ { "host": "prod", "database": "myapp", "when": "daily@2" } ]
}
JSON
  run curl -s "$(api /api/dashboard)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"next_scheduled\":"* ]]
  [[ "$output" == *"\"when\": \"daily@2\""* ]]
  # next_at must be a future ISO 8601 Z timestamp.
  [[ "$output" =~ \"next_at\":\ \"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:00:00Z\" ]]
}

@test "GET /api/dashboard sorts stale cards before fresh cards" {
  # Two pairs: prod/myapp (already in fixture) becomes the stale one,
  # staging/recent gets touched with a fresh mtime.
  python3 -c "
import os, time
p = '$WIZ_SCRATCH/data/prod/myapp/myapp_20260520_120000.sql.zst'
os.utime(p, (time.time() - 86400 * 10, time.time() - 86400 * 10))
"
  mkdir -p "$WIZ_SCRATCH/data/staging/recent"
  touch "$WIZ_SCRATCH/data/staging/recent/r.sql.zst"
  run curl -s "$(api /api/dashboard)"
  [ "$status" -eq 0 ]
  # Stale prod row appears earlier in the body than the fresh staging row.
  local pos_stale pos_fresh
  pos_stale=$(awk -v s="$output" 'BEGIN{print index(s, "\"host\": \"prod\"")}')
  pos_fresh=$(awk -v s="$output" 'BEGIN{print index(s, "\"host\": \"staging\"")}')
  [ "$pos_stale" -gt 0 ]
  [ "$pos_fresh" -gt 0 ]
  [ "$pos_stale" -lt "$pos_fresh" ]
}

@test "GET /api/dashboard exposes last_failure when audit log has a failure row" {
  local fail_ts
  fail_ts=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=4)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  cat > "$WIZ_AUDIT_DIR/audit.log" <<JSONL
{"timestamp":"$fail_ts","action":"backup","outcome":"failure","db_host":"prod","database":"myapp","error":"pg_dump: connection refused"}
JSONL
  run curl -s "$(api /api/dashboard)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"last_failure\":"* ]]
  [[ "$output" == *"pg_dump: connection refused"* ]]
}


# /api/audit-log new filters: date range, regex, outcome, result envelope.
# Triggering ANY new param flips the response to the envelope shape:
#   {"entries": [...], "total": N, "filtered": M}
# Legacy callers (no new params) still see a bare array — see existing tests.
# ----------------------------------------------------------------------------

@test "GET /api/audit-log?from=&to= filters by date range" {
  cat > "$WIZ_AUDIT_DIR/audit.log" <<'JSONL'
{"timestamp":"2026-04-15T10:00:00Z","action":"backup","outcome":"success","db_host":"old","database":"app"}
{"timestamp":"2026-05-10T11:00:00Z","action":"backup","outcome":"success","db_host":"prod","database":"app"}
{"timestamp":"2026-05-20T12:00:00Z","action":"backup","outcome":"success","db_host":"prod","database":"app"}
{"timestamp":"2026-06-05T13:00:00Z","action":"backup","outcome":"success","db_host":"new","database":"app"}
JSONL
  run curl -s "$(api /api/audit-log)&from=2026-05-01&to=2026-05-31"
  [ "$status" -eq 0 ]
  # In-range entries present.
  [[ "$output" == *"2026-05-10"* ]]
  [[ "$output" == *"2026-05-20"* ]]
  # Out-of-range entries absent.
  [[ "$output" != *"2026-04-15"* ]]
  [[ "$output" != *"2026-06-05"* ]]
  # Envelope shape activated by the new params.
  [[ "$output" == *"\"entries\""* ]]
  [[ "$output" == *"\"total\""* ]]
  [[ "$output" == *"\"filtered\""* ]]
}

@test "GET /api/audit-log?q=prod-mysql regex-matches over entry text" {
  cat > "$WIZ_AUDIT_DIR/audit.log" <<'JSONL'
{"timestamp":"2026-05-01T10:00:00Z","action":"backup","outcome":"success","db_host":"prod-mysql","database":"orders"}
{"timestamp":"2026-05-02T11:00:00Z","action":"backup","outcome":"success","db_host":"stage-pg","database":"orders"}
{"timestamp":"2026-05-03T12:00:00Z","action":"restore","outcome":"failure","target_db":"prod-mysql-restore"}
JSONL
  run curl -s "$(api /api/audit-log)&q=prod-mysql"
  [ "$status" -eq 0 ]
  # Both rows mentioning prod-mysql come back; stage-pg does not.
  [[ "$output" == *"prod-mysql"* ]]
  [[ "$output" != *"stage-pg"* ]]
}

@test "GET /api/audit-log?q=[[[[ returns 400 with invalid-regex error" {
  : > "$WIZ_AUDIT_DIR/audit.log"
  # URL-encode the brackets to keep curl from treating them specially.
  run curl -s -o /tmp/wiz_invalid_regex_body -w "%{http_code}" \
    "$(api /api/audit-log)&q=%5B%5B%5B%5B"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
  run cat /tmp/wiz_invalid_regex_body
  [[ "$output" == *"invalid regex"* ]]
  rm -f /tmp/wiz_invalid_regex_body
}

@test "GET /api/audit-log?outcome=failure filters to failures only" {
  cat > "$WIZ_AUDIT_DIR/audit.log" <<'JSONL'
{"timestamp":"2026-05-01T10:00:00Z","action":"backup","outcome":"success","db_host":"prod","database":"app"}
{"timestamp":"2026-05-02T11:00:00Z","action":"backup","outcome":"failure","db_host":"prod","database":"app"}
{"timestamp":"2026-05-03T12:00:00Z","action":"restore","outcome":"failure","target_db":"app"}
JSONL
  run curl -s "$(api /api/audit-log)&outcome=failure"
  [ "$status" -eq 0 ]
  # Both failures present; the success is excluded.
  [[ "$output" == *"\"outcome\": \"failure\""* ]]
  [[ "$output" != *"\"outcome\": \"success\""* ]]
  # Envelope reports total=3 (whole window) and filtered=2 (just failures).
  [[ "$output" == *"\"total\": 3"* ]]
  [[ "$output" == *"\"filtered\": 2"* ]]
}

@test "GET /api/audit-log?outcome=BOGUS returns 400" {
  run curl -s -o /dev/null -w "%{http_code}" "$(api /api/audit-log)&outcome=BOGUS"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

@test "GET /api/audit-log result envelope contains entries/total/filtered" {
  cat > "$WIZ_AUDIT_DIR/audit.log" <<'JSONL'
{"timestamp":"2026-05-01T10:00:00Z","action":"backup","outcome":"success","db_host":"prod","database":"app"}
{"timestamp":"2026-05-02T11:00:00Z","action":"restore","outcome":"success","target_db":"app"}
JSONL
  # format=v2 opts into the envelope without needing a filter.
  run curl -s "$(api /api/audit-log)&format=v2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"entries\""* ]]
  [[ "$output" == *"\"total\": 2"* ]]
  [[ "$output" == *"\"filtered\": 2"* ]]
}

# ----------------------------------------------------------------------------
# /api/vault/*  — vault management endpoints (PR-Y3)
# ----------------------------------------------------------------------------

@test "GET / now composes the vault fragment too" {
  run curl -s "$(api /)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dbxVault()"* ]]
}

@test "GET /api/vault/list returns an empty array when no credentials stored" {
  # Fresh setup → fake vault store is empty.
  run curl -s "$(api /api/vault/list)"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "GET /api/vault/list returns rows after seeding the fake store" {
  # Seed via the same POST endpoint that the UI uses.
  curl -s -X POST -H "Content-Type: application/json" \
    -d '{"key":"prod-mysql","value":"hunter2"}' \
    "$(api /api/vault/set)" >/dev/null
  run curl -s "$(api /api/vault/list)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"key\": \"prod-mysql\""* ]]
  [[ "$output" == *"\"backend\": \"macos-keychain\""* ]]
}

@test "GET /api/vault/get with valid key returns the stored value" {
  curl -s -X POST -H "Content-Type: application/json" \
    -d '{"key":"prod-mysql","value":"hunter2"}' \
    "$(api /api/vault/set)" >/dev/null
  run curl -s "$(api /api/vault/get)&key=prod-mysql"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"key\": \"prod-mysql\""* ]]
  [[ "$output" == *"\"value\": \"hunter2\""* ]]
}

@test "GET /api/vault/get rejects bad key shape with 400" {
  run curl -s -o /dev/null -w "%{http_code}" "$(api /api/vault/get)&key=bad;rm"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

@test "POST /api/vault/set rejects bad key shape with 400" {
  run curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d '{"key":"bad;rm","value":"x"}' "$(api /api/vault/set)"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

@test "POST /api/vault/set rejects oversized value (>4096 bytes) with 400" {
  # 5000-char payload — well over the 4096-byte cap.
  local big
  big=$(python3 -c "print('x' * 5000)")
  run curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"key\":\"prod-mysql\",\"value\":\"$big\"}" "$(api /api/vault/set)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"exceeds"* ]] || [[ "$output" == *"4096"* ]]
}

@test "POST /api/vault/set with non-dict body returns 400" {
  run curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d '"just-a-string"' "$(api /api/vault/set)"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

@test "POST /api/vault/delete happy path returns 200" {
  curl -s -X POST -H "Content-Type: application/json" \
    -d '{"key":"prod-mysql","value":"hunter2"}' \
    "$(api /api/vault/set)" >/dev/null
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"key":"prod-mysql"}' "$(api /api/vault/delete)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"ok\": true"* ]]
}

@test "POST /api/vault/delete rejects bad key shape with 400" {
  run curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d '{"key":"bad;rm"}' "$(api /api/vault/delete)"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

@test "GET /api/vault/age-recipients returns {path, recipients} from the sandbox file" {
  cat > "$DBX_AGE_RECIPIENTS" <<'TXT'
# header comment, should be filtered out
age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
age1zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz
TXT
  run curl -s "$(api /api/vault/age-recipients)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"path\":"* ]]
  [[ "$output" == *"age-recipients.txt"* ]]
  [[ "$output" == *"age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"* ]]
  [[ "$output" == *"age1zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"* ]]
  # Comment must not appear.
  [[ "$output" != *"header comment"* ]]
}

@test "GET /api/vault/age-recipients returns empty list when file is missing" {
  [ ! -f "$DBX_AGE_RECIPIENTS" ]
  run curl -s "$(api /api/vault/age-recipients)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"recipients\": []"* ]]
}

@test "POST /api/vault/age-recipients/add rejects invalid recipient shape" {
  run curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d '{"recipient":"not-an-age-key"}' "$(api /api/vault/age-recipients/add)"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

@test "POST /api/vault/age-recipients/add happy path appends a line" {
  local recipient="age1abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmn0pqrs"
  run curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"recipient\":\"$recipient\"}" "$(api /api/vault/age-recipients/add)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"ok\": true"* ]]
  [ -f "$DBX_AGE_RECIPIENTS" ]
  run cat "$DBX_AGE_RECIPIENTS"
  [[ "$output" == *"$recipient"* ]]
}

@test "POST /api/vault/age-recipients/add preserves comment lines on append" {
  # Seed with a comment and one recipient.
  cat > "$DBX_AGE_RECIPIENTS" <<'TXT'
# managed by dbx
age1zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz
TXT
  local new="age1abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmn0pqrs"
  curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"recipient\":\"$new\"}" "$(api /api/vault/age-recipients/add)" >/dev/null
  run cat "$DBX_AGE_RECIPIENTS"
  [[ "$output" == *"# managed by dbx"* ]]
  [[ "$output" == *"age1zzzz"* ]]
  [[ "$output" == *"$new"* ]]
}

@test "POST /api/vault/age-recipients/remove removes a line" {
  local r1="age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
  local r2="age1zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
  cat > "$DBX_AGE_RECIPIENTS" <<TXT
$r1
$r2
TXT
  run curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"recipient\":\"$r1\"}" "$(api /api/vault/age-recipients/remove)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"ok\": true"* ]]
  run cat "$DBX_AGE_RECIPIENTS"
  [[ "$output" != *"$r1"* ]]
  [[ "$output" == *"$r2"* ]]
}

@test "GET /api/vault/list with bad token returns 403" {
  run curl -s -o /dev/null -w "%{http_code}" \
    "http://127.0.0.1:$WIZ_PORT/api/vault/list?token=NOPE"
  [ "$status" -eq 0 ]
  [ "$output" = "403" ]
}

@test "GET /api/vault/list surfaces last_set from audit.log vault_set rows" {
  # Seed an audit row for vault_set against `prod-mysql`, then store a
  # credential so the list endpoint joins the two.
  cat > "$WIZ_AUDIT_DIR/audit.log" <<'JSONL'
{"timestamp":"2026-05-25T02:07:58Z","action":"vault_set","outcome":"success","account":"prod-mysql"}
JSONL
  curl -s -X POST -H "Content-Type: application/json" \
    -d '{"key":"prod-mysql","value":"hunter2"}' \
    "$(api /api/vault/set)" >/dev/null
  run curl -s "$(api /api/vault/list)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"last_set\": \"2026-05-25T02:07:58Z\""* ]]
}
# ----------------------------------------------------------------------------
# /api/storage/*  — usage breakdown + retention preview + sweep (PR-Y5)
# ----------------------------------------------------------------------------

@test "GET / now composes the storage fragment too" {
  run curl -s "$(api /)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dbxStorage()"* ]]
}

@test "GET /api/storage/usage returns expected shape with fixture data" {
  run curl -s "$(api /api/storage/usage)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"total_bytes\":"* ]]
  [[ "$output" == *"\"total_files\": 1"* ]]
  [[ "$output" == *"\"free_bytes\":"* ]]
  [[ "$output" == *"\"by_pair\":"* ]]
  [[ "$output" == *"\"host\": \"prod\""* ]]
  [[ "$output" == *"\"database\": \"myapp\""* ]]
  [[ "$output" == *"\"count\": 1"* ]]
  [[ "$output" == *"\"largest_bytes\":"* ]]
  [[ "$output" == *"\"oldest_iso\":"* ]]
  [[ "$output" == *"\"newest_iso\":"* ]]
}

@test "GET /api/storage/usage with bad token returns 403" {
  run curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$WIZ_PORT/api/storage/usage?token=NOPE"
  [ "$status" -eq 0 ]
  [ "$output" = "403" ]
}

@test "GET /api/storage/clean-preview requires keep OR older_than" {
  run curl -s -o /dev/null -w "%{http_code}" "$(api /api/storage/clean-preview)"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

@test "GET /api/storage/clean-preview?keep=2 against 5 backups marks 3 for delete" {
  # Replace the single fixture file with 5 backups of varying mtime under
  # prod/myapp. We use python to set mtimes (BSD vs GNU touch differ).
  rm -f "$WIZ_SCRATCH/data/prod/myapp/"*.sql.zst*
  for d in 1 2 3 4 5; do
    f="$WIZ_SCRATCH/data/prod/myapp/myapp_2026050${d}_000000.sql.zst"
    echo "data-$d" > "$f"
    echo "{}" > "${f}.meta.json"
  done
  python3 -c "
import os, time
base = '$WIZ_SCRATCH/data/prod/myapp'
now = time.time()
# Day 5 is newest; day 1 is oldest. mtime offsets in seconds.
for i, d in enumerate(['5','4','3','2','1']):
    f = os.path.join(base, f'myapp_2026050{d}_000000.sql.zst')
    t = now - i * 86400
    os.utime(f, (t, t))
"
  run curl -s "$(api /api/storage/clean-preview)&keep=2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"reclaim_count\": 3"* ]]
}

@test "GET /api/storage/clean-preview?older_than=999999 returns 0 to delete" {
  run curl -s "$(api /api/storage/clean-preview)&older_than=3650"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"reclaim_count\": 0"* ]]
  [[ "$output" == *"\"would_delete\": []"* ]]
}

@test "GET /api/storage/clean-preview?keep=0 returns 400" {
  run curl -s -o /dev/null -w "%{http_code}" "$(api /api/storage/clean-preview)&keep=0"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

@test "GET /api/storage/clean-preview?keep=notanumber returns 400" {
  run curl -s -o /dev/null -w "%{http_code}" "$(api /api/storage/clean-preview)&keep=abc"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

@test "GET /api/storage/clean-preview?older_than=4000 returns 400 (out of range)" {
  run curl -s -o /dev/null -w "%{http_code}" "$(api /api/storage/clean-preview)&older_than=4000"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

@test "POST /api/storage/clean with valid args returns a job_id" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"keep":7}' "$(api /api/storage/clean)"
  [ "$status" -eq 0 ]
  [[ "$output" =~ \"job_id\":\ ?\"[0-9a-f]{32}\" ]]
}

@test "POST /api/storage/clean forwards --keep and --older-than into argv" {
  local body job_id
  body=$(curl -s -X POST -H "Content-Type: application/json" \
    -d '{"keep":3,"older_than":14,"dry_run":true}' "$(api /api/storage/clean)")
  job_id=$(echo "$body" | python3 -c "import sys,json;print(json.load(sys.stdin)['job_id'])")
  [ -n "$job_id" ]
  run curl -s -N --max-time 3 "http://127.0.0.1:$WIZ_PORT/api/jobs/$job_id/events?token=$WIZ_TOKEN"
  # The fake dbx echoes its argv on the first line.
  [[ "$output" == *"cmd=clean --keep 3 --older-than 14 --dry-run"* ]]
}

@test "POST /api/storage/clean rejects missing keep + older_than" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{}' "$(api /api/storage/clean)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"at least one"* ]]
}

@test "POST /api/storage/clean rejects non-boolean dry_run" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"keep":7,"dry_run":"yes"}' "$(api /api/storage/clean)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry_run must be a boolean"* ]]
}

@test "POST /api/storage/clean with bad token returns 403" {
  run curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" -d '{"keep":7}' \
    "http://127.0.0.1:$WIZ_PORT/api/storage/clean?token=NOPE"
  [ "$status" -eq 0 ]
  [ "$output" = "403" ]
}

# ----------------------------------------------------------------------------
# /api/restore/diff  — guided-restore step-3 preview
# ----------------------------------------------------------------------------

@test "GET /api/restore/diff with missing target returns 400" {
  run curl -s -o /dev/null -w "%{http_code}" \
    "$(api /api/restore/diff)&source=prod/myapp/latest"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

@test "GET /api/restore/diff with bad source returns 400" {
  run curl -s "$(api /api/restore/diff)&source=/etc/passwd&target=newdb"
  [ "$status" -eq 0 ]
  [[ "$output" == *"data-dir"* ]] || [[ "$output" == *"host/db/latest"* ]]
}

@test "GET /api/restore/diff with bad target name (shell metachar) returns 400" {
  run curl -s -o /tmp/wiz_diff_bad_target -w "%{http_code}" \
    "$(api /api/restore/diff)&source=prod/myapp/latest&target=bad%3Brm"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
  run cat /tmp/wiz_diff_bad_target
  [[ "$output" == *"target must match"* ]]
  rm -f /tmp/wiz_diff_bad_target
}

@test "GET /api/restore/diff with no host/db returns 400 when source not found" {
  run curl -s "$(api /api/restore/diff)&source=nosuchhost/nosuchdb/latest&target=newdb"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no backups found"* ]] || [[ "$output" == *"not found"* ]]
}

@test "GET /api/restore/diff with valid source + non-existent target reports CREATED" {
  # Default fixture has prod/myapp/myapp_20260520_120000.sql.zst with
  # source_flavor=postgres in its sidecar. No docker is available in this
  # test environment, so _list_target_tables degrades to (False, []).
  run curl -s "$(api /api/restore/diff)&source=prod/myapp/latest&target=sandbox"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"target_exists\": false"* ]]
  [[ "$output" == *"will be CREATED"* ]]
  [[ "$output" == *"\"name\": \"sandbox\""* ]]
  # source.path + source.filename echo the resolved backup file.
  [[ "$output" == *"myapp_20260520_120000.sql.zst"* ]]
  # Container is resolved from source_flavor=postgres → postgres-dbx.
  [[ "$output" == *"\"container\": \"postgres-dbx\""* ]]
}

@test "GET /api/restore/diff surfaces source safety from config.json" {
  cat > "$WIZ_SCRATCH/config.json" <<'JSON'
{ "hosts": { "prod": { "type": "postgres", "user": "u", "safety": "prod" } } }
JSON
  run curl -s "$(api /api/restore/diff)&source=prod/myapp/latest&target=sandbox"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"safety\": \"prod\""* ]]
}

@test "GET /api/restore/diff resolves mysql flavor to mysql-dbx container" {
  # Plant a mysql-flavored backup + meta sidecar.
  mkdir -p "$WIZ_SCRATCH/data/stage/orders"
  touch "$WIZ_SCRATCH/data/stage/orders/orders_20260101_120000.sql.zst"
  cat > "$WIZ_SCRATCH/data/stage/orders/orders_20260101_120000.sql.zst.meta.json" <<'JSON'
{"timestamp":"2026-01-01T12:00:00Z","source_flavor":"mysql","source_major_version":"8"}
JSON
  run curl -s "$(api /api/restore/diff)&source=stage/orders/latest&target=test_db"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"container\": \"mysql-dbx\""* ]]
  [[ "$output" == *"\"source_flavor\": \"mysql\""* ]]
}

@test "GET /api/restore/diff with bad token returns 403" {
  run curl -s -o /dev/null -w "%{http_code}" \
    "http://127.0.0.1:$WIZ_PORT/api/restore/diff?token=NOPE&source=prod/myapp/latest&target=x"
  [ "$status" -eq 0 ]
  [ "$output" = "403" ]
}

# ---------------------------------------------------------------------------
# Scrub endpoints
# ---------------------------------------------------------------------------

# Helper: write a config with a single host (+ optional scrub block) so each
# scrub test starts from a known starting point.
_plant_scrub_config() {
  cat > "$WIZ_SCRATCH/config.json"
}

@test "GET /api/scrub/status returns [] when no hosts configured" {
  run curl -s "$(api /api/scrub/status)"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "GET /api/scrub/status surfaces per-host manifest status" {
  _plant_scrub_config <<'JSON'
{
  "hosts": {
    "prod": {
      "type": "postgres",
      "user": "u",
      "safety": "prod",
      "databases": { "myapp": {} },
      "scrub": { "manifest": "scrub/prod.json", "required": true }
    },
    "stage": {
      "type": "postgres",
      "user": "u",
      "databases": { "shop": {} }
    }
  }
}
JSON
  # Plant the prod manifest file so manifest_exists flips true.
  mkdir -p "$WIZ_SCRATCH/scrub"
  echo '{"version":"1","tables":{}}' > "$WIZ_SCRATCH/scrub/prod.json"

  run curl -s "$(api /api/scrub/status)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"alias\": \"prod\""* ]]
  [[ "$output" == *"\"manifest_exists\": true"* ]]
  [[ "$output" == *"\"scrub_required\": true"* ]]
  [[ "$output" == *"\"safety\": \"prod\""* ]]
  [[ "$output" == *"\"databases\": ["* ]]
  [[ "$output" == *"\"myapp\""* ]]
  # The stage host has no scrub block at all
  [[ "$output" == *"\"alias\": \"stage\""* ]]
  [[ "$output" == *"\"manifest_path\": null"* ]]
}

@test "GET /api/scrub/manifest returns the file contents for a configured host" {
  _plant_scrub_config <<'JSON'
{ "hosts": { "prod": { "type": "postgres", "user": "u", "scrub": { "manifest": "scrub/prod.json" } } } }
JSON
  mkdir -p "$WIZ_SCRATCH/scrub"
  echo '{"version":"1","tables":{"users":{"columns":{"email":{"strategy":"fake_email"}}}}}' \
    > "$WIZ_SCRATCH/scrub/prod.json"

  run curl -s "$(api /api/scrub/manifest)&host=prod"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"host\": \"prod\""* ]]
  [[ "$output" == *"\"manifest_path\":"* ]]
  [[ "$output" == *"\"strategy\": \"fake_email\""* ]]
}

@test "GET /api/scrub/manifest returns null manifest when host is configured but file is missing" {
  _plant_scrub_config <<'JSON'
{ "hosts": { "prod": { "type": "postgres", "user": "u", "scrub": { "manifest": "scrub/prod.json" } } } }
JSON
  run curl -s "$(api /api/scrub/manifest)&host=prod"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"manifest\": null"* ]]
}

@test "GET /api/scrub/manifest rejects unconfigured host" {
  _plant_scrub_config <<'JSON'
{ "hosts": { "prod": { "type": "postgres", "user": "u" } } }
JSON
  run curl -s -o /dev/null -w "%{http_code}" "$(api /api/scrub/manifest)&host=nope"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

@test "POST /api/scrub/init returns parsed manifest JSON from the fake dbx" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"prod","database":"myapp"}' \
    "$(api /api/scrub/init)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"ok\": true"* ]]
  [[ "$output" == *"\"manifest\":"* ]]
  [[ "$output" == *"\"fake_email\""* ]]
}

@test "POST /api/scrub/init rejects bad host shape" {
  run curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"host":"../etc","database":"myapp"}' \
    "$(api /api/scrub/init)"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

@test "POST /api/scrub/init accepts the 'local' pseudo-host" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"local","database":"myapp"}' \
    "$(api /api/scrub/init)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"ok\": true"* ]]
}

@test "POST /api/scrub/check reports ok=true on clean schema" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"prod","database":"myapp"}' \
    "$(api /api/scrub/check)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"ok\": true"* ]]
  [[ "$output" == *"\"report\":"* ]]
}

@test "POST /api/scrub/check reports ok=false on drift (exit 2)" {
  # Pass the env signal through the server-spawned dbx by re-launching the
  # server inside this test with DBX_FAKE_SCRUB_CHECK_DRIFT=1. The default
  # server in setup() doesn't carry it. Easier: kill + relaunch.
  kill "$WIZ_PID" 2>/dev/null
  wait "$WIZ_PID" 2>/dev/null || true
  DBX_FAKE_SCRUB_CHECK_DRIFT=1 python3 "$WIZ_REPO_ROOT/lib/wizard-server.py" \
    --port "$WIZ_PORT" --token "$WIZ_TOKEN" \
    --html             "$WIZ_REPO_ROOT/lib/wizard.html" \
    --form-fragment    "$WIZ_REPO_ROOT/lib/wizard-form.html" \
    --backups-fragment "$WIZ_REPO_ROOT/lib/wizard-backups.html" \
    --backup-fragment  "$WIZ_REPO_ROOT/lib/wizard-backup.html" \
    --restore-fragment "$WIZ_REPO_ROOT/lib/wizard-restore.html" \
    --schedule-fragment "$WIZ_REPO_ROOT/lib/wizard-schedule.html" \
    --runs-fragment    "$WIZ_REPO_ROOT/lib/wizard-runs.html" \
    --dashboard-fragment "$WIZ_REPO_ROOT/lib/wizard-dashboard.html" \
    --vault-fragment   "$WIZ_REPO_ROOT/lib/wizard-vault.html" \
    --storage-fragment "$WIZ_REPO_ROOT/lib/wizard-storage.html" \
    --scrub-fragment   "$WIZ_REPO_ROOT/lib/wizard-scrub.html" \
    --analyze-fragment "$WIZ_REPO_ROOT/lib/wizard-analyze.html" \
    --config-path      "$WIZ_SCRATCH/config.json" \
    --data-dir         "$WIZ_SCRATCH/data" \
    --audit-dir        "$WIZ_AUDIT_DIR" \
    --dbx-bin          "$WIZ_SCRATCH/dbx" \
    --lib-dir          "$WIZ_REPO_ROOT/lib" \
    --done-marker      "$WIZ_DONE" \
    >"$WIZ_SCRATCH/server.log" 2>&1 &
  WIZ_PID=$!
  for _ in $(seq 1 20); do
    if curl -s -o /dev/null "http://127.0.0.1:$WIZ_PORT/?token=$WIZ_TOKEN"; then break; fi
    sleep 0.1
  done

  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"prod","database":"myapp"}' \
    "$(api /api/scrub/check)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"ok\": false"* ]]
  [[ "$output" == *"\"phone\""* ]]
}

@test "POST /api/scrub/save writes manifest and patches config" {
  _plant_scrub_config <<'JSON'
{ "hosts": { "prod": { "type": "postgres", "user": "u" } } }
JSON
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{
      "host": "prod",
      "manifest_path": "scrub/prod.json",
      "manifest": {
        "version": "1",
        "tables": { "users": { "columns": { "email": { "strategy": "fake_email" } } } }
      }
    }' \
    "$(api /api/scrub/save)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"ok\": true"* ]]
  [ -f "$WIZ_SCRATCH/scrub/prod.json" ]
  # The file was written with our content
  grep -q 'fake_email' "$WIZ_SCRATCH/scrub/prod.json"
  # Config got patched
  grep -q '"manifest": "scrub/prod.json"' "$WIZ_SCRATCH/config.json"
}

@test "POST /api/scrub/save without host writes manifest but leaves config alone" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{
      "manifest_path": "scrub/standalone.json",
      "manifest": { "version": "1", "tables": {} }
    }' \
    "$(api /api/scrub/save)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"ok\": true"* ]]
  [ -f "$WIZ_SCRATCH/scrub/standalone.json" ]
}

@test "POST /api/scrub/save rejects manifests with unknown strategies" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{
      "manifest_path": "scrub/bad.json",
      "manifest": {
        "tables": { "t": { "columns": { "c": { "strategy": "make_stuff_up" } } } }
      }
    }' \
    "$(api /api/scrub/save)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"strategy must be one of"* ]]
  [ ! -f "$WIZ_SCRATCH/scrub/bad.json" ]
}

@test "POST /api/scrub/save rejects paths outside HOME / config dir" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{
      "manifest_path": "/etc/dbx-evil.json",
      "manifest": { "version": "1", "tables": {} }
    }' \
    "$(api /api/scrub/save)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"under the config directory or"* ]]
}

@test "POST /api/scrub/save rejects non-.json paths" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{
      "manifest_path": "scrub/oops.txt",
      "manifest": { "version": "1", "tables": {} }
    }' \
    "$(api /api/scrub/save)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"must end with .json"* ]]
}

@test "GET / composes the Scrub fragment into the HTML shell" {
  run curl -s "$(api /)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dbxScrub()"* ]]
  [[ "$output" == *"Per-host PII manifests"* ]]
}

# Code-review follow-ups: catch the three classes of drift between the
# Python pre-validator and lib/scrub.sh's authoritative validator.

@test "POST /api/scrub/save rejects strategies bash doesn't recognize" {
  # fake_company/fake_address/fake_city/fake_username are NOT in
  # lib/scrub.sh's case arm. Accepting them in the wizard would mean a
  # successful save followed by a CLI rejection on the next scrub run.
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{
      "manifest_path": "scrub/bad.json",
      "manifest": {
        "tables": { "users": { "columns": { "co": { "strategy": "fake_company" } } } }
      }
    }' \
    "$(api /api/scrub/save)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"strategy must be one of"* ]]
}

@test "POST /api/scrub/save rejects tables with neither no_pii nor columns" {
  # lib/scrub.sh:scrub_validate_manifest errors out with "table 'X' has
  # neither no_pii=true nor a 'columns' object". The wizard must reject
  # the same shape so a save doesn't leave behind a CLI-invalid file.
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{
      "manifest_path": "scrub/empty.json",
      "manifest": { "tables": { "users": {} } }
    }' \
    "$(api /api/scrub/save)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"must declare either no_pii=true"* ]]
  [ ! -f "$WIZ_SCRATCH/scrub/empty.json" ]   # not even partially written
}

@test "POST /api/scrub/save rejects a bad host alias BEFORE writing the file" {
  # Old order wrote the manifest, then validated host alias, leaving an
  # orphaned file when the alias was invalid. The Save UI told the user
  # "save failed" while a file sat on disk.
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{
      "host": "../etc/evil",
      "manifest_path": "scrub/orphan.json",
      "manifest": {
        "tables": { "users": { "columns": { "email": { "strategy": "fake_email" } } } }
      }
    }' \
    "$(api /api/scrub/save)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"host alias has invalid characters"* ]]
  [ ! -f "$WIZ_SCRATCH/scrub/orphan.json" ]
}

@test "POST /api/scrub/save rejects a target whose existing symlink escapes HOME" {
  # Symlink TOCTOU mitigation: if a file already lives at the target path
  # and it's a symlink resolving outside $HOME / config dir, reject before
  # the write. (New files have no symlink to follow — safe by default.)
  # We need the symlink TARGET to be outside both HOME (=$WIZ_SCRATCH/home,
  # set in setup) AND the config dir (=$WIZ_SCRATCH, the config.json
  # parent). A sibling mktemp tree fits that bill: it's not under the
  # wizard's HOME and not under the wizard's config dir.
  ESCAPE_DST=$(mktemp -d)
  mkdir -p "$WIZ_SCRATCH/home/scrub"
  ln -sf "$ESCAPE_DST/evil.json" "$WIZ_SCRATCH/home/scrub/escape.json"
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{
      "manifest_path": "'"$WIZ_SCRATCH/home/scrub/escape.json"'",
      "manifest": { "tables": { "users": { "columns": { "e": { "strategy": "fake_email" } } } } }
    }' \
    "$(api /api/scrub/save)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolves (via symlink) outside"* ]]
  [ ! -e "$ESCAPE_DST/evil.json" ]
  rm -rf "$ESCAPE_DST"
}

# ---------------------------------------------------------------------------
# /api/analyze  — table stats + PII pre-scan from `dbx analyze --json`
# ---------------------------------------------------------------------------

@test "GET / composes the Analyze fragment into the HTML shell" {
  run curl -s "$(api /)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dbxAnalyze()"* ]]
  [[ "$output" == *"Per-table row count"* ]]
}

@test "POST /api/analyze returns parsed JSON from the fake dbx" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"prod","database":"myapp"}' \
    "$(api /api/analyze)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"engine\": \"mysql\""* ]]
  [[ "$output" == *"\"tables\": 2"* ]]
  [[ "$output" == *"\"rows\": 1200"* ]]
  [[ "$output" == *"\"name\": \"users\""* ]]
  [[ "$output" == *"\"excluded\": true"* ]]
  [[ "$output" == *"\"columns\": ["* ]]
}

@test "POST /api/analyze rejects bad host shape" {
  run curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"host":"../etc","database":"myapp"}' \
    "$(api /api/analyze)"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

@test "POST /api/analyze rejects bad database shape" {
  run curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"host":"prod","database":"bad;rm"}' \
    "$(api /api/analyze)"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

@test "POST /api/analyze rejects non-boolean no_pii_scan" {
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"prod","database":"myapp","no_pii_scan":"yes"}' \
    "$(api /api/analyze)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no_pii_scan must be a boolean"* ]]
}

@test "POST /api/analyze surfaces CLI failure as 502 with stderr" {
  # Relaunch the server with DBX_FAKE_ANALYZE_FAIL=1 so the fake exits 1
  # with a stderr message. The handler should return 502 and include the
  # stderr in the body so the wizard UI can display it.
  kill "$WIZ_PID" 2>/dev/null
  wait "$WIZ_PID" 2>/dev/null || true
  DBX_FAKE_ANALYZE_FAIL=1 python3 "$WIZ_REPO_ROOT/lib/wizard-server.py" \
    --port "$WIZ_PORT" --token "$WIZ_TOKEN" \
    --html             "$WIZ_REPO_ROOT/lib/wizard.html" \
    --form-fragment    "$WIZ_REPO_ROOT/lib/wizard-form.html" \
    --backups-fragment "$WIZ_REPO_ROOT/lib/wizard-backups.html" \
    --backup-fragment  "$WIZ_REPO_ROOT/lib/wizard-backup.html" \
    --restore-fragment "$WIZ_REPO_ROOT/lib/wizard-restore.html" \
    --schedule-fragment "$WIZ_REPO_ROOT/lib/wizard-schedule.html" \
    --runs-fragment    "$WIZ_REPO_ROOT/lib/wizard-runs.html" \
    --dashboard-fragment "$WIZ_REPO_ROOT/lib/wizard-dashboard.html" \
    --vault-fragment   "$WIZ_REPO_ROOT/lib/wizard-vault.html" \
    --storage-fragment "$WIZ_REPO_ROOT/lib/wizard-storage.html" \
    --scrub-fragment   "$WIZ_REPO_ROOT/lib/wizard-scrub.html" \
    --analyze-fragment "$WIZ_REPO_ROOT/lib/wizard-analyze.html" \
    --config-path      "$WIZ_SCRATCH/config.json" \
    --data-dir         "$WIZ_SCRATCH/data" \
    --audit-dir        "$WIZ_AUDIT_DIR" \
    --dbx-bin          "$WIZ_SCRATCH/dbx" \
    --lib-dir          "$WIZ_REPO_ROOT/lib" \
    --done-marker      "$WIZ_DONE" \
    >"$WIZ_SCRATCH/server.log" 2>&1 &
  WIZ_PID=$!
  for _ in $(seq 1 20); do
    if curl -s -o /dev/null "http://127.0.0.1:$WIZ_PORT/?token=$WIZ_TOKEN"; then break; fi
    sleep 0.1
  done

  run curl -s -o /tmp/wiz_analyze_fail_body -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d '{"host":"prod","database":"myapp"}' \
    "$(api /api/analyze)"
  [ "$status" -eq 0 ]
  [ "$output" = "502" ]
  run cat /tmp/wiz_analyze_fail_body
  [[ "$output" == *"dbx analyze failed"* ]]
  [[ "$output" == *"connection refused"* ]]
  rm -f /tmp/wiz_analyze_fail_body
}

@test "POST /api/analyze passes CLI stderr through on SUCCESS too (diagnostics)" {
  # Relaunch the server with DBX_FAKE_ANALYZE_STDERR set so the fake
  # writes a log_step-style message to stderr alongside the successful
  # JSON. The handler should include `stderr` in the 200 response so the
  # wizard's diagnostics panel can render it.
  kill "$WIZ_PID" 2>/dev/null
  wait "$WIZ_PID" 2>/dev/null || true
  DBX_FAKE_ANALYZE_STDERR="Scanning prod-mysql/b2b for PII candidates..." \
  python3 "$WIZ_REPO_ROOT/lib/wizard-server.py" \
    --port "$WIZ_PORT" --token "$WIZ_TOKEN" \
    --html             "$WIZ_REPO_ROOT/lib/wizard.html" \
    --form-fragment    "$WIZ_REPO_ROOT/lib/wizard-form.html" \
    --backups-fragment "$WIZ_REPO_ROOT/lib/wizard-backups.html" \
    --backup-fragment  "$WIZ_REPO_ROOT/lib/wizard-backup.html" \
    --restore-fragment "$WIZ_REPO_ROOT/lib/wizard-restore.html" \
    --schedule-fragment "$WIZ_REPO_ROOT/lib/wizard-schedule.html" \
    --runs-fragment    "$WIZ_REPO_ROOT/lib/wizard-runs.html" \
    --dashboard-fragment "$WIZ_REPO_ROOT/lib/wizard-dashboard.html" \
    --vault-fragment   "$WIZ_REPO_ROOT/lib/wizard-vault.html" \
    --storage-fragment "$WIZ_REPO_ROOT/lib/wizard-storage.html" \
    --scrub-fragment   "$WIZ_REPO_ROOT/lib/wizard-scrub.html" \
    --analyze-fragment "$WIZ_REPO_ROOT/lib/wizard-analyze.html" \
    --config-path      "$WIZ_SCRATCH/config.json" \
    --data-dir         "$WIZ_SCRATCH/data" \
    --audit-dir        "$WIZ_AUDIT_DIR" \
    --dbx-bin          "$WIZ_SCRATCH/dbx" \
    --lib-dir          "$WIZ_REPO_ROOT/lib" \
    --done-marker      "$WIZ_DONE" \
    >"$WIZ_SCRATCH/server.log" 2>&1 &
  WIZ_PID=$!
  for _ in $(seq 1 20); do
    if curl -s -o /dev/null "http://127.0.0.1:$WIZ_PORT/?token=$WIZ_TOKEN"; then break; fi
    sleep 0.1
  done

  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"prod","database":"myapp"}' \
    "$(api /api/analyze)"
  [ "$status" -eq 0 ]
  # Happy-path payload still there.
  [[ "$output" == *"\"engine\": \"mysql\""* ]]
  # Diagnostics passed through to the 200 response.
  [[ "$output" == *"\"stderr\""* ]]
  [[ "$output" == *"Scanning prod-mysql/b2b for PII candidates"* ]]
}

# ---------------------------------------------------------------------------
# /api/analyze/exclude  — build up databases[].exclude_data from the Analyze
# table. Patches config.hosts[host].databases[db].exclude_data in place.
# ---------------------------------------------------------------------------

@test "POST /api/analyze/exclude patches databases[].exclude_data" {
  cat > "$WIZ_SCRATCH/config.json" <<'JSON'
{ "hosts": { "prod": { "type": "postgres", "user": "u", "databases": { "myapp": {} } } } }
JSON
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"prod","database":"myapp","exclude_data":["sessions","cache"]}' \
    "$(api /api/analyze/exclude)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"ok\": true"* ]]
  # Stored sorted + de-duped under the right db block.
  run python3 -c "import json;print(json.load(open('$WIZ_SCRATCH/config.json'))['hosts']['prod']['databases']['myapp']['exclude_data'])"
  [ "$output" = "['cache', 'sessions']" ]
}

@test "POST /api/analyze/exclude with empty list removes the key" {
  cat > "$WIZ_SCRATCH/config.json" <<'JSON'
{ "hosts": { "prod": { "type": "postgres", "user": "u", "databases": { "myapp": { "exclude_data": ["sessions"] } } } } }
JSON
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"prod","database":"myapp","exclude_data":[]}' \
    "$(api /api/analyze/exclude)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"ok\": true"* ]]
  run python3 -c "import json;print('exclude_data' in json.load(open('$WIZ_SCRATCH/config.json'))['hosts']['prod']['databases']['myapp'])"
  [ "$output" = "False" ]
}

@test "POST /api/analyze/exclude rejects a host not in config" {
  cat > "$WIZ_SCRATCH/config.json" <<'JSON'
{ "hosts": { "prod": { "type": "postgres", "user": "u", "databases": { "myapp": {} } } } }
JSON
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"ghost","database":"myapp","exclude_data":["sessions"]}' \
    "$(api /api/analyze/exclude)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not in config"* ]]
}

@test "POST /api/analyze/exclude rejects a database not configured under the host" {
  cat > "$WIZ_SCRATCH/config.json" <<'JSON'
{ "hosts": { "prod": { "type": "postgres", "user": "u", "databases": { "myapp": {} } } } }
JSON
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"prod","database":"nope","exclude_data":["sessions"]}' \
    "$(api /api/analyze/exclude)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not configured under host"* ]]
}

@test "POST /api/analyze/exclude rejects an injection-shaped table name and leaves config untouched" {
  cat > "$WIZ_SCRATCH/config.json" <<'JSON'
{ "hosts": { "prod": { "type": "postgres", "user": "u", "databases": { "myapp": {} } } } }
JSON
  run curl -s -X POST -H "Content-Type: application/json" \
    -d '{"host":"prod","database":"myapp","exclude_data":["sessions","bad;rm -rf /"]}' \
    "$(api /api/analyze/exclude)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"invalid table name"* ]]
  # Nothing was written — the bad name aborted before the config patch.
  run python3 -c "import json;print('exclude_data' in json.load(open('$WIZ_SCRATCH/config.json'))['hosts']['prod']['databases']['myapp'])"
  [ "$output" = "False" ]
}
