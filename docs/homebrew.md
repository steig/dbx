# Homebrew

```bash
brew tap steig/dbx https://github.com/steig/dbx
brew install dbx
```

The second argument to `brew tap` is not optional. `brew tap steig/dbx` on its
own looks for a repository called `steig/homebrew-dbx`, and there isn't one —
the formula lives in the dbx repository itself. Giving the URL explicitly taps
that repository directly, and Homebrew finds `Formula/dbx.rb` inside it.

Upgrade and remove with the usual commands:

```bash
brew upgrade dbx
brew uninstall dbx
```

!!! warning "Don't run `dbx update` on a Homebrew install"

    `dbx update` re-runs the `curl | bash` installer, which writes to
    `~/.local/bin` and `~/.local/lib/dbx`. On a Homebrew install that leaves a
    second, unmanaged copy of dbx on your machine, and which one you get depends
    on your `PATH` order. Use `brew upgrade dbx`.

Removing dbx does not remove your config (`~/.config/dbx`) or your backups. See
[Uninstall](install.md#uninstall) for those, and remove any
`dbx schedule` jobs *before* uninstalling — otherwise the launchd agents keep
firing against a binary that is gone.

## What it installs

| Path | Contents |
|------|----------|
| `$(brew --prefix)/bin/dbx` | Two-line wrapper that execs the launcher |
| `$(brew --prefix)/libexec/dbx` | The launcher itself |
| `$(brew --prefix)/libexec/lib/` | The 14 library modules, wizard HTML, `wizard-server.py` |
| `$(brew --prefix)/share/man/man1/` | All 19 man pages — `man dbx` works immediately |
| `.../etc/bash_completion.d/dbx`, `.../share/zsh/site-functions/_dbx`, `.../share/fish/vendor_completions.d/dbx.fish` | Shell completions |

The launcher and `lib/` have to stay siblings — dbx resolves its libraries as
`$(dirname "$0")/lib` — so both go under `libexec` and `bin/dbx` is a wrapper
that execs the real path. A symlink would not work: `dirname` of a symlink is
the directory holding the *link*, so the launcher would look for its libraries
in `bin/lib`. The upside of the wrapper is that the formula patches nothing —
every shipped byte is exactly what the release tarball contained.

Unlike `install.sh`, nothing needs adding to `PATH` or `MANPATH`; Homebrew's
prefix is already on both.

## Dependencies

The formula depends on `jq` and `zstd` and nothing else.

**Docker is not a dependency, and you still need it.** dbx runs
`pg_dump`/`mysqldump` inside containers. Homebrew's `docker` is a cask (Docker
Desktop), but Colima, OrbStack, Podman and Rancher Desktop serve dbx equally
well, so the formula does not choose for you. Install one before your first
backup.

Everything else is optional and each tool gates one feature — `age` or `gnupg`
for encryption, `gum` for the interactive wizards, `minio-mc` or `awscli` for
S3 offload, `fzf` for the interactive backup picker, `pv` for MySQL restore
progress. `brew info dbx` prints the list. The full table is under
[Requirements](install.md#requirements).

## Integrity

Homebrew verifies the `sha256` of the release tarball before it unpacks
anything, so the per-file `SHASUMS256.txt` that `install.sh` uses is redundant
here: one digest over the whole archive is strictly stronger than 47 digests
over its contents, and it covers the manifest too. It has the same limit as
`SHASUMS256.txt` — it proves the bytes arrived intact, not who produced them.
See [Integrity verification](install.md#integrity-verification) for what that
does and does not buy you.

## For maintainers

### Why the formula is in this repository

Homebrew's convention is a separate `homebrew-<name>` repository, which buys a
shorter tap command (`brew tap steig/dbx`) and costs a second place the version
lives. dbx has already paid for that mistake once: `dbx-build-image.1` shipped
with a stale version because a hand-maintained list drifted from the files it
described (#122), which is why `scripts/check-release-consistency.sh` exists.

Keeping the formula in-tree means the same drift guard checks it, the same CI
runs against it, and `scripts/update-formula.sh` sits beside
`scripts/release.sh`. The price is one extra argument at tap time. If a
`steig/homebrew-dbx` repository is ever created, `Formula/dbx.rb` can be copied
into it unchanged — but it should be a mirror, not a second source of truth.

### Why the formula always lags one release

A formula pins the sha256 of its own tag's source tarball. That tarball
*contains the formula* — so a formula stating the digest of the archive it is
part of has no fixed point, and the release commit cannot bump it.

It doesn't need to. Homebrew reads formulae from the tap's default branch, never
from a tag, so a formula on `main` naming the newest pushed tag is exactly
right. It is repointed immediately after the tag is pushed:

```bash
scripts/release.sh minor                 # bumps VERSION, man pages, CHANGELOG
git commit -am "chore: release X.Y.Z"
git tag vX.Y.Z
git push && git push --tags              # the tag must exist first

scripts/update-formula.sh                # downloads the tarball, writes the digest
git commit -am "chore(homebrew): dbx X.Y.Z"
git push
```

`scripts/update-formula.sh` takes the digest from the tarball GitHub actually
serves. Never type one in by hand.

Until that second commit lands, `brew install` gives the previous release. That
window is minutes, and a formula pointing at the last good tag is a much better
failure mode than one pointing at a digest that doesn't exist.

### What keeps it correct

Two checks, split by what they can see:

- **`scripts/check-release-consistency.sh` (check 6, offline, every PR)** —
  the pinned tag has a `CHANGELOG.md` release heading, so it names a release
  that was actually cut rather than one someone typed; and the `sha256` is 64
  hex characters, so a placeholder can't ship. It deliberately does *not*
  require the formula to equal `VERSION`, which would fail on every release
  commit.
- **`scripts/update-formula.sh --check` (needs the network)** — re-downloads
  the pinned tarball and compares digests. This is the one that catches a wrong
  digest, and a wrong digest means every `brew install` of the tap fails.
  `.github/workflows/formula.yml` runs it whenever the formula changes and once
  a week besides, and also runs `brew install` + `brew test` on a macOS runner.

### Before publishing the tap

`brew audit` and `brew style` enforce Homebrew's own conventions and are not run
by CI, because much of `--strict` targets homebrew-core submissions rather than
third-party taps. Run them once by hand on a machine with a normal Homebrew:

```bash
brew tap steig/dbx https://github.com/steig/dbx
brew audit --strict --online steig/dbx/dbx
brew style steig/dbx/dbx
brew install --build-from-source steig/dbx/dbx
brew test steig/dbx/dbx
```
