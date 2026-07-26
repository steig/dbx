#!/usr/bin/env bash
#
# dbx installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/steig/dbx/main/install.sh | bash
#
set -euo pipefail

REPO="steig/dbx"
# Git ref to install from. Defaults to main (the public one-liner installer);
# `dbx update` sets DBX_REF to the latest release tag so the install isn't
# served stale content from the CDN cache on main right after a release.
REF="${DBX_REF:-main}"
BASE_URL="https://raw.githubusercontent.com/$REPO/$REF"
INSTALL_DIR="${DBX_INSTALL_DIR:-$HOME/.local/bin}"
LIB_DIR="${DBX_LIB_DIR:-$HOME/.local/lib/dbx}"
MAN_DIR="${DBX_MAN_DIR:-$HOME/.local/share/man/man1}"

# Refuse to install anything this script could not check against SHASUMS256.txt
# instead of warning and carrying on. Off by default so installing a release
# from before the manifest existed still works — see init_verification.
REQUIRE_CHECKSUMS="${DBX_REQUIRE_CHECKSUMS:-0}"

# Hand-maintained list of man pages to fetch. Kept in sync by hand with
# the files under `man/man1/` in the repo; reviewers should add to this
# list when adding a new subcommand man page.
MAN_PAGES=(
  dbx.1
  dbx-backup.1
  dbx-restore.1
  dbx-verify.1
  dbx-list.1
  dbx-clean.1
  dbx-query.1
  dbx-test.1
  dbx-analyze.1
  dbx-host.1
  dbx-build-image.1
  dbx-config.1
  dbx-vault.1
  dbx-wizard.1
  dbx-schedule.1
  dbx-storage.1
  dbx-scrub.1
  dbx-containers.1
  dbx-completion.1
)

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Staging tree + temp launcher path, with cleanup. Declared at script scope (not
# `local` in main) so the EXIT trap can still see them — a function-local would
# be out of scope by the time the trap fires, and under `set -u` that reads as
# an unbound variable.
STAGE=""
DBX_TMP=""
cleanup() {
  [[ -n "${STAGE:-}" ]] && rm -rf "$STAGE" 2>/dev/null
  [[ -n "${DBX_TMP:-}" ]] && rm -f "$DBX_TMP" 2>/dev/null
  return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Integrity verification
#
# Every file is downloaded into a staging tree and checked against
# SHASUMS256.txt — fetched from the same ref — before anything is moved into
# place. That makes a corrupted, truncated, or CDN-cache-skewed download a hard
# error instead of a half-installed dbx, and it means a failed install leaves
# the existing one exactly as it was.
#
# What this does NOT do is prove where the files came from: the manifest is
# served by the same origin as the files it describes, and this script is
# itself fetched unverified by `curl | bash`. Anyone able to tamper with the
# origin can serve a matching manifest, or an install.sh with these checks
# removed. Provenance needs a signature verified against a key obtained out of
# band; see docs/install.md.
# ---------------------------------------------------------------------------

# Absolute path of the fetched manifest, empty when there isn't a usable one.
MANIFEST=""

# sha256 of $1 as a bare hex digest, portable across coreutils (sha256sum) and
# macOS (shasum). Hashing stdin rather than the path keeps the filename column
# out of the output. Deliberately duplicates _sha256_stdin from lib/core.sh:
# this script is fetched on its own and can't source the libraries it installs.
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 < "$1" | cut -d' ' -f1
  else
    return 1
  fi
}

# Report that something could not be verified — fatal under
# DBX_REQUIRE_CHECKSUMS=1, a warning otherwise.
unverified() {
  [[ "$REQUIRE_CHECKSUMS" == "1" ]] &&
    error "Cannot verify this install: $1 (DBX_REQUIRE_CHECKSUMS=1)"
  warn "Integrity check skipped: $1"
}

# Fetch SHASUMS256.txt for $REF into the staging tree. Releases up to 0.38.0
# were cut before the manifest existed, so its absence is not fatal by default —
# installing an older tag warns and continues rather than failing with something
# that reads like tampering.
init_verification() {
  if ! curl -fsSL "$BASE_URL/SHASUMS256.txt" -o "$STAGE/SHASUMS256.txt" 2>/dev/null; then
    rm -f "$STAGE/SHASUMS256.txt"
    unverified "$REPO@$REF publishes no SHASUMS256.txt"
    return 0
  fi
  if ! sha256_file "$STAGE/SHASUMS256.txt" >/dev/null 2>&1; then
    unverified "no sha256sum or shasum command available to check it"
    return 0
  fi
  # The launcher is always listed. Its absence means the manifest itself arrived
  # empty or truncated — say that once instead of warning about all 47 files.
  if ! grep -q '  dbx$' "$STAGE/SHASUMS256.txt"; then
    unverified "the SHASUMS256.txt served for $REF is empty or truncated"
    return 0
  fi
  MANIFEST="$STAGE/SHASUMS256.txt"
  info "Verifying downloads against SHASUMS256.txt"
}

# Expected digest for repo-relative path $1. Non-zero when it isn't listed.
manifest_digest() {
  [[ -n "$MANIFEST" ]] || return 1
  awk -v p="$1" '$2 == p { print $1; hit = 1; exit } END { exit !hit }' "$MANIFEST"
}

# Abort unless the staged copy of $1 matches the manifest.
verify_staged() {
  local path="$1" want got
  [[ -n "$MANIFEST" ]] || return 0
  if ! want=$(manifest_digest "$path"); then
    unverified "$path is not listed in SHASUMS256.txt"
    return 0
  fi
  got=$(sha256_file "$STAGE/$path")
  [[ "$want" == "$got" ]] || error "Checksum mismatch for $path
  expected: $want
  actual:   $got
Nothing was installed and your existing dbx is untouched. Retry the install; if
it keeps failing, report it at https://github.com/$REPO/issues"
}

# Download repo-relative path $1 into the staging tree. Returns non-zero on a
# failed fetch, after removing the partial file curl may have left behind.
fetch() {
  local path="$1"
  mkdir -p "$STAGE/$(dirname "$path")"
  curl -fsSL "$BASE_URL/$path" -o "$STAGE/$path" && return 0
  rm -f "$STAGE/$path"
  return 1
}

# Fetch $1 and check it, failing the install if either step fails.
fetch_verified() {
  fetch "$1" || error "Download failed: $1"
  verify_staged "$1"
}

# Check dependencies
check_deps() {
  local missing=()
  for cmd in docker jq zstd ssh curl; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  # Check for credential storage
  if [[ "$(uname)" == "Linux" ]] && ! command -v secret-tool &>/dev/null; then
    missing+=("libsecret-tools")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo ""
    echo -e "${RED}Missing dependencies:${NC} ${missing[*]}"
    echo ""
    echo "Install them first:"
    if [[ "$(uname)" == "Darwin" ]]; then
      echo "  brew install ${missing[*]}"
    else
      echo "  apt install ${missing[*]}  # or equivalent"
    fi
    echo ""
  fi

  # `dbx storage` shells out to an S3 client that only the Docker image ships,
  # so a source install had no way to learn it was needed until every S3
  # operation failed. Reported separately from the hard dependencies above:
  # storage is opt-in, either client will do, and neither is a distro package
  # the block's `apt install` line could offer — on Debian/Ubuntu `mc` is
  # Midnight Commander.
  if ! command -v mc &>/dev/null && ! command -v aws &>/dev/null; then
    echo ""
    echo -e "${BLUE}Optional:${NC} 'dbx storage' (S3/MinIO offload) needs an S3 client — none found."
    echo "  mc:  https://min.io/docs/minio/linux/reference/minio-mc.html#install-mc"
    echo "  aws: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    echo ""
  fi
}

main() {
  echo ""
  echo "Installing dbx..."
  echo ""

  # Create directories
  mkdir -p "$INSTALL_DIR" "$LIB_DIR" "$MAN_DIR"

  # Everything lands here first and is checksummed before a single file is
  # moved into place, so a bad download can't leave a half-installed dbx.
  STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dbx-install.XXXXXX")"

  # Download files
  info "Downloading from github.com/$REPO@$REF..."
  init_verification

  fetch_verified dbx

  for lib in core.sh host.sh tunnel.sh encrypt.sh postgres.sh mysql.sh post_restore.sh scrub.sh scrub_strategies.sh notify.sh schedule.sh storage.sh update.sh wizard.sh completion.sh; do
    fetch_verified "lib/$lib"
  done

  # HTML assets for the browser-based `dbx wizard` config builder. Same
  # form fragment also powers the static docs builder; downloading both
  # gives offline-capable wizard mode.
  for asset in wizard.html wizard-form.html wizard-backups.html wizard-backup.html wizard-restore.html wizard-schedule.html wizard-runs.html wizard-dashboard.html wizard-vault.html wizard-storage.html wizard-scrub.html wizard-analyze.html; do
    fetch_verified "lib/$asset"
  done

  # Python HTTP server backing the wizard. Standalone file so it stays
  # readable and unit-testable; lib/wizard.sh spawns it via argparse flags.
  fetch_verified lib/wizard-server.py

  # Man pages. `man dbx` should work right after install. A page the target ref
  # doesn't have yet is skipped — but only when the manifest agrees it isn't
  # there. A page the manifest lists and the fetch missed is a partial download,
  # which used to pass silently.
  info "Installing man pages to $MAN_DIR..."
  for page in "${MAN_PAGES[@]}"; do
    if fetch "man/man1/$page"; then
      verify_staged "man/man1/$page"
    elif manifest_digest "man/man1/$page" >/dev/null; then
      error "Download failed: man/man1/$page (SHASUMS256.txt says $REF has it)"
    fi
  done

  # Verified — install. Libraries and man pages first, launcher last, so the
  # launcher is never newer than the libs it loads.
  local staged
  for staged in "$STAGE"/lib/*; do
    if [[ -e "$staged" ]]; then mv "$staged" "$LIB_DIR/$(basename "$staged")"; fi
  done
  for staged in "$STAGE"/man/man1/*; do
    if [[ -e "$staged" ]]; then mv "$staged" "$MAN_DIR/$(basename "$staged")"; fi
  done

  # Update lib path in the launcher to use the installed lib location.
  # Avoid `sed -i` — its argument shape differs between BSD and GNU sed, and
  # `uname` can't tell us which is actually first in PATH (e.g. GNU sed via
  # Nix or Homebrew on macOS). A temp-file rewrite works with either.
  #
  # The rewrite goes to a temp path inside $INSTALL_DIR (same filesystem, so the
  # move below is a rename). `dbx update` runs FROM $INSTALL_DIR/dbx, and
  # writing onto that live path truncates + rewrites the file the running bash
  # process is still reading by offset — corrupting it mid-run ("cker,: command
  # not found"). A rename swaps the inode instead, so the running process keeps
  # reading its original (now-unlinked) file intact.
  DBX_TMP="$INSTALL_DIR/.dbx.install.$$"
  sed "s|LIB_DIR=\"\$SCRIPT_DIR/lib\"|LIB_DIR=\"$LIB_DIR\"|" "$STAGE/dbx" > "$DBX_TMP"
  chmod +x "$DBX_TMP"
  # Atomic swap — the ONLY write to $INSTALL_DIR/dbx in the whole installer, and
  # it happens last.
  mv "$DBX_TMP" "$INSTALL_DIR/dbx"

  # Extract and show version
  local version
  version=$(grep '^VERSION=' "$INSTALL_DIR/dbx" | cut -d'"' -f2)
  success "Installed dbx $version to $INSTALL_DIR/dbx"

  # Check if install dir is in PATH
  if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo ""
    echo -e "${BLUE}Add to your PATH:${NC}"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
    echo ""
  fi

  # If the man page directory isn't already on MANPATH, point the user
  # at how to add it. `manpath` is a portable enough check (BSD on
  # macOS, GNU on Linux), and we look at the parent ($HOME/.local/share/man)
  # because manpath usually returns the section parent, not man1.
  local man_parent
  man_parent="$(dirname "$MAN_DIR")"
  if command -v manpath >/dev/null 2>&1; then
    if ! manpath 2>/dev/null | tr ':' '\n' | grep -Fxq "$man_parent"; then
      echo ""
      echo -e "${BLUE}Add to your MANPATH so 'man dbx' works:${NC}"
      echo "  export MANPATH=\"$man_parent:\$MANPATH\""
      echo "  # (add this to your ~/.bashrc / ~/.zshrc)"
      echo ""
    fi
  fi

  check_deps

  echo ""
  success "Installation complete!"
  echo ""
  echo "Get started:"
  echo "  dbx config init    # Create config"
  echo "  dbx help           # Show all commands"
  echo ""
}

main "$@"
