#!/usr/bin/env bats
#
# Tests for the postgres probe helpers in lib/postgres.sh (#148):
# pg_detect_server_version, pg_detect_extensions and pg_fk_edges. Each is a
# psql invocation plus output shaping — `docker` is stubbed as a shell function
# so the argv assembly and the parsing are exercised without a database.
#
# The container-backed behaviour (a real PG 15 source, a real empty database)
# is covered in tests/integration/container_introspection.bats; what these
# assert is the flag set, the credential handling and the text munging.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
  DOCKER_ARGV="$BATS_TEST_TMPDIR/docker.argv"; : > "$DOCKER_ARGV"
  DOCKER_ENV="$BATS_TEST_TMPDIR/docker.env"; : > "$DOCKER_ENV"
}

docker() {
  printf '%s\n' "$*" >> "$DOCKER_ARGV"
  printf 'PGPASSWORD=%s\n' "${PGPASSWORD-<unset>}" >> "$DOCKER_ENV"
  [[ -n "${DOCKER_STDOUT:-}" ]] && printf '%s' "$DOCKER_STDOUT"
  return "${DOCKER_RC:-0}"
}

# ---------------------------------------------------------------------------
# pg_detect_server_version
# ---------------------------------------------------------------------------

@test "pg_detect_server_version: server_version_num is parsed to a major" {
  DOCKER_STDOUT=$'160003\n'
  run pg_detect_server_version db.internal 5432 app secret appdb
  [ "$status" -eq 0 ]
  [ "$output" = "16" ]
}

@test "pg_detect_server_version: surrounding whitespace is stripped before parsing" {
  DOCKER_STDOUT=$'  150004  \n\n'
  run pg_detect_server_version db.internal 5432 app secret appdb
  [ "$output" = "15" ]
}

@test "pg_detect_server_version: an unreachable server yields 'unknown'" {
  DOCKER_RC=1 DOCKER_STDOUT="" run pg_detect_server_version db.internal 5432 app secret appdb
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

@test "pg_detect_server_version: connects with the given host/port/user/database" {
  DOCKER_STDOUT=$'160003\n'
  pg_detect_server_version db.internal 6543 app secret appdb >/dev/null
  grep -q -- '-h db.internal -p 6543 -U app -d appdb' "$DOCKER_ARGV"
  grep -q -- '-tA' "$DOCKER_ARGV"
}

@test "pg_detect_server_version: the database defaults to postgres" {
  DOCKER_STDOUT=$'160003\n'
  pg_detect_server_version db.internal 5432 app secret >/dev/null
  grep -q -- '-d postgres' "$DOCKER_ARGV"
}

@test "pg_detect_server_version: the password goes via env, not docker argv (#127)" {
  DOCKER_STDOUT=$'160003\n'
  pg_detect_server_version db.internal 5432 app hunter2 appdb >/dev/null
  ! grep -q 'hunter2' "$DOCKER_ARGV"
  grep -q -- '-e PGPASSWORD' "$DOCKER_ARGV"
  grep -q '^PGPASSWORD=hunter2$' "$DOCKER_ENV"
}

# ---------------------------------------------------------------------------
# pg_detect_extensions
# ---------------------------------------------------------------------------

@test "pg_detect_extensions: rows become a space-separated list with no trailing space" {
  DOCKER_STDOUT=$'pg_trgm\nvector\n'
  run pg_detect_extensions db.internal 5432 app secret appdb
  [ "$status" -eq 0 ]
  [ "$output" = "pg_trgm vector" ]
  # `run` strips a trailing newline but not a trailing space — assert directly.
  out=$(pg_detect_extensions db.internal 5432 app secret appdb)
  [ "$out" = "pg_trgm vector" ]
}

@test "pg_detect_extensions: no rows yields the empty string" {
  DOCKER_STDOUT=""
  run pg_detect_extensions db.internal 5432 app secret appdb
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pg_detect_extensions: a failed probe is empty, not fatal" {
  DOCKER_RC=1 DOCKER_STDOUT="" run pg_detect_extensions db.internal 5432 app secret appdb
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pg_detect_extensions: the password goes via env, not docker argv (#127)" {
  DOCKER_STDOUT=$'vector\n'
  pg_detect_extensions db.internal 5432 app hunter2 appdb >/dev/null
  ! grep -q 'hunter2' "$DOCKER_ARGV"
  grep -q '^PGPASSWORD=hunter2$' "$DOCKER_ENV"
}

# ---------------------------------------------------------------------------
# pg_fk_edges — feeds fk_exclusion_closure / fk_dangling_pairs
# ---------------------------------------------------------------------------

@test "pg_fk_edges: emits the child<TAB>parent rows psql produced" {
  DOCKER_STDOUT=$'attachment\tmessage\nmessage\tuser\n'
  run pg_fk_edges db.internal 5432 app secret appdb
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$(printf 'attachment\tmessage')" ]
  [ "${lines[1]}" = "$(printf 'message\tuser')" ]
}

@test "pg_fk_edges: asks psql for unaligned tuples separated by tabs" {
  DOCKER_STDOUT=""
  pg_fk_edges db.internal 5432 app secret appdb >/dev/null
  grep -q -- '-tA' "$DOCKER_ARGV"
  grep -q -- "-F $(printf '\t')" "$DOCKER_ARGV"
  grep -q -- '-h db.internal -p 5432 -U app -d appdb' "$DOCKER_ARGV"
}

@test "pg_fk_edges: a failed query is empty and non-fatal" {
  DOCKER_RC=1 DOCKER_STDOUT="" run pg_fk_edges db.internal 5432 app secret appdb
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pg_fk_edges: the password goes via env, not docker argv (#127)" {
  DOCKER_STDOUT=""
  pg_fk_edges db.internal 5432 app hunter2 appdb >/dev/null
  ! grep -q 'hunter2' "$DOCKER_ARGV"
  grep -q -- '-e PGPASSWORD' "$DOCKER_ARGV"
  grep -q '^PGPASSWORD=hunter2$' "$DOCKER_ENV"
}

@test "pg_fk_edges output feeds fk_exclusion_closure end to end" {
  DOCKER_STDOUT=$'attachment\tmessage\nmessage\tuser\n'
  edges=$(pg_fk_edges db.internal 5432 app secret appdb)
  closure=$(printf '%s\n' "$edges" | fk_exclusion_closure "user")
  [ "$(printf '%s\n' "$closure" | tr '\n' ' ')" = "attachment message user " ]
}
