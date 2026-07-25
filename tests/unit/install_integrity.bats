#!/usr/bin/env bats
#
# Tests for install.sh's SHASUMS256 verification (#140).
#
# install.sh is `curl | bash` — it can't source anything from the repo — so it
# is exercised as a whole, with a stub `curl` on PATH serving a fixture "origin"
# tree out of BATS_TEST_TMPDIR. Nothing here reaches the network or writes
# outside the test's tmpdir.

load '../helpers/common'

setup() {
  ORIGIN="$BATS_TEST_TMPDIR/origin"
  PREFIX="$BATS_TEST_TMPDIR/prefix"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$ORIGIN/lib" "$ORIGIN/man/man1" "$STUB_BIN" "$BATS_TEST_TMPDIR/home"

  # The origin serves the real payload, so the committed SHASUMS256.txt is the
  # manifest under test — if it ever drifts from the files, these go red.
  cp "$DBX_REPO_ROOT/dbx" "$DBX_REPO_ROOT/SHASUMS256.txt" "$ORIGIN/"
  cp "$DBX_REPO_ROOT"/lib/*.sh "$DBX_REPO_ROOT"/lib/*.html \
     "$DBX_REPO_ROOT/lib/wizard-server.py" "$ORIGIN/lib/"
  cp "$DBX_REPO_ROOT"/man/man1/*.1 "$ORIGIN/man/man1/"

  write_curl_stub
}

# Serve $DBX_TEST_ORIGIN instead of raw.githubusercontent.com. Understands the
# only curl shape install.sh uses: `curl -fsSL <url> -o <dest>`. Exits 22 like
# curl -f does on a 404, without leaving the destination behind.
write_curl_stub() {
  cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
url=""; dest=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) dest="$2"; shift 2 ;;
    -*) shift ;;
    *)  url="$1"; shift ;;
  esac
done
# https://raw.githubusercontent.com/<owner>/dbx/<ref>/<path>  ->  <path>
path="${url#*/dbx/}"
path="${path#*/}"
[ -f "$DBX_TEST_ORIGIN/$path" ] || exit 22
cat "$DBX_TEST_ORIGIN/$path" > "$dest"
STUB
  chmod +x "$STUB_BIN/curl"
}

install_dbx() {
  run env PATH="$STUB_BIN:$PATH" \
      HOME="$BATS_TEST_TMPDIR/home" \
      DBX_TEST_ORIGIN="$ORIGIN" \
      DBX_INSTALL_DIR="$PREFIX/bin" \
      DBX_LIB_DIR="$PREFIX/lib" \
      DBX_MAN_DIR="$PREFIX/man" \
      "$@" \
      bash "$DBX_REPO_ROOT/install.sh"
}

# Replace a payload file's contents, leaving the manifest alone — a tampered or
# truncated download.
corrupt() {
  printf 'corrupted\n' >> "$ORIGIN/$1"
}

# ----------------------------------------------------------------------------
# The happy path still installs
# ----------------------------------------------------------------------------

@test "install: verifies against the manifest and installs everything" {
  install_dbx
  [ "$status" -eq 0 ]
  [[ "$output" == *"Verifying downloads against SHASUMS256.txt"* ]]
  [[ "$output" != *"Integrity check skipped"* ]]

  [ -x "$PREFIX/bin/dbx" ]
  [ -f "$PREFIX/lib/core.sh" ]
  [ -f "$PREFIX/lib/wizard.html" ]
  [ -f "$PREFIX/lib/wizard-server.py" ]
  [ -f "$PREFIX/man/dbx.1" ]
}

@test "install: rewrites LIB_DIR in the installed launcher" {
  install_dbx
  [ "$status" -eq 0 ]
  grep -q "LIB_DIR=\"$PREFIX/lib\"" "$PREFIX/bin/dbx"
}

# ----------------------------------------------------------------------------
# A file that doesn't match its digest
# ----------------------------------------------------------------------------

@test "install: rejects a corrupted library" {
  corrupt lib/core.sh
  install_dbx
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checksum mismatch for lib/core.sh"* ]]
}

@test "install: rejects a corrupted launcher" {
  corrupt dbx
  install_dbx
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checksum mismatch for dbx"* ]]
}

@test "install: rejects a corrupted man page" {
  corrupt man/man1/dbx-backup.1
  install_dbx
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checksum mismatch for man/man1/dbx-backup.1"* ]]
}

@test "install: a mismatch installs nothing at all" {
  # Corrupt the LAST thing fetched, so everything before it verified fine.
  corrupt man/man1/dbx.1
  install_dbx
  [ "$status" -ne 0 ]
  [ ! -e "$PREFIX/bin/dbx" ]
  [ -z "$(ls -A "$PREFIX/lib")" ]
  [ -z "$(ls -A "$PREFIX/man")" ]
}

@test "install: a mismatch leaves an existing install untouched" {
  mkdir -p "$PREFIX/bin" "$PREFIX/lib"
  printf 'previous launcher\n' > "$PREFIX/bin/dbx"
  printf 'previous lib\n' > "$PREFIX/lib/core.sh"

  corrupt lib/core.sh
  install_dbx
  [ "$status" -ne 0 ]
  [ "$(cat "$PREFIX/bin/dbx")" = "previous launcher" ]
  [ "$(cat "$PREFIX/lib/core.sh")" = "previous lib" ]
}

@test "install: leaves no staging directory behind on failure" {
  # Point install.sh at a private TMPDIR and assert it is empty afterwards.
  # Counting dbx-install.* in the shared /tmp before and after cannot work:
  # sibling tests in this file create staging dirs concurrently under
  # `bats -j`, so the two counts differ for reasons unrelated to cleanup.
  local stage_root="$BATS_TEST_TMPDIR/stage-root"
  mkdir -p "$stage_root"

  corrupt dbx
  install_dbx TMPDIR="$stage_root"
  [ "$status" -ne 0 ]

  run find "$stage_root" -maxdepth 1 -name 'dbx-install.*'
  [ -z "$output" ]
}

# ----------------------------------------------------------------------------
# Refs published before SHASUMS256.txt existed (<= 0.38.0)
# ----------------------------------------------------------------------------

@test "install: warns and continues when the ref has no manifest" {
  rm "$ORIGIN/SHASUMS256.txt"
  install_dbx
  [ "$status" -eq 0 ]
  [[ "$output" == *"Integrity check skipped"* ]]
  [[ "$output" == *"publishes no SHASUMS256.txt"* ]]
  [ -x "$PREFIX/bin/dbx" ]
}

@test "install: DBX_REQUIRE_CHECKSUMS=1 turns a missing manifest into an error" {
  rm "$ORIGIN/SHASUMS256.txt"
  install_dbx DBX_REQUIRE_CHECKSUMS=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cannot verify this install"* ]]
  [ ! -e "$PREFIX/bin/dbx" ]
}

@test "install: a file missing from the manifest warns, or fails when required" {
  grep -v ' lib/notify.sh$' "$ORIGIN/SHASUMS256.txt" > "$ORIGIN/SHASUMS256.new"
  mv "$ORIGIN/SHASUMS256.new" "$ORIGIN/SHASUMS256.txt"

  install_dbx
  [ "$status" -eq 0 ]
  [[ "$output" == *"lib/notify.sh is not listed in SHASUMS256.txt"* ]]
  [ -x "$PREFIX/bin/dbx" ]

  rm -rf "$PREFIX"
  install_dbx DBX_REQUIRE_CHECKSUMS=1
  [ "$status" -ne 0 ]
  [ ! -e "$PREFIX/bin/dbx" ]
}

# ----------------------------------------------------------------------------
# Man pages: the `|| true` that used to swallow partial installs
# ----------------------------------------------------------------------------

@test "install: a truncated manifest is reported once, not per file" {
  : > "$ORIGIN/SHASUMS256.txt"
  install_dbx
  [ "$status" -eq 0 ]
  [[ "$output" == *"empty or truncated"* ]]
  [ "$(grep -c 'Integrity check skipped' <<< "$output")" -eq 1 ]
  [ -x "$PREFIX/bin/dbx" ]
}

@test "install: a man page the manifest lists but the ref is missing is fatal" {
  rm "$ORIGIN/man/man1/dbx-scrub.1"
  install_dbx
  [ "$status" -ne 0 ]
  [[ "$output" == *"Download failed: man/man1/dbx-scrub.1"* ]]
  [ ! -e "$PREFIX/bin/dbx" ]
}

@test "install: a man page absent from both the ref and the manifest is skipped" {
  rm "$ORIGIN/man/man1/dbx-scrub.1"
  grep -v ' man/man1/dbx-scrub.1$' "$ORIGIN/SHASUMS256.txt" > "$ORIGIN/SHASUMS256.new"
  mv "$ORIGIN/SHASUMS256.new" "$ORIGIN/SHASUMS256.txt"

  install_dbx
  [ "$status" -eq 0 ]
  [ -x "$PREFIX/bin/dbx" ]
  [ ! -e "$PREFIX/man/dbx-scrub.1" ]
}

@test "install: an unverifiable ref still refuses a failed launcher download" {
  rm "$ORIGIN/SHASUMS256.txt" "$ORIGIN/dbx"
  install_dbx
  [ "$status" -ne 0 ]
  [[ "$output" == *"Download failed: dbx"* ]]
}

# ----------------------------------------------------------------------------
# The manifest covers what the installer actually fetches
# ----------------------------------------------------------------------------

# Every path install.sh downloads, derived from the installer itself rather than
# restated here — a new lib or man page that nobody hashed must fail this.
installer_paths() {
  printf 'dbx\n'
  grep -E '^[[:space:]]*for lib in ' "$DBX_REPO_ROOT/install.sh" |
    grep -oE '[a-z_]+\.sh' | sed 's|^|lib/|'
  grep -E '^[[:space:]]*for asset in ' "$DBX_REPO_ROOT/install.sh" |
    grep -oE '[a-z-]+\.html' | sed 's|^|lib/|'
  printf 'lib/wizard-server.py\n'
  sed -n '/^MAN_PAGES=(/,/^)/p' "$DBX_REPO_ROOT/install.sh" |
    grep -oE 'dbx[a-z0-9-]*\.1' | sed 's|^|man/man1/|'
}

@test "SHASUMS256.txt: lists every file install.sh downloads" {
  while read -r path; do
    grep -q "  $path\$" "$DBX_REPO_ROOT/SHASUMS256.txt" ||
      { echo "not in SHASUMS256.txt: $path"; false; }
  done < <(installer_paths)
}

@test "SHASUMS256.txt: lists nothing install.sh doesn't download" {
  fetched="$(installer_paths | sort)"
  while read -r _ path; do
    printf '%s\n' "$fetched" | grep -Fxq "$path" ||
      { echo "in SHASUMS256.txt but never downloaded: $path"; false; }
  done < "$DBX_REPO_ROOT/SHASUMS256.txt"
}
