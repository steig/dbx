# Interactive wizards

Two commands replace hand-editing `config.json` with end-to-end-validated interactive flows. Both require `gum` (`brew install gum` / `apt install gum` / `nix-shell -p gum`).

## `dbx host add`

```bash
dbx host add
```

Walks through: alias → database type → user → network (direct or SSH tunnel) → credentials → live connection test → pick databases (multi-select from the live remote list) → per-database options (`exclude_data`, MySQL `definer_handling`) → summary.

On a failed connection test you get a four-choice recovery:

1. **Re-enter credentials** — wrong password is the common case.
2. **Re-enter host fields** — fix a typo in the bastion or target host.
3. **Save anyway** — useful when the DB is briefly down but the config is right.
4. **Abort + rollback** — removes both the provisional config block and the vault entry, leaving no partial state.

If remote storage isn't configured yet, the wizard offers to set that up too (chaining into `dbx storage add`). If it is, it offers to flip `auto_upload` on for the new host.

## `dbx storage add`

```bash
dbx storage add
```

Wizard for S3 / S3-compatible remote storage (AWS S3, MinIO, R2, Backblaze B2, etc.). Collects provider, endpoint, region, bucket, prefix, and credentials, then proves the config works with a full **upload → list → download → delete round-trip** against the configured bucket before committing — catching the read-but-no-write IAM case that a plain credentials check would miss.

The secret key lives in the vault, never plaintext in `config.json`. Re-running with storage already configured asks before replacing.

Same four-choice recovery loop on failure as `dbx host add`.
