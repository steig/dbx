#!/usr/bin/env bash
#
# release.sh — cut a release by rewriting every version-carrying file in one pass.
#
# A dbx release bumps VERSION in `dbx`, the .TH line of all 19 man pages, and
# moves CHANGELOG.md's [Unreleased] section under a dated heading — 21 files
# that have to agree. Doing that by hand is how dbx-build-image.1 shipped
# desynced (#122, #147).
#
# Which files carry the version is NOT defined here: this script sources
# scripts/check-release-consistency.sh — the CI drift guard — and reuses its
# accessors, so the bump and the check can never disagree about what to touch.
# The same guard runs as the final gate after the rewrite.
#
# Usage:
#   scripts/release.sh 0.39.0            # explicit version
#   scripts/release.sh minor             # major | minor | patch
#   scripts/release.sh --dry-run minor   # print the diff, write nothing
#
# Tagging, pushing, and `gh release create` stay in the maintainer's hands —
# the script prints them as the next step. Portable to macOS bash 3.2 / BSD
# tools: no GNU-isms, no ${var//pat/rep}.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defines release_version / release_man_pages / release_man_th_version, sets
# ROOT, and cd's there. Sourcing runs no checks.
# shellcheck source=./check-release-consistency.sh
. "$SCRIPT_DIR/check-release-consistency.sh"

info() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: scripts/release.sh [--dry-run] <X.Y.Z | major | minor | patch>

Rewrites VERSION in dbx, the .TH line of every man/man1/*.1 (version + date),
and moves CHANGELOG.md's [Unreleased] section under a dated heading. Then runs
scripts/check-release-consistency.sh as a gate.

Options:
  --dry-run   Print a diff of every change and exit without writing.
  -h, --help  This message.

Does not commit, tag, push, or create a GitHub release — those are printed for
you to run.
EOF
}

# --- version helpers (bash 3.2: no arrays, no ${var//pat/rep}) ---

# $1 version, $2 field index 1-3
ver_part() {
  local v="$1"
  case "$2" in
    1) printf '%s\n' "${v%%.*}" ;;
    2) v="${v#*.}"; printf '%s\n' "${v%%.*}" ;;
    3) printf '%s\n' "${v##*.}" ;;
  esac
}

# Semver core only. Pre-release suffixes are rejected on purpose: the drift
# guard matches a bare `dbx X.Y.Z` token in the .TH lines, so `0.39.0-rc1`
# would read back as `0.39.0` and fail the gate.
valid_version() {
  printf '%s' "$1" | grep -qE '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
}

# $1 current version, $2 major|minor|patch
bump_version() {
  local cur="$1" what="$2" major minor patch
  major="$(ver_part "$cur" 1)"
  minor="$(ver_part "$cur" 2)"
  patch="$(ver_part "$cur" 3)"
  case "$what" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
  esac
  printf '%s.%s.%s\n' "$major" "$minor" "$patch"
}

# $1 newer than $2?
version_gt() {
  local i a b
  for i in 1 2 3; do
    a="$(ver_part "$1" "$i")"
    b="$(ver_part "$2" "$i")"
    [ "$a" -eq "$b" ] || { [ "$a" -gt "$b" ]; return; }
  done
  return 1
}

# --- arguments ---

dry_run=0
target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *)
      [ -z "$target" ] || die "unexpected argument: $1"
      target="$1"
      ;;
  esac
  shift
done

if [ -z "$target" ]; then
  usage >&2
  exit 2
fi

current="$(release_version)"
[ -n "$current" ] || die "could not read VERSION from dbx"

case "$target" in
  major|minor|patch) version="$(bump_version "$current" "$target")" ;;
  *) version="$target" ;;
esac

valid_version "$version" || die "not a valid version: $version (want X.Y.Z, e.g. 0.39.0)"
version_gt "$version" "$current" || die "$version is not newer than the current VERSION $current"

# --- guards ---

git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $ROOT"

if [ "$dry_run" -eq 0 ] && [ -n "$(git status --porcelain)" ]; then
  die "working tree is dirty — commit or stash first (a release is one clean 'chore: release' commit)"
fi

# --- CHANGELOG: [Unreleased] must exist exactly once and have content ---

unreleased_count="$(grep -c '^## \[Unreleased\]' CHANGELOG.md || true)"
[ "$unreleased_count" = "1" ] ||
  die "expected exactly one '## [Unreleased]' heading in CHANGELOG.md, found $unreleased_count"

unreleased_body="$(awk '/^## \[Unreleased\]/ { f = 1; next } f && /^## / { exit } f { print }' CHANGELOG.md)"
printf '%s' "$unreleased_body" | grep -q '[^[:space:]]' ||
  die "CHANGELOG.md's [Unreleased] section is empty — nothing to release"

# --- stage the rewrites ---

today="$(date +%F)"
stage="$(mktemp -d "${TMPDIR:-/tmp}/dbx-release.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

changed=""

# Rewrite $1 through awk (remaining args) into the staging tree.
stage_awk() {
  local rel="$1"
  shift
  mkdir -p "$stage/$(dirname "$rel")"
  awk "$@" "$rel" > "$stage/$rel"
  changed="$changed$rel
"
}

stage_awk dbx -v ver="$version" '
  !done && /^VERSION="/ { print "VERSION=\"" ver "\""; done = 1; next }
  { print }
'

# Both the date and the version token on line 1 are hand-typed today, so both
# get rewritten. Character classes rather than {4} intervals: not every awk
# supports interval expressions.
for page in $(release_man_pages); do
  [ -n "$(release_man_th_version "$page")" ] ||
    die "$page: no \"dbx X.Y.Z\" token on its .TH line — fix it by hand first"
  stage_awk "$page" -v ver="$version" -v d="$today" '
    NR == 1 {
      gsub(/"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]"/, "\"" d "\"")
      gsub(/dbx [0-9]+\.[0-9]+\.[0-9]+/, "dbx " ver)
    }
    { print }
  '
done

# The curated prose stays where it is; only the heading above it changes, with
# a fresh empty [Unreleased] left on top.
stage_awk CHANGELOG.md -v ver="$version" -v d="$today" '
  !done && /^## \[Unreleased\]/ {
    print "## [Unreleased]"
    print ""
    print "## [" ver "] - " d
    done = 1
    next
  }
  { print }
'

# --- apply (or show) ---

if [ "$dry_run" -eq 1 ]; then
  info "Dry run: $current -> $version (release date $today)"
  info ""
  for rel in $changed; do
    diff -u -L "$rel" -L "$rel (after)" "$rel" "$stage/$rel" || true
  done
  info ""
  info "No files written. Re-run without --dry-run to apply."
  exit 0
fi

# `cat >` rather than `mv` so the file keeps its mode (dbx is executable).
for rel in $changed; do
  cat "$stage/$rel" > "$rel"
done

info "Bumped $current -> $version across $(printf '%s' "$changed" | grep -c '') files (release date $today)."
info ""

# --- gate: the same check CI runs ---

bash "$SCRIPT_DIR/check-release-consistency.sh" ||
  die "release-consistency check failed AFTER the bump — the tree is half-released. Fix the drift above and re-run (\`git checkout .\` to start over)."

cat <<EOF

Next (not run for you):

  git diff                      # review the bump
  git commit -am "chore: release $version"
  git tag v$version
  git push && git push --tags   # the tag fires release-image.yml
  gh release create v$version --title "v$version" --notes "<the new CHANGELOG.md section>"
EOF
