#!/usr/bin/env bats
load '../helpers/integration'

setup_file() {
  require_docker
  # Use a throwaway container name so we don't disturb postgres-dbx.
  # Must be `export`ed — bats does not auto-propagate setup_file locals into @test bodies.
  export TEST_CONTAINER="dbx_introspect_test_$$"
  docker run -d --name "$TEST_CONTAINER" \
    -e POSTGRES_PASSWORD=devpassword \
    postgres:15-alpine >/dev/null
  for _ in $(seq 1 30); do
    docker exec "$TEST_CONTAINER" pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 1
  done
}

teardown_file() {
  docker rm -f "$TEST_CONTAINER" >/dev/null 2>&1 || true
}

setup() {
  setup_dbx_env
  source_dbx_libs
}

@test "container_image returns the image tag for a running container" {
  result=$(container_image "$TEST_CONTAINER")
  [ "$result" = "postgres:15-alpine" ]
}

@test "container_image returns empty for a nonexistent container" {
  result=$(container_image "this_container_does_not_exist_xyz")
  [ -z "$result" ]
}

@test "pg_container_has_user_dbs: empty container returns 1" {
  # Fresh container with no user DBs created
  run pg_container_has_user_dbs "$TEST_CONTAINER" devpassword
  [ "$status" -ne 0 ]
}

@test "pg_container_has_user_dbs: user DB present returns 0" {
  docker exec -e PGPASSWORD=devpassword "$TEST_CONTAINER" \
    psql -U postgres -c "CREATE DATABASE check_me" >/dev/null
  run pg_container_has_user_dbs "$TEST_CONTAINER" devpassword
  [ "$status" -eq 0 ]
  docker exec -e PGPASSWORD=devpassword "$TEST_CONTAINER" \
    psql -U postgres -c "DROP DATABASE check_me" >/dev/null
}

@test "ensure_container_image: matching image is a no-op" {
  run ensure_container_image "$TEST_CONTAINER" "postgres:15-alpine" "false"
  [ "$status" -eq 0 ]
}

@test "ensure_container_image: empty container + mismatch + no flag → recreates" {
  # Container is empty; mismatched image; no --recreate flag → should still rebuild
  run ensure_container_image "$TEST_CONTAINER" "postgres:13-alpine" "false"
  [ "$status" -eq 0 ]
  result=$(container_image "$TEST_CONTAINER")
  [ "$result" = "postgres:13-alpine" ]
}

@test "ensure_container_image: user DBs + mismatch + no flag → fails with DB list" {
  # Recreate as PG 15 first
  docker rm -f "$TEST_CONTAINER" >/dev/null 2>&1
  docker run -d --name "$TEST_CONTAINER" \
    -e POSTGRES_PASSWORD=devpassword \
    postgres:15-alpine >/dev/null
  for _ in $(seq 1 30); do
    docker exec "$TEST_CONTAINER" pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 1
  done
  docker exec -e PGPASSWORD=devpassword "$TEST_CONTAINER" \
    psql -U postgres -c "CREATE DATABASE myapp_v1_test" >/dev/null

  run ensure_container_image "$TEST_CONTAINER" "postgres:13-alpine" "false"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "myapp_v1_test"
  echo "$output" | grep -q -- "--recreate-container"
}

@test "ensure_container_image: user DBs + mismatch + flag set → recreates" {
  # State from previous test: PG 15 with myapp_v1_test inside
  run ensure_container_image "$TEST_CONTAINER" "postgres:13-alpine" "true"
  [ "$status" -eq 0 ]
  result=$(container_image "$TEST_CONTAINER")
  [ "$result" = "postgres:13-alpine" ]
}
