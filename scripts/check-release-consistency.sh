#!/usr/bin/env bash
#
# check-release-consistency.sh — fail if release-synchronized files have drifted.
#
# Guards five drift classes that a manual release (or a feature PR that adds a
# command/lib) can silently desync:
#
#   1. install.sh MAN_PAGES vs the actual man/man1/*.1 files  (set, order-insensitive)
#   2. every man/man1/*.1 .TH version token vs VERSION in dbx
#   3. install.sh's lib download list vs the actual lib/*.sh files  (set)
#   4. install.sh's wizard asset list vs the actual lib/*.html files  (set)
#   5. SHASUMS256.txt vs the bytes of every file install.sh downloads
#
# Set comparisons are deliberate: MAN_PAGES and the lib list are curated in a
# non-alphabetical order that controls fetch order, so they must NOT be sorted
# or regenerated — only checked. Runs in CI on every PR and is safe to run
# locally (`scripts/check-release-consistency.sh`). Portable to macOS bash 3.2
# / BSD tools: no GNU-isms, no ${var//pat/rep}.
#
# scripts/release.sh sources this file to reuse the accessors below, so the
# bump and the check share one definition of which files carry the version.
# Sourcing runs no checks — it only cd's to the repo root.

set -euo pipefail

# Resolve repo root from this script's location so it runs from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

# --- accessors (shared with scripts/release.sh) ---

# VERSION in dbx — the single source of truth every other file must match.
release_version() {
  grep -E '^VERSION=' dbx | head -1 | cut -d'"' -f2 || true
}

# Every file whose .TH line carries the version.
release_man_pages() {
  local f
  for f in man/man1/*.1; do printf '%s\n' "$f"; done
}

# The X.Y.Z token from a man page's .TH line; empty if the line is malformed.
# `|| true`: a missing token must reach the caller's friendly check, not abort
# the script via pipefail (the malformed-man-page case is the point).
release_man_th_version() {
  head -1 "$1" | grep -oE 'dbx [0-9]+\.[0-9]+\.[0-9]+' | head -1 | awk '{print $2}' || true
}

# Every file install.sh downloads onto a user's machine, repo-relative. Checks
# 1, 3 and 4 below assert that these globs and install.sh's curated download
# lists describe the same set, so this stays a derivation of what ships rather
# than a fourth hand-maintained list. Subshell body: LC_ALL pins glob collation
# so the generated manifest is byte-identical on every machine.
release_payload_files() (
  LC_ALL=C
  printf '%s\n' dbx
  for f in lib/*.sh lib/*.html lib/wizard-server.py man/man1/*.1; do
    printf '%s\n' "$f"
  done
)

# sha256 of $1 as a bare hex digest, portable across coreutils and macOS.
# Hashing stdin rather than the path keeps the filename column out of the
# output. install.sh carries its own copy of this — it is fetched standalone by
# `curl | bash` and cannot source anything from the repo.
release_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | cut -d' ' -f1
  else
    shasum -a 256 < "$1" | cut -d' ' -f1
  fi
}

# The body of SHASUMS256.txt: `<sha256>  <path>` per payload file, in the format
# `sha256sum -c` reads, so a checkout can verify itself with the stock tool.
# $1 (optional): an overlay directory — a file that exists there is hashed
# instead of the working-tree copy, which is how release.sh previews the
# manifest for a bump it hasn't applied yet.
release_shasums() {
  local overlay="${1:-}" f src
  release_payload_files | while read -r f; do
    src="$f"
    if [ -n "$overlay" ] && [ -f "$overlay/$f" ]; then
      src="$overlay/$f"
    fi
    printf '%s  %s\n' "$(release_sha256_file "$src")" "$f"
  done
}

# --- checks ---

fail=0
problem() { printf 'DRIFT: %s\n' "$1" >&2; fail=1; }

# Compare two newline-lists as sets; report members missing from either side.
# $1 label-for-A  $2 label-for-B  $3 list-A  $4 list-B
compare_sets() {
  local a_label="$1" b_label="$2" a="$3" b="$4" only_a only_b
  only_a="$(comm -23 <(printf '%s\n' "$a" | sort -u) <(printf '%s\n' "$b" | sort -u))"
  only_b="$(comm -13 <(printf '%s\n' "$a" | sort -u) <(printf '%s\n' "$b" | sort -u))"
  if [ -n "$only_a" ]; then
    problem "in $a_label but not $b_label:"; printf '%s\n' "$only_a" | sed 's/^/  /' >&2
  fi
  if [ -n "$only_b" ]; then
    problem "in $b_label but not $a_label:"; printf '%s\n' "$only_b" | sed 's/^/  /' >&2
  fi
}

check_release_consistency() {
  local version declared_man actual_man declared_lib actual_lib f token
  local declared_asset actual_asset regenerated
  fail=0

  version="$(release_version)"
  if [ -z "$version" ]; then
    echo "ERROR: could not read VERSION from dbx" >&2; exit 2
  fi
  echo "VERSION (dbx): $version"

  # --- 1. MAN_PAGES vs man/man1/*.1 ---
  declared_man="$(sed -n '/^MAN_PAGES=(/,/^)/p' install.sh | grep -oE 'dbx[a-z0-9-]*\.1')"
  actual_man="$(release_man_pages | while read -r f; do basename "$f"; done)"
  compare_sets "install.sh MAN_PAGES" "man/man1/" "$declared_man" "$actual_man"

  # --- 2. .TH version token in every man page == VERSION ---
  for f in $(release_man_pages); do
    token="$(release_man_th_version "$f")"
    if [ -z "$token" ]; then
      problem "$f: no \"dbx X.Y.Z\" token on its .TH line"
    elif [ "$token" != "$version" ]; then
      problem "$f: .TH version $token != dbx VERSION $version"
    fi
  done

  # --- 3. install.sh lib download list vs lib/*.sh ---
  declared_lib="$(grep -E '^[[:space:]]*for lib in ' install.sh | grep -oE '[a-z_]+\.sh')"
  actual_lib="$(for f in lib/*.sh; do basename "$f"; done)"
  compare_sets "install.sh lib list" "lib/" "$declared_lib" "$actual_lib"

  # --- 4. install.sh wizard asset list vs lib/*.html ---
  declared_asset="$(grep -E '^[[:space:]]*for asset in ' install.sh | grep -oE '[a-z-]+\.html')"
  actual_asset="$(for f in lib/*.html; do basename "$f"; done)"
  compare_sets "install.sh asset list" "lib/" "$declared_asset" "$actual_asset"

  # --- 5. SHASUMS256.txt vs the payload on disk ---
  # The manifest is generated, never hand-edited: any PR touching a shipped file
  # has to re-run scripts/gen-shasums.sh, or installs of that ref would fail
  # verification.
  if [ ! -f SHASUMS256.txt ]; then
    problem "SHASUMS256.txt is missing — generate it with scripts/gen-shasums.sh"
  else
    regenerated="$(release_shasums)"
    if [ "$regenerated" != "$(cat SHASUMS256.txt)" ]; then
      problem "SHASUMS256.txt is stale — regenerate it with scripts/gen-shasums.sh:"
      diff -u SHASUMS256.txt <(printf '%s\n' "$regenerated") | sed 's/^/  /' >&2 || true
    fi
  fi

  if [ "$fail" -ne 0 ]; then
    echo "" >&2
    echo "Release-consistency check FAILED. Fix the drift above before merging." >&2
    exit 1
  fi
  echo "OK: man pages, .TH versions, install.sh's file lists, and SHASUMS256.txt are all in sync with VERSION $version."
}

# Executed directly: run the checks. Sourced (by release.sh): just define them.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  check_release_consistency
fi
