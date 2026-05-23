# Encryption

Two backends. **age** is the recommended default.

## age (recommended)

```bash
dbx vault init-age            # generate keys at ~/.config/sops/age/keys.txt
# then in config:
#   "defaults": { "encryption_type": "age" }
```

Keys live at:

| Path | Contents |
|------|----------|
| `~/.config/sops/age/keys.txt` | private identity |
| `~/.config/dbx/age-recipients.txt` | public recipient(s) |

!!! warning "Back up the identity file"
    Without `keys.txt`, your encrypted backups are unreadable. Copy it to a password manager, hardware token, or another machine you control.

## GPG

```bash
dbx vault set-encryption-key   # symmetric passphrase, stored in vault
# then in config:
#   "defaults": { "encryption_type": "gpg" }
```

GPG uses symmetric encryption with the passphrase from the vault. Don't lose that passphrase — same caveat as the age identity file.

## How it's wired in

Encryption sits between the `zstd` compression step and the output file. The stream is:

```text
pg_dump / mysqldump  →  zstd  →  age|gpg  →  <file>.sql.zst[.age|.gpg]
```

Restore reverses it. The `.meta.json` sibling records which encryption mode was used so restores pick the right tooling automatically.

## Verifying integrity

```bash
dbx verify ~/.data/dbx/production/myapp/myapp_20260508_103000.sql.zst.age
# [OK] Checksum verified
```

`dbx verify` (with no arg, if `fzf` is installed) gives you an interactive picker.
