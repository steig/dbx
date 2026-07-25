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

Or force a backend with the `DBX_VAULT_BACKEND` environment variable (wins over
config and auto-detection) — useful for a headless/container deployment that has
no host keychain:

```bash
DBX_VAULT_BACKEND=gpg-file dbx vault info
```

## Inspecting the vault

```bash
dbx vault info               # show active backend
dbx vault list               # all stored credentials (alias: ls)
dbx vault get <host>         # retrieve one (prints to stdout)
dbx vault set <host>         # store / replace (prompts for password)
dbx vault delete <host>      # remove (alias: rm)
dbx vault set s3-secret-key-<storage>   # store / replace a storage backend's S3 secret
dbx vault set s3-secret-key             # same, for the legacy single `storage` block
dbx vault set-encryption-key      # store the backup encryption passphrase (prompts)
dbx vault delete-encryption-key   # remove the stored encryption passphrase
dbx vault init-age                # generate the age recipient/identity (alias: init-encryption)
```

## Notes

- `password_cmd` in `config.json` is a stdout-producing shell command — handy for short-lived credentials from `aws sts get-session-token`, `vault read`, or similar. dbx invokes it once per operation.

!!! warning "`config.json` is a trust boundary"
    `password_cmd` and the other `_cmd` / notification `command.*` fields are run as shell commands on the dbx host, so **write access to `config.json` is equivalent to code execution.** These fields are CLI/operator-managed only: the wizard refuses to set or change them from a browser client (it restores the on-disk value on every save). Set them by editing `config.json` directly or via the CLI, and treat the file's permissions accordingly.
- The plaintext `password` field is a last-resort fallback. dbx warns when it's set.
- `dbx vault set` only accepts a name it can recognise: a host alias from `config.json`, or a storage backend's `s3-secret-key[-<name>]` key. Anything else is refused as a typo — `dbx vault get` and `dbx vault delete` will still read and remove a key put in the vault by other means.
- For other credentials (Slack webhook URLs, …), store them with the vault backend's own tool under the `dbx` service name — `security add-generic-password -s dbx -a slack-webhook -w`, `secret-tool store service dbx account slack-webhook`, `pass insert dbx/slack-webhook` — and reference them via `_cmd` keys in config:
  ```json
  "slack": { "webhook_url_cmd": "dbx vault get slack-webhook" }
  ```
