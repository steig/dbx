#!/usr/bin/env bats
#
# End-to-end CLI tests for `dbx scrub init|check|validate` against a
# real postgres container. Seeds a database with a known schema, runs
# the commands, asserts on JSON output where possible.

load '../helpers/integration'

setup_file() {
  require_docker
  ensure_postgres_container
}

setup() {
  setup_dbx_env
  write_local_config
  # Each test seeds its own schema in a unique DB.
}

teardown() {
  if [[ -n "${TEST_DB:-}" ]]; then
    pg_drop_db "$TEST_DB"
  fi
}

# ----------------------------------------------------------------------------
# init
# ----------------------------------------------------------------------------

@test "scrub init: emits draft with dictionary-matching columns" {
  TEST_DB="scrub_init_basic_$$"
  seed_postgres_db "$TEST_DB" '
    CREATE TABLE users (
      id SERIAL PRIMARY KEY,
      email VARCHAR(255),
      phone VARCHAR(20),
      dob DATE,
      first_name TEXT,
      created_at TIMESTAMP
    );
    CREATE TABLE widgets (
      id SERIAL PRIMARY KEY,
      name TEXT,
      qty INTEGER
    );
  '
  local out="$DBX_CONFIG_DIR/dbx.scrub.json"
  dbx_run scrub init "local-pg/$TEST_DB" --output "$out"
  [ "$status" -eq 0 ]
  [ -f "$out" ]

  # users has email/phone/dob/first_name -> should appear with suggested strategies
  [ "$(jq -r '.tables.users.columns.email.strategy' "$out")" = "fake_email" ]
  [ "$(jq -r '.tables.users.columns.phone.strategy' "$out")" = "fake_phone" ]
  [ "$(jq -r '.tables.users.columns.dob.strategy' "$out")" = "shift_date" ]
  [ "$(jq -r '.tables.users.columns.dob.max_days' "$out")" = "30" ]
  [ "$(jq -r '.tables.users.columns.first_name.strategy' "$out")" = "fake_name" ]

  # id, created_at not in dictionary -> not present
  [ "$(jq -r '.tables.users.columns | has("id")' "$out")" = "false" ]
  [ "$(jq -r '.tables.users.columns | has("created_at")' "$out")" = "false" ]

  # widgets has no PII-matching columns -> not present by default
  [ "$(jq -r '.tables | has("widgets")' "$out")" = "false" ]

  # seed_env default
  [ "$(jq -r '.seed_env' "$out")" = "DBX_SCRUB_SEED" ]
  [ "$(jq -r '.version' "$out")" = "1" ]
}

@test "scrub init --include-empty: tables with no PII match get no_pii markers" {
  TEST_DB="scrub_init_empty_$$"
  seed_postgres_db "$TEST_DB" '
    CREATE TABLE users (id SERIAL, email TEXT);
    CREATE TABLE widgets (id SERIAL, name TEXT, qty INT);
  '
  local out="$DBX_CONFIG_DIR/dbx.scrub.json"
  dbx_run scrub init "local-pg/$TEST_DB" --include-empty --output "$out"
  [ "$status" -eq 0 ]

  [ "$(jq -r '.tables.widgets.no_pii' "$out")" = "true" ]
  [ "$(jq -r '.tables.widgets.reason' "$out")" = "init: no dictionary matches" ]
}

@test "scrub init: JSON columns get jsonb_scrub_paths placeholder" {
  TEST_DB="scrub_init_json_$$"
  seed_postgres_db "$TEST_DB" '
    CREATE TABLE user_meta (
      id SERIAL,
      preferences JSONB,
      legacy_settings JSON
    );
  '
  local out="$DBX_CONFIG_DIR/dbx.scrub.json"
  dbx_run scrub init "local-pg/$TEST_DB" --output "$out"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tables.user_meta.columns.preferences.strategy' "$out")" = "jsonb_scrub_paths" ]
  [ "$(jq -r '.tables.user_meta.columns.legacy_settings.strategy' "$out")" = "jsonb_scrub_paths" ]
}

# ----------------------------------------------------------------------------
# check
# ----------------------------------------------------------------------------

@test "scrub check: clean schema vs matching manifest → exit 0" {
  TEST_DB="scrub_check_clean_$$"
  seed_postgres_db "$TEST_DB" '
    CREATE TABLE users (id SERIAL, email VARCHAR(255), phone VARCHAR(20));
  '
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{
  "version": 1,
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
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-pg": {
      "type": "postgres",
      "host": "127.0.0.1",
      "port": 5432,
      "user": "postgres",
      "password_cmd": "echo devpassword",
      "scrub": {"manifest": "dbx.scrub.json"}
    }
  }
}
EOF
  dbx_run scrub check "local-pg/$TEST_DB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "manifest is current"
}

@test "scrub check: new PII column not in manifest → exit 2 + drift report" {
  TEST_DB="scrub_check_drift_$$"
  seed_postgres_db "$TEST_DB" '
    CREATE TABLE users (id SERIAL, email VARCHAR(255), backup_email VARCHAR(255));
  '
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{
  "version": 1,
  "tables": {
    "users": {
      "columns": {"email": {"strategy": "fake_email"}}
    }
  }
}
EOF
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-pg": {
      "type": "postgres", "host": "127.0.0.1", "port": 5432, "user": "postgres",
      "password_cmd": "echo devpassword",
      "scrub": {"manifest": "dbx.scrub.json"}
    }
  }
}
EOF
  dbx_run scrub check "local-pg/$TEST_DB"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "DRIFT DETECTED"
  echo "$output" | grep -q "backup_email"
  echo "$output" | grep -q "suggested: fake_email"
}

@test "scrub check --json: emits structured drift report on stdout" {
  TEST_DB="scrub_check_json_$$"
  seed_postgres_db "$TEST_DB" '
    CREATE TABLE users (id SERIAL, email VARCHAR(255), recovery_phone VARCHAR(20));
  '
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{
  "version": 1,
  "tables": {"users": {"columns": {"email": {"strategy": "fake_email"}}}}
}
EOF
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-pg": {
      "type": "postgres", "host": "127.0.0.1", "port": 5432, "user": "postgres",
      "password_cmd": "echo devpassword",
      "scrub": {"manifest": "dbx.scrub.json"}
    }
  }
}
EOF
  dbx_run scrub check "local-pg/$TEST_DB" --json
  [ "$status" -eq 2 ]
  # First non-log line should be valid JSON with ok=false
  json_out=$(echo "$output" | sed -n '/^{/,$p')
  [ "$(echo "$json_out" | jq -r '.ok')" = "false" ]
  [ "$(echo "$json_out" | jq -r '.new_columns_with_dict_match[0].column')" = "recovery_phone" ]
}

@test "scrub check: undeclared JSON column → drift" {
  TEST_DB="scrub_check_json_undecl_$$"
  seed_postgres_db "$TEST_DB" '
    CREATE TABLE meta (id SERIAL, prefs JSONB);
  '
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{"version": 1, "tables": {}}
EOF
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-pg": {
      "type": "postgres", "host": "127.0.0.1", "port": 5432, "user": "postgres",
      "password_cmd": "echo devpassword",
      "scrub": {"manifest": "dbx.scrub.json"}
    }
  }
}
EOF
  dbx_run scrub check "local-pg/$TEST_DB"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "UNDECLARED JSON columns"
  echo "$output" | grep -q "meta.prefs"
}

@test "scrub check: no manifest configured → exit 1 with hint" {
  TEST_DB="scrub_check_noman_$$"
  seed_postgres_db "$TEST_DB" 'CREATE TABLE t (id SERIAL);'
  # config has no scrub block
  dbx_run scrub check "local-pg/$TEST_DB"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "no manifest configured"
}

# ----------------------------------------------------------------------------
# validate
# ----------------------------------------------------------------------------

@test "scrub validate: valid manifest → exit 0" {
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{
  "version": 1,
  "tables": {"users": {"columns": {"email": {"strategy": "fake_email"}}}}
}
EOF
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-pg": {"type":"postgres","host":"127.0.0.1","port":5432,"user":"postgres",
                 "password_cmd":"echo devpassword",
                 "scrub": {"manifest":"dbx.scrub.json"}}
  }
}
EOF
  dbx_run scrub validate local-pg
  [ "$status" -eq 0 ]
}

@test "scrub validate: invalid manifest → exit 1, errors listed" {
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{"version": 1, "tables": {"users": {"columns": {"email": {}}}}}
EOF
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-pg": {"type":"postgres","host":"127.0.0.1","port":5432,"user":"postgres",
                 "password_cmd":"echo devpassword",
                 "scrub": {"manifest":"dbx.scrub.json"}}
  }
}
EOF
  dbx_run scrub validate local-pg
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "missing 'strategy'"
}

# ----------------------------------------------------------------------------
# dispatcher errors
# ----------------------------------------------------------------------------

@test "scrub: unknown action errors with usage hint" {
  dbx_run scrub bogus
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "Unknown scrub action"
}

@test "scrub init: missing target errors" {
  dbx_run scrub init
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "<host>/<database>"
}

@test "scrub init: malformed target (no slash) errors" {
  dbx_run scrub init prod
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "Target must be in the form"
}

# ----------------------------------------------------------------------------
# config validate: scrub manifest checks
# ----------------------------------------------------------------------------

@test "config validate: reports OK for valid scrub manifest" {
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{"version": 1, "tables": {"users": {"columns": {"email": {"strategy": "fake_email"}}}}}
EOF
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-pg": {
      "type": "postgres", "host": "127.0.0.1", "port": 5432, "user": "postgres",
      "password_cmd": "echo devpassword",
      "scrub": {"manifest": "dbx.scrub.json"}
    }
  }
}
EOF
  dbx_run config validate
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "scrub manifest valid"
}

@test "config validate: fails on invalid scrub manifest (unknown strategy)" {
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{"version": 1, "tables": {"u": {"columns": {"c": {"strategy": "hocus_pocus"}}}}}
EOF
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-pg": {
      "type": "postgres", "host": "127.0.0.1", "port": 5432, "user": "postgres",
      "password_cmd": "echo devpassword",
      "scrub": {"manifest": "dbx.scrub.json"}
    }
  }
}
EOF
  dbx_run config validate
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "scrub manifest INVALID"
  echo "$output" | grep -q "unknown strategy"
}

@test "config validate: fails when scrub.manifest path is missing" {
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-pg": {
      "type": "postgres", "host": "127.0.0.1", "port": 5432, "user": "postgres",
      "password_cmd": "echo devpassword",
      "scrub": {"manifest": "nonexistent.json"}
    }
  }
}
EOF
  dbx_run config validate
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "references missing file"
}

@test "config validate: warns when scrub.required=true and seed_env is unset" {
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{
  "version": 1,
  "seed_env": "DBX_TEST_NO_SUCH_SEED_$$",
  "tables": {"users": {"columns": {"email": {"strategy": "fake_email"}}}}
}
EOF
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-pg": {
      "type": "postgres", "host": "127.0.0.1", "port": 5432, "user": "postgres",
      "password_cmd": "echo devpassword",
      "scrub": {"manifest": "dbx.scrub.json", "required": true}
    }
  }
}
EOF
  unset "DBX_TEST_NO_SUCH_SEED_$$"
  dbx_run config validate
  # Warning, not error — exit should remain 0 (passwords-warn case)
  echo "$output" | grep -q "seed_env"
  echo "$output" | grep -q "unset"
}
