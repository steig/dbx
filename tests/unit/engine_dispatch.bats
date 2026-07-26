#!/usr/bin/env bats
#
# Tests for the engine-dispatch helpers in lib/core.sh (#143) — the single
# home for the `postgres|postgresql` / `mysql|mariadb` mapping that ~18 sites
# used to spell out by hand.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
}

# ----------------------------------------------------------------------------
# engine_for — db_type -> canonical key
# ----------------------------------------------------------------------------

@test "engine_for: postgres and postgresql both resolve to pg" {
  [ "$(engine_for postgres)" = "pg" ]
  [ "$(engine_for postgresql)" = "pg" ]
}

@test "engine_for: mysql and mariadb both resolve to mysql" {
  [ "$(engine_for mysql)" = "mysql" ]
  [ "$(engine_for mariadb)" = "mysql" ]
}

@test "engine_for: an unknown type returns non-zero and prints nothing" {
  run engine_for sqlite
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "engine_for: an empty type returns non-zero" {
  run engine_for ""
  [ "$status" -ne 0 ]
}

# The key doubles as both a function-name prefix (pg_*/mysql_*) and a suffix
# (*_pg/*_mysql). Callers rely on that; pin it so a rename to e.g. "postgres"
# does not silently break the indirect calls built from it.
@test "engine_for: the key composes with both naming families in the tree" {
  local key
  key=$(engine_for postgres)
  declare -f "${key}_run_sql_stream" >/dev/null
  declare -f "scrub_schema_query_${key}" >/dev/null

  key=$(engine_for mariadb)
  declare -f "${key}_run_sql_stream" >/dev/null
  declare -f "scrub_schema_query_${key}" >/dev/null
}

# ----------------------------------------------------------------------------
# engine_container — db_type -> managed container name
# ----------------------------------------------------------------------------

@test "engine_container: maps each spelling to its managed container" {
  [ "$(engine_container postgres)" = "$POSTGRES_CONTAINER" ]
  [ "$(engine_container postgresql)" = "$POSTGRES_CONTAINER" ]
  [ "$(engine_container mysql)" = "$MYSQL_CONTAINER" ]
  [ "$(engine_container mariadb)" = "$MYSQL_CONTAINER" ]
}

@test "engine_container: an unknown type returns non-zero and prints nothing" {
  run engine_container redis
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ----------------------------------------------------------------------------
# engine_for_container — container name/image -> canonical key
# ----------------------------------------------------------------------------

@test "engine_for_container: the managed container names resolve by name" {
  [ "$(engine_for_container postgres-dbx)" = "pg" ]
  [ "$(engine_for_container mysql-dbx)" = "mysql" ]
}

# The image fallback is what covers the non-standard container names the
# integration suite creates. Passing the image explicitly avoids a docker call.
@test "engine_for_container: falls back to the image tag for odd names" {
  [ "$(engine_for_container bats-ctr-1 postgres:17-alpine)" = "pg" ]
  [ "$(engine_for_container bats-ctr-1 pgvector/pgvector:pg16)" = "pg" ]
  [ "$(engine_for_container bats-ctr-1 postgis/postgis:16-3.5)" = "pg" ]
  [ "$(engine_for_container bats-ctr-1 timescale/timescaledb:latest-pg16)" = "pg" ]
  [ "$(engine_for_container bats-ctr-1 dbx-pg17-vector)" = "pg" ]
  [ "$(engine_for_container bats-ctr-1 mysql:8.0)" = "mysql" ]
  [ "$(engine_for_container bats-ctr-1 mariadb:11.4)" = "mysql" ]
}

@test "engine_for_container: the name wins over a contradicting image" {
  [ "$(engine_for_container postgres-dbx mysql:8.0)" = "pg" ]
}

@test "engine_for_container: an unidentifiable container returns non-zero" {
  run engine_for_container bats-ctr-1 redis:7
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ----------------------------------------------------------------------------
# engine_call — dispatch to pg_<op> / mysql_<op>
# ----------------------------------------------------------------------------

@test "engine_call: routes to the postgres implementation" {
  pg_probe()    { echo "PG $*"; }
  mysql_probe() { echo "MYSQL $*"; }
  [ "$(engine_call postgresql probe a b)" = "PG a b" ]
}

@test "engine_call: routes to the mysql implementation" {
  pg_probe()    { echo "PG $*"; }
  mysql_probe() { echo "MYSQL $*"; }
  [ "$(engine_call mariadb probe a b)" = "MYSQL a b" ]
}

@test "engine_call: forwards arguments verbatim, including empty ones" {
  pg_probe() { printf '%s|' "$@"; }
  [ "$(engine_call postgres probe one "" "three four")" = "one||three four|" ]
}

@test "engine_call: propagates the implementation's exit status" {
  pg_probe() { return 3; }
  run engine_call postgres probe
  [ "$status" -eq 3 ]
}

@test "engine_call: dies on an unknown database type" {
  run engine_call sqlite probe
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown database type: sqlite"* ]]
}
