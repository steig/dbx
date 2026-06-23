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
