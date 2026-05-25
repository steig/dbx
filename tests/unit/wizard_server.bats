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

  # Fake dbx that just echoes its argv and a few log lines, exit 0.
  cat > "$WIZ_SCRATCH/dbx" <<'SH'
#!/usr/bin/env bash
echo "[INFO] cmd=$*"
echo "[INFO] line 1"
echo "[OK] done"
SH
  chmod +x "$WIZ_SCRATCH/dbx"

  WIZ_TOKEN="testtoken1234567890abcdef00000000"
  WIZ_PORT="$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()")"
  WIZ_DONE="$WIZ_SCRATCH/done"

  python3 "$WIZ_REPO_ROOT/lib/wizard-server.py" \
    --port "$WIZ_PORT" \
    --token "$WIZ_TOKEN" \
    --html             "$WIZ_REPO_ROOT/lib/wizard.html" \
    --form-fragment     "$WIZ_REPO_ROOT/lib/wizard-form.html" \
    --backups-fragment  "$WIZ_REPO_ROOT/lib/wizard-backups.html" \
    --restore-fragment  "$WIZ_REPO_ROOT/lib/wizard-restore.html" \
    --schedule-fragment "$WIZ_REPO_ROOT/lib/wizard-schedule.html" \
    --config-path       "$WIZ_SCRATCH/config.json" \
    --data-dir          "$WIZ_SCRATCH/data" \
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
