# Credential storage

Auto-detected in this order:

| Platform | Backend |
|----------|---------|
| macOS | `security` (Keychain) |
| Linux desktop | `secret-tool` (libsecret / GNOME Keyring) |
| Linux headless | `pass` (password-store) |
| Fallback | GPG-encrypted file at `~/.config/dbx/vault.gpg` |

Override in config:

```json
{ "vault": { "backend": "pass", "gpg_key": "your-key-id" } }
```

## Inspecting the vault

```bash
dbx vault info               # show active backend
dbx vault list               # all stored credentials (alias: ls)
dbx vault get <host>         # retrieve one (prints to stdout)
dbx vault set <host>         # store / replace (prompts for password)
dbx vault delete <host>      # remove (alias: rm)
dbx vault set-encryption-key      # store the backup encryption passphrase (prompts)
dbx vault delete-encryption-key   # remove the stored encryption passphrase
dbx vault init-age                # generate the age recipient/identity (alias: init-encryption)
```

## Notes

- `password_cmd` in `config.json` is a stdout-producing shell command — handy for short-lived credentials from `aws sts get-session-token`, `vault read`, or similar. dbx invokes it once per operation.
- The plaintext `password` field is a last-resort fallback. dbx warns when it's set.
- For non-DB credentials (Slack webhook URLs, S3 secret keys), store them in the vault under any name and reference via `_cmd` keys in config:
  ```json
  "slack": { "webhook_url_cmd": "dbx vault get slack-webhook" }
  ```
