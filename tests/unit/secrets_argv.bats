#!/usr/bin/env bats
#
# Regression tests for #127: secrets must not appear in process argv (visible
# via `ps` / /proc/PID/cmdline on a multi-user host). A fake `gpg` on PATH
# records the argv it was invoked with and the passphrase it received on the
# --passphrase-fd; the tests assert the passphrase reached gpg via the fd but
# never via argv.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs

  ARGV_LOG="$BATS_TEST_TMPDIR/gpg-argv.log"
  FD_LOG="$BATS_TEST_TMPDIR/gpg-fd.log"
  export ARGV_LOG FD_LOG
  : >"$ARGV_LOG"
  : >"$FD_LOG"

  # Fake gpg: log argv, read the passphrase from --passphrase-fd N, drain the
  # data stream on stdin, and emit output (to -o FILE if given, else stdout).
  local stubdir="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$stubdir"
  cat >"$stubdir/gpg" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_LOG"
out=""; fd=""; prev=""
for a in "$@"; do
  case "$prev" in
    -o) out="$a" ;;
    --passphrase-fd) fd="$a" ;;
  esac
  prev="$a"
done
if [ -n "$fd" ]; then
  IFS= read -r -u "$fd" pass 2>/dev/null || true
  printf '%s\n' "$pass" >> "$FD_LOG"
fi
cat >/dev/null   # drain the data stream so the upstream pipe doesn't SIGPIPE
if [ -n "$out" ]; then printf 'FAKEGPG\n' > "$out"; else printf 'FAKEGPG\n'; fi
STUB
  chmod +x "$stubdir/gpg"

  # Fake docker: log argv, and separately log any PGPASSWORD/MYSQL_PWD seen in
  # the environment (proving the secret is delivered via env, not argv). Emit a
  # numeric count so *_container_has_user_dbs is happy.
  DOCKER_ARGV_LOG="$BATS_TEST_TMPDIR/docker-argv.log"
  DOCKER_ENV_LOG="$BATS_TEST_TMPDIR/docker-env.log"
  export DOCKER_ARGV_LOG DOCKER_ENV_LOG
  : >"$DOCKER_ARGV_LOG"
  : >"$DOCKER_ENV_LOG"
  cat >"$stubdir/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_ARGV_LOG"
[ -n "${PGPASSWORD:-}" ] && printf 'PGPASSWORD=%s\n' "$PGPASSWORD" >> "$DOCKER_ENV_LOG"
[ -n "${MYSQL_PWD:-}" ] && printf 'MYSQL_PWD=%s\n' "$MYSQL_PWD" >> "$DOCKER_ENV_LOG"
echo 1
STUB
  chmod +x "$stubdir/docker"

  PATH="$stubdir:$PATH"

  SENTINEL="S3CRET-PASS-$$"
  # Bypass keychain/config: feed encrypt/decrypt a known passphrase directly.
  get_encryption_key() { echo "$SENTINEL"; }
}

# Assert the sentinel reached gpg via the fd but not via argv.
assert_no_argv_leak() {
  grep -q -- '--passphrase-fd' "$ARGV_LOG" || {
    echo "expected --passphrase-fd in gpg argv; got:"; cat "$ARGV_LOG"; return 1
  }
  if grep -q "$SENTINEL" "$ARGV_LOG"; then
    echo "LEAK: passphrase found in gpg argv:"; cat "$ARGV_LOG"; return 1
  fi
  grep -q "$SENTINEL" "$FD_LOG" || {
    echo "passphrase did not reach gpg via fd; fd log:"; cat "$FD_LOG"; return 1
  }
}

@test "encrypt_stream: passphrase via fd, not argv (#127)" {
  echo "plaintext" | encrypt_stream >/dev/null
  assert_no_argv_leak
}

@test "decrypt_stream: passphrase via fd, not argv (#127)" {
  echo "ciphertext" | decrypt_stream >/dev/null
  assert_no_argv_leak
}

@test "gpg_file_write (symmetric): passphrase via fd, not argv (#127)" {
  VAULT_GPG_FILE="$BATS_TEST_TMPDIR/vault.gpg"
  get_vault_gpg_key() { echo ""; }   # force the symmetric (passphrase) branch
  gpg_file_write '{"k":"v"}'
  assert_no_argv_leak
  [ -f "$VAULT_GPG_FILE" ]
}

# Assert a DB password reached docker via the environment but not via argv.
# $1 = env var name (PGPASSWORD|MYSQL_PWD)
assert_no_docker_argv_leak() {
  local var="$1"
  grep -q -- "-e $var" "$DOCKER_ARGV_LOG" || {
    echo "expected name-only '-e $var' in docker argv; got:"; cat "$DOCKER_ARGV_LOG"; return 1
  }
  if grep -q "$SENTINEL" "$DOCKER_ARGV_LOG"; then
    echo "LEAK: password found in docker argv:"; cat "$DOCKER_ARGV_LOG"; return 1
  fi
  grep -q "$var=$SENTINEL" "$DOCKER_ENV_LOG" || {
    echo "password did not reach docker via env; env log:"; cat "$DOCKER_ENV_LOG"; return 1
  }
}

@test "pg_container_has_user_dbs: password via env, not docker argv (#127)" {
  pg_container_has_user_dbs some-pg-container "$SENTINEL"
  assert_no_docker_argv_leak PGPASSWORD
}

@test "mysql_container_has_user_dbs: password via env, not docker argv (#127)" {
  mysql_container_has_user_dbs some-my-container "$SENTINEL"
  assert_no_docker_argv_leak MYSQL_PWD
}

@test "_list_user_dbs (postgres): password via env, not docker argv (#127)" {
  DBX_PG_PASSWORD="$SENTINEL" _list_user_dbs some-postgres-container >/dev/null
  assert_no_docker_argv_leak PGPASSWORD
}

@test "_list_user_dbs (mysql): password via env, not docker argv (#127)" {
  DBX_MYSQL_PASSWORD="$SENTINEL" _list_user_dbs some-mysql-container >/dev/null
  assert_no_docker_argv_leak MYSQL_PWD
}

# ----------------------------------------------------------------------------
# Call sites in the `dbx` script itself (cmd_query, cmd_test, analyze --json).
# These live outside lib/, so they need the script sourced with
# DBX_NO_AUTO_MAIN=1 and the docker / tunnel / credential layers stubbed.
# ----------------------------------------------------------------------------

dbx_script_subshell() {
  SNIPPET="$1" SENTINEL="$SENTINEL" bash -c '
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
    eval "$SNIPPET"
  '
}

@test "dbx query (postgres, database named): password via env, not docker argv (#127)" {
  write_config '{"hosts":{"prod":{"type":"postgres","host":"127.0.0.1","port":5432,"user":"u","safety":"prod"}}}'
  run dbx_script_subshell 'cmd_query prod app'
  [ "$status" -eq 0 ]
  assert_no_docker_argv_leak PGPASSWORD
  # PGOPTIONS is not a secret and still travels as a name=value pair.
  grep -q -- '-e PGOPTIONS=' "$DOCKER_ARGV_LOG"
}

@test "dbx query (postgres, no database): password via env, not docker argv (#127)" {
  write_config '{"hosts":{"prod":{"type":"postgres","host":"127.0.0.1","port":5432,"user":"u"}}}'
  run dbx_script_subshell 'cmd_query prod'
  [ "$status" -eq 0 ]
  assert_no_docker_argv_leak PGPASSWORD
}

@test "dbx query (mysql prod, database named): password via env, not docker argv (#127)" {
  write_config '{"hosts":{"prod":{"type":"mysql","host":"127.0.0.1","port":3306,"user":"u","safety":"prod"}}}'
  run dbx_script_subshell 'cmd_query prod app'
  [ "$status" -eq 0 ]
  assert_no_docker_argv_leak MYSQL_PWD
  grep -q -- '--init-command=SET SESSION TRANSACTION READ ONLY' "$DOCKER_ARGV_LOG"
}

@test "dbx query (mysql prod, no database): password via env, not docker argv (#127)" {
  write_config '{"hosts":{"prod":{"type":"mysql","host":"127.0.0.1","port":3306,"user":"u","safety":"prod"}}}'
  run dbx_script_subshell 'cmd_query prod'
  [ "$status" -eq 0 ]
  assert_no_docker_argv_leak MYSQL_PWD
}

@test "dbx query (mysql, database named): password via env, not docker argv (#127)" {
  write_config '{"hosts":{"dev":{"type":"mysql","host":"127.0.0.1","port":3306,"user":"u"}}}'
  run dbx_script_subshell 'cmd_query dev app'
  [ "$status" -eq 0 ]
  assert_no_docker_argv_leak MYSQL_PWD
}

@test "dbx query (mysql, no database): password via env, not docker argv (#127)" {
  write_config '{"hosts":{"dev":{"type":"mysql","host":"127.0.0.1","port":3306,"user":"u"}}}'
  run dbx_script_subshell 'cmd_query dev'
  [ "$status" -eq 0 ]
  assert_no_docker_argv_leak MYSQL_PWD
}

@test "dbx test (postgres connectivity check): password via env, not docker argv (#127)" {
  write_config '{"hosts":{"prod":{"type":"postgres","host":"127.0.0.1","port":5432,"user":"u"}}}'
  run dbx_script_subshell 'cmd_test prod'
  [ "$status" -eq 0 ]
  assert_no_docker_argv_leak PGPASSWORD
}

@test "dbx test (mysql connectivity check): password via env, not docker argv (#127)" {
  write_config '{"hosts":{"dev":{"type":"mysql","host":"127.0.0.1","port":3306,"user":"u"}}}'
  run dbx_script_subshell 'cmd_test dev'
  [ "$status" -eq 0 ]
  assert_no_docker_argv_leak MYSQL_PWD
}

@test "analyze --json (postgres stats query): password via env, not docker argv (#127)" {
  write_config '{"hosts":{"prod":{"type":"postgres","host":"127.0.0.1","port":5432,"user":"u"}}}'
  # The fake docker returns a stub row that the downstream jq stitching may
  # reject; the exit status is not what this test is about.
  run dbx_script_subshell '_analyze_emit_json prod app postgres true'
  assert_no_docker_argv_leak PGPASSWORD
}
