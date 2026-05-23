#!/usr/bin/env bats
#
# End-to-end post-restore hook round-trips against real Postgres + MySQL
# containers. Unit-level config parsing, path resolution, and var
# construction are covered by tests/unit/post_restore.bats — these tests
# exist to prove the docker exec + transactional wrap + variable
# interpolation actually work against real engines.

load '../helpers/integration'

setup_file() {
  require_docker
  ensure_postgres_container
  ensure_mysql_container
}

setup() {
  setup_dbx_env
  TEST_DB="dbx_hooks_test_$$_${BATS_TEST_NUMBER}"
  RESTORE_DB="${TEST_DB}_restored"
  HOOKS_DIR="$DBX_CONFIG_DIR/hooks"
  mkdir -p "$HOOKS_DIR"
}

teardown() {
  pg_drop_db "$TEST_DB"
  pg_drop_db "$RESTORE_DB"
  mysql_drop_db "$TEST_DB"
  mysql_drop_db "$RESTORE_DB"
}

# Write a config for one engine with a per-db post_restore array.
# Args: $1 = "pg" or "mysql", $2 = raw JSON for the post_restore block.
_write_hook_config() {
  local engine="$1"
  local post_restore_json="${2:-[]}"
  local alias host_name type port user
  case "$engine" in
    pg)    alias="local-pg";    type="postgres"; port=5432; user="postgres" ;;
    mysql) alias="local-mysql"; type="mysql";    port=3306; user="root" ;;
    *) echo "unknown engine: $engine" >&2; return 1 ;;
  esac
  host_name="127.0.0.1"
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "$alias": {
      "type": "$type",
      "host": "$host_name",
      "port": $port,
      "user": "$user",
      "password_cmd": "echo devpassword",
      "databases": {
        "$TEST_DB": {
          "post_restore": $post_restore_json
        }
      }
    }
  },
  "defaults": { "compression_level": 1, "keep_backups": 10 }
}
EOF
}

# Back-compat shims so the rest of the file reads naturally per engine.
_write_pg_hook_config()    { _write_hook_config "pg"    "$@"; }
_write_mysql_hook_config() { _write_hook_config "mysql" "$@"; }

_seed_pg_secret_table() {
  seed_postgres_db "$TEST_DB" "CREATE TABLE secrets(id int PRIMARY KEY, val text);
INSERT INTO secrets VALUES (1,'real'),(2,'real');"
}

_seed_mysql_secret_table() {
  seed_mysql_db "$TEST_DB" "CREATE TABLE secrets(id INT PRIMARY KEY, val VARCHAR(50));
INSERT INTO secrets VALUES (1,'real'),(2,'real');"
}

_pg_secret_val() {
  docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -d "$1" -t -A -c "SELECT val FROM secrets WHERE id=1" 2>/dev/null
}

_mysql_secret_val() {
  docker exec -e MYSQL_PWD=devpassword mysql-dbx \
    mysql -u root -N -e "SELECT val FROM \`$1\`.secrets WHERE id=1" 2>/dev/null
}

# ----------------------------------------------------------------------------
# Postgres
# ----------------------------------------------------------------------------

@test "postgres: file hook mutates row in restored DB" {
  _seed_pg_secret_table
  cat > "$HOOKS_DIR/scrub.sql" <<'EOF'
UPDATE secrets SET val = 'scrubbed';
EOF
  _write_pg_hook_config '[{"file":"hooks/scrub.sql"}]'

  dbx_run backup local-pg "$TEST_DB"
  [ "$status" -eq 0 ]
  dbx_run restore "local-pg/$TEST_DB/latest" --name "$RESTORE_DB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Running post-restore hooks"
  [ "$(_pg_secret_val "$RESTORE_DB")" = "scrubbed" ]
}

@test "postgres: inline SQL hook mutates row in restored DB" {
  _seed_pg_secret_table
  _write_pg_hook_config '[{"sql":"UPDATE secrets SET val = '\''inline_done'\'';"}]'

  dbx_run backup local-pg "$TEST_DB"
  [ "$status" -eq 0 ]
  dbx_run restore "local-pg/$TEST_DB/latest" --name "$RESTORE_DB"
  [ "$status" -eq 0 ]
  [ "$(_pg_secret_val "$RESTORE_DB")" = "inline_done" ]
}

@test "postgres: --no-post-restore skips hooks" {
  _seed_pg_secret_table
  _write_pg_hook_config '[{"sql":"UPDATE secrets SET val = '\''should_not_run'\'';"}]'

  dbx_run backup local-pg "$TEST_DB"
  [ "$status" -eq 0 ]
  dbx_run restore "local-pg/$TEST_DB/latest" --name "$RESTORE_DB" --no-post-restore
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "Running post-restore hooks"
  [ "$(_pg_secret_val "$RESTORE_DB")" = "real" ]
}

@test "postgres: failing hook SQL fails the restore (fail-fast)" {
  _seed_pg_secret_table
  _write_pg_hook_config '[{"sql":"UPDATE nonexistent_table SET val = '\''x'\'';"}]'

  dbx_run backup local-pg "$TEST_DB"
  [ "$status" -eq 0 ]
  dbx_run restore "local-pg/$TEST_DB/latest" --name "$RESTORE_DB"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "post-restore hooks failed"
  # The restored DB IS left in place (the engine restore succeeded, only
  # the hook failed); confirm it exists.
  docker exec "$POSTGRES_CONTAINER" psql -U postgres -lqt 2>/dev/null \
    | cut -d'|' -f1 | grep -qw "$RESTORE_DB"
}

@test "postgres: target_db variable is interpolated into psql hook" {
  _seed_pg_secret_table
  # Use :'target_db' to verify the var is passed and quoted as a string.
  cat > "$HOOKS_DIR/stamp.sql" <<'EOF'
CREATE TABLE _provenance(restored_into text);
INSERT INTO _provenance VALUES (:'target_db');
EOF
  _write_pg_hook_config '[{"file":"hooks/stamp.sql"}]'

  dbx_run backup local-pg "$TEST_DB"
  [ "$status" -eq 0 ]
  dbx_run restore "local-pg/$TEST_DB/latest" --name "$RESTORE_DB"
  [ "$status" -eq 0 ]
  local got
  got=$(docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -d "$RESTORE_DB" -t -A -c "SELECT restored_into FROM _provenance" 2>/dev/null)
  [ "$got" = "$RESTORE_DB" ]
}

@test "postgres: per-host inherited hook runs before per-db hook" {
  _seed_pg_secret_table
  # Two hooks: host-level sets 'host_ran', db-level appends to mark order.
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-pg": {
      "type": "postgres",
      "host": "127.0.0.1",
      "port": 5432,
      "user": "postgres",
      "password_cmd": "echo devpassword",
      "post_restore": [
        {"sql":"UPDATE secrets SET val = 'host_ran';"}
      ],
      "databases": {
        "$TEST_DB": {
          "post_restore": [
            {"sql":"UPDATE secrets SET val = val || '+db_ran';"}
          ]
        }
      }
    }
  },
  "defaults": { "compression_level": 1, "keep_backups": 10 }
}
EOF

  dbx_run backup local-pg "$TEST_DB"
  [ "$status" -eq 0 ]
  dbx_run restore "local-pg/$TEST_DB/latest" --name "$RESTORE_DB"
  [ "$status" -eq 0 ]
  [ "$(_pg_secret_val "$RESTORE_DB")" = "host_ran+db_ran" ]
}

@test "postgres: --hooks-only runs hooks against existing DB without re-restoring" {
  _seed_pg_secret_table
  # First restore without hooks so the DB exists with 'real'.
  _write_pg_hook_config '[]'
  dbx_run backup local-pg "$TEST_DB"
  [ "$status" -eq 0 ]
  dbx_run restore "local-pg/$TEST_DB/latest" --name "$RESTORE_DB"
  [ "$status" -eq 0 ]
  [ "$(_pg_secret_val "$RESTORE_DB")" = "real" ]

  # Now add a hook to the config and re-run with --hooks-only.
  _write_pg_hook_config '[{"sql":"UPDATE secrets SET val = '\''hooks_only_ran'\'';"}]'
  dbx_run restore "local-pg/$TEST_DB/latest" --hooks-only --name "$RESTORE_DB"
  [ "$status" -eq 0 ]
  [ "$(_pg_secret_val "$RESTORE_DB")" = "hooks_only_ran" ]
}

@test "postgres: --hooks-only errors when --name not provided" {
  _write_pg_hook_config '[]'
  dbx_run restore "local-pg/$TEST_DB/latest" --hooks-only
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "requires --name"
}

@test "postgres: --hooks-only errors when target DB doesn't exist" {
  _write_pg_hook_config '[{"sql":"SELECT 1;"}]'
  dbx_run restore "local-pg/$TEST_DB/latest" --hooks-only --name "nonexistent_db_xyz"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "not found in"
}

@test "postgres: --hooks-only + --no-post-restore is rejected" {
  _write_pg_hook_config '[]'
  dbx_run restore "local-pg/$TEST_DB/latest" --hooks-only --no-post-restore --name "anything"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "mutually exclusive"
}

# ----------------------------------------------------------------------------
# MySQL
# ----------------------------------------------------------------------------

@test "mysql: file hook mutates row in restored DB" {
  _seed_mysql_secret_table
  cat > "$HOOKS_DIR/scrub.sql" <<'EOF'
UPDATE secrets SET val = 'scrubbed';
EOF
  _write_mysql_hook_config '[{"file":"hooks/scrub.sql"}]'

  dbx_run backup local-mysql "$TEST_DB"
  [ "$status" -eq 0 ]
  dbx_run restore "local-mysql/$TEST_DB/latest" --name "$RESTORE_DB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Running post-restore hooks"
  [ "$(_mysql_secret_val "$RESTORE_DB")" = "scrubbed" ]
}

@test "mysql: inline SQL hook mutates row in restored DB" {
  _seed_mysql_secret_table
  _write_mysql_hook_config '[{"sql":"UPDATE secrets SET val = '\''inline_done'\'';"}]'

  dbx_run backup local-mysql "$TEST_DB"
  [ "$status" -eq 0 ]
  dbx_run restore "local-mysql/$TEST_DB/latest" --name "$RESTORE_DB"
  [ "$status" -eq 0 ]
  [ "$(_mysql_secret_val "$RESTORE_DB")" = "inline_done" ]
}

@test "mysql: --no-post-restore skips hooks" {
  _seed_mysql_secret_table
  _write_mysql_hook_config '[{"sql":"UPDATE secrets SET val = '\''should_not_run'\'';"}]'

  dbx_run backup local-mysql "$TEST_DB"
  [ "$status" -eq 0 ]
  dbx_run restore "local-mysql/$TEST_DB/latest" --name "$RESTORE_DB" --no-post-restore
  [ "$status" -eq 0 ]
  [ "$(_mysql_secret_val "$RESTORE_DB")" = "real" ]
}

@test "mysql: failing hook fails the restore" {
  _seed_mysql_secret_table
  _write_mysql_hook_config '[{"sql":"UPDATE nonexistent SET x = 1;"}]'

  dbx_run backup local-mysql "$TEST_DB"
  [ "$status" -eq 0 ]
  dbx_run restore "local-mysql/$TEST_DB/latest" --name "$RESTORE_DB"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "post-restore hooks failed"
}

# ----------------------------------------------------------------------------
# config validate
# ----------------------------------------------------------------------------

@test "config validate: catches missing hook file path" {
  _write_pg_hook_config '[{"file":"hooks/does_not_exist.sql"}]'
  dbx_run config validate
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "file not found"
  echo "$output" | grep -q "does_not_exist.sql"
}

@test "config validate: catches entry with both file and sql" {
  _write_pg_hook_config '[{"file":"hooks/x.sql","sql":"SELECT 1"}]'
  touch "$HOOKS_DIR/x.sql"
  dbx_run config validate
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "both 'file' and 'sql'"
}

@test "config validate: catches entry with neither file nor sql" {
  _write_pg_hook_config '[{}]'
  dbx_run config validate
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "neither 'file' nor 'sql'"
}

@test "config validate: passes with valid hooks" {
  cat > "$HOOKS_DIR/ok.sql" <<'EOF'
SELECT 1;
EOF
  _write_pg_hook_config '[{"file":"hooks/ok.sql"},{"sql":"SELECT 1"}]'
  dbx_run config validate
  [ "$status" -eq 0 ]
}
