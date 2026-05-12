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
