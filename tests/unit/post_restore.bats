#!/usr/bin/env bats
#
# Tests for lib/post_restore.sh — config parsing, path resolution, error
# semantics. Engine dispatch is exercised by tests/integration/post_restore.bats.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
}

# ----------------------------------------------------------------------------
# resolve_hook_path
# ----------------------------------------------------------------------------

@test "resolve_hook_path: absolute path is returned unchanged" {
  result=$(resolve_hook_path "/tmp/foo/bar.sql")
  [ "$result" = "/tmp/foo/bar.sql" ]
}

@test "resolve_hook_path: relative path is resolved against config dir" {
  # $CONFIG_FILE is set by source_dbx_libs to $DBX_CONFIG_DIR/config.json
  result=$(resolve_hook_path "hooks/scrub.sql")
  [ "$result" = "$DBX_CONFIG_DIR/hooks/scrub.sql" ]
}

@test "resolve_hook_path: bare filename resolves to config dir" {
  result=$(resolve_hook_path "scrub.sql")
  [ "$result" = "$DBX_CONFIG_DIR/scrub.sql" ]
}

# ----------------------------------------------------------------------------
# read_post_restore_hooks
# ----------------------------------------------------------------------------

@test "read_post_restore_hooks: missing key returns []" {
  write_config '{"hosts":{"prod":{"databases":{"app":{}}}}}'
  result=$(read_post_restore_hooks "prod" "app")
  [ "$result" = "[]" ]
}

@test "read_post_restore_hooks: missing host returns []" {
  write_config '{"hosts":{}}'
  result=$(read_post_restore_hooks "nope" "app")
  [ "$result" = "[]" ]
}

@test "read_post_restore_hooks: returns the configured array" {
  write_config '{"hosts":{"prod":{"databases":{"app":{"post_restore":[{"file":"a.sql"},{"sql":"SELECT 1"}]}}}}}'
  result=$(read_post_restore_hooks "prod" "app")
  [ "$(jq 'length' <<<"$result")" = "2" ]
  [ "$(jq -r '.[0].file' <<<"$result")" = "a.sql" ]
  [ "$(jq -r '.[1].sql' <<<"$result")" = "SELECT 1" ]
}

# ----------------------------------------------------------------------------
# run_post_restore_hooks — config-validation paths (no docker required)
# ----------------------------------------------------------------------------

@test "run_post_restore_hooks: no hooks configured is a no-op" {
  write_config '{"hosts":{"prod":{"databases":{"app":{}}}}}'
  run run_post_restore_hooks "prod" "app" "target" "postgres"
  [ "$status" -eq 0 ]
}

@test "run_post_restore_hooks: empty array is a no-op" {
  write_config '{"hosts":{"prod":{"databases":{"app":{"post_restore":[]}}}}}'
  run run_post_restore_hooks "prod" "app" "target" "postgres"
  [ "$status" -eq 0 ]
}

@test "run_post_restore_hooks: entry with neither file nor sql errors" {
  write_config '{"hosts":{"prod":{"databases":{"app":{"post_restore":[{}]}}}}}'
  run run_post_restore_hooks "prod" "app" "target" "postgres"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "neither 'file' nor 'sql'"
}

@test "run_post_restore_hooks: entry with both file and sql errors" {
  write_config '{"hosts":{"prod":{"databases":{"app":{"post_restore":[{"file":"a.sql","sql":"SELECT 1"}]}}}}}'
  run run_post_restore_hooks "prod" "app" "target" "postgres"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "both 'file' and 'sql'"
}

@test "run_post_restore_hooks: missing hook file errors with resolved path" {
  write_config '{"hosts":{"prod":{"databases":{"app":{"post_restore":[{"file":"nope.sql"}]}}}}}'
  run run_post_restore_hooks "prod" "app" "target" "postgres"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "file not found"
  echo "$output" | grep -qF "$DBX_CONFIG_DIR/nope.sql"
}

@test "run_post_restore_hooks: error message includes the entry index" {
  write_config '{"hosts":{"prod":{"databases":{"app":{"post_restore":[{"file":"missing.sql"}]}}}}}'
  run run_post_restore_hooks "prod" "app" "target" "postgres"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "post_restore\[0\]"
}

# ----------------------------------------------------------------------------
# read_host_post_restore_hooks — host-level inheritance reads
# ----------------------------------------------------------------------------

@test "read_host_post_restore_hooks: missing key returns []" {
  write_config '{"hosts":{"prod":{"databases":{"app":{}}}}}'
  result=$(read_host_post_restore_hooks "prod")
  [ "$result" = "[]" ]
}

@test "read_host_post_restore_hooks: returns the configured host-level array" {
  write_config '{"hosts":{"prod":{"post_restore":[{"sql":"SELECT 1"}],"databases":{"app":{}}}}}'
  result=$(read_host_post_restore_hooks "prod")
  [ "$(jq 'length' <<<"$result")" = "1" ]
  [ "$(jq -r '.[0].sql' <<<"$result")" = "SELECT 1" ]
}

# ----------------------------------------------------------------------------
# parse_backup_timestamp
# ----------------------------------------------------------------------------

@test "parse_backup_timestamp: standard dbx filename → ISO-8601" {
  result=$(parse_backup_timestamp "app_20260508_103000.dump.zst")
  [ "$result" = "2026-05-08T10:30:00Z" ]
}

@test "parse_backup_timestamp: filename without suffix → empty" {
  result=$(parse_backup_timestamp "random-file.sql")
  [ -z "$result" ]
}

@test "parse_backup_timestamp: empty input → empty" {
  result=$(parse_backup_timestamp "")
  [ -z "$result" ]
}

# ----------------------------------------------------------------------------
# Engine var-construction helpers (pure, no docker)
# ----------------------------------------------------------------------------

@test "pg_build_psql_var_flags: builds -v key=value pairs, skips bad entries" {
  # Use mapfile-style read so multiline output becomes an array.
  local -a got=()
  while IFS= read -r line; do got+=("$line"); done < <(pg_build_psql_var_flags "target_db=foo" "noequals" "source_host=bar")
  [ "${#got[@]}" -eq 4 ]
  [ "${got[0]}" = "-v" ]
  [ "${got[1]}" = "target_db=foo" ]
  [ "${got[2]}" = "-v" ]
  [ "${got[3]}" = "source_host=bar" ]
}

@test "pg_build_psql_var_flags: zero args → no output" {
  result=$(pg_build_psql_var_flags)
  [ -z "$result" ]
}

@test "mysql_build_var_prelude: builds SET @key := 'value'; lines in order" {
  result=$(mysql_build_var_prelude "target_db=foo" "source_host=bar")
  expected="SET @target_db := 'foo';
SET @source_host := 'bar';"
  [ "$result" = "$expected" ]
}

@test "mysql_build_var_prelude: single quotes in value are doubled" {
  result=$(mysql_build_var_prelude "name=O'Brien")
  [ "$result" = "SET @name := 'O''Brien';" ]
}

@test "mysql_build_var_prelude: backslashes are escaped before quote-doubling" {
  # MySQL with default NO_BACKSLASH_ESCAPES=OFF interprets \n, \t, etc.
  # inside single-quoted strings. Values containing backslashes must be
  # escaped or the SET statement either corrupts the value or breaks.
  result=$(mysql_build_var_prelude 'path=C:\Users\foo')
  [ "$result" = "SET @path := 'C:\\\\Users\\\\foo';" ]
}

@test "mysql_build_var_prelude: entries without = are skipped" {
  result=$(mysql_build_var_prelude "good=yes" "bare" "also_good=ok")
  expected="SET @good := 'yes';
SET @also_good := 'ok';"
  [ "$result" = "$expected" ]
}

@test "mysql_build_var_prelude: zero args → empty output" {
  result=$(mysql_build_var_prelude)
  [ -z "$result" ]
}

# ----------------------------------------------------------------------------
# Per-host inheritance + ordering — log output is the observable contract.
# We stub the engine helpers so these tests don't need docker.
# ----------------------------------------------------------------------------

# Stub pg_run_sql_stream so it just consumes stdin and exits 0.
_stub_engine_helpers_ok() {
  pg_run_sql_stream() { cat >/dev/null; return 0; }
  mysql_run_sql_stream() { cat >/dev/null; return 0; }
  require_container() { return 0; }
}

@test "run_post_restore_hooks: host hooks run before db hooks, both counted" {
  _stub_engine_helpers_ok
  write_config '{
    "hosts": {
      "prod": {
        "post_restore": [{"sql":"SELECT 1"},{"sql":"SELECT 2"}],
        "databases": {
          "app": {
            "post_restore": [{"sql":"SELECT 3"}]
          }
        }
      }
    }
  }'
  run run_post_restore_hooks "prod" "app" "target" "postgres"
  [ "$status" -eq 0 ]
  # Total = 3; log step announces it.
  echo "$output" | grep -q "Running post-restore hooks (3)"
  # Host hooks tagged (host), per-db tagged (db).
  echo "$output" | grep -q "\[1/3\] (host)"
  echo "$output" | grep -q "\[2/3\] (host)"
  echo "$output" | grep -q "\[3/3\] (db)"
  # Ordering: every (host) line appears before any (db) line.
  host_line=$(echo "$output" | grep -n "(host)" | tail -1 | cut -d: -f1)
  db_line=$(echo "$output" | grep -n "(db)" | head -1 | cut -d: -f1)
  [ "$host_line" -lt "$db_line" ]
}

@test "run_post_restore_hooks: host hooks only (no db hooks) → only host runs" {
  _stub_engine_helpers_ok
  write_config '{
    "hosts": {
      "prod": {
        "post_restore": [{"sql":"SELECT 1"}],
        "databases": { "app": {} }
      }
    }
  }'
  run run_post_restore_hooks "prod" "app" "target" "postgres"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Running post-restore hooks (1)"
  echo "$output" | grep -q "\[1/1\] (host)"
  ! echo "$output" | grep -q "(db)"
}

@test "run_post_restore_hooks: db hooks only (no host hooks) → only db runs" {
  _stub_engine_helpers_ok
  write_config '{
    "hosts": {
      "prod": {
        "databases": {
          "app": {
            "post_restore": [{"sql":"SELECT 1"}]
          }
        }
      }
    }
  }'
  run run_post_restore_hooks "prod" "app" "target" "postgres"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Running post-restore hooks (1)"
  echo "$output" | grep -q "\[1/1\] (db)"
  ! echo "$output" | grep -q "(host)"
}

@test "run_post_restore_hooks: both arrays empty → no-op (no log step)" {
  _stub_engine_helpers_ok
  write_config '{
    "hosts": {
      "prod": {
        "post_restore": [],
        "databases": { "app": { "post_restore": [] } }
      }
    }
  }'
  run run_post_restore_hooks "prod" "app" "target" "postgres"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "Running post-restore hooks"
}

@test "run_post_restore_hooks: global index continues across host→db boundary" {
  # 2 host hooks, then a malformed db hook. Error should reference
  # post_restore[2] (the 3rd hook, 0-based) and tag (db).
  _stub_engine_helpers_ok
  write_config '{
    "hosts": {
      "prod": {
        "post_restore": [{"sql":"SELECT 1"},{"sql":"SELECT 2"}],
        "databases": {
          "app": {
            "post_restore": [{}]
          }
        }
      }
    }
  }'
  run run_post_restore_hooks "prod" "app" "target" "postgres"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "post_restore\[2\] (db)"
  echo "$output" | grep -q "neither 'file' nor 'sql'"
}

@test "run_post_restore_hooks: inline label uses global index" {
  _stub_engine_helpers_ok
  write_config '{
    "hosts": {
      "prod": {
        "post_restore": [{"sql":"SELECT 1"}],
        "databases": {
          "app": {
            "post_restore": [{"sql":"SELECT 2"}]
          }
        }
      }
    }
  }'
  run run_post_restore_hooks "prod" "app" "target" "postgres"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "\[1/2\] (host) inline #1"
  echo "$output" | grep -q "\[2/2\] (db) inline #2"
}
