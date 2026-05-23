# `dbx host add` Interactive Wizard — Design

**Status:** Design (pre-implementation). The implementation plan is written
separately by `superpowers:writing-plans` and lives next to this doc.

**Goal:** Replace the manual "edit `config.json` by hand" path for two
related setup tasks with interactive wizards that validate end-to-end
before committing:

1. **`dbx host add`** — collects every field needed to back up and restore
   a database, runs the existing `cmd_test` against the provisional
   config, and (on success) lets the user pick which databases to back up.
2. **`dbx storage add`** — collects the S3 / S3-compatible endpoint,
   bucket, prefix, and credentials, then proves the config works with a
   real upload-list-delete round-trip before writing.

The two compose: at the end of a successful `dbx host add`, the wizard
checks `is_storage_configured`. If no storage is configured, it offers
to run the storage wizard inline. If storage IS already configured, it
offers to flip `auto_upload: true` for the freshly added host. Either
way, only one extra prompt — the storage flow can also be invoked
standalone via `dbx storage add` at any time.

**Non-goals:**

- A general-purpose host or storage CRUD surface. Only `add` ships now
  for both. `remove`, `list`, and `edit` are *reserved* under the
  respective dispatchers but unimplemented (`die "not yet implemented"`).
  This keeps the future surface stable without scope creep.
- Replacing or restructuring `dbx test`, `dbx vault set`, `dbx storage
  info`, or any existing command. The wizards *use* them but don't
  reshape them.
- A non-interactive add-host / add-storage mode (`--from-file` / flags).
  The user explicitly asked for "interactive". Non-interactive callers
  can still edit `config.json` and run `dbx test` / `dbx storage info`.
- Supporting non-S3 storage backends (rsync, rclone, etc.). The
  underlying `lib/storage.sh` is S3-only today and that stays.

---

## Surface

```
dbx host add
```

No arguments. Everything is collected via `gum` prompts. The command:

1. `require_config` (run `dbx config init` first if missing — the wizard
   errors with that hint, it does not silently init).
2. `require_jq`, `require_docker`, `require_gum` (mirrors `cmd_tui`).
3. Does not strictly enforce TTY-on-stdin. `gum` reads from `/dev/tty`
   when available and from stdin otherwise, which is the behavior the
   integration tests rely on (they drive the wizard via piped stdin —
   see Testing). The downside — a user piping into the wizard by
   accident gets garbage output — is the same risk `dbx tui` runs
   today.

The existing TUI menu entry `tui_config_add_host` (`lib/tui.sh:673`) is
replaced by a one-line shell-out to `dbx host add`, matching how that file
already invokes `dbx vault set`, `dbx config edit`, and `dbx config init`.

`dbx help` gains a `host add` entry under a new `HOST MANAGEMENT` section.

---

## Wizard flow

The wizard runs as one linear sequence with one retry loop around the
validation step. Each prompt has a sensible default where one exists, and
empty input on a *required* field aborts the wizard (matches the existing
TUI convention — `[[ -z "$new_host" ]] && return 0`).

### Step 1 — Identity

| Prompt              | Type        | Required | Notes                                       |
| ------------------- | ----------- | -------- | ------------------------------------------- |
| Host alias          | `gum input` | Yes      | Validated: must match `^[a-zA-Z0-9][a-zA-Z0-9_-]*$` (alphanumeric start, then alphanumerics / `_` / `-`), must not already exist in config. Shell-safe so the alias can flow into `dbx test "$alias"`, `dbx vault set "$alias"` etc. without quoting hazards. On collision, prompt again with the existing host's type/user shown. |
| Database type       | `gum choose postgres mysql` | Yes | Drives port default and downstream branches. |
| Database user       | `gum input` | Yes      | No default.                                 |

### Step 2 — Network branch

Single `gum choose`:

- **Direct connection** — prompt for `host` (default `localhost`) and
  `port` (default `5432` for postgres, `3306` for mysql).
- **SSH tunnel** — prompt for `jump_host`, `target_host`, `target_port`
  (default same as direct). The wizard writes an `ssh_tunnel` block; no
  top-level `host`/`port` is written.

The two branches are mutually exclusive — the config schema treats them
that way too (`get_effective_host` / `get_effective_port` in
`lib/tunnel.sh` pick the right pair based on which block is present).

### Step 3 — Credentials

`gum input --password` to collect the database password. Stored
immediately via the existing `vault_set` helper so the active backend
(macOS Keychain / `pass` / age-encrypted file) is honored — no plaintext
in `config.json`.

If `get_password "$alias"` already returns a value (vault entry from a
prior failed run with the same alias), offer **Use existing / Replace**.

### Step 4 — Provisional write + validation

The wizard *cannot* run `cmd_test` without the host existing in the
config — `cmd_test` reads everything via `get_config_value
".hosts[\"$host\"]…"`. So:

1. Apply the new host block to `$CONFIG_FILE` via `jq` + temp-file (same
   atomic pattern as `tui_config_add_host`). The host is now writable
   from the user's perspective.
2. Run `cmd_test "$alias"` and capture its exit code. Output streams to
   the terminal as it runs — this is what the user is *here* to see.

On exit code 0 → continue to Step 5.

On exit code != 0 → `gum choose`:

- **Re-enter credentials and retry** — back to Step 3, then Step 4.
- **Re-enter host fields and retry** — back to Step 2 (network branch).
  Identity (Step 1) is *not* re-prompted; the alias stays.
- **Save anyway** — leave the (broken) host in `config.json` with a
  warning. The user knows what they're doing (e.g., target db is offline
  right now). Skip Step 5 and Step 6.
- **Abort** — `jq del(.hosts[$alias])` to roll the config back to its
  pre-wizard state, then exit with a non-zero code. Vault entry is also
  removed (`vault_delete`) so a re-run starts fresh.

### Step 5 — Database picker

`cmd_test` already lists user-visible databases as its final step. The
wizard re-runs the same query (not `cmd_test` again — just the `SELECT
datname …` / `SHOW DATABASES` query, factored into a small helper
`list_remote_databases "$alias"`) and feeds the result to
`gum choose --no-limit --header "Pick databases to back up:"`.

Filters: same as `cmd_test`'s display filter — drop
`information_schema`, `performance_schema`, `mysql`, `sys` for MySQL;
drop template databases for postgres.

Empty selection is allowed (some users only know which DBs they want
later). The wizard writes an empty `databases: {}` in that case.

### Step 6 — Per-database options

For each picked database, asked in order:

| Prompt                                  | Type                  | Applies to        | Default |
| --------------------------------------- | --------------------- | ----------------- | ------- |
| Tables to exclude data from (comma-sep) | `gum input`           | both              | empty   |
| Strip `DEFINER` clauses?                | `gum confirm`         | MySQL host only   | yes     |

Excludes become `exclude_data: ["a","b","c"]` (same shape as
`tui_config_add_database`). `definer_handling` is written at the **host**
level (matches existing schema: `.hosts[$alias].definer_handling`), since
it's a host-wide policy, not per-database. The confirm prompt maps to the
string values the config consumer expects: yes → `"strip"`, no → `"keep"`
(see `lib/core.sh::get_definer_handling`). For postgres hosts the prompt
is skipped and no key is written.

### Step 7 — Storage chain (conditional)

Storage is global config (`.storage.*`), not per-host. The wizard
checks `is_storage_configured` and branches:

- **Storage not yet configured:** `gum confirm "Configure remote
  storage for these backups now?"`. If yes, the wizard delegates to
  `dbx storage add` (see "`dbx storage add` flow" below) by calling
  the `storage_add` function directly (it's in the same `dbx`
  binary). If no, skip.
- **Storage already configured:** `gum confirm "Enable auto-upload
  to remote storage for '$alias' backups?"`. If yes, set
  `.hosts[$alias].auto_upload = true` via jq+temp-file. If no, skip.
  (The existing `defaults.auto_upload` global flag still applies if
  set; this is a per-host override.)

### Step 8 — Commit + summary

After the optional storage chain, the wizard prints a short summary
(host alias, type, network mode, database count, storage state) and
exits 0.

---

## `dbx storage add` flow

Parallel to `dbx host add` — its own dispatcher slot, same
`cmd_*` / `*_add` inline-function pattern. Standalone command users can
invoke any time; also called from Step 7 of `dbx host add`.

### Step 1 — Provider branch

`gum choose`:

- **AWS S3** — no endpoint URL; `region` is required.
- **S3-compatible (MinIO, R2, Backblaze B2, …)** — `endpoint` URL
  required; `region` optional (some backends ignore it).

### Step 2 — Bucket + prefix

| Prompt           | Type        | Required | Notes                         |
| ---------------- | ----------- | -------- | ----------------------------- |
| Bucket           | `gum input` | Yes      | No defaults.                  |
| Prefix (path)    | `gum input` | No       | Default: empty (root of bucket). |

### Step 3 — Credentials

| Prompt              | Type                  | Required | Storage              |
| ------------------- | --------------------- | -------- | -------------------- |
| Access key          | `gum input`           | Yes      | Plaintext in config (`.storage.s3.access_key`) — matches existing schema. |
| Secret key          | `gum input --password`| Yes      | Vault under key `s3-secret-key` (existing convention, see `lib/storage.sh:66`). |

### Step 4 — Provisional write + round-trip test

1. Write `.storage` block to `$CONFIG_FILE` via jq+temp-file.
2. Store the secret in the vault.
3. Run `storage_test_roundtrip` — a new helper that:
   - Creates a 1-byte temp file
   - Uploads it to `.dbx-test/<timestamp>` under the configured prefix
   - Lists the prefix, asserts the file appears
   - Downloads it, asserts byte-identical
   - Deletes it from the bucket
   - Returns 0 on full success; non-zero on any failure with the
     failing step logged

On success → Step 5.
On failure → `gum choose`:

- **Re-enter credentials and retry** — back to Step 3, then retest.
- **Re-enter all fields and retry** — back to Step 1.
- **Save anyway** — leave the broken storage config in place with a
  warning.
- **Abort and roll back** — delete `.storage` block, `vault_delete
  s3-secret-key`, exit 1.

### Step 5 — Summary

Print endpoint (or "AWS S3"), bucket, prefix, and exit 0.

### Why a real round-trip (not just creds check)

Bucket-list permissions don't imply write permissions. A user with a
working alias but a read-only IAM policy would pass a "list bucket"
check and then fail later during the first real backup upload. The
round-trip catches this at config time, in front of the user, while
they still remember which secret key they pasted.

---

## Architecture

### Single dispatcher, inline implementation

Following the existing `cmd_config` / `cmd_vault` / `cmd_schedule`
pattern in `dbx`:

```bash
cmd_host() {
  local action="${1:-}"; shift || true
  case "$action" in
    add) host_add "$@" ;;
    remove|rm|delete|list|ls|test|edit)
      die "host $action: not yet implemented"
      ;;
    ""|help)
      die "Usage: dbx host <action>\n  Actions: add"
      ;;
    *)
      die "Unknown host action: $action"
      ;;
  esac
}
```

`host_add` and its small helpers live in the same `dbx` file. The wizard
is ~200 lines; that's comparable to `cmd_config`'s 175.

### New helpers

| Name | Lives in | Why factored |
| --- | --- | --- |
| `host_alias_valid <name>` | `lib/core.sh` | Reusable, single regex check |
| `host_exists <name>` | `lib/core.sh` | Wraps `get_host_config` truthiness check |
| `list_remote_databases <host>` | `lib/core.sh` | Used by wizard and reusable for any future "pick db" UX. Extracted from the docker-exec block at `dbx:1180-1195`. |
| `storage_test_roundtrip` | `lib/storage.sh` | New. Upload → list → download → delete a 1-byte test object under `.dbx-test/<timestamp>`. Used by `dbx storage add`, available standalone for future `dbx storage test` command. |
| `host_add` | `dbx` | Wizard. Not extracted to lib — single caller, matches inline-dispatcher convention. |
| `storage_add` | `dbx` | Wizard. Same reasoning. |

`cmd_test` is **reused as-is** — the wizard calls `cmd_test "$alias"`
after the provisional write. No changes to `cmd_test`.

`cmd_storage` is **extended** with a new `add` action that calls
`storage_add`. The existing actions (`upload`, `download`, `list`,
`delete`, `sync`, `info`) are unchanged.

### TUI hook

`lib/tui.sh:673` (`tui_config_add_host`) is rewritten as:

```bash
tui_config_add_host() {
  echo
  dbx host add
  sleep 1
}
```

The old gum-prompt-and-jq block is deleted. This is the consolidation the
user explicitly accepted — TUI shells out, matching the surrounding
menu items.

---

## Data flow

```
User input (gum prompts)
  └─> in-memory locals
       ├─> vault_set        (password)        [Step 3]
       └─> jq + atomic mv   (host block)      [Step 4 provisional]
            └─> cmd_test "$alias"
                 ├─> success → list_remote_databases
                 │   └─> per-db jq + atomic mv [Step 6]
                 └─> failure → retry loop or abort/save-anyway
                      └─> on abort: jq del + vault_delete  (rollback)
```

The config file is touched **twice** in the happy path: once for the host
block, once after database selection. Each touch goes through
`jq … > tmp && mv tmp $CONFIG_FILE` so the file is never half-written.
`secure_file "$CONFIG_FILE"` is reapplied after each write (the existing
`config init` path already does this).

---

## Error handling

| Failure mode | Behavior |
| --- | --- |
| No config file | `require_config` errors with the hint to run `dbx config init`. Wizard never starts. |
| `gum` missing | `require_gum` errors with install hint. |
| Docker not running | `require_docker` errors at start. |
| Non-TTY stdin | Fail fast: `Run \`dbx host add\` from an interactive terminal.` |
| Alias collision | Re-prompt with the existing host's type/user shown. |
| Empty required field | Abort wizard with no config changes. |
| Validation failure | Retry loop (Step 4 choices above). |
| User aborts mid-validation-retry | `jq del` host block, `vault_delete` credentials, exit 1. |
| `jq` write failure | Temp-file pattern means original file is preserved; surface the jq error and exit 1. |

The "Save anyway" path is the only way a broken host ends up in
`config.json`. It's gated behind an explicit choice and the warning
includes the failing test step.

---

## Testing

### Unit tests (`tests/unit/host_add.bats`, new)

Pure-logic / pure-bash tests, no docker, no network:

- `host_alias_valid` accepts `prod-1`, `db_2`, `MixedCase`; rejects empty,
  `with space`, `with/slash`, `.dot`, leading dash.
- `host_exists` returns true / false against fixture configs.
- `list_remote_databases` is **not** unit-tested (needs docker) — covered
  by integration.

### Integration tests (`tests/integration/host_add.bats`, new)

Drive `dbx host add` end-to-end against the `postgres-dbx` / `mysql-dbx`
test containers already set up in `tests/helpers/integration.bash`.

The wizard requires a TTY on stdin (per the Surface section), so the
tests provide one. Two options, pick whichever lands cleaner during
implementation:

1. **`script -qec` PTY wrapper** (POSIX, on the Linux CI runner). Feed
   the wizard's input via a heredoc inside the wrapped command.
2. **`expect`** if it turns out to be needed for the multi-step retry
   cases. Adds a CI dependency, so reach for it only if (1) doesn't
   cover the retry path cleanly.

Cases:

- Happy path, postgres, direct connection, one database picked → config
  contains the host, `dbx test <alias>` exits 0, `dbx backup <alias>`
  exits 0.
- Happy path, mysql, SSH tunnel (using the test bastion fixture),
  multi-database pick, with `exclude_data` on one database.
- Validation failure → retry credentials path: first password is wrong,
  second is correct → config is written, vault has the second password.
- Validation failure → abort: config is unchanged, vault entry removed.
- Alias collision: existing host is in config → wizard re-prompts.

### CI

Add the new bats files to the existing `unit` / `integration` jobs (they
pick up `tests/unit/*.bats` and `tests/integration/*.bats` by glob).
Shellcheck and bash syntax check cover the new code automatically.

---

## Out of scope (deferred)

- **`dbx host remove` / `list` / `edit`** and **`dbx storage remove` /
  `edit`.** Dispatcher slots reserved but unimplemented. When asked,
  fail with `not yet implemented`.
- **Non-interactive add** for either wizard.
- **Notification (Slack/email/desktop) setup.** Stays in
  `dbx config edit` for now.
- **Non-S3 storage backends** (rsync, rclone, sftp). `lib/storage.sh`
  doesn't support them, so the wizard doesn't either.
- **Editing an existing host or storage config.** Re-running `dbx host
  add <existing>` is rejected; re-running `dbx storage add` with
  storage already configured prompts `Replace existing storage config?`
  and routes to the same flow with the old block deleted on confirm.
- **Migrating existing TUI add-database flow** to a `dbx host
  add-database` command. The new wizard *does* invoke the per-database
  prompts during initial add, but managing databases on an existing
  host stays in the TUI for now.
