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

## `dbx wizard` (browser mode)

`dbx wizard` opens the same [Config builder](config-builder.md) you can use online — but locally. dbx spins up a one-shot HTTP server on `127.0.0.1:<random-port>`, opens your default browser to it with a one-time URL token, you fill in the form, click **Save & exit**, browser POSTs the result back, dbx writes `~/.config/dbx/config.json` and shuts down.

```bash
dbx wizard
# → opens browser at http://127.0.0.1:NNNN/?token=...
# → click Save & exit when done
# → terminal continues with next-steps hints (vault, validate, test)
```

**When browser mode isn't available** (SSH session, missing `python3`, no GUI), `dbx wizard` automatically falls back to the gum-driven `dbx host add` flow. Force the fallback with `--no-browser`, or require browser mode (fail if unavailable) with `--browser`.

The server binds to `127.0.0.1` only and requires the URL token on every request. After a successful save, the server exits within a second. No other ports, no external dependencies beyond `python3`.

Compare:

| | `dbx host add` (gum) | `dbx wizard` (browser) |
|---|---|---|
| UI | Terminal prompts | Form in your browser |
| Dependencies | `gum` | `python3` + a GUI browser |
| Best for | SSH sessions, headless servers, terminal lovers | Local interactive setup, screen-sharing, less-CLI-fluent teammates |
| Output | `~/.config/dbx/config.json` | `~/.config/dbx/config.json` |
| Validates against live DB? | Yes (live connection test) | No (form-only; run `dbx test <alias>` after) |
| Adds vault entries? | Yes (interactive password prompt) | No (output references `dbx vault set` commands you run after) |
