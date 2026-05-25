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
