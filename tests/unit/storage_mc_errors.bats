#!/usr/bin/env bats
#
# Tests for #211 (mc is an undeclared runtime dependency) and #212 (mc's
# errors are discarded, so "not installed", "bad credentials" and "bucket
# unreachable" all print `[INFO] storage test: upload` and exit 1).
#
# A fake `mc` on PATH stands in for the real client: it emulates a bucket with
# a directory, and each subcommand's exit code and stderr are driven by
# environment variables. For #211 the opposite is needed — a PATH with neither
# `mc` nor `aws` on it — so path_without_s3_client() links in the handful of
# externals the storage code path actually uses and nothing else.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs

  # Stands in for the S3 secret everywhere. If this string ever reaches the
  # terminal the fix has regressed (#127).
  SENTINEL="s3-sentinel-secret-$$"

  STUBDIR="$BATS_TEST_TMPDIR/stub"
  MC_STORE="$BATS_TEST_TMPDIR/bucket"
  mkdir -p "$STUBDIR" "$MC_STORE"
  cat >"$STUBDIR/mc" <<'STUB'
#!/usr/bin/env bash
# Fake mc. Credentials arrive in MC_HOST_<alias> (#217), so a failing
# subcommand is the first thing that can reject them; MC_ECHO_HOST=1
# reproduces the worst case left, a client quoting its own alias URL — which
# carries the secret — back in an error message.
sub="$1"; shift
echo_host() {
  [ "${MC_ECHO_HOST:-0}" = 1 ] || return 0
  printf 'mc: <ERROR> alias URL: %s\n' "${MC_HOST_dbx_storage:-<unset>}" >&2
}
case "$sub" in
  cp)
    [ -n "${MC_CP_STDERR:-}" ] && printf '%s\n' "$MC_CP_STDERR" >&2
    [ "${MC_CP_RC:-0}" != 0 ] && exit "$MC_CP_RC"
    src="$1"; dst="$2"
    if [ -f "$src" ]; then
      cp "$src" "$MC_STORE/$(basename "$dst")"
    else
      cp "$MC_STORE/$(basename "$src")" "$dst" 2>/dev/null || exit 1
    fi
    echo "...copied"
    exit 0
    ;;
  ls)
    [ -n "${MC_LS_STDERR:-}" ] && printf '%s\n' "$MC_LS_STDERR" >&2
    [ "${MC_LS_RC:-0}" != 0 ] && exit "$MC_LS_RC"
    ls -1 "$MC_STORE"
    exit 0
    ;;
  rm)
    [ -n "${MC_RM_STDERR:-}" ] && printf '%s\n' "$MC_RM_STDERR" >&2
    [ "${MC_RM_RC:-0}" != 0 ] && { echo_host; exit "$MC_RM_RC"; }
    rm -f "$MC_STORE/$(basename "$1")"
    exit 0
    ;;
esac
exit 0
STUB
  chmod +x "$STUBDIR/mc"
  export MC_STORE
}

# A working config whose secret comes from a command, so the run never touches
# the developer's real keychain.
config_ok() {
  write_config "$(printf '{"storage":{"type":"s3","s3":{"endpoint":"http://s3.example","bucket":"b","access_key":"AK","secret_key_cmd":"printf %%s %s"}}}' "$SENTINEL")"
}

with_mc() { PATH="$STUBDIR:$PATH"; }

# PATH holding everything the storage code path shells out to, minus any S3
# client — `command -v mc` then fails exactly as it does on a fresh install.
path_without_s3_client() {
  local d="$BATS_TEST_TMPDIR/nos3" b src
  mkdir -p "$d"
  for b in jq mktemp date grep cat rm cmp cp ls basename dirname mkdir find awk uname tr wc head sort; do
    src=$(command -v "$b" 2>/dev/null) || continue
    ln -sf "$src" "$d/$b"
  done
  printf '%s' "$d"
}

# `run` publishes $status/$output as globals, so wrapping it is safe.
run_without_s3_client() {
  local saved="$PATH"
  PATH="$(path_without_s3_client)"
  run "$@"
  PATH="$saved"
}

# ----------------------------------------------------------------------------
# #211 — mc is a real runtime dependency, so say so
# ----------------------------------------------------------------------------

@test "require_s3_client: names both clients and where to get them (#211)" {
  run_without_s3_client require_s3_client
  [ "$status" -eq 1 ]
  [[ "$output" == *"No S3 client found"* ]]
  [[ "$output" == *"min.io"* ]]
  [[ "$output" == *"aws"* ]]
}

@test "storage test: says the S3 client is missing instead of exiting silently (#211)" {
  config_ok
  run_without_s3_client storage_test_roundtrip
  [ "$status" -ne 0 ]
  [[ "$output" == *"No S3 client found"* ]]
}

# install.sh runs main() on load, so check_deps is lifted out and run on its
# own. Written to a file rather than inlined into `bash -c`, so the installer's
# own `$(uname)` and `${missing[*]}` are expanded by that script and not by
# this one.
check_deps_script() {
  local f="$BATS_TEST_TMPDIR/check_deps.sh"
  {
    echo 'RED=; GREEN=; BLUE=; NC='
    awk '/^check_deps\(\) \{/,/^\}/' "$DBX_REPO_ROOT/install.sh"
    echo 'check_deps'
  } >"$f"
  printf '%s' "$f"
}

@test "install.sh: points at an S3 client when neither mc nor aws is present (#211)" {
  run env PATH="$(path_without_s3_client)" "$BASH" "$(check_deps_script)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"needs an S3 client"* ]]
  [[ "$output" == *"min.io"* ]]
}

@test "install.sh: stays quiet about S3 when a client is installed (#211)" {
  run env PATH="$STUBDIR:$(path_without_s3_client)" "$BASH" "$(check_deps_script)"
  [ "$status" -eq 0 ]
  [[ "$output" != *"needs an S3 client"* ]]
}

# ----------------------------------------------------------------------------
# #212 — mc's own error text reaches the user
# ----------------------------------------------------------------------------

# `mc alias set` used to run first, so a bad key was rejected before anything
# was transferred. The credentials travel in MC_HOST_<alias> now (#217) and the
# first real operation is what rejects them — what the user is told must not
# change, and must not be confused with an endpoint that isn't answering.
@test "storage test: surfaces mc's rejection of the credentials (#212, #217)" {
  config_ok
  with_mc
  MC_CP_RC=1
  MC_CP_STDERR='mc: <ERROR> Failed to copy `/tmp/probe`. The request signature we calculated does not match the signature you provided.'
  export MC_CP_RC MC_CP_STDERR

  run storage_test_roundtrip
  [ "$status" -ne 0 ]
  [[ "$output" == *"signature we calculated does not match"* ]]
  [[ "$output" != *"connection refused"* ]]
}

@test "storage test: surfaces an endpoint that isn't answering (#212, #217)" {
  config_ok
  with_mc
  MC_CP_RC=1
  MC_CP_STDERR='mc: <ERROR> Failed to copy `/tmp/probe`. Get "http://s3.example/b/": dial tcp: connect: connection refused'
  export MC_CP_RC MC_CP_STDERR

  run storage_test_roundtrip
  [ "$status" -ne 0 ]
  [[ "$output" == *"connection refused"* ]]
  [[ "$output" != *"signature"* ]]
}

# An endpoint with no scheme is the one credential-independent thing mc_configure
# can still catch on its own: mc rejects `MC_HOST_x=AK:SK@host` with nothing more
# useful than "Invalid arguments provided".
@test "storage test: names a scheme-less endpoint instead of letting mc shrug (#217)" {
  write_config "$(printf '{"storage":{"type":"s3","s3":{"endpoint":"s3.example","bucket":"b","access_key":"AK","secret_key_cmd":"printf %%s %s"}}}' "$SENTINEL")"
  with_mc
  run storage_test_roundtrip
  [ "$status" -ne 0 ]
  [[ "$output" == *"must start with http:// or https://"* ]]
  [[ "$output" == *"s3.example"* ]]
}

@test "storage test: surfaces mc's upload error (#212)" {
  config_ok
  with_mc
  MC_CP_RC=1
  MC_CP_STDERR='mc: <ERROR> Unable to validate target. Bucket b does not exist.'
  export MC_CP_RC MC_CP_STDERR

  run storage_test_roundtrip
  [ "$status" -ne 0 ]
  [[ "$output" == *"Bucket b does not exist"* ]]
}

@test "storage test: surfaces mc's error when the listing comes back empty (#212)" {
  config_ok
  with_mc
  MC_LS_RC=1
  MC_LS_STDERR='mc: <ERROR> Unable to list folder. Access Denied.'
  export MC_LS_RC MC_LS_STDERR

  run storage_test_roundtrip
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unable to list folder"* ]]
}

@test "storage test: surfaces mc's error when cleanup fails (#212)" {
  config_ok
  with_mc
  MC_RM_RC=1
  MC_RM_STDERR='mc: <ERROR> Unable to remove target. Object is WORM protected.'
  export MC_RM_RC MC_RM_STDERR

  run storage_test_roundtrip
  [ "$status" -ne 0 ]
  [[ "$output" == *"WORM protected"* ]]
}

@test "storage test: a fully working backend still round-trips quietly (#212)" {
  config_ok
  with_mc
  run storage_test_roundtrip
  [ "$status" -eq 0 ]
  [[ "$output" == *"round-trip OK"* ]]
  [[ "$output" != *"ERROR"* ]]
}

# ----------------------------------------------------------------------------
# #212 — the three failures are told apart, not collapsed into exit 1
# ----------------------------------------------------------------------------

@test "storage test: an empty secret_key_cmd is blamed on the command, not the config (#212)" {
  write_config '{"storage":{"type":"s3","s3":{"endpoint":"http://s3.example","bucket":"b","access_key":"AK","secret_key_cmd":"cat /nonexistent/dbx-secret"}}}'
  with_mc
  run storage_test_roundtrip
  [ "$status" -ne 0 ]
  [[ "$output" == *"secret_key_cmd produced no secret"* ]]
  [[ "$output" == *"/nonexistent/dbx-secret"* ]]
  [[ "$output" == *"missing: secret_key"* ]]
}

@test "storage test: names which config field is missing (#212)" {
  write_config "$(printf '{"storage":{"type":"s3","s3":{"bucket":"b","secret_key_cmd":"printf %%s %s"}}}' "$SENTINEL")"
  with_mc
  run storage_test_roundtrip
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing: endpoint access_key"* ]]
}

# ----------------------------------------------------------------------------
# The secret never reaches the terminal (#127)
# ----------------------------------------------------------------------------

@test "storage test: mc quoting its own alias URL does not leak the secret (#127, #217)" {
  config_ok
  with_mc
  MC_ECHO_HOST=1
  MC_RM_RC=1
  export MC_ECHO_HOST MC_RM_RC

  run storage_test_roundtrip
  [ "$status" -ne 0 ]
  # The error is surfaced...
  [[ "$output" == *"alias URL: http://"* ]]
  # ...with the secret blanked out, and the access key left readable.
  [[ "$output" != *"$SENTINEL"* ]]
  [[ "$output" == *"AK:***@s3.example"* ]]
}

@test "storage test: a successful round-trip never prints the secret (#127)" {
  config_ok
  with_mc
  run storage_test_roundtrip
  [ "$status" -eq 0 ]
  [[ "$output" != *"$SENTINEL"* ]]
}
