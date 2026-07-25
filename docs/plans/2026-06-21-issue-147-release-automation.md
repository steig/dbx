# Automate the release process

**Issue:** #147  
**Status:** Plan (verdict: sound). Recommended: `scripts/release.sh` + CI drift-guard; reject release-please.  
**Generated:** 2026-06-21 via multi-agent investigate→verify→synthesize workflow.

## Root cause

A dbx release is fully manual with no version-bump automation. There are TWO distinct failure surfaces that the draft initially conflated; they must be kept separate.

SURFACE 1 — version bump (happens EVERY release): a release is a single commit ("chore: release X.Y.Z") that hand-edits exactly 21 files. Confirmed by `git show --stat 1c4f876` (0.37.0) and `b0bafef` (0.36.0), both "21 files changed":
  - dbx:7 — `VERSION="0.37.0"` (single source of truth; `dbx version` at dbx:3279 echoes it; the Dockerfile has NO hardcoded version, and release-image.yml derives the version from the git tag).
  - 19 man pages man/man1/*.1 — line 1 `.TH NAME 1 "DATE" "dbx VERSION" "User Commands"` (e.g. `.TH DBX 1 "2026-06-20" "dbx 0.37.0" ...`). BOTH the version token and the date are hand-typed. Nothing validates that all 19 `.TH` strings agree with dbx:7.
  - CHANGELOG.md — move items from `## [Unreleased]` (line 5) into a new `## [X.Y.Z] - DATE` section (Keep a Changelog + SemVer). Entries are hand-curated paragraph-length prose with PR refs.
  Then `git tag vX.Y.Z`, `git push --tags` (auto-fires release-image.yml to build/push the GHCR container), and `gh release create` with notes that mirror the CHANGELOG section. install.sh is NOT touched in a routine version bump (verified: neither 0.36.0 nor 0.37.0 commits modify install.sh).
  Why it desyncs: 21 hand-synchronized edits per release; trivial to miss a man page or fat-finger the date/version, with zero validation.

SURFACE 2 — command/library drift (happens on feature PRs, NOT at release time): install.sh carries TWO hand-maintained parallel lists that cannot glob the repo because they curl files by name from GitHub raw: MAN_PAGES (install.sh:22-42, 19 entries, comment at :19-21 admits "Kept in sync by hand") and the lib/*.sh list (install.sh:111-112, 14 files matching `ls lib/*.sh`). When a command or lib is added/removed, these drift. The dbx-build-image.1 casualty (fixed in #122) was a MAN_PAGES omission. Root enabler is an AGENTS.md process asymmetry: "Adding a New Library Module" (AGENTS.md step 4) says update install.sh, but "Adding a New Command" (steps 1-5) never mentions adding the man page to MAN_PAGES.

NOTE: issue #147 says "18 man pages"; the actual count is 19 (`ls man/man1` = 19, all present in MAN_PAGES, currently in sync). Use 19 in any PR description; the issue's numbers are stale.

## Proposed fix

RECOMMENDATION: Option (a) — a scripts/release.sh one-pass rewriter+validator, paired with a CI drift-guard. Do NOT adopt release-please.

Rationale (verified against the repo):
- dbx is a single shell script distributed via `curl | bash` (install.sh), not a registry package. There is no package.json/Cargo.toml/manifest release-please understands; the version is a bash string (dbx:7) plus 19 roff `.TH` lines. release-please has no native updater for `.TH` lines or a bash VERSION var — you'd hand-write `extra-files` + generic-string config + custom regex, i.e. reimplement the rewriter inside release-please's manifest, plus add release-please-config.json, .release-please-manifest.json, a bot PR workflow, and a GitHub App/PAT. More moving parts for a repo that releases as one clean commit by one maintainer.
- release-please's value (auto-derive version + changelog from Conventional Commits, open a release PR) is wasted here: the CHANGELOG is hand-curated paragraph prose with PR refs (verified CHANGELOG.md:11) that release-please would fight. The maintainer clearly wants to write notes by hand.
- The real pain is mechanical (21 synchronized edits) plus the install.sh drift class. A script solves the mechanical part; a CI check solves drift. Reject release-please.

CRITICAL CORRECTION from critique (verified): MAN_PAGES in install.sh is in CURATED, NON-alphabetical order (dbx.1, dbx-backup.1, dbx-restore.1, dbx-verify.1, ...), NOT sorted. Do NOT regenerate it sorted — that would reorder all 19 entries (spurious diff + changed fetch order). The CI guard must be a SET comparison (order-insensitive). release.sh should NOT touch MAN_PAGES on a normal version bump at all (install.sh is not a per-release file); instead MAN_PAGES sync is enforced by the CI drift-guard on every PR.

What scripts/release.sh does (one pass, idempotent, validate-then-write; portable bash for macOS bash 3.2 / BSD sed):
1. Take target version as $1 (`scripts/release.sh 0.38.0`); validate SemVer; assert > current dbx:7 VERSION; assert clean tree and on main.
2. Rewrite VERSION at dbx:7.
3. Rewrite every man/man1/*.1 `.TH` line — substitute BOTH the `dbx X.Y.Z` token and the date (`date +%F`) — looping over `man/man1/*.1` from the filesystem (not a hardcoded list).
4. CHANGELOG: rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`, insert a fresh empty `## [Unreleased]` above; abort if Unreleased was empty.
5. VALIDATE pass: assert all 19 `.TH` version tokens == dbx:7 == new CHANGELOG heading; assert the install.sh MAN_PAGES SET == `ls man/man1` set (set comparison, NOT regen). Fail loudly on any mismatch.
6. Print (do NOT execute) the follow-up commands: commit "chore: release X.Y.Z", `git tag vX.Y.Z`, `git push --tags`, `gh release create`. Keep irreversible network steps in the maintainer's hands (matches current discipline; tag push auto-fires release-image.yml).

PLUS a CI drift-guard job in ci.yml (cheap, runs every PR, targets SURFACE 2 — the real recurring bug class):
- Fail if the SET of man/man1/*.1 basenames != install.sh MAN_PAGES (order-insensitive).
- Fail if any `.TH` version token != dbx:7 VERSION.
- Optionally also compare install.sh lib list vs `ls lib/*.sh` (14 files) — same drift class, check-only (do not auto-regen; wizard-server.py/wizard-form.html are fetched separately at install.sh:119-124).
This guard is the HIGHEST-VALUE, LOWEST-COST piece and should ship even if release.sh slips.

SHASUMS256 (issue #147 deliverable): explicitly DEFER and surface as a decision in the PR description, not just an open question — dbx ships as curl|bash source, not a binary, so there is no checksum artifact today. Note this so #147 is consciously, not silently, partially addressed.

## Affected locations

- /Users/tom.steig/code/dbx/dbx (line 7: VERSION="0.37.0"; line 3279: `echo "dbx $VERSION"`)
- /Users/tom.steig/code/dbx/man/man1/dbx.1 (.TH line 1)
- /Users/tom.steig/code/dbx/man/man1/dbx-analyze.1
- /Users/tom.steig/code/dbx/man/man1/dbx-backup.1
- /Users/tom.steig/code/dbx/man/man1/dbx-build-image.1
- /Users/tom.steig/code/dbx/man/man1/dbx-clean.1
- /Users/tom.steig/code/dbx/man/man1/dbx-completion.1
- /Users/tom.steig/code/dbx/man/man1/dbx-config.1
- /Users/tom.steig/code/dbx/man/man1/dbx-containers.1
- /Users/tom.steig/code/dbx/man/man1/dbx-host.1
- /Users/tom.steig/code/dbx/man/man1/dbx-list.1
- /Users/tom.steig/code/dbx/man/man1/dbx-query.1
- /Users/tom.steig/code/dbx/man/man1/dbx-restore.1
- /Users/tom.steig/code/dbx/man/man1/dbx-schedule.1
- /Users/tom.steig/code/dbx/man/man1/dbx-scrub.1
- /Users/tom.steig/code/dbx/man/man1/dbx-storage.1
- /Users/tom.steig/code/dbx/man/man1/dbx-test.1
- /Users/tom.steig/code/dbx/man/man1/dbx-vault.1
- /Users/tom.steig/code/dbx/man/man1/dbx-verify.1
- /Users/tom.steig/code/dbx/man/man1/dbx-wizard.1
- /Users/tom.steig/code/dbx/CHANGELOG.md (Unreleased section at line 5)
- /Users/tom.steig/code/dbx/install.sh (MAN_PAGES at lines 22-42, curated NON-alphabetical order; lib/*.sh list at lines 111-112) — drift surface, NOT a per-release edit
- /Users/tom.steig/code/dbx/.github/workflows/release-image.yml (on push tags ['v*'], derives version from tag — already wired, no edit)
- /Users/tom.steig/code/dbx/.github/workflows/ci.yml (add release-consistency job; existing portable `sed -i.bak || sed -i ''` at line 54; bats on ubuntu+macos at lines 100-118)
- /Users/tom.steig/code/dbx/AGENTS.md ('Adding a New Command' steps 1-5 vs 'Adding a New Library Module' step 4 — the asymmetry enabling MAN_PAGES drift)
- /Users/tom.steig/code/dbx/scripts/release.sh (does NOT exist yet — to be created)
- /Users/tom.steig/code/dbx/tests/unit/release.bats (does NOT exist yet — to be created)
- /Users/tom.steig/code/dbx/CONTRIBUTING.md (document scripts/release.sh as THE release procedure)
- OUT OF SCOPE / intentionally NOT synced (do not edit, do not add to sync list): /Users/tom.steig/code/dbx/docs/container.md (lines 8,63,116 illustrative :0.36.0 examples); /Users/tom.steig/code/dbx/docker/docker-compose.yml (ghcr.io/steig/dbx:latest, intentionally unpinned); /Users/tom.steig/code/dbx/README.md:544-545 (stale `dbx 0.33.0` example output — illustrative, already stale, leave alone); /Users/tom.steig/code/dbx/README.md:7 (dynamic shields.io `github/v/release` badge — auto-updates from GitHub release)

## Steps

- Create scripts/release.sh (bash, set -euo pipefail) taking target version as $1; guards: SemVer-valid, > current dbx:7 VERSION, clean working tree, on main branch.
- In release.sh: rewrite VERSION at dbx:7; loop `man/man1/*.1` and rewrite each .TH line's `dbx X.Y.Z` token AND date to `$(date +%F)`; rename CHANGELOG `## [Unreleased]` to `## [X.Y.Z] - $(date +%F)` and re-insert an empty Unreleased above; abort if Unreleased was empty. Use portable in-place editing (write-to-temp-then-mv, or `sed -i.bak || sed -i ''` like ci.yml:54) — no GNU-isms, no `${var//PAT/REP}` (bash 3.2 quirk).
- In release.sh: add a final VALIDATE pass — assert all 19 .TH version tokens == dbx:7 == CHANGELOG heading, and that install.sh MAN_PAGES SET == `ls man/man1` set (set comparison, NOT regeneration; preserve curated order). Exit non-zero on any mismatch. Print (do NOT execute) the commit + `git tag vX.Y.Z` + `git push --tags` + `gh release create` commands.
- Add a `release-consistency` job to .github/workflows/ci.yml: (a) SET-diff `ls man/man1` basenames against install.sh MAN_PAGES (order-insensitive); (b) assert every .TH version token == dbx:7 VERSION; (c) optionally SET-diff install.sh lib list against `ls lib/*.sh`. Fail red on drift. Runs on every PR — this is the primary fix for SURFACE 2 and should ship first.
- Add tests/unit/release.bats: copy dbx + man/man1 + CHANGELOG + install.sh into a temp dir, run release.sh, assert (1) dbx VERSION updated, (2) every .TH has new version + today's date, (3) CHANGELOG has new dated section + fresh empty Unreleased, (4) MAN_PAGES set == ls man/man1, (5) validate pass exits 0; plus a NEGATIVE test that tampers one .TH and asserts validate exits non-zero. Must run on macos-latest too (bash 3.2 / BSD sed), matching ci.yml bats matrix.
- Patch AGENTS.md 'Adding a New Command' (steps 1-5) to add: 'add the man page filename to install.sh MAN_PAGES + add/extend a unit test' — closing the asymmetry vs 'Adding a New Library Module' step 4 that caused the dbx-build-image.1 omission.
- Update CONTRIBUTING.md / AGENTS.md to document `scripts/release.sh X.Y.Z` as THE release procedure, replacing the manual 21-file edit, with the manual tag/push/gh-release as the explicit final step.
- In the PR description: (a) use 19 man pages, not 18; (b) explicitly DEFER SHASUMS256 as a conscious decision (dbx is curl|bash source, not a binary); (c) list the intentionally-not-synced files (docs/container.md examples, docker-compose :latest, README.md:544 example output, README dynamic release badge) so a future contributor doesn't mistake any for a sync target.

## Risks

bash 3.2 on macOS: release.sh and all sed/awk must avoid GNU-isms and the `${var//PAT/REP}` quirk (repo memory: macOS system bash differs from nix bash; macos-latest unit-test CI catches it). Use portable in-place editing (write-temp-then-mv, or `sed -i.bak || sed -i ''` as ci.yml:54 already does) and run the bats test on macos-latest. The CHANGELOG section rename must anchor to the exact `## [Unreleased]` heading to avoid mangling the curated prose. MAN_PAGES is curated NON-alphabetical order: the validate/CI step must be a SET comparison, never a sorted regeneration, or it will reorder all 19 entries and change install fetch order. The MAN_PAGES set check could mask a genuinely intended man-page omission — none exists today; document the assumption. release.sh deliberately does NOT push the tag, so a maintainer skipping that step yields a bumped-but-unreleased main; the printed instructions mitigate. Blast radius is low: read-mostly tooling, no runtime/production code path touched, container build already automated on tag.

## Test strategy

Primary signal is bats (`nix shell nixpkgs#bats --command bats tests/unit/`, also wired in ci.yml:100-118 on ubuntu+macos). Add tests/unit/release.bats that copies dbx + man/man1 + CHANGELOG + install.sh into a temp dir, runs release.sh, and asserts: (1) dbx VERSION updated; (2) every .TH carries the new version AND today's date; (3) CHANGELOG has the new dated section + fresh empty Unreleased; (4) MAN_PAGES set == ls man/man1; (5) validate pass exits 0. Add a NEGATIVE test: tamper one .TH and assert validate exits non-zero. MUST run on macos-latest (bash 3.2 / BSD sed). For the CI drift-guard: test by removing one MAN_PAGES entry on a scratch branch and confirming the job goes red. Manual dry-run: `scripts/release.sh 0.38.0` on a throwaway branch — `git diff` should match the shape of `git show 1c4f876` (21 files: dbx + 19 man + CHANGELOG), then `git checkout .`. No DB/docker needed.

## Effort

S (script path), confirmed. Issue labels S (script) / M (release-please); I concur. The recommended script + CI guard is Small — roughly half a day: scripts/release.sh ~80-120 lines portable bash; ci.yml release-consistency job ~15-25 lines YAML; one bats test file; small AGENTS.md/CONTRIBUTING.md edits. The CI drift-guard ALONE is ~1 hour and delivers most of the desync protection (SURFACE 2) — ship it first even if release.sh slips. release-please (Option b) would be M-to-L here due to custom .TH/bash-VERSION updaters, manifest+config files, and bot PR workflow + auth — more work for a worse fit.

## Open questions

- Should release.sh auto-run `git tag` / `git push --tags` / `gh release create`, or stop after file edits and print the commands? Recommendation: stop (keep irreversible network steps manual, matching current practice; tag push auto-fires release-image.yml). Confirm maintainer agrees.
- Release notes: keep hand-authored notes mirroring the CHANGELOG section (current practice), or have release.sh seed `gh release create --notes-file` from the just-cut CHANGELOG section? Latter removes a copy-paste step but needs maintainer to accept generated notes.
- SHASUMS256 (issue #147 deliverable): recommend explicit DEFER — dbx is curl|bash source, not a binary, so there's no checksum artifact today. Surface this as a decision in the PR, not a silent omission, so #147 is consciously scoped. Confirm a checksums file is genuinely wanted; if so, over what (the dbx script + lib tarball)? Out of scope for the core fix.
- Should the CI drift-guard also cover the install.sh lib/*.sh list (line 111, 14 files)? Recommend check-only (SET comparison), not auto-regen, given wizard-server.py / wizard-form.html are fetched separately (install.sh:119-124).
- Confirm the man-page count is 19 today (not 18 as issue #147 states); use 19 in the plan/PR to avoid re-introducing the stale number.
