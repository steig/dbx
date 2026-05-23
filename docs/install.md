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

## Update notifications

dbx checks GitHub Releases at the end of each interactive command and prints a one-liner when a newer tag is published. Cached 24h. Skipped when stdout isn't a TTY (so cron and scheduled runs stay silent).

```text
$ dbx version
dbx 0.9.0
[INFO] dbx 0.10.0 is available (you have 0.9.0). Run 'dbx update' to upgrade.
```

Opt out with `DBX_NO_UPDATE_CHECK=1`.
