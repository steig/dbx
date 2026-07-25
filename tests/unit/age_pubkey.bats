#!/usr/bin/env bats
#
# Regression tests for #150: init_age_encryption used to derive the recipients
# file from `grep -v '^#' identity | head -1 | age-keygen -y`, i.e. from
# whatever sat on the first non-comment line of the identity file. On a
# multi-key file that silently publishes only the first key's recipient, so
# backups become undecryptable by the other identities; on a file with a
# leading blank line it feeds age-keygen an empty line and yields nothing.
# age-keygen must be handed the identity file itself.

load '../helpers/common'

setup() {
  export DBX_AGE_IDENTITY="$BATS_TEST_TMPDIR/keys.txt"
  export DBX_AGE_RECIPIENTS="$BATS_TEST_TMPDIR/age-recipients.txt"
  setup_dbx_env

  # Fake age-keygen: log argv, then map every AGE-SECRET-KEY-1<x> line to the
  # recipient age1<x>, reading either the file named after -y or stdin.
  KEYGEN_ARGV_LOG="$BATS_TEST_TMPDIR/age-keygen-argv.log"
  export KEYGEN_ARGV_LOG
  : >"$KEYGEN_ARGV_LOG"
  local stubdir="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$stubdir"
  cat >"$stubdir/age-keygen" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KEYGEN_ARGV_LOG"
if [ "$1" = "-y" ] && [ -n "${2:-}" ]; then
  exec awk '/^AGE-SECRET-KEY-1/ { sub(/^AGE-SECRET-KEY-1/, "age1"); print }' "$2"
fi
exec awk '/^AGE-SECRET-KEY-1/ { sub(/^AGE-SECRET-KEY-1/, "age1"); print }'
STUB
  chmod +x "$stubdir/age-keygen"
  PATH="$stubdir:$PATH"

  source_dbx_libs
}

@test "recipients file gets every key from a multi-key identity file" {
  cat >"$DBX_AGE_IDENTITY" <<'EOF'
# created: 2026-01-01T00:00:00Z
# public key: age1alpha
AGE-SECRET-KEY-1alpha
# created: 2026-02-02T00:00:00Z
# public key: age1beta
AGE-SECRET-KEY-1beta
EOF
  run init_age_encryption
  [ "$status" -eq 0 ]
  run grep -c . "$DBX_AGE_RECIPIENTS"
  [ "$output" = "2" ]
  grep -qx "age1alpha" "$DBX_AGE_RECIPIENTS"
  grep -qx "age1beta" "$DBX_AGE_RECIPIENTS"
}

@test "identity file with a leading blank line still yields its key" {
  printf '\n# public key: age1gamma\nAGE-SECRET-KEY-1gamma\n' >"$DBX_AGE_IDENTITY"
  run init_age_encryption
  [ "$status" -eq 0 ]
  grep -qx "age1gamma" "$DBX_AGE_RECIPIENTS"
  # No new key pair was generated over the existing identity.
  run grep -q -- "-o" "$KEYGEN_ARGV_LOG"
  [ "$status" -ne 0 ]
}

@test "age-keygen reads the identity file directly, not a piped line" {
  printf '# public key: age1delta\nAGE-SECRET-KEY-1delta\n' >"$DBX_AGE_IDENTITY"
  init_age_encryption
  run grep -qx -- "-y $DBX_AGE_IDENTITY" "$KEYGEN_ARGV_LOG"
  [ "$status" -eq 0 ]
}

@test "recipients file is created 600" {
  printf '# public key: age1eps\nAGE-SECRET-KEY-1eps\n' >"$DBX_AGE_IDENTITY"
  init_age_encryption
  local mode
  mode=$(stat -c '%a' "$DBX_AGE_RECIPIENTS" 2>/dev/null || stat -f '%Lp' "$DBX_AGE_RECIPIENTS" 2>/dev/null)
  [ "$mode" = "600" ]
}
