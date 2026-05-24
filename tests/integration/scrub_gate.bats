#!/usr/bin/env bats
#
# End-to-end test of the scrub gate: dbx backup → dbx restore with
# scrub.required=true → verify columns are scrubbed (or target dropped
# on failure). This is the security-critical path; a bug here can
# leak PII or stop legitimate restores. Tests cover the happy path
# AND each failure mode (drift, sniff fail, missing seed, --no-scrub).

load '../helpers/integration'

setup_file() {
  require_docker
  ensure_postgres_container
}

setup() {
  setup_dbx_env
  TEST_SRC="scrubgate_src_$$_${BATS_TEST_NUMBER}"
  TEST_TGT="scrubgate_tgt_$$_${BATS_TEST_NUMBER}"
  export DBX_SCRUB_SEED="test-salt-12345"
}

teardown() {
  pg_drop_db "${TEST_SRC:-}"
  pg_drop_db "${TEST_TGT:-}"
  unset DBX_SCRUB_SEED
}

# Write a config with scrub.required=true and the given manifest path.
_write_scrub_config() {
  local manifest_rel="$1" required="${2:-true}"
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-pg": {
      "type": "postgres",
      "host": "127.0.0.1",
      "port": 5432,
      "user": "postgres",
      "password_cmd": "echo devpassword",
      "scrub": {
        "manifest": "$manifest_rel",
        "required": $required
      },
      "databases": { "$TEST_SRC": {} }
    }
  }
}
EOF
}

# ----------------------------------------------------------------------------
# Happy path
# ----------------------------------------------------------------------------

@test "scrub gate: happy path — restore + scrub + sniff verify (postgres)" {
  seed_postgres_db "$TEST_SRC" "
    CREATE TABLE users (id SERIAL PRIMARY KEY, email TEXT, phone TEXT);
    INSERT INTO users(email, phone) VALUES
      ('tom@steig.io', '+15551234567'),
      ('alice@example.org', '+19998887766'),
      ('bob@example.net', '+12121234567');
  "
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{
  "version": 1,
  "seed_env": "DBX_SCRUB_SEED",
  "tables": {
    "users": {
      "columns": {
        "email": {"strategy": "fake_email"},
        "phone": {"strategy": "fake_phone"}
      }
    }
  }
}
EOF
  _write_scrub_config "dbx.scrub.json" true

  dbx_run backup local-pg "$TEST_SRC"
  [ "$status" -eq 0 ]

  dbx_run restore "local-pg/$TEST_SRC/latest" --name "$TEST_TGT"
  [ "$status" -eq 0 ]

  # email rows are fake (@dbx.test) — none retain original domain
  local leftover_email
  leftover_email=$(docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -d "$TEST_TGT" -tA \
    -c "SELECT count(*) FROM users WHERE email NOT LIKE '%@dbx.test'" | tr -d '[:space:]')
  [ "$leftover_email" = "0" ]

  # phone rows match the fake +1555 prefix
  local leftover_phone
  leftover_phone=$(docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -d "$TEST_TGT" -tA \
    -c "SELECT count(*) FROM users WHERE phone NOT LIKE '+1555%'" | tr -d '[:space:]')
  [ "$leftover_phone" = "0" ]

  # scrub_report.json written
  [ -f "$DBX_DATA_DIR/local-pg/$TEST_SRC/scrub_report.json" ]
  local rep
  rep=$(cat "$DBX_DATA_DIR/local-pg/$TEST_SRC/scrub_report.json")
  [ "$(jq -r '.ok' <<<"$rep")" = "true" ]
  [ "$(jq -r '.verified | length' <<<"$rep")" = "2" ]
  [ "$(jq -r '.target_db' <<<"$rep")" = "$TEST_TGT" ]
}

@test "scrub gate: stable fakes — same source value → same fake across two restores" {
  seed_postgres_db "$TEST_SRC" "
    CREATE TABLE users (id SERIAL PRIMARY KEY, email TEXT);
    INSERT INTO users(email) VALUES ('tom@steig.io');
  "
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{"version": 1, "seed_env": "DBX_SCRUB_SEED",
 "tables": {"users": {"columns": {"email": {"strategy": "fake_email"}}}}}
EOF
  _write_scrub_config "dbx.scrub.json" true

  dbx_run backup local-pg "$TEST_SRC"
  [ "$status" -eq 0 ]

  dbx_run restore "local-pg/$TEST_SRC/latest" --name "${TEST_TGT}_a"
  [ "$status" -eq 0 ]
  local fake_a
  fake_a=$(docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -d "${TEST_TGT}_a" -tA -c "SELECT email FROM users" | tr -d '[:space:]')
  pg_drop_db "${TEST_TGT}_a"

  dbx_run restore "local-pg/$TEST_SRC/latest" --name "${TEST_TGT}_b"
  [ "$status" -eq 0 ]
  local fake_b
  fake_b=$(docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -d "${TEST_TGT}_b" -tA -c "SELECT email FROM users" | tr -d '[:space:]')
  pg_drop_db "${TEST_TGT}_b"

  [ -n "$fake_a" ]
  [ "$fake_a" = "$fake_b" ]
}

# ----------------------------------------------------------------------------
# Failure modes — every one MUST drop the target DB
# ----------------------------------------------------------------------------

@test "scrub gate: drift (new PII column not in manifest) → preflight aborts before restore" {
  # Schema has a new PII column the manifest doesn't cover. With
  # meta.json schema capture, the preflight catches it BEFORE
  # pg_restore_backup runs — no data lands in postgres-dbx at all.
  seed_postgres_db "$TEST_SRC" "
    CREATE TABLE users (id SERIAL, email TEXT, backup_email TEXT);
    INSERT INTO users(email, backup_email) VALUES ('tom@steig.io', 'tom2@steig.io');
  "
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{"version": 1, "seed_env": "DBX_SCRUB_SEED",
 "tables": {"users": {"columns": {"email": {"strategy": "fake_email"}}}}}
EOF
  _write_scrub_config "dbx.scrub.json" true

  dbx_run backup local-pg "$TEST_SRC"
  [ "$status" -eq 0 ]

  dbx_run restore "local-pg/$TEST_SRC/latest" --name "$TEST_TGT"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "DRIFT DETECTED in backup's captured schema"
  echo "$output" | grep -q "No data was restored"

  # target DB must NEVER have been created
  local exists
  exists=$(docker exec postgres-dbx psql -U postgres -tA \
    -c "SELECT count(*) FROM pg_database WHERE datname = '$TEST_TGT'" | tr -d '[:space:]')
  [ "$exists" = "0" ]
}

@test "scrub gate: legacy backup (no scrub_schema in meta) → post-restore drift still catches it" {
  # Backwards-compat: an old backup taken before the meta.json schema
  # capture feature. Preflight should skip (deferring to post-restore),
  # then the post-restore gate fires + drops the target.
  seed_postgres_db "$TEST_SRC" "
    CREATE TABLE users (id SERIAL, email TEXT, backup_email TEXT);
    INSERT INTO users(email, backup_email) VALUES ('tom@steig.io', 'alt@steig.io');
  "
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{"version": 1, "seed_env": "DBX_SCRUB_SEED",
 "tables": {"users": {"columns": {"email": {"strategy": "fake_email"}}}}}
EOF
  _write_scrub_config "dbx.scrub.json" true

  dbx_run backup local-pg "$TEST_SRC"
  [ "$status" -eq 0 ]

  # Simulate a legacy backup: strip scrub_schema from the meta.json.
  # Use find (not ls glob) so .meta.json files don't accidentally
  # come back as the "backup".
  local meta
  meta=$(find "$DBX_DATA_DIR/local-pg/$TEST_SRC/" -maxdepth 1 -type f -name '*.meta.json' | head -1)
  jq 'del(.scrub_schema)' "$meta" > "$meta.tmp" && mv "$meta.tmp" "$meta"

  dbx_run restore "local-pg/$TEST_SRC/latest" --name "$TEST_TGT"
  [ "$status" -ne 0 ]
  # Preflight skips with the "deferring" log; post-restore gate fires + drops
  echo "$output" | grep -q "deferring to post-restore drift check"
  echo "$output" | grep -q "DRIFT DETECTED"
  echo "$output" | grep -q "DROPPED"

  local exists
  exists=$(docker exec postgres-dbx psql -U postgres -tA \
    -c "SELECT count(*) FROM pg_database WHERE datname = '$TEST_TGT'" | tr -d '[:space:]')
  [ "$exists" = "0" ]
}

@test "scrub gate: missing seed_env → target DROPPED before any UPDATE" {
  seed_postgres_db "$TEST_SRC" "
    CREATE TABLE users (id SERIAL, email TEXT);
    INSERT INTO users(email) VALUES ('tom@steig.io');
  "
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{"version": 1, "seed_env": "DBX_SCRUB_NO_SUCH_VAR_$$",
 "tables": {"users": {"columns": {"email": {"strategy": "fake_email"}}}}}
EOF
  _write_scrub_config "dbx.scrub.json" true

  dbx_run backup local-pg "$TEST_SRC"
  [ "$status" -eq 0 ]

  unset "DBX_SCRUB_NO_SUCH_VAR_$$"
  dbx_run restore "local-pg/$TEST_SRC/latest" --name "$TEST_TGT"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "seed_env"

  local exists
  exists=$(docker exec postgres-dbx psql -U postgres -tA \
    -c "SELECT count(*) FROM pg_database WHERE datname = '$TEST_TGT'" | tr -d '[:space:]')
  [ "$exists" = "0" ]
}

@test "scrub gate: --no-scrub bypasses gate with loud warning; target survives unscrubbed" {
  seed_postgres_db "$TEST_SRC" "
    CREATE TABLE users (id SERIAL, email TEXT);
    INSERT INTO users(email) VALUES ('tom@steig.io');
  "
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{"version": 1, "seed_env": "DBX_SCRUB_SEED",
 "tables": {"users": {"columns": {"email": {"strategy": "fake_email"}}}}}
EOF
  _write_scrub_config "dbx.scrub.json" true

  dbx_run backup local-pg "$TEST_SRC"
  [ "$status" -eq 0 ]

  dbx_run restore "local-pg/$TEST_SRC/latest" --name "$TEST_TGT" --no-scrub
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PII scrub gate BYPASSED"
  echo "$output" | grep -q "UNSCRUBBED prod data"

  # Original PII still present (no scrub ran)
  local original
  original=$(docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -d "$TEST_TGT" -tA \
    -c "SELECT count(*) FROM users WHERE email = 'tom@steig.io'" | tr -d '[:space:]')
  [ "$original" = "1" ]
}

@test "scrub gate: inactive (scrub.required not set) → normal restore, no scrub" {
  # Regression check: a host with NO scrub gate config should restore
  # exactly as before this feature landed. PII present in target.
  seed_postgres_db "$TEST_SRC" "
    CREATE TABLE users (id SERIAL, email TEXT);
    INSERT INTO users(email) VALUES ('tom@steig.io');
  "
  # Config WITHOUT scrub block at all
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-pg": {
      "type": "postgres", "host": "127.0.0.1", "port": 5432, "user": "postgres",
      "password_cmd": "echo devpassword",
      "databases": { "$TEST_SRC": {} }
    }
  }
}
EOF

  dbx_run backup local-pg "$TEST_SRC"
  [ "$status" -eq 0 ]
  dbx_run restore "local-pg/$TEST_SRC/latest" --name "$TEST_TGT"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "scrub gate"
  local present
  present=$(docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -d "$TEST_TGT" -tA \
    -c "SELECT count(*) FROM users WHERE email = 'tom@steig.io'" | tr -d '[:space:]')
  [ "$present" = "1" ]
}

@test "scrub gate: required=false (configured but opt-out) → no gate; target keeps PII" {
  seed_postgres_db "$TEST_SRC" "
    CREATE TABLE users (id SERIAL, email TEXT);
    INSERT INTO users(email) VALUES ('tom@steig.io');
  "
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{"version": 1, "tables": {"users": {"columns": {"email": {"strategy": "fake_email"}}}}}
EOF
  _write_scrub_config "dbx.scrub.json" false

  dbx_run backup local-pg "$TEST_SRC"
  [ "$status" -eq 0 ]
  dbx_run restore "local-pg/$TEST_SRC/latest" --name "$TEST_TGT"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "scrub gate"
}
