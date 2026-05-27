#!/usr/bin/env bats
# Build-on-demand custom Postgres image tests. These run a real `docker build`
# (slow; needs network for apt), so they're gated behind DBX_RUN_BUILD_TESTS.
# Enable with: DBX_RUN_BUILD_TESTS=1 bats tests/integration/image_build.bats
load '../helpers/integration'

setup() {
  require_docker
  [ -n "${DBX_RUN_BUILD_TESTS:-}" ] || skip "set DBX_RUN_BUILD_TESTS=1 to run image-build tests (slow; needs network)"
  setup_dbx_env
  source_dbx_libs
  VERIFY_CONTAINER="dbx_build_verify_$$_${BATS_TEST_NUMBER}"
  BUILT_TAG=""
}

teardown() {
  [ -n "${VERIFY_CONTAINER:-}" ] && docker rm -f "$VERIFY_CONTAINER" >/dev/null 2>&1 || true
  [ -n "${BUILT_TAG:-}" ] && docker rmi -f "$BUILT_TAG" >/dev/null 2>&1 || true
}

# Start a container from $BUILT_TAG and wait for it to accept connections.
_boot_verify() {
  docker run -d --name "$VERIFY_CONTAINER" \
    -e POSTGRES_PASSWORD=devpassword "$BUILT_TAG" >/dev/null
  local _
  for _ in $(seq 1 30); do
    docker exec "$VERIFY_CONTAINER" pg_isready -U postgres >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "$VERIFY_CONTAINER failed to become ready" >&2
  return 1
}

@test "build-image: builds an image that can CREATE EXTENSION pg_partman" {
  BUILT_TAG=$(pick_postgres_image 17 "pg_partman" "")
  dbx_run build-image pg17 --extensions pg_partman
  [ "$status" -eq 0 ]
  docker image inspect "$BUILT_TAG" >/dev/null 2>&1

  _boot_verify
  run docker exec -e PGPASSWORD=devpassword "$VERIFY_CONTAINER" \
    psql -U postgres -c "CREATE EXTENSION pg_partman CASCADE;"
  [ "$status" -eq 0 ]
}

@test "build-image: pg_cron image bakes shared_preload_libraries" {
  BUILT_TAG=$(pick_postgres_image 17 "pg_cron" "")
  dbx_run build-image pg17 --extensions pg_cron
  [ "$status" -eq 0 ]

  _boot_verify
  run docker exec -e PGPASSWORD=devpassword "$VERIFY_CONTAINER" \
    psql -U postgres -tAc "SHOW shared_preload_libraries;"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "pg_cron"
}

@test "build-image: second invocation hits the cache (already built)" {
  BUILT_TAG=$(pick_postgres_image 17 "pg_partman" "")
  dbx_run build-image pg17 --extensions pg_partman
  [ "$status" -eq 0 ]
  dbx_run build-image pg17 --extensions pg_partman
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "already built"
}
