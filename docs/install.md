# Install

```bash
curl -fsSL https://raw.githubusercontent.com/steig/dbx/main/install.sh | bash
```

Or via [Homebrew](homebrew.md) — `brew tap steig/dbx https://github.com/steig/dbx && brew install dbx`.

Or clone:

```bash
git clone https://github.com/steig/dbx.git
export PATH="$PWD/dbx:$PATH"
```

Or with [Nix](nix.md): `nix profile install github:steig/dbx`.

Once installed, `dbx update` upgrades in place when a new release is out.

## Integrity verification

Every release ships a `SHASUMS256.txt` listing the sha256 of each file the installer downloads — the `dbx` launcher, the libraries, the wizard assets, and the man pages. `install.sh` fetches it for the ref it is installing, downloads everything into a staging directory, checks each file, and only then moves anything into place.

```text
[INFO] Downloading from github.com/steig/dbx@main...
[INFO] Verifying downloads against SHASUMS256.txt
```

A mismatch aborts the install and prints both digests. Nothing is moved into place, so an existing install is left exactly as it was.

**What this protects against:** a truncated or corrupted download, a proxy that mangles a file, and a CDN serving a half-updated ref (`raw.githubusercontent.com` caches each path independently, so a mid-release install can otherwise mix versions).

**What it does not protect against:** a compromised origin. The manifest is served from the same place as the files it describes, and `install.sh` is itself fetched over the same channel with nothing to check it against — so anyone able to tamper with one can tamper with both. Real provenance needs a signature verified against a key you obtained some other way; dbx does not sign releases today. If that matters to you, clone the repo at a tag you have inspected and install from the checkout, or run the [container image](container.md) by digest.

Verify a checkout yourself with the stock tool:

```bash
sha256sum -c SHASUMS256.txt     # macOS: shasum -a 256 -c SHASUMS256.txt
```

Releases up to 0.38.0 were cut before the manifest existed. Installing one of those tags (`DBX_REF=v0.38.0`) warns and continues rather than failing:

```bash
DBX_REQUIRE_CHECKSUMS=1 curl -fsSL https://raw.githubusercontent.com/steig/dbx/main/install.sh | bash
```

`DBX_REQUIRE_CHECKSUMS=1` turns anything unverifiable — a ref with no manifest, a file the manifest doesn't list, a machine with neither `sha256sum` nor `shasum` — into an error instead of a warning.

## Requirements

**Required**

- `docker`
- `jq`
- `zstd`
- `ssh` (for remote databases)

**Optional**

| Tool | What it enables |
|------|-----------------|
| `libsecret-tools` | Linux desktop credential storage (GNOME Keyring) |
| `pass` | Linux headless credential storage |
| `age` | Recommended modern backup encryption |
| `gpg` | Alternative encryption + headless vault fallback |
| `mc` or `aws` CLI | S3 / MinIO upload |
| `fzf` | Interactive backup picker for restore / verify |
| `pv` | Progress bar during MySQL restore |
| `gum` | Required for the [interactive wizards](wizards.md) (`dbx host add` / `dbx storage add`) |
| `python3` | Required for browser mode of [`dbx wizard`](wizards.md#dbx-wizard-browser-mode); without it, `dbx wizard` falls back to the gum-based flow |

## Update notifications

dbx checks GitHub Releases at the end of each interactive command and prints a one-liner when a newer tag is published. Cached 24h. Skipped when stdout isn't a TTY (so cron and scheduled runs stay silent).

```text
$ dbx version
dbx 0.9.0
[INFO] dbx 0.10.0 is available (you have 0.9.0). Run 'dbx update' to upgrade.
```

Opt out with `DBX_NO_UPDATE_CHECK=1`.

## Uninstall

dbx is a handful of files and (optionally) some scheduled jobs. There is no `--uninstall` flag yet, so removal is manual. Do the steps in order.

### 1. Remove scheduled backups first

If you ever ran `dbx schedule add`, remove those jobs before deleting the binary — otherwise the launchd/systemd units are orphaned and keep firing (and failing).

```bash
dbx schedule list                       # see what's installed
dbx schedule remove <host> <database>   # repeat for each job listed
```

If you've already removed the binary, delete the units directly:

```bash
# macOS (launchd)
rm -f ~/Library/LaunchAgents/com.dbx.backup.*.plist

# Linux (systemd user units)
rm -f ~/.config/systemd/user/com.dbx.backup.*.{service,timer}
systemctl --user daemon-reload
```

### 2. Remove the binary, libraries, and man pages

These are the three install locations. The defaults are shown; if you installed with `DBX_INSTALL_DIR`, `DBX_LIB_DIR`, or `DBX_MAN_DIR` set to custom paths, substitute those instead.

```bash
rm -f  ~/.local/bin/dbx                 # binary        ($DBX_INSTALL_DIR)
rm -rf ~/.local/lib/dbx                 # libraries     ($DBX_LIB_DIR)
rm -f  ~/.local/share/man/man1/dbx*.1   # man pages     ($DBX_MAN_DIR)
```

### 3. Configuration and backups (left in place)

The uninstall above does **not** touch your config or your backups — by design.

- **Config:** `~/.config/dbx` (override: `DBX_CONFIG_DIR`) holds `config.json` and, if you use the vault, `vault.gpg`. Remove it only if you're done with dbx for good:

  ```bash
  rm -rf ~/.config/dbx
  ```

- **Backups:** dbx writes backups to the directory you configured (there is no fixed default — check `config.json` or your storage settings for the path). **This is your data.** Inspect it before deleting anything, and do not blindly `rm -rf` it.
