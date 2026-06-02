#!/usr/bin/env bats
#
# E2E tests for `dbx restore --transform=<script>` and `--into <container>`
# (the boring integration features, issue #41).
#
# Test scenarios:
#   1. --transform on a stored backup: PII gets sanitized; target gets
#      sanitized rows; broken script → atomic rollback (no partial restore).
#   2. --into pointed at a separate "boring sidecar" postgres container:
#      restored data lands in THAT container, not postgres-dbx.
#   3. Combined --transform + --into: the load-bearing boring use case.
#   4. --into errors: missing container, non-postgres container,
#      MySQL --into rejected, scrub gate bypass + audit entry.

load '../helpers/integration'

# Spin up a standalone "sidecar" postgres container that --into will target.
# Distinct from postgres-dbx so we can prove dbx targeted the right one.
ensure_sidecar_pg_container() {
  local name="${1:-dbx-test-sidecar-pg}"
  if ! docker ps --format '{{.Names}}' | grep -q "^${name}$"; then
    docker rm -f "$name" >/dev/null 2>&1
    docker run -d --name "$name" \
      -e POSTGRES_PASSWORD=sidecarpass \
      -e POSTGRES_USER=sidecaruser \
      -e POSTGRES_DB=sidecardb \
      postgres:17-alpine >/dev/null
    pg_wait_ready "$name" sidecaruser sidecarpass sidecardb
  fi
}

setup_file() {
  require_docker
  ensure_postgres_container
  ensure_sidecar_pg_container
}

setup() {
  setup_dbx_env
  write_local_config
  TEST_SRC="rti_src_$$_${BATS_TEST_NUMBER}"
  TEST_TGT="rti_tgt_$$_${BATS_TEST_NUMBER}"
  SIDECAR="dbx-test-sidecar-pg"
  TRANSFORM_SCRIPT="$DBX_CONFIG_DIR/sanitize.sh"
}

teardown() {
  pg_drop_db "${TEST_SRC:-}"
  pg_drop_db "${TEST_TGT:-}"
  docker exec "$SIDECAR" psql -U sidecaruser -c "DROP DATABASE IF EXISTS \"$TEST_TGT\"" >/dev/null 2>&1 || true
}

# Write a sanitize script that replaces emails and phone numbers in the
# plain-SQL stream coming from pg_restore -f -. Simple sed pipeline.
_write_sanitize_script() {
  cat > "$TRANSFORM_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Stream sanitizer: replaces real email/phone in COPY blocks with placeholders.
sed -E \
  -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/redacted@example.com/g' \
  -e 's/\+1[0-9]{10}/+15550000000/g'
EOF
  chmod +x "$TRANSFORM_SCRIPT"
}

# ----------------------------------------------------------------------------
# --transform alone (target: postgres-dbx, the default)
# ----------------------------------------------------------------------------

@test "--transform: sanitize.sh redacts PII before the target sees it" {
  _write_sanitize_script
  seed_postgres_db "$TEST_SRC" "
    CREATE TABLE users (id SERIAL, email TEXT, phone TEXT);
    INSERT INTO users(email, phone) VALUES
      ('tom@steig.io', '+15551234567'),
      ('alice@example.org', '+19998887766');
  "
  dbx_run backup local-pg "$TEST_SRC"
  [ "$status" -eq 0 ]

  dbx_run restore "local-pg/$TEST_SRC/latest" \
    --name "$TEST_TGT" \
    --transform="$TRANSFORM_SCRIPT"
  [ "$status" -eq 0 ]

  # Every email row should now be 'redacted@example.com'
  local non_redacted_email
  non_redacted_email=$(docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -d "$TEST_TGT" -tA \
    -c "SELECT count(*) FROM users WHERE email <> 'redacted@example.com'" | tr -d '[:space:]')
  [ "$non_redacted_email" = "0" ]

  # Every phone row should be '+15550000000'
  local non_redacted_phone
  non_redacted_phone=$(docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -d "$TEST_TGT" -tA \
    -c "SELECT count(*) FROM users WHERE phone <> '+15550000000'" | tr -d '[:space:]')
  [ "$non_redacted_phone" = "0" ]

  # Row count preserved
  local row_count
  row_count=$(docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -d "$TEST_TGT" -tA -c "SELECT count(*) FROM users" | tr -d '[:space:]')
  [ "$row_count" = "2" ]
}

@test "--transform: script exits non-zero → atomic rollback (no rows land)" {
  # A script that reads a few bytes then errors. With psql -1 the
  # partial input rolls back; the target DB receives nothing.
  cat > "$TRANSFORM_SCRIPT" <<'EOF'
#!/usr/bin/env bash
head -c 100
exit 1
EOF
  chmod +x "$TRANSFORM_SCRIPT"

  seed_postgres_db "$TEST_SRC" "
    CREATE TABLE users (id SERIAL, email TEXT);
    INSERT INTO users(email) VALUES ('tom@steig.io');
  "
  dbx_run backup local-pg "$TEST_SRC"
  [ "$status" -eq 0 ]

  dbx_run restore "local-pg/$TEST_SRC/latest" \
    --name "$TEST_TGT" \
    --transform="$TRANSFORM_SCRIPT"
  [ "$status" -ne 0 ]

  # Target DB must NOT exist (we drop on streaming failure for cleanliness)
  local exists
  exists=$(docker exec postgres-dbx psql -U postgres -tA \
    -c "SELECT count(*) FROM pg_database WHERE datname = '$TEST_TGT'" | tr -d '[:space:]')
  [ "$exists" = "0" ]
}

@test "--transform: non-existent script errors before any work" {
  seed_postgres_db "$TEST_SRC" "CREATE TABLE t (id INT);"
  dbx_run backup local-pg "$TEST_SRC"
  [ "$status" -eq 0 ]

  dbx_run restore "local-pg/$TEST_SRC/latest" \
    --name "$TEST_TGT" \
    --transform=/nonexistent/path/to/script.sh
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "is not an executable"
}

# ----------------------------------------------------------------------------
# --into (target: separate sidecar container)
# ----------------------------------------------------------------------------

@test "--into: data lands in the sidecar container, NOT postgres-dbx" {
  seed_postgres_db "$TEST_SRC" "
    CREATE TABLE widgets (id SERIAL, name TEXT);
    INSERT INTO widgets(name) VALUES ('A'), ('B'), ('C');
  "
  dbx_run backup local-pg "$TEST_SRC"
  [ "$status" -eq 0 ]

  dbx_run restore "local-pg/$TEST_SRC/latest" \
    --name "$TEST_TGT" \
    --into "$SIDECAR"
  [ "$status" -eq 0 ]

  # In the sidecar: target DB exists with 3 widget rows
  local sidecar_count
  sidecar_count=$(docker exec -e PGPASSWORD=sidecarpass "$SIDECAR" \
    psql -U sidecaruser -d "$TEST_TGT" -tA -c "SELECT count(*) FROM widgets" | tr -d '[:space:]')
  [ "$sidecar_count" = "3" ]

  # In postgres-dbx: target DB should NOT exist
  local dbx_exists
  dbx_exists=$(docker exec postgres-dbx psql -U postgres -tA \
    -c "SELECT count(*) FROM pg_database WHERE datname = '$TEST_TGT'" | tr -d '[:space:]')
  [ "$dbx_exists" = "0" ]
}

@test "--into: nonexistent container → clear error before any work" {
  seed_postgres_db "$TEST_SRC" "CREATE TABLE t (id INT);"
  dbx_run backup local-pg "$TEST_SRC"
  [ "$status" -eq 0 ]

  dbx_run restore "local-pg/$TEST_SRC/latest" \
    --name "$TEST_TGT" \
    --into "dbx-test-does-not-exist-$$"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "is not running"
}

@test "--into: bypasses scrub gate with loud warning + audit entry" {
  # Configure scrub.required=true on local-pg. Normally that gate would
  # fire on restore. With --into, we bypass it and emit an audit_log
  # entry tagged 'scrub_bypass'.
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{
  "version": 1, "seed_env": "DBX_SCRUB_SEED",
  "tables": {"users": {"columns": {"email": {"strategy": "fake_email"}}}}
}
EOF
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-pg": {
      "type": "postgres", "host": "127.0.0.1", "port": 5432, "user": "postgres",
      "password_cmd": "echo devpassword",
      "scrub": {"manifest": "dbx.scrub.json", "required": true},
      "databases": { "$TEST_SRC": {} }
    }
  }
}
EOF
  export DBX_SCRUB_SEED="some-salt"
  seed_postgres_db "$TEST_SRC" "
    CREATE TABLE users (id SERIAL, email TEXT);
    INSERT INTO users(email) VALUES ('tom@steig.io');
  "
  dbx_run backup local-pg "$TEST_SRC"
  [ "$status" -eq 0 ]

  dbx_run restore "local-pg/$TEST_SRC/latest" \
    --name "$TEST_TGT" \
    --into "$SIDECAR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PII scrub gate BYPASSED for external container"
  # Audit log entry exists tagged scrub_bypass + into_external
  grep -q "scrub_bypass" "$DBX_AUDIT_DIR/audit.log" || \
    grep -q "scrub_bypass" "$DBX_AUDIT_DIR"/*.log

  # Data is unscrubbed in the sidecar (the operator's choice)
  local present
  present=$(docker exec -e PGPASSWORD=sidecarpass "$SIDECAR" \
    psql -U sidecaruser -d "$TEST_TGT" -tA \
    -c "SELECT count(*) FROM users WHERE email = 'tom@steig.io'" | tr -d '[:space:]')
  [ "$present" = "1" ]
  unset DBX_SCRUB_SEED
}

# ----------------------------------------------------------------------------
# Combined: --transform + --into (the boring v0.5 use case)
# ----------------------------------------------------------------------------

@test "--transform + --into: sanitized rows land in the sidecar" {
  _write_sanitize_script
  seed_postgres_db "$TEST_SRC" "
    CREATE TABLE users (id SERIAL, email TEXT, phone TEXT);
    INSERT INTO users(email, phone) VALUES
      ('tom@steig.io', '+15551234567'),
      ('alice@example.org', '+19998887766'),
      ('bob@example.net', '+12121234567');
  "
  dbx_run backup local-pg "$TEST_SRC"
  [ "$status" -eq 0 ]

  dbx_run restore "local-pg/$TEST_SRC/latest" \
    --name "$TEST_TGT" \
    --transform="$TRANSFORM_SCRIPT" \
    --into "$SIDECAR"
  [ "$status" -eq 0 ]

  # Sidecar has 3 rows, all sanitized
  local total redacted_email redacted_phone
  total=$(docker exec -e PGPASSWORD=sidecarpass "$SIDECAR" \
    psql -U sidecaruser -d "$TEST_TGT" -tA -c "SELECT count(*) FROM users" | tr -d '[:space:]')
  redacted_email=$(docker exec -e PGPASSWORD=sidecarpass "$SIDECAR" \
    psql -U sidecaruser -d "$TEST_TGT" -tA \
    -c "SELECT count(*) FROM users WHERE email = 'redacted@example.com'" | tr -d '[:space:]')
  redacted_phone=$(docker exec -e PGPASSWORD=sidecarpass "$SIDECAR" \
    psql -U sidecaruser -d "$TEST_TGT" -tA \
    -c "SELECT count(*) FROM users WHERE phone = '+15550000000'" | tr -d '[:space:]')
  [ "$total" = "3" ]
  [ "$redacted_email" = "3" ]
  [ "$redacted_phone" = "3" ]

  # The ORIGINAL email never made it anywhere — not in sidecar, not in postgres-dbx
  local orig_in_sidecar
  orig_in_sidecar=$(docker exec -e PGPASSWORD=sidecarpass "$SIDECAR" \
    psql -U sidecaruser -d "$TEST_TGT" -tA \
    -c "SELECT count(*) FROM users WHERE email = 'tom@steig.io'" | tr -d '[:space:]')
  [ "$orig_in_sidecar" = "0" ]
}

# ----------------------------------------------------------------------------
# Flag combination guards
# ----------------------------------------------------------------------------

@test "--into + mysql db_type: rejected with clear message" {
  # Need a mysql host to even get to the point where --into is checked.
  ensure_mysql_container
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-mysql": {
      "type": "mysql", "host": "127.0.0.1", "port": 3306, "user": "root",
      "password_cmd": "echo devpassword"
    }
  }
}
EOF
  local mydb="rti_my_$$"
  seed_mysql_db "$mydb" "CREATE TABLE t (id INT);"
  dbx_run backup local-mysql "$mydb"
  [ "$status" -eq 0 ]
  dbx_run restore "local-mysql/$mydb/latest" --name "rti_mytgt_$$" --into "$SIDECAR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "only supported for postgres"
  mysql_drop_db "$mydb"
  mysql_drop_db "rti_mytgt_$$"
}

@test "--hooks-only + --transform: mutually exclusive" {
  dbx_run restore /tmp/nonexistent.sql --hooks-only --name foo --transform=/bin/cat
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "incompatible"
}

@test "--into: post-restore hooks are SKIPPED (would target wrong container)" {
  # Hooks use pg_run_sql_stream which hardcodes postgres-dbx. With
  # --into, running them would mutate postgres-dbx instead of the
  # sidecar — silent wrong-target writes. We skip with a log_warn.
  seed_postgres_db "$TEST_SRC" "
    CREATE TABLE t (id SERIAL, label TEXT);
    INSERT INTO t(label) VALUES ('original');
  "
  cat > "$DBX_CONFIG_DIR/relabel.sql" <<'SQL'
UPDATE t SET label = 'mutated_by_hook';
SQL
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-pg": {
      "type": "postgres", "host": "127.0.0.1", "port": 5432, "user": "postgres",
      "password_cmd": "echo devpassword",
      "post_restore": [{"file": "relabel.sql"}],
      "databases": { "$TEST_SRC": {} }
    }
  }
}
EOF
  dbx_run backup local-pg "$TEST_SRC"
  [ "$status" -eq 0 ]

  dbx_run restore "local-pg/$TEST_SRC/latest" \
    --name "$TEST_TGT" \
    --into "$SIDECAR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "post-restore hooks are skipped"

  # Sidecar row still says 'original' — the hook did NOT run.
  local label
  label=$(docker exec -e PGPASSWORD=sidecarpass "$SIDECAR" \
    psql -U sidecaruser -d "$TEST_TGT" -tA -c "SELECT label FROM t LIMIT 1" | tr -d '[:space:]')
  [ "$label" = "original" ]

  # postgres-dbx must NOT have had the wrong-target mutation: no
  # database with the target name exists there at all.
  local exists
  exists=$(docker exec postgres-dbx psql -U postgres -tA \
    -c "SELECT count(*) FROM pg_database WHERE datname = '$TEST_TGT'" | tr -d '[:space:]')
  [ "$exists" = "0" ]
}

# ----------------------------------------------------------------------------
# --transform env scrubbing (default: env -i + allowlist)
# ----------------------------------------------------------------------------

# Sanitize script that writes the values of PGPASSWORD and DBX_SCRUB_SEED
# (or empty strings if unset) into a marker file, then passes stdin through
# unchanged. We assert the marker file shows BOTH as empty under the
# default env-clean behavior, and as populated under --transform-inherit-env.
_write_env_probe_script() {
  local marker="$1"
  cat > "$TRANSFORM_SCRIPT" <<EOF
#!/usr/bin/env bash
{
  printf 'PGPASSWORD=%s\n' "\${PGPASSWORD:-<unset>}"
  printf 'DBX_SCRUB_SEED=%s\n' "\${DBX_SCRUB_SEED:-<unset>}"
  printf 'DBX_TRANSFORM_FOO=%s\n' "\${DBX_TRANSFORM_FOO:-<unset>}"
} > "$marker"
cat   # pass stdin through unchanged
EOF
  chmod +x "$TRANSFORM_SCRIPT"
}

@test "--transform default: PGPASSWORD and DBX_SCRUB_SEED are NOT inherited" {
  local marker="$BATS_TEST_TMPDIR/env-probe.txt"
  _write_env_probe_script "$marker"

  seed_postgres_db "$TEST_SRC" "CREATE TABLE t (id INT); INSERT INTO t VALUES (1);"
  export DBX_SCRUB_SEED="should-not-leak-to-script"
  export PGPASSWORD="should-not-leak-to-script-either"
  export DBX_TRANSFORM_FOO="explicit-pass-through"
  dbx_run backup local-pg "$TEST_SRC"
  [ "$status" -eq 0 ]

  dbx_run restore "local-pg/$TEST_SRC/latest" \
    --name "$TEST_TGT" \
    --transform="$TRANSFORM_SCRIPT"
  [ "$status" -eq 0 ]

  # Probe captured what the script saw:
  [ -f "$marker" ]
  grep -q '^PGPASSWORD=<unset>$' "$marker"
  grep -q '^DBX_SCRUB_SEED=<unset>$' "$marker"
  # The DBX_TRANSFORM_* prefix is explicitly passed through.
  grep -q '^DBX_TRANSFORM_FOO=explicit-pass-through$' "$marker"

  unset DBX_SCRUB_SEED PGPASSWORD DBX_TRANSFORM_FOO
}

@test "--transform --transform-inherit-env: legacy behavior, all env passed through" {
  local marker="$BATS_TEST_TMPDIR/env-probe-inherit.txt"
  _write_env_probe_script "$marker"

  seed_postgres_db "$TEST_SRC" "CREATE TABLE t (id INT); INSERT INTO t VALUES (1);"
  export DBX_SCRUB_SEED="visible-with-inherit-flag"
  dbx_run backup local-pg "$TEST_SRC"
  [ "$status" -eq 0 ]

  dbx_run restore "local-pg/$TEST_SRC/latest" \
    --name "$TEST_TGT" \
    --transform="$TRANSFORM_SCRIPT" \
    --transform-inherit-env
  [ "$status" -eq 0 ]

  [ -f "$marker" ]
  grep -q '^DBX_SCRUB_SEED=visible-with-inherit-flag$' "$marker"

  unset DBX_SCRUB_SEED
}

@test "--transform-inherit-env without --transform is rejected" {
  dbx_run restore /tmp/nonexistent.sql --name foo --transform-inherit-env
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "requires --transform"
}
