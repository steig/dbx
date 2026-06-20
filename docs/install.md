# Install

```bash
curl -fsSL https://raw.githubusercontent.com/steig/dbx/main/install.sh | bash
```

Or clone:

```bash
git clone https://github.com/steig/dbx.git
export PATH="$PWD/dbx:$PATH"
```

Once installed, `dbx update` upgrades in place when a new release is out.

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
