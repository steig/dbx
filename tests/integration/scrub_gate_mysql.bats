#!/usr/bin/env bats
#
# E2E gate tests for MySQL. Mirrors tests/integration/scrub_gate.bats
# but exercises mysql-dbx → mysql_backup → mysql_restore_backup →
# scrub_run_gate (MySQL branch: CONCAT, JSON_SET, MD5, SUBSTRING).
#
# Engine asymmetry between Postgres and MySQL is where scrub bugs hide,
# so this file is the load-bearing E2E proof that the MySQL branch
# actually executes correctly (not just emits plausible SQL).

load '../helpers/integration'

setup_file() {
  require_docker
  ensure_mysql_container
}

setup() {
  setup_dbx_env
  TEST_SRC="scrubgate_my_src_$$_${BATS_TEST_NUMBER}"
  TEST_TGT="scrubgate_my_tgt_$$_${BATS_TEST_NUMBER}"
  export DBX_SCRUB_SEED="test-salt-12345"
}

teardown() {
  mysql_drop_db "${TEST_SRC:-}"
  mysql_drop_db "${TEST_TGT:-}"
  unset DBX_SCRUB_SEED
}

_write_scrub_config_mysql() {
  local manifest_rel="$1" required="${2:-true}"
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-mysql": {
      "type": "mysql",
      "host": "127.0.0.1",
      "port": 3306,
      "user": "root",
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
# Happy path — exercises CONCAT, MD5, SUBSTRING via real UPDATE + sniff
# ----------------------------------------------------------------------------

@test "scrub gate (mysql): happy path — restore + scrub + sniff verify" {
  seed_mysql_db "$TEST_SRC" "
    CREATE TABLE users (
      id INT AUTO_INCREMENT PRIMARY KEY,
      email VARCHAR(255),
      phone VARCHAR(20),
      bio TEXT
    );
    INSERT INTO users(email, phone, bio) VALUES
      ('tom@steig.io', '+15551234567', 'Some long bio with PII inside'),
      ('alice@example.org', '+19998887766', 'Another bio'),
      ('bob@example.net', '+12121234567', 'Yet another long-ish biography');
  "
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{
  "version": 1,
  "seed_env": "DBX_SCRUB_SEED",
  "tables": {
    "users": {
      "columns": {
        "email": {"strategy": "fake_email"},
        "phone": {"strategy": "fake_phone"},
        "bio":   {"strategy": "truncate", "length": 8}
      }
    }
  }
}
EOF
  _write_scrub_config_mysql "dbx.scrub.json" true

  dbx_run backup local-mysql "$TEST_SRC"
  [ "$status" -eq 0 ]

  dbx_run restore "local-mysql/$TEST_SRC/latest" --name "$TEST_TGT"
  [ "$status" -eq 0 ]

  # email: none should retain the original domain
  local leftover_email
  leftover_email=$(docker exec -e MYSQL_PWD=devpassword mysql-dbx \
    mysql -u root -NB -e "SELECT count(*) FROM \`$TEST_TGT\`.users WHERE email NOT LIKE '%@dbx.test'" | tr -d '[:space:]')
  [ "$leftover_email" = "0" ]

  # phone: every row matches the +1555 prefix
  local leftover_phone
  leftover_phone=$(docker exec -e MYSQL_PWD=devpassword mysql-dbx \
    mysql -u root -NB -e "SELECT count(*) FROM \`$TEST_TGT\`.users WHERE phone NOT LIKE '+1555%'" | tr -d '[:space:]')
  [ "$leftover_phone" = "0" ]

  # bio: SUBSTRING(bio, 1, 8) — every row <= 8 chars now
  local leftover_bio
  leftover_bio=$(docker exec -e MYSQL_PWD=devpassword mysql-dbx \
    mysql -u root -NB -e "SELECT count(*) FROM \`$TEST_TGT\`.users WHERE CHAR_LENGTH(bio) > 8" | tr -d '[:space:]')
  [ "$leftover_bio" = "0" ]

  # scrub_report.json written with 3 verified entries
  [ -f "$DBX_DATA_DIR/local-mysql/$TEST_SRC/scrub_report.json" ]
  local rep
  rep=$(cat "$DBX_DATA_DIR/local-mysql/$TEST_SRC/scrub_report.json")
  [ "$(jq -r '.ok' <<<"$rep")" = "true" ]
  [ "$(jq -r '.verified | length' <<<"$rep")" = "3" ]
  [ "$(jq -r '.target_db' <<<"$rep")" = "$TEST_TGT" ]
}

@test "scrub gate (mysql): stable fakes — same source value → same fake across two restores" {
  seed_mysql_db "$TEST_SRC" "
    CREATE TABLE users (id INT AUTO_INCREMENT PRIMARY KEY, email VARCHAR(255));
    INSERT INTO users(email) VALUES ('tom@steig.io');
  "
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{"version": 1, "seed_env": "DBX_SCRUB_SEED",
 "tables": {"users": {"columns": {"email": {"strategy": "fake_email"}}}}}
EOF
  _write_scrub_config_mysql "dbx.scrub.json" true

  dbx_run backup local-mysql "$TEST_SRC"
  [ "$status" -eq 0 ]

  dbx_run restore "local-mysql/$TEST_SRC/latest" --name "${TEST_TGT}_a"
  [ "$status" -eq 0 ]
  local fake_a
  fake_a=$(docker exec -e MYSQL_PWD=devpassword mysql-dbx \
    mysql -u root -NB -e "SELECT email FROM \`${TEST_TGT}_a\`.users" | tr -d '[:space:]')
  mysql_drop_db "${TEST_TGT}_a"

  dbx_run restore "local-mysql/$TEST_SRC/latest" --name "${TEST_TGT}_b"
  [ "$status" -eq 0 ]
  local fake_b
  fake_b=$(docker exec -e MYSQL_PWD=devpassword mysql-dbx \
    mysql -u root -NB -e "SELECT email FROM \`${TEST_TGT}_b\`.users" | tr -d '[:space:]')
  mysql_drop_db "${TEST_TGT}_b"

  [ -n "$fake_a" ]
  [ "$fake_a" = "$fake_b" ]
}

# ----------------------------------------------------------------------------
# redact with replacement — NOT NULL column scenario (the #2 fix)
# ----------------------------------------------------------------------------

@test "scrub gate (mysql): redact with replacement handles NOT NULL columns" {
  seed_mysql_db "$TEST_SRC" "
    CREATE TABLE users (
      id INT AUTO_INCREMENT PRIMARY KEY,
      ssn VARCHAR(11) NOT NULL
    );
    INSERT INTO users(ssn) VALUES ('123-45-6789'), ('999-88-7777');
  "
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{
  "version": 1, "seed_env": "DBX_SCRUB_SEED",
  "tables": {"users": {"columns": {
    "ssn": {"strategy": "redact", "replacement": "XXX-XX-XXXX"}
  }}}
}
EOF
  _write_scrub_config_mysql "dbx.scrub.json" true

  dbx_run backup local-mysql "$TEST_SRC"
  [ "$status" -eq 0 ]

  dbx_run restore "local-mysql/$TEST_SRC/latest" --name "$TEST_TGT"
  [ "$status" -eq 0 ]

  # All rows now equal the replacement; sniff would have failed otherwise.
  local mismatch
  mismatch=$(docker exec -e MYSQL_PWD=devpassword mysql-dbx \
    mysql -u root -NB -e "SELECT count(*) FROM \`$TEST_TGT\`.users WHERE ssn <> 'XXX-XX-XXXX'" | tr -d '[:space:]')
  [ "$mismatch" = "0" ]
}

# ----------------------------------------------------------------------------
# Failure modes — all must drop the target
# ----------------------------------------------------------------------------

@test "scrub gate (mysql): drift (new PII column not in manifest) → preflight aborts before restore" {
  seed_mysql_db "$TEST_SRC" "
    CREATE TABLE users (
      id INT AUTO_INCREMENT PRIMARY KEY,
      email VARCHAR(255),
      backup_email VARCHAR(255)
    );
    INSERT INTO users(email, backup_email) VALUES ('tom@steig.io', 'alt@steig.io');
  "
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{"version": 1, "seed_env": "DBX_SCRUB_SEED",
 "tables": {"users": {"columns": {"email": {"strategy": "fake_email"}}}}}
EOF
  _write_scrub_config_mysql "dbx.scrub.json" true

  dbx_run backup local-mysql "$TEST_SRC"
  [ "$status" -eq 0 ]

  dbx_run restore "local-mysql/$TEST_SRC/latest" --name "$TEST_TGT"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "DRIFT DETECTED in backup's captured schema"
  echo "$output" | grep -q "No data was restored"

  local exists
  exists=$(docker exec -e MYSQL_PWD=devpassword mysql-dbx mysql -u root -NB \
    -e "SELECT count(*) FROM information_schema.schemata WHERE schema_name = '$TEST_TGT'" | tr -d '[:space:]')
  [ "$exists" = "0" ]
}

@test "scrub gate (mysql): missing seed_env → target DROPPED before any UPDATE" {
  seed_mysql_db "$TEST_SRC" "
    CREATE TABLE users (id INT AUTO_INCREMENT PRIMARY KEY, email VARCHAR(255));
    INSERT INTO users(email) VALUES ('tom@steig.io');
  "
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{"version": 1, "seed_env": "DBX_SCRUB_NO_SUCH_VAR_$$",
 "tables": {"users": {"columns": {"email": {"strategy": "fake_email"}}}}}
EOF
  _write_scrub_config_mysql "dbx.scrub.json" true

  dbx_run backup local-mysql "$TEST_SRC"
  [ "$status" -eq 0 ]

  unset "DBX_SCRUB_NO_SUCH_VAR_$$"
  dbx_run restore "local-mysql/$TEST_SRC/latest" --name "$TEST_TGT"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "seed_env"

  local exists
  exists=$(docker exec -e MYSQL_PWD=devpassword mysql-dbx mysql -u root -NB \
    -e "SELECT count(*) FROM information_schema.schemata WHERE schema_name = '$TEST_TGT'" | tr -d '[:space:]')
  [ "$exists" = "0" ]
}

@test "scrub gate (mysql): --no-scrub bypasses gate; target survives unscrubbed" {
  seed_mysql_db "$TEST_SRC" "
    CREATE TABLE users (id INT AUTO_INCREMENT PRIMARY KEY, email VARCHAR(255));
    INSERT INTO users(email) VALUES ('tom@steig.io');
  "
  cat > "$DBX_CONFIG_DIR/dbx.scrub.json" <<EOF
{"version": 1, "seed_env": "DBX_SCRUB_SEED",
 "tables": {"users": {"columns": {"email": {"strategy": "fake_email"}}}}}
EOF
  _write_scrub_config_mysql "dbx.scrub.json" true

  dbx_run backup local-mysql "$TEST_SRC"
  [ "$status" -eq 0 ]

  dbx_run restore "local-mysql/$TEST_SRC/latest" --name "$TEST_TGT" --no-scrub
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PII scrub gate BYPASSED"

  local original
  original=$(docker exec -e MYSQL_PWD=devpassword mysql-dbx \
    mysql -u root -NB -e "SELECT count(*) FROM \`$TEST_TGT\`.users WHERE email = 'tom@steig.io'" | tr -d '[:space:]')
  [ "$original" = "1" ]
}

@test "scrub gate (mysql): inactive (no scrub block) → normal restore, no scrub" {
  seed_mysql_db "$TEST_SRC" "
    CREATE TABLE users (id INT AUTO_INCREMENT PRIMARY KEY, email VARCHAR(255));
    INSERT INTO users(email) VALUES ('tom@steig.io');
  "
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-mysql": {
      "type": "mysql", "host": "127.0.0.1", "port": 3306, "user": "root",
      "password_cmd": "echo devpassword",
      "databases": { "$TEST_SRC": {} }
    }
  }
}
EOF

  dbx_run backup local-mysql "$TEST_SRC"
  [ "$status" -eq 0 ]
  dbx_run restore "local-mysql/$TEST_SRC/latest" --name "$TEST_TGT"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "scrub gate"
  local present
  present=$(docker exec -e MYSQL_PWD=devpassword mysql-dbx \
    mysql -u root -NB -e "SELECT count(*) FROM \`$TEST_TGT\`.users WHERE email = 'tom@steig.io'" | tr -d '[:space:]')
  [ "$present" = "1" ]
}
