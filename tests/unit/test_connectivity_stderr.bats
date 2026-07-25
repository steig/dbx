#!/usr/bin/env bats
#
# Tests for #201: `dbx test` Test 4 must surface the client's stderr. Before
# this, psql/mysqladmin ran under `>/dev/null 2>&1`, so "database does not
# exist", "password authentication failed" and a dead network all collapsed
# into one "connection failed" line.
#
# A fake `docker` on PATH stands in for the client: it prints whatever
# DOCKER_STDERR holds on stderr, some noise on stdout, and exits DOCKER_RC.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs

  SENTINEL="S3CRET-PASS-$$"

  STUBDIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUBDIR"
  cat >"$STUBDIR/docker" <<'STUB'
#!/usr/bin/env bash
[ "${DOCKER_ECHO_ARGV:-0}" = 1 ] && printf 'argv: %s\n' "$*" >&2
printf '%s' "${DOCKER_STDERR:-}" >&2
echo "stdout that must not be surfaced"
exit "${DOCKER_RC:-0}"
STUB
  chmod +x "$STUBDIR/docker"

  DOCKER_RC=0
  DOCKER_STDERR=""
  DOCKER_ECHO_ARGV=0
}

# Run cmd_test with the docker/tunnel/credential layers stubbed out, the same
# way tests/unit/secrets_argv.bats does.
run_cmd_test() {
  DOCKER_RC="$DOCKER_RC" DOCKER_STDERR="$DOCKER_STDERR" \
  DOCKER_ECHO_ARGV="$DOCKER_ECHO_ARGV" SENTINEL="$SENTINEL" HOST="$1" \
  PATH="$STUBDIR:$PATH" bash -c '
    set -uo pipefail
    export DBX_NO_AUTO_MAIN=1
    # shellcheck source=/dev/null
    source "'"$DBX_BIN"'"
    # Stubs go after the source so they win over the real definitions.
    require_docker()        { :; }
    require_container()     { :; }
    has_ssh_tunnel()        { return 1; }
    create_ssh_tunnel()     { :; }
    list_remote_databases() { :; }
    get_password()          { printf "%s" "$SENTINEL"; }
    cmd_test "$HOST"
  '
}

config_postgres() {
  write_config '{"hosts":{"prod":{"type":"postgres","host":"127.0.0.1","port":5432,"user":"u"}}}'
}

config_mysql() {
  write_config '{"hosts":{"dev":{"type":"mysql","host":"127.0.0.1","port":3306,"user":"u"}}}'
}

# ----------------------------------------------------------------------------
# The error text reaches the user
# ----------------------------------------------------------------------------

@test "dbx test (postgres): surfaces the psql error under the failure (#201)" {
  config_postgres
  DOCKER_RC=2
  DOCKER_STDERR='psql: error: connection to server at "127.0.0.1", port 5432 failed: FATAL:  database "app" does not exist
'
  run run_cmd_test prod
  [ "$status" -eq 1 ]
  [[ "$output" == *"PostgreSQL connection failed"* ]]
  [[ "$output" == *'FATAL:  database "app" does not exist'* ]]
}

@test "dbx test (postgres): keeps every line of a multi-line psql error (#201)" {
  config_postgres
  DOCKER_RC=2
  DOCKER_STDERR='psql: error: connection to server at "127.0.0.1", port 5432 failed: Connection refused
	Is the server running on that host and accepting TCP/IP connections?
'
  run run_cmd_test prod
  [ "$status" -eq 1 ]
  [[ "$output" == *"Connection refused"* ]]
  [[ "$output" == *"Is the server running on that host"* ]]
}

@test "dbx test (mysql): surfaces the mysqladmin error under the failure (#201)" {
  config_mysql
  DOCKER_RC=1
  DOCKER_STDERR="mysqladmin: connect to server at '127.0.0.1' failed
error: 'Access denied for user 'u'@'localhost' (using password: YES)'
"
  run run_cmd_test dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"MySQL connection failed"* ]]
  [[ "$output" == *"Access denied for user"* ]]
}

@test "dbx test: an empty client stderr adds no blank log line (#201)" {
  config_postgres
  DOCKER_RC=2
  DOCKER_STDERR=$'\n  \n'
  run run_cmd_test prod
  [ "$status" -eq 1 ]
  [[ "$output" == *"PostgreSQL connection failed"* ]]
  # The last line is the error itself, not an empty [INFO].
  [[ "${lines[${#lines[@]}-1]}" == *"PostgreSQL connection failed"* ]]
}

# ----------------------------------------------------------------------------
# Success is unchanged
# ----------------------------------------------------------------------------

@test "dbx test (postgres): success still reports success and swallows stdout (#201)" {
  config_postgres
  DOCKER_RC=0
  DOCKER_STDERR="NOTICE: some chatter"
  run run_cmd_test prod
  [ "$status" -eq 0 ]
  [[ "$output" == *"PostgreSQL connection successful"* ]]
  [[ "$output" != *"connection failed"* ]]
  [[ "$output" != *"stdout that must not be surfaced"* ]]
  [[ "$output" != *"NOTICE: some chatter"* ]]
}

@test "dbx test (mysql): success still reports success (#201)" {
  config_mysql
  DOCKER_RC=0
  run run_cmd_test dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"MySQL connection successful"* ]]
  [[ "$output" != *"stdout that must not be surfaced"* ]]
}

# ----------------------------------------------------------------------------
# The password must not ride along in the surfaced output (#127, #201)
# ----------------------------------------------------------------------------

@test "dbx test (postgres): failure output never contains the password (#201)" {
  config_postgres
  DOCKER_RC=2
  DOCKER_STDERR='psql: error: connection to server at "127.0.0.1", port 5432 failed: FATAL:  password authentication failed for user "u"
'
  run run_cmd_test prod
  [ "$status" -eq 1 ]
  [[ "$output" == *"password authentication failed"* ]]
  [[ "$output" != *"$SENTINEL"* ]]
}

@test "dbx test (mysql): failure output never contains the password (#201)" {
  config_mysql
  DOCKER_RC=1
  DOCKER_STDERR="mysqladmin: connect to server at '127.0.0.1' failed
error: 'Access denied for user 'u'@'localhost' (using password: YES)'
"
  run run_cmd_test dev
  [ "$status" -eq 1 ]
  [[ "$output" != *"$SENTINEL"* ]]
}

# A client that echoed its own argv back would leak the password if the
# password were ever moved onto the command line. Asserts both halves of
# #127: name-only `-e PGPASSWORD`, and no value anywhere in argv.
@test "dbx test (postgres): surfaced argv carries -e PGPASSWORD by name only (#127, #201)" {
  config_postgres
  DOCKER_RC=2
  DOCKER_ECHO_ARGV=1
  run run_cmd_test prod
  [ "$status" -eq 1 ]
  [[ "$output" == *"-e PGPASSWORD"* ]]
  [[ "$output" != *"$SENTINEL"* ]]
}

@test "dbx test (mysql): surfaced argv carries -e MYSQL_PWD by name only (#127, #201)" {
  config_mysql
  DOCKER_RC=1
  DOCKER_ECHO_ARGV=1
  run run_cmd_test dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"-e MYSQL_PWD"* ]]
  [[ "$output" != *"$SENTINEL"* ]]
}
