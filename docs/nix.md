# Nix

dbx ships a flake. It provides two things: a **package** you can run or install
without touching your `PATH` by hand, and a **devShell** carrying the exact
toolchain CI uses.

Requires Nix 2.4+ with flakes enabled (`experimental-features = nix-command flakes`).

## Run it without installing

```bash
nix run github:steig/dbx -- version
nix run github:steig/dbx -- backup prod
```

## Install it

```bash
nix profile install github:steig/dbx
```

This is an alternative to `install.sh` and to Homebrew — pick one. A Nix install
puts `dbx`, the 19 man pages, and bash/zsh/fish completions in your profile.

In a NixOS or nix-darwin configuration:

```nix
{
  inputs.dbx.url = "github:steig/dbx";

  # in your system module:
  environment.systemPackages = [ inputs.dbx.packages.${pkgs.system}.default ];
}
```

Supported systems: `aarch64-darwin` (Apple silicon), `aarch64-linux`,
`x86_64-linux`.

**Intel macOS is not covered.** nixpkgs 26.11 dropped `x86_64-darwin`, so the
flake does not offer it — listing a system whose nixpkgs throws would break
`nix flake show --all-systems` for everyone. On an Intel Mac use `install.sh` or
Homebrew.

## You still need Docker

dbx runs `pg_dump`/`mysqldump` inside containers, so it needs a Docker daemon and
a `docker` client that can talk to it. **The flake does not provide either.** A
daemon can't be vendored into a package, and a client pinned by dbx would fight
the one your Docker Desktop, colima, or podman setup already installs. Install
Docker the way you normally would; dbx finds it on your `PATH`.

Everything else dbx shells out to *is* wrapped into the package's `PATH`, so a
`nix run` on a bare machine behaves the same as on a fully provisioned one:

| Wrapped in | Why |
|------------|-----|
| `jq` | config is JSON — used on every code path |
| `zstd` | backup compression |
| `curl` | notifier webhooks, release lookups |
| `ssh` | tunnelled/remote hosts |
| `gpg`, `age` | [encryption](encryption.md) backends |
| `openssl` | wizard session tokens |
| `gum`, `fzf` | the interactive wizards hard-fail without them |
| `pv` | restore progress |
| `python3` | the browser [wizard](wizards.md) server |
| `secret-tool`, `xdg-open` (Linux only) | keyring [credential storage](credentials.md) and browser launch |

Two things are deliberately left out besides Docker:

- **`mc` / `aws`** — [cloud storage](storage.md) is opt-in, either client
  satisfies it, and both are large. Install whichever you use.
- **desktop notifiers** (`terminal-notifier`, `notify-send`) — environment
  specific; [notifications](notifications.md) fall back to stdout.

## `dbx update` does not apply

`dbx update` re-runs `install.sh`, which writes to `~/.local`. That is the wrong
thing to do to a Nix-managed install, so the package sets
`DBX_NO_UPDATE_CHECK=1` by default and you will not be nagged. Upgrade with Nix
instead:

```bash
nix profile upgrade dbx
```

Set `DBX_NO_UPDATE_CHECK=0` if you want the notice back.

## The dev shell

```bash
nix develop
```

You get `bats`, `parallel` (for `bats -j`), `shellcheck`, `ruff`, `actionlint`,
`just`, `jq`, `zstd`, `age`, `gnupg`, `mc`, `curl` and `python3` — everything
[`.github/workflows/ci.yml`](https://github.com/steig/dbx/blob/main/.github/workflows/ci.yml)
runs, at one pinned set of versions. Inside it the commands in
[CONTRIBUTING.md](https://github.com/steig/dbx/blob/main/CONTRIBUTING.md) work
directly:

```bash
just lint
bats tests/unit/
bash scripts/check-release-consistency.sh
```

Docker is not in the shell either — `bats tests/integration/` uses your host
daemon.

## Checks

```bash
nix flake check
```

Runs what a build sandbox can actually run:

- `lint` — `shellcheck -S error` plus `bash -n` on `dbx` and every `lib/*.sh`
- `release-consistency` — `scripts/check-release-consistency.sh`
- `package` — builds `dbx` and asserts `dbx version` reports the version read
  out of the launcher

**Neither test suite is a check.** `tests/integration/` boots Postgres and MySQL
in Docker, which a sandbox has no access to. `tests/unit/` writes its `docker`,
`gpg` and `mc` stubs at runtime from `#!/usr/bin/env bash` heredocs, and a
sandbox has no `/usr/bin/env` — 117 of 904 tests fail there for that reason
alone, and `patchShebangs` cannot help because the stubs do not exist until the
tests run. Both suites are green in `nix develop`; run them there.

## Version and the lock file

The package version is read out of the `VERSION=` line in the `dbx` launcher at
evaluation time. `flake.nix` is not a file releases have to bump, and it cannot
drift out of sync with the 21 files
[`scripts/check-release-consistency.sh`](https://github.com/steig/dbx/blob/main/scripts/check-release-consistency.sh)
guards.

`flake.lock` is committed, so `nix develop` gives every contributor the same
`bats` and `shellcheck` — which is the point of having it. Refresh it
deliberately:

```bash
nix flake update
```
