#!/usr/bin/env bats
#
# Tests for scripts/release.sh — the one-pass version bump.
#
# Every test runs against a throwaway copy of the release-synchronized files in
# BATS_TEST_TMPDIR (a real git repo, since release.sh refuses a dirty tree).
# Nothing here touches the checked-out repo. Target versions are derived from
# whatever VERSION is today, so the suite survives the releases it cuts.

load '../helpers/common'

setup() {
  # Keep the developer's global git config out of the fixture repos. Besides
  # commit.gpgsign and hooks, core.fsmonitor is a hang: the daemon a fixture
  # spawns inherits the test's stdout pipe and never closes it.
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME=dbx GIT_AUTHOR_EMAIL=dbx@test
  export GIT_COMMITTER_NAME=dbx GIT_COMMITTER_EMAIL=dbx@test

  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/man/man1" "$REPO/scripts" "$REPO/lib"
  cp "$DBX_REPO_ROOT/dbx" "$REPO/dbx"
  cp "$DBX_REPO_ROOT/CHANGELOG.md" "$DBX_REPO_ROOT/install.sh" "$REPO/"
  seed_unreleased
  cp "$DBX_REPO_ROOT"/man/man1/*.1 "$REPO/man/man1/"
  cp "$DBX_REPO_ROOT"/lib/*.sh "$REPO/lib/"
  cp "$DBX_REPO_ROOT"/scripts/*.sh "$REPO/scripts/"
  git -C "$REPO" init -q
  # Belt and braces for git < 2.32, which ignores GIT_CONFIG_GLOBAL.
  git -C "$REPO" config core.fsmonitor false
  commit_fixture

  CURRENT=$(dbx_version)
  MAJOR=${CURRENT%%.*}
  rest=${CURRENT#*.}
  MINOR=${rest%%.*}
  PATCH=${rest##*.}
  NEXT="$((MAJOR + 1)).0.0"
  TODAY=$(date +%F)
}

commit_fixture() {
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm fixture
}

# Give the fixture its own [Unreleased] entry. release.sh refuses to cut a
# release from an empty [Unreleased], which is exactly the state the real
# CHANGELOG is in for the whole window after a release commit — inheriting it
# would turn this file red on main every time a release lands.
seed_unreleased() {
  awk '/^## \[Unreleased\]/ {
         print; print ""; print "### Added"; print ""
         print "- **Fixture entry.** Seeded by tests/unit/release.bats."
         next
       }
       { print }' "$REPO/CHANGELOG.md" > "$REPO/CHANGELOG.new"
  mv "$REPO/CHANGELOG.new" "$REPO/CHANGELOG.md"
}

release() {
  run bash "$REPO/scripts/release.sh" "$@"
}

dbx_version() { grep -E '^VERSION=' "$REPO/dbx" | head -1 | cut -d'"' -f2; }
th_version() { head -1 "$1" | grep -oE 'dbx [0-9]+\.[0-9]+\.[0-9]+' | awk '{print $2}'; }
th_date() { head -1 "$1" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1; }

# Body of the [Unreleased] section (everything up to the next `## ` heading).
unreleased_body() {
  awk '/^## \[Unreleased\]/ { f = 1; next } f && /^## / { exit } f { print }' \
    "$REPO/CHANGELOG.md"
}

# Everything from the first already-released section to EOF — must survive a
# bump byte-for-byte.
released_sections() {
  awk '/^## \[/ && $0 !~ /Unreleased/ { f = 1 } f { print }' "$REPO/CHANGELOG.md"
}

# ----------------------------------------------------------------------------
# Version argument handling
# ----------------------------------------------------------------------------

@test "release: rejects a non-semver version" {
  release 0.39
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a valid version"* ]]
}

@test "release: rejects a pre-release suffix (the .TH token can't carry it)" {
  release "$NEXT-rc1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a valid version"* ]]
}

@test "release: rejects a version that is not newer than the current one" {
  release "$CURRENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not newer"* ]]
}

@test "release: rejects an unknown option" {
  release --nope "$NEXT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "release: no argument exits non-zero with usage" {
  release
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "release: --help exits 0" {
  release --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "release: patch/minor/major increment from the current VERSION" {
  release --dry-run patch
  [ "$status" -eq 0 ]
  [[ "$output" == *"$CURRENT -> $MAJOR.$MINOR.$((PATCH + 1))"* ]]

  release --dry-run minor
  [ "$status" -eq 0 ]
  [[ "$output" == *"$CURRENT -> $MAJOR.$((MINOR + 1)).0"* ]]

  release --dry-run major
  [ "$status" -eq 0 ]
  [[ "$output" == *"$CURRENT -> $((MAJOR + 1)).0.0"* ]]
}

# ----------------------------------------------------------------------------
# Guards
# ----------------------------------------------------------------------------

@test "release: refuses to run on a dirty tree" {
  echo "scratch" >> "$REPO/CHANGELOG.md"
  release "$NEXT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dirty"* ]]
  [ "$(dbx_version)" = "$CURRENT" ]
}

@test "release: refuses when [Unreleased] has no content" {
  awk '/^## \[Unreleased\]/ { print; print ""; drop = 1; next }
       drop && /^## / { drop = 0 }
       !drop' "$REPO/CHANGELOG.md" > "$REPO/CHANGELOG.new"
  mv "$REPO/CHANGELOG.new" "$REPO/CHANGELOG.md"
  commit_fixture

  release "$NEXT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty"* ]]
}

@test "release: refuses a man page whose .TH has no version token" {
  awk 'NR == 1 { print ".TH DBX-CLEAN 1 \"2026-06-23\" \"User Commands\""; next } { print }' \
    "$REPO/man/man1/dbx-clean.1" > "$REPO/man/man1/dbx-clean.new"
  mv "$REPO/man/man1/dbx-clean.new" "$REPO/man/man1/dbx-clean.1"
  commit_fixture

  release "$NEXT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dbx-clean.1"* ]]
  [ "$(dbx_version)" = "$CURRENT" ]
}

# ----------------------------------------------------------------------------
# --dry-run
# ----------------------------------------------------------------------------

@test "release: --dry-run writes nothing" {
  release --dry-run "$NEXT"
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$REPO" status --porcelain)" ]
  [ "$(dbx_version)" = "$CURRENT" ]
}

@test "release: --dry-run shows the diff for dbx, a man page, and the CHANGELOG" {
  release --dry-run "$NEXT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"+VERSION=\"$NEXT\""* ]]
  [[ "$output" == *"+.TH DBX 1 \"$TODAY\" \"dbx $NEXT\""* ]]
  [[ "$output" == *"+## [$NEXT] - $TODAY"* ]]
  [[ "$output" == *"No files written"* ]]
}

@test "release: --dry-run works on a dirty tree" {
  echo "scratch" >> "$REPO/CHANGELOG.md"
  release --dry-run "$NEXT"
  [ "$status" -eq 0 ]
}

# ----------------------------------------------------------------------------
# The bump itself
# ----------------------------------------------------------------------------

@test "release: bumps VERSION in dbx and keeps it executable" {
  release "$NEXT"
  [ "$status" -eq 0 ]
  [ "$(dbx_version)" = "$NEXT" ]
  [ -x "$REPO/dbx" ]
}

@test "release: rewrites the version AND date on every man page .TH line" {
  release "$NEXT"
  [ "$status" -eq 0 ]
  for f in "$REPO"/man/man1/*.1; do
    [ "$(th_version "$f")" = "$NEXT" ]
    [ "$(th_date "$f")" = "$TODAY" ]
  done
}

@test "release: moves [Unreleased] under a dated heading and leaves it empty" {
  body_before=$(unreleased_body)
  released_before=$(released_sections)

  release "$NEXT"
  [ "$status" -eq 0 ]

  # Exactly one Unreleased heading, and it is now empty.
  [ "$(grep -c '^## \[Unreleased\]' "$REPO/CHANGELOG.md")" = "1" ]
  [ -z "$(unreleased_body | tr -d '[:space:]')" ]

  # The old content sits under the new dated heading, unchanged.
  moved=$(awk -v h="## [$NEXT] - $TODAY" \
    '$0 == h { f = 1; next } f && /^## / { exit } f { print }' "$REPO/CHANGELOG.md")
  [ "$moved" = "$body_before" ]

  # Previously released sections are untouched, from their old top heading down.
  prev_head=$(printf '%s\n' "$released_before" | head -1)
  [ "$(awk -v h="$prev_head" '$0 == h { f = 1 } f { print }' "$REPO/CHANGELOG.md")" \
    = "$released_before" ]
}

@test "release: leaves check-release-consistency.sh passing" {
  release "$NEXT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: man pages, .TH versions, and lib list are all in sync"* ]]

  run bash "$REPO/scripts/check-release-consistency.sh"
  [ "$status" -eq 0 ]
}

@test "release: prints the tag/push/gh steps without running them" {
  release "$NEXT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"chore: release $NEXT"* ]]
  [[ "$output" == *"git tag v$NEXT"* ]]
  # Nothing was committed or tagged on our behalf.
  [ -n "$(git -C "$REPO" status --porcelain)" ]
  [ -z "$(git -C "$REPO" tag -l)" ]
}

@test "release: touches exactly the release-synchronized files" {
  release "$NEXT"
  [ "$status" -eq 0 ]
  changed=$(git -C "$REPO" status --porcelain | awk '{print $2}' | sort)
  expected=$( { printf 'CHANGELOG.md\ndbx\n'
                for f in "$REPO"/man/man1/*.1; do echo "man/man1/$(basename "$f")"; done
              } | sort)
  [ "$changed" = "$expected" ]
}

# ----------------------------------------------------------------------------
# check-release-consistency.sh still catches drift after the refactor
# ----------------------------------------------------------------------------

@test "check-release-consistency: fails when one .TH version drifts" {
  awk 'NR == 1 { gsub(/dbx [0-9.]+/, "dbx 0.1.0") } { print }' \
    "$REPO/man/man1/dbx-clean.1" > "$REPO/man/man1/dbx-clean.new"
  mv "$REPO/man/man1/dbx-clean.new" "$REPO/man/man1/dbx-clean.1"

  run bash "$REPO/scripts/check-release-consistency.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dbx-clean.1"* ]]
}

@test "check-release-consistency: fails when a man page is missing from MAN_PAGES" {
  cp "$REPO/man/man1/dbx-clean.1" "$REPO/man/man1/dbx-newcmd.1"
  run bash "$REPO/scripts/check-release-consistency.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dbx-newcmd.1"* ]]
}
