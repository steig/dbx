#!/usr/bin/env bats
load '../helpers/common'
setup() { setup_dbx_env; source_dbx_libs; }

@test "pick_postgres_image: bare PG returns postgres:N-alpine" {
  result=$(pick_postgres_image 15 "" "")
  [ "$result" = "postgres:15-alpine" ]
}

@test "pick_postgres_image: PG 17 with no extensions" {
  result=$(pick_postgres_image 17 "" "")
  [ "$result" = "postgres:17-alpine" ]
}

@test "pick_postgres_image: PG 13 with no extensions" {
  result=$(pick_postgres_image 13 "" "")
  [ "$result" = "postgres:13-alpine" ]
}

@test "pick_postgres_image: vector extension → pgvector image" {
  result=$(pick_postgres_image 17 "vector" "")
  [ "$result" = "pgvector/pgvector:pg17" ]
}

@test "pick_postgres_image: postgis extension → postgis image" {
  result=$(pick_postgres_image 16 "postgis" "")
  [ "$result" = "postgis/postgis:16-3.5" ]
}

@test "pick_postgres_image: timescaledb → timescale image" {
  result=$(pick_postgres_image 14 "timescaledb" "")
  [ "$result" = "timescale/timescaledb:latest-pg14" ]
}

@test "pick_postgres_image: bundled contrib (btree_gin) → stock image" {
  result=$(pick_postgres_image 15 "btree_gin" "")
  [ "$result" = "postgres:15-alpine" ]
}

@test "pick_postgres_image: multiple contrib extensions → stock image" {
  result=$(pick_postgres_image 16 "btree_gin pg_trgm hstore uuid-ossp" "")
  [ "$result" = "postgres:16-alpine" ]
}

@test "pick_postgres_image: contrib alongside specialized → specialized wins" {
  result=$(pick_postgres_image 17 "vector btree_gin pg_trgm" "")
  [ "$result" = "pgvector/pgvector:pg17" ]
}

@test "pick_postgres_image: buildable third-party (pg_partman) → dbx custom tag" {
  result=$(pick_postgres_image 17 "pg_partman" "")
  echo "$result" | grep -qE '^dbx-pg17:[0-9a-f]{12}$'
}

@test "pick_postgres_image: multiple buildable extensions → single custom tag" {
  result=$(pick_postgres_image 16 "pg_partman pg_cron" "")
  echo "$result" | grep -qE '^dbx-pg16:[0-9a-f]{12}$'
}

@test "pick_postgres_image: contrib alongside buildable → custom tag (contrib rides along)" {
  result=$(pick_postgres_image 17 "btree_gin pg_partman" "")
  echo "$result" | grep -qE '^dbx-pg17:[0-9a-f]{12}$'
}

@test "pick_postgres_image: escape-hatch extension via 4th arg → custom tag" {
  result=$(pick_postgres_image 17 "pg_madeup" "" "pg_madeup:madeup:")
  echo "$result" | grep -qE '^dbx-pg17:[0-9a-f]{12}$'
}

@test "pick_postgres_image: specialized + buildable fails (no combined image)" {
  run pick_postgres_image 17 "vector pg_partman" ""
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "combine"
  echo "$output" | grep -q "pg_partman"
}

@test "pick_postgres_image: truly unknown extension fails with hint" {
  run pick_postgres_image 15 "pg_nonesuch" ""
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "DBX_POSTGRES_IMAGE"
  echo "$output" | grep -q "pg_nonesuch"
}

@test "pick_postgres_image: two conflicting allowlisted extensions fails" {
  run pick_postgres_image 17 "vector postgis" ""
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "DBX_POSTGRES_IMAGE"
}

@test "pick_postgres_image: override template with {major}" {
  result=$(pick_postgres_image 15 "vector" "myrepo/pg:{major}")
  [ "$result" = "myrepo/pg:15" ]
}

@test "pick_mysql_image: mysql 8.0" {
  result=$(pick_mysql_image mysql 8 0 "")
  [ "$result" = "mysql:8.0" ]
}

@test "pick_mysql_image: mysql 8.4" {
  result=$(pick_mysql_image mysql 8 4 "")
  [ "$result" = "mysql:8.4" ]
}

@test "pick_mysql_image: mariadb 10.11" {
  result=$(pick_mysql_image mariadb 10 11 "")
  [ "$result" = "mariadb:10.11" ]
}

@test "pick_mysql_image: mariadb 11.4" {
  result=$(pick_mysql_image mariadb 11 4 "")
  [ "$result" = "mariadb:11.4" ]
}

@test "pick_mysql_image: unknown flavor falls back to mysql 8.0" {
  result=$(pick_mysql_image unknown "" "" "")
  [ "$result" = "mysql:8.0" ]
}

@test "pick_mysql_image: override template with {version}" {
  result=$(pick_mysql_image mariadb 10 11 "myrepo/mariadb:{version}")
  [ "$result" = "myrepo/mariadb:10.11" ]
}

@test "pick_mysql_image: override with empty version inputs normalizes to 8.0" {
  result=$(pick_mysql_image unknown "" "" "myrepo/mysql:{version}")
  [ "$result" = "myrepo/mysql:8.0" ]
}
