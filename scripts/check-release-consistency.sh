#!/usr/bin/env bash
#
# check-release-consistency.sh — fail if release-synchronized files have drifted.
#
# Guards three drift classes that a manual release (or a feature PR that adds a
# command/lib) can silently desync:
#
#   1. install.sh MAN_PAGES vs the actual man/man1/*.1 files  (set, order-insensitive)
#   2. every man/man1/*.1 .TH version token vs VERSION in dbx
#   3. install.sh's lib download list vs the actual lib/*.sh files  (set)
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

  if [ "$fail" -ne 0 ]; then
    echo "" >&2
    echo "Release-consistency check FAILED. Fix the drift above before merging." >&2
    exit 1
  fi
  echo "OK: man pages, .TH versions, and lib list are all in sync with VERSION $version."
}

# Executed directly: run the checks. Sourced (by release.sh): just define them.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  check_release_consistency
fi
