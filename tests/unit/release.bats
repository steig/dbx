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
  mkdir -p "$REPO/man/man1" "$REPO/scripts" "$REPO/lib" "$REPO/Formula"
  cp "$DBX_REPO_ROOT/dbx" "$REPO/dbx"
  cp "$DBX_REPO_ROOT/CHANGELOG.md" "$DBX_REPO_ROOT/install.sh" \
     "$DBX_REPO_ROOT/SHASUMS256.txt" "$REPO/"
  seed_unreleased
  cp "$DBX_REPO_ROOT"/man/man1/*.1 "$REPO/man/man1/"
  # The whole payload, not just the libs: SHASUMS256.txt covers every file
  # install.sh downloads, and the drift guard rehashes all of them.
  cp "$DBX_REPO_ROOT"/lib/*.sh "$DBX_REPO_ROOT"/lib/*.html \
     "$DBX_REPO_ROOT/lib/wizard-server.py" "$REPO/lib/"
  cp "$DBX_REPO_ROOT"/scripts/*.sh "$REPO/scripts/"
  # The drift guard's check 6 reads the Homebrew formula, so the fixture needs
  # one — an absent formula is itself a drift the guard reports.
  cp "$DBX_REPO_ROOT/Formula/dbx.rb" "$REPO/Formula/dbx.rb"
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
  [[ "$output" == *"OK: man pages, .TH versions, install.sh's file lists, and SHASUMS256.txt are all in sync"* ]]

  run bash "$REPO/scripts/check-release-consistency.sh"
  [ "$status" -eq 0 ]
}

@test "release: regenerates SHASUMS256.txt over the bumped files" {
  before=$(grep '  dbx$' "$REPO/SHASUMS256.txt")

  release "$NEXT"
  [ "$status" -eq 0 ]

  # The launcher and every man page changed, so their digests must have too.
  [ "$(grep '  dbx$' "$REPO/SHASUMS256.txt")" != "$before" ]
  run bash -c "cd '$REPO' && shasum -a 256 -c SHASUMS256.txt >/dev/null 2>&1 ||
               sha256sum -c SHASUMS256.txt >/dev/null 2>&1"
  [ "$status" -eq 0 ]
}

@test "release: --dry-run previews the SHASUMS256.txt rewrite without writing it" {
  before=$(cat "$REPO/SHASUMS256.txt")
  release --dry-run "$NEXT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHASUMS256.txt (after)"* ]]
  [ "$(cat "$REPO/SHASUMS256.txt")" = "$before" ]
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
  expected=$( { printf 'CHANGELOG.md\nSHASUMS256.txt\ndbx\n'
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

@test "check-release-consistency: fails when a shipped file changes without regenerating SHASUMS256.txt" {
  echo "# edited" >> "$REPO/lib/notify.sh"
  run bash "$REPO/scripts/check-release-consistency.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SHASUMS256.txt is stale"* ]]
  [[ "$output" == *"lib/notify.sh"* ]]
}

@test "check-release-consistency: fails when SHASUMS256.txt is missing" {
  rm "$REPO/SHASUMS256.txt"
  run bash "$REPO/scripts/check-release-consistency.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SHASUMS256.txt is missing"* ]]
}

@test "gen-shasums: rewrites the manifest for the tree it runs in" {
  echo "# edited" >> "$REPO/lib/notify.sh"
  run bash "$REPO/scripts/gen-shasums.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wrote SHASUMS256.txt"* ]]

  run bash "$REPO/scripts/check-release-consistency.sh"
  [ "$status" -eq 0 ]
}

# ----------------------------------------------------------------------------
# Homebrew formula — check 6 and scripts/update-formula.sh
#
# The formula pins the sha256 of its own tag's source tarball, so it can never
# name the version being cut (the tarball contains the formula; there is no
# fixed point). It lags by one release and is repointed post-tag. These tests
# pin that asymmetry down, because the obvious "== VERSION" assumption would
# turn every release commit red.
# ----------------------------------------------------------------------------

formula() { echo "$REPO/Formula/dbx.rb"; }
formula_version() {
  grep -E '^[[:space:]]*url "' "$(formula)" |
    grep -oE '/v[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' | head -1 |
    awk '{ sub(/^\/v/, ""); sub(/\.tar\.gz$/, ""); print }'
}
formula_sha() { grep -E '^[[:space:]]*sha256 "' "$(formula)" | head -1 | cut -d'"' -f2; }

# Rewrite the formula through awk. Args are passed to awk verbatim, so `-v`
# assignments can precede the program.
edit_formula() {
  awk "$@" "$(formula)" > "$(formula).new"
  mv "$(formula).new" "$(formula)"
}

# A `curl` earlier on PATH that ignores the URL and writes fixed bytes to -o.
# update-formula.sh's only network call is the tarball download, so this makes
# the digest it computes deterministic and the test offline.
stub_curl() {
  mkdir -p "$REPO/stub"
  cat > "$REPO/stub/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
  [ "$1" = "-o" ] && { out="$2"; shift; }
  shift
done
printf 'fixture tarball\n' > "$out"
EOF
  chmod +x "$REPO/stub/curl"
  PATH="$REPO/stub:$PATH"
}

# The digest of what stub_curl serves, hashed the way the scripts hash.
stub_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf 'fixture tarball\n' | sha256sum | cut -d' ' -f1
  else
    printf 'fixture tarball\n' | shasum -a 256 | cut -d' ' -f1
  fi
}

@test "formula: parses as Ruby" {
  command -v ruby >/dev/null 2>&1 || skip "ruby not installed"
  run ruby -c "$DBX_REPO_ROOT/Formula/dbx.rb"
  [ "$status" -eq 0 ]
}

@test "formula: the checked-in formula pins a released tag (guard is green as committed)" {
  run bash "$REPO/scripts/check-release-consistency.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Formula/dbx.rb: v$(formula_version)"* ]]
}

@test "formula: the guard stays green when the formula lags a fresh release" {
  # The state every release commit is in: VERSION bumped, formula still on the
  # previous tag because the new one has not been pushed yet.
  #
  # Compare the formula against its OWN value from before the bump, not against
  # $CURRENT. $CURRENT is read from the working tree's VERSION in setup(), so
  # asserting formula == $CURRENT quietly requires the formula to be level with
  # VERSION — true at rest, false on a release commit, which is precisely the
  # state this test exists to cover. It made the test fail on the one commit
  # where it mattered.
  local formula_before
  formula_before=$(formula_version)

  release "$NEXT"
  [ "$status" -eq 0 ]
  [ "$(formula_version)" = "$formula_before" ]
  [ "$(dbx_version)" = "$NEXT" ]

  run bash "$REPO/scripts/check-release-consistency.sh"
  [ "$status" -eq 0 ]
}

@test "formula: release.sh does not touch it" {
  before=$(cat "$(formula)")
  release "$NEXT"
  [ "$status" -eq 0 ]
  [ "$(cat "$(formula)")" = "$before" ]
}

@test "check-release-consistency: fails when the formula is missing" {
  rm "$(formula)"
  run bash "$REPO/scripts/check-release-consistency.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Formula/dbx.rb is missing"* ]]
}

@test "check-release-consistency: fails on a placeholder sha256" {
  edit_formula '/^[[:space:]]*sha256 "/ { print "  sha256 \"TODO\""; next } { print }'
  run bash "$REPO/scripts/check-release-consistency.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a 64-character hex digest"* ]]
}

@test "check-release-consistency: fails when the formula pins a tag that was never cut" {
  edit_formula '{ gsub(/\/v[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz/, "/v99.99.99.tar.gz"); print }'
  run bash "$REPO/scripts/check-release-consistency.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"v99.99.99"* ]]
  [[ "$output" == *"never cut"* ]]
}

@test "check-release-consistency: fails when the url is not a tag tarball" {
  edit_formula '/^[[:space:]]*url "/ { print "  url \"https://example.com/dbx.zip\""; next } { print }'
  run bash "$REPO/scripts/check-release-consistency.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not name a vX.Y.Z source tarball"* ]]
}

@test "update-formula: rewrites url and sha256 from the downloaded tarball" {
  stub_curl
  run bash "$REPO/scripts/update-formula.sh" "$NEXT"
  [ "$status" -eq 0 ]
  [ "$(formula_version)" = "$NEXT" ]
  [ "$(formula_sha)" = "$(stub_sha)" ]
  [[ "$(grep -c '^  url "' "$(formula)")" = "1" ]]
}

@test "update-formula: with no argument uses VERSION from dbx" {
  stub_curl
  run bash "$REPO/scripts/update-formula.sh"
  [ "$status" -eq 0 ]
  [ "$(formula_version)" = "$CURRENT" ]
}

@test "update-formula: accepts a leading v and rejects a non-semver version" {
  stub_curl
  run bash "$REPO/scripts/update-formula.sh" "v$NEXT"
  [ "$status" -eq 0 ]
  [ "$(formula_version)" = "$NEXT" ]

  run bash "$REPO/scripts/update-formula.sh" 1.2
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a valid version"* ]]
}

@test "update-formula: leaves the formula parseable and the guard green" {
  command -v ruby >/dev/null 2>&1 || skip "ruby not installed"
  stub_curl
  # A version that exists in the CHANGELOG, so check 6 stays satisfied.
  run bash "$REPO/scripts/update-formula.sh" "$CURRENT"
  [ "$status" -eq 0 ]

  run ruby -c "$(formula)"
  [ "$status" -eq 0 ]

  run bash "$REPO/scripts/check-release-consistency.sh"
  [ "$status" -eq 0 ]
}

@test "update-formula: --check passes when the pinned digest matches" {
  stub_curl
  edit_formula -v s="$(stub_sha)" '/^[[:space:]]*sha256 "/ { print "  sha256 \"" s "\""; next } { print }'
  run bash "$REPO/scripts/update-formula.sh" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: $(stub_sha)"* ]]
}

@test "update-formula: --check fails, loudly, when the pinned digest is wrong" {
  stub_curl
  run bash "$REPO/scripts/update-formula.sh" --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"sha256 mismatch"* ]]
  [[ "$output" == *"Every \`brew install\` of this tap is failing"* ]]
}

@test "update-formula: --check writes nothing" {
  stub_curl
  before=$(cat "$(formula)")
  run bash "$REPO/scripts/update-formula.sh" --check
  [ "$(cat "$(formula)")" = "$before" ]
}

@test "update-formula: argument handling" {
  run bash "$REPO/scripts/update-formula.sh" --check 0.1.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"--check takes no version"* ]]

  run bash "$REPO/scripts/update-formula.sh" --nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]

  run bash "$REPO/scripts/update-formula.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}
