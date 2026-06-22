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
