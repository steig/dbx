#!/usr/bin/env bash
#
# update-formula.sh — repoint Formula/dbx.rb at a released tag, with a digest
# that was computed, never typed.
#
# The Homebrew formula is the one release artifact that CANNOT be bumped in the
# release commit. It pins the sha256 of the tag's own source tarball, and that
# tarball contains the formula — so a formula stating its own tag's digest has
# no fixed point. It therefore lags by one step: `scripts/release.sh` cuts the
# release, the maintainer pushes the tag, and *then* this script repoints the
# formula at it. Homebrew reads formulae from the tap's default branch, not from
# a tag, so a formula on main that names the newest tag is exactly right.
#
# Usage:
#   scripts/update-formula.sh                # bump to VERSION in dbx (post-tag)
#   scripts/update-formula.sh 0.39.1         # bump to an explicit tag
#   scripts/update-formula.sh --check        # verify the pinned digest, write nothing
#
# --check is what .github/workflows/formula.yml runs: it re-downloads the
# tarball the committed formula points at and compares. That is the half of the
# invariant scripts/check-release-consistency.sh cannot cover, because a digest
# can only be checked against the network.
#
# Portable to macOS bash 3.2 / BSD tools: no GNU-isms, no ${var//pat/rep}.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defines release_version / release_sha256_file / release_formula_* and the
# RELEASE_FORMULA path, sets ROOT, and cd's there. Sourcing runs no checks.
# shellcheck source=./check-release-consistency.sh
. "$SCRIPT_DIR/check-release-consistency.sh"

info() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: scripts/update-formula.sh [--check] [X.Y.Z]

Rewrites the url and sha256 in Formula/dbx.rb to point at tag vX.Y.Z, taking the
digest from the tarball GitHub actually serves. With no version, uses VERSION
from dbx — the normal post-tag invocation.

  --check     Re-download the tarball the committed formula pins and verify its
              digest. Writes nothing; non-zero on mismatch.
  -h, --help  This message.

The tag must already be pushed: the digest is of GitHub's generated source
tarball for that tag, which cannot exist before it does.
EOF
}

tarball_url() { printf 'https://github.com/steig/dbx/archive/refs/tags/v%s.tar.gz\n' "$1"; }

# sha256 of the source tarball for version $1, downloaded to a temp file.
# Hashing a file rather than a pipe so a truncated transfer fails curl instead of
# silently hashing a short body.
fetch_tarball_sha256() {
  local version="$1" url tmp digest
  url="$(tarball_url "$version")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/dbx-formula.XXXXXX")"
  # shellcheck disable=SC2064  # expand $tmp now, not at trap time
  trap "rm -f '$tmp'" RETURN
  curl -fsSL --retry 3 "$url" -o "$tmp" ||
    die "could not download $url — is the tag pushed?"
  digest="$(release_sha256_file "$tmp")"
  [ -n "$digest" ] || die "no sha256sum or shasum command available"
  printf '%s\n' "$digest"
}

# --- arguments ---

check_only=0
target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check_only=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *)
      [ -z "$target" ] || die "unexpected argument: $1"
      target="${1#v}"
      ;;
  esac
  shift
done

[ -f "$RELEASE_FORMULA" ] || die "$RELEASE_FORMULA not found"

# --- --check: verify what is committed, change nothing ---

if [ "$check_only" -eq 1 ]; then
  [ -z "$target" ] || die "--check takes no version — it verifies the pinned one"
  pinned="$(release_formula_version)"
  [ -n "$pinned" ] || die "could not read the pinned tag from $RELEASE_FORMULA's url"
  want="$(release_formula_sha256)"
  info "$RELEASE_FORMULA pins v$pinned"
  got="$(fetch_tarball_sha256 "$pinned")"
  if [ "$want" != "$got" ]; then
    printf 'ERROR: sha256 mismatch for %s\n  formula: %s\n  actual:  %s\n' \
      "$(tarball_url "$pinned")" "$want" "$got" >&2
    printf 'Every `brew install` of this tap is failing. Re-run scripts/update-formula.sh %s.\n' \
      "$pinned" >&2
    exit 1
  fi
  info "OK: $want"
  exit 0
fi

# --- bump ---

[ -n "$target" ] || target="$(release_version)"
[ -n "$target" ] || die "could not read VERSION from dbx"
printf '%s' "$target" | grep -qE '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ||
  die "not a valid version: $target (want X.Y.Z)"

sha="$(fetch_tarball_sha256 "$target")"
url="$(tarball_url "$target")"

tmp="$(mktemp "${TMPDIR:-/tmp}/dbx-formula.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
# Only the first url/sha256 pair is touched: `head` carries a git url with no
# digest of its own, and a future `resource` block would carry its own pair.
awk -v u="$url" -v s="$sha" '
  !u_done && /^[[:space:]]*url "https:\/\/github.com\/steig\/dbx\/archive\// {
    print "  url \"" u "\""; u_done = 1; next
  }
  !s_done && /^[[:space:]]*sha256 "/ { print "  sha256 \"" s "\""; s_done = 1; next }
  { print }
  END { if (!u_done || !s_done) exit 3 }
' "$RELEASE_FORMULA" > "$tmp" ||
  die "could not find the url and sha256 lines in $RELEASE_FORMULA"
cat "$tmp" > "$RELEASE_FORMULA"

if [ "$(release_formula_version)" != "$target" ]; then
  die "rewrote $RELEASE_FORMULA but it still does not read back as v$target"
fi

info "$RELEASE_FORMULA -> v$target"
info "  url    $url"
info "  sha256 $sha"
info ""
info "Commit it: git commit -am \"chore(homebrew): dbx $target\""
