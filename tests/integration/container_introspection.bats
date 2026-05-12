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
