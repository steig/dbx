# Contributing to dbx

Thanks for your interest in improving dbx! This is a pure Bash CLI for database
backup and restore — no build step, no compiled artifacts. This guide is the
human on-ramp; [`AGENTS.md`](AGENTS.md) holds the deeper conventions, error-handling
patterns, and the cross-platform gotchas the test suite enforces.

## Prerequisites

dbx itself runs the database tooling inside Docker, so you don't need a local
Postgres or MySQL install. For development you do need:

- **bash** (the script targets bash 3.2+ for macOS compatibility)
- **[shellcheck](https://www.shellcheck.net/)** — the lint gate
- **[bats-core](https://github.com/bats-core/bats-core)** — the test runner
  (`brew install bats-core` on macOS, `sudo apt install bats` on Debian/Ubuntu)
- **jq** — config is JSON; dbx and the tests use jq throughout
- **docker** — only for the integration tests (they boot real Postgres + MySQL)
- Optional, for the encryption tests: **age**, **gpg**, **zstd**. Tests that
  need an absent binary `skip` cleanly.

## Running the checks locally

Run these before opening a PR — they mirror CI (`.github/workflows/ci.yml`).

```bash
# 1. Lint — CI runs shellcheck with severity=error
shellcheck -S error dbx lib/*.sh

# 2. Syntax check
bash -n dbx && for f in lib/*.sh; do bash -n "$f"; done

# 3. Unit tests — pure functions, no docker, ~1s
bats tests/unit/

# 4. Integration tests — boots postgres-dbx + mysql-dbx, ~30s, needs docker
bats tests/integration/

# 5. Release consistency — man pages, .TH versions, and install.sh's file lists
bash scripts/check-release-consistency.sh

# Full sweep
bats tests/unit/ tests/integration/
```

See [`tests/README.md`](tests/README.md) for the test layout, how to run a
single test, and a debugging guide.

## CI gate

Pull requests to `main` must pass CI before merge. It runs on an
ubuntu + macOS matrix and checks:

1. **Shellcheck** (severity: error) on `dbx` and all `lib/*.sh`
2. **Bash syntax** (`bash -n`) on every script
3. **Test Install** — runs `install.sh` and verifies `dbx help` works
4. **Release consistency** — `scripts/check-release-consistency.sh`
5. **Ruff** — lints the Python under `lib/`
6. **Unit tests** (bats) — ubuntu + macOS
7. **Integration tests** (docker) — ubuntu only
8. **Container image** — builds `docker/Dockerfile` and smoke-tests it

## Commit and PR conventions

- **Conventional Commits.** Commit messages and PR titles follow
  `type(scope): summary`, e.g. `feat(schedule): mirror schedule add/remove`,
  `fix(restore): verify backup checksum before import`, `docs: add SECURITY.md`.
  Common types in this repo: `feat`, `fix`, `docs`, `chore`, `ci`, `refactor`.
- **Keep PRs focused.** One logical change per PR; it makes review and the
  changelog easier.
- **Update [`CHANGELOG.md`](CHANGELOG.md)** under `## [Unreleased]` when your
  change is user-facing (new flag, behavior change, fix users would notice).
- **Update the docs** under `docs/` (and `mkdocs.yml`'s `nav:`) when you add or
  change a public command or page. Internal design notes go in `docs/plans/`,
  which is excluded from the published site.
- **Add or update tests** for the behavior you change.

## Adding a command or library

`AGENTS.md` has step-by-step checklists for [adding a new command](AGENTS.md#adding-a-new-command),
[a new library module](AGENTS.md#adding-a-new-library-module), and
[a test](AGENTS.md#adding-a-test). The short version: register the command in
`dbx`'s dispatcher and help output, prefix module helpers with the module name,
add the new file to `install.sh`, and wire it into the test helpers.

## Cutting a release (maintainers)

A release is one commit that bumps every version-carrying file at once — 21 of
them. Don't hand-edit them; `scripts/release.sh` does the whole pass:

```bash
scripts/release.sh --dry-run minor   # review the diff first
scripts/release.sh minor             # or major | patch | an explicit 0.39.0
```

It rewrites `VERSION` in `dbx`, the `.TH` line (version **and** date) of every
`man/man1/*.1`, and moves `CHANGELOG.md`'s `## [Unreleased]` section under a new
`## [X.Y.Z] - YYYY-MM-DD` heading, leaving a fresh empty `[Unreleased]` behind.
It refuses to run on a dirty tree, on a version that isn't newer than the current
one, or when `[Unreleased]` is empty, and it finishes by running
`scripts/check-release-consistency.sh` — the same drift guard CI runs. The script
takes its file list from that guard, so the bump and the check can't disagree.

Publishing stays manual; the script prints these when it's done:

```bash
git commit -am "chore: release X.Y.Z"
git tag vX.Y.Z
git push && git push --tags   # the tag fires release-image.yml → GHCR image
gh release create vX.Y.Z --title "vX.Y.Z" --notes "<the new CHANGELOG section>"
```

Deliberately *not* bumped: `install.sh`'s `MAN_PAGES` and lib lists (curated
order — the guard checks them as sets on every PR but never regenerates them),
the `:latest` tags under `docker/`, and the illustrative version strings in
`docs/` and `README.md`.

## Reporting bugs and security issues

- **Bugs and docs:** open an issue using the templates under
  [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/).
- **Security vulnerabilities:** do **not** open a public issue — follow the
  private disclosure process in [`.github/SECURITY.md`](.github/SECURITY.md).

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By
participating you agree to uphold it.
