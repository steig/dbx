# Quick start

```bash
# 1. Initialize config + encryption
dbx config init
dbx config edit                       # add your hosts
dbx vault init-age                    # generate age keys (optional but recommended)

# 2. Store the DB password in the system vault
dbx vault set production

# 3. Test the connection end-to-end
dbx test production

# 4. Back up
dbx backup production myapp

# 5. Restore to a sandboxed local container
dbx restore production/myapp/latest
```

Restore creates a versioned database (e.g. `myapp_v1_20260508`) inside the auto-managed `postgres-dbx` or `mysql-dbx` container — production stays untouched.

## Prefer interactive setup?

Both step 1 (add a host) and step 4-onward (storage) have [interactive wizards](wizards.md):

```bash
dbx host add       # alias → connection → live test → pick databases
dbx storage add    # provider → bucket → real S3 round-trip → save
```

Both validate against the real services before writing config — failures don't leave partial state behind.

## Next steps

- [Configuration reference](configuration.md) — full schema, including SSH tunnels and exclude_data
- [Encryption](encryption.md) — age (recommended) or GPG
- [Scheduled backups](scheduling.md) — launchd / systemd timers
- [Post-restore hooks](post-restore-hooks.md) — auto-scrub PII on restore
