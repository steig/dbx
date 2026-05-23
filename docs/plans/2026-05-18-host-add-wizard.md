# `dbx host add` Interactive Wizard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship two composed interactive wizards: `dbx host add` (alias → network → creds → validate → pick DBs) and `dbx storage add` (provider → bucket → creds → upload-list-delete round-trip). The host wizard tail-calls the storage wizard if no remote storage is configured, or offers per-host `auto_upload` if it is. Both reuse existing connection/upload infrastructure unchanged. Spec lives at `docs/plans/2026-05-18-host-add-wizard-design.md`.

**Architecture:** Two dispatchers + wizards inline in `dbx` (mirrors `cmd_config` / `cmd_vault` / `cmd_schedule`). Reusable helpers go into the appropriate libs: host helpers (`host_alias_valid`, `host_exists`, `list_remote_databases`) into `lib/core.sh`; storage round-trip helper (`storage_test_roundtrip`) into `lib/storage.sh`. TUI's existing add-host menu becomes a one-line shell-out to `dbx host add`. `cmd_storage` gets a new `add` action; existing actions untouched.

**Tech Stack:** Bash, jq, gum (interactive prompts), Docker (via existing `cmd_test`), `mc` or `aws` CLI (via existing `lib/storage.sh`), bats for tests, optional MinIO container for storage integration tests.

---

## File Structure

| File                                 | Change | Responsibility                                                                                                            |
| ------------------------------------ | ------ | ------------------------------------------------------------------------------------------------------------------------- |
| `lib/core.sh`                        | Modify | Add `host_alias_valid`, `host_exists`, `list_remote_databases`                                                            |
| `lib/storage.sh`                     | Modify | Add `storage_test_roundtrip`                                                                                              |
| `dbx`                                | Modify | Add `cmd_host` + `host_add`; add `add` action to `cmd_storage` + `storage_add`; expand help with `HOST MANAGEMENT` and storage `add` |
| `lib/tui.sh`                         | Modify | Replace `tui_config_add_host` body with `dbx host add` shell-out                                                          |
| `tests/unit/host_add.bats`           | Create | Unit tests for host helpers + dispatcher scaffolding                                                                      |
| `tests/unit/storage_add.bats`        | Create | Unit tests for storage dispatcher + `storage_test_roundtrip` with a stubbed S3 client                                     |
| `tests/integration/host_add.bats`    | Create | End-to-end host wizard against `postgres-dbx` / `mysql-dbx` containers via stdin scripting                                |
| `tests/integration/storage_add.bats` | Create | End-to-end storage wizard against a MinIO container                                                                       |
| `tests/helpers/integration.bash`     | Modify | Add `ensure_minio_container` (parallels `ensure_postgres_container`)                                                      |
| `README.md`                          | Modify | Document both new wizards under the existing usage section                                                                |
| `AGENTS.md`                          | Modify | Note the `cmd_host` + `cmd_storage add` dispatcher additions                                                              |
| `CHANGELOG.md`                       | Modify | Unreleased entry: new `dbx host add` and `dbx storage add` wizards                                                        |

---

## Task 1: Pure helper — `host_alias_valid`

**Files:**
- Create: `tests/unit/host_add.bats`
- Modify: `lib/core.sh` (append helper after `get_definer_handling`)

- [ ] **Step 1: Write the failing test**

```bash
# tests/unit/host_add.bats
#!/usr/bin/env bats
load '../helpers/common'
setup() { setup_dbx_env; source_dbx_libs; }

@test "host_alias_valid: accepts typical aliases" {
  host_alias_valid "production"
  host_alias_valid "prod-east-1"
  host_alias_valid "db_2"
  host_alias_valid "MixedCase"
  host_alias_valid "a"
}

@test "host_alias_valid: rejects empty string" {
  run host_alias_valid ""
  [ "$status" -ne 0 ]
}

@test "host_alias_valid: rejects leading dash" {
  run host_alias_valid "-prod"
  [ "$status" -ne 0 ]
}

@test "host_alias_valid: rejects leading underscore" {
  run host_alias_valid "_prod"
  [ "$status" -ne 0 ]
}

@test "host_alias_valid: rejects whitespace" {
  run host_alias_valid "with space"
  [ "$status" -ne 0 ]
}

@test "host_alias_valid: rejects slash" {
  run host_alias_valid "with/slash"
  [ "$status" -ne 0 ]
}

@test "host_alias_valid: rejects dot" {
  run host_alias_valid "prod.east"
  [ "$status" -ne 0 ]
}

@test "host_alias_valid: rejects shell metachars" {
  run host_alias_valid "prod;rm"
  [ "$status" -ne 0 ]
  run host_alias_valid 'prod$x'
  [ "$status" -ne 0 ]
  run host_alias_valid 'prod`x`'
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/unit/host_add.bats -f host_alias_valid`
Expected: All tests fail with `command not found: host_alias_valid`.

- [ ] **Step 3: Implement the helper**

Append to `lib/core.sh` (after `get_definer_handling`, around line ~190):

```bash
# Validate a host alias string. Allowed: alphanumeric start, then
# alphanumerics / underscore / dash. Keeps the alias safe to pass through
# `dbx test "$alias"`, jq paths, vault keys, etc. without quoting hazards.
host_alias_valid() {
  local alias="${1:-}"
  [[ "$alias" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/unit/host_add.bats -f host_alias_valid`
Expected: 8/8 pass.

- [ ] **Step 5: Commit**

```bash
git add tests/unit/host_add.bats lib/core.sh
git commit -m "feat(core): add host_alias_valid helper

Validates host alias strings to be shell-safe before they flow into
\`dbx test\`, jq paths, vault keys, and other contexts that don't quote
their inputs."
```

---

## Task 2: Pure helper — `host_exists`

**Files:**
- Modify: `tests/unit/host_add.bats` (append cases)
- Modify: `lib/core.sh` (append helper after `host_alias_valid`)

- [ ] **Step 1: Write the failing test**

Append to `tests/unit/host_add.bats`:

```bash
@test "host_exists: false when config has no such host" {
  cat > "$CONFIG_FILE" <<'JSON'
{"hosts": {"alpha": {"type": "postgres", "user": "u"}}}
JSON
  run host_exists "beta"
  [ "$status" -ne 0 ]
}

@test "host_exists: true when host is present" {
  cat > "$CONFIG_FILE" <<'JSON'
{"hosts": {"alpha": {"type": "postgres", "user": "u"}}}
JSON
  run host_exists "alpha"
  [ "$status" -eq 0 ]
}

@test "host_exists: false when hosts key missing entirely" {
  echo '{}' > "$CONFIG_FILE"
  run host_exists "alpha"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/unit/host_add.bats -f host_exists`
Expected: All fail with `command not found: host_exists`.

- [ ] **Step 3: Implement the helper**

Append to `lib/core.sh` (after `host_alias_valid`):

```bash
# Return 0 if the given host alias exists in the config, 1 otherwise.
host_exists() {
  local alias="${1:-}"
  [[ -z "$alias" ]] && return 1
  local found
  found=$(jq -r --arg h "$alias" '.hosts | has($h)' "$CONFIG_FILE" 2>/dev/null || echo "false")
  [[ "$found" == "true" ]]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/unit/host_add.bats -f host_exists`
Expected: 3/3 pass.

- [ ] **Step 5: Commit**

```bash
git add tests/unit/host_add.bats lib/core.sh
git commit -m "feat(core): add host_exists helper

Reusable config-lookup check; used by the host-add wizard for alias
collision detection."
```

---

## Task 3: Extract `list_remote_databases` from `cmd_test`

**Goal:** Factor the database-listing query that lives inside `cmd_test` (`dbx:1180-1195`) into a reusable function so the wizard can call it without re-running the full 5-step test pipeline.

**Files:**
- Modify: `lib/core.sh` (append helper)
- Modify: `dbx` (replace inline block in `cmd_test` with a call to the helper)

- [ ] **Step 1: Write the helper**

Append to `lib/core.sh`:

```bash
# Query the remote server (via existing docker container + already-up
# tunnel) and print the user-visible database names, one per line.
# Filters out system / template databases so the output is a clean list
# for a "pick which to back up" prompt.
#
# Preconditions: the host exists in config, credentials resolve via
# get_password, the relevant docker container is up, and (if configured)
# the SSH tunnel is already established.
list_remote_databases() {
  local host="$1"
  local db_type db_host db_port db_user db_pass
  db_type=$(get_db_type "$host")
  db_host=$(get_effective_host "$host")
  db_port=$(get_effective_port "$host")
  db_user=$(get_config_value ".hosts[\"$host\"].user")
  db_pass=$(get_password "$host")

  case "$db_type" in
    postgres|postgresql)
      docker exec -e PGPASSWORD="$db_pass" "$POSTGRES_CONTAINER" \
        psql -h "$db_host" -p "$db_port" -U "$db_user" -t -A -c \
        "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname" \
        2>/dev/null
      ;;
    mysql|mariadb)
      docker exec -e MYSQL_PWD="$db_pass" "$MYSQL_CONTAINER" \
        mysql -h "$db_host" -P "$db_port" -u "$db_user" -N -e "SHOW DATABASES" \
        2>/dev/null \
        | grep -v -E "^(information_schema|performance_schema|mysql|sys)$" || true
      ;;
    *)
      return 1
      ;;
  esac
}
```

- [ ] **Step 2: Update `cmd_test` to use it**

In `dbx`, replace the block at lines 1180-1195 (the `# Test 5: List available databases` section) with:

```bash
  # Test 5: List available databases
  log_info "Available databases:"
  list_remote_databases "$host" 2>/dev/null | while read -r dbname; do
    [[ -n "$dbname" ]] && echo "  - $dbname"
  done
```

- [ ] **Step 3: Run the existing test suite for regressions**

Run: `bats tests/integration/`
Expected: All tests still pass — `dbx test` output is unchanged from the user's perspective.

If the integration test suite doesn't already cover `dbx test`, run it manually against a live container:

```bash
docker exec postgres-dbx createdb -U postgres listtest >/dev/null 2>&1 || true
dbx test <some-pg-host>
```

Expected: Same `- dbname` lines as before the refactor.

- [ ] **Step 4: Commit**

```bash
git add lib/core.sh dbx
git commit -m "refactor(core): extract list_remote_databases helper from cmd_test

Lets the upcoming host-add wizard reuse the database-discovery query
without re-running the full 5-step \`dbx test\` pipeline. No behavior
change in \`dbx test\` itself."
```

---

## Task 4: `cmd_host` dispatcher + help text scaffold

**Goal:** Add the top-level `host` command surface with only the dispatcher and reserved-but-unimplemented action errors. Wizard body comes in later tasks.

**Files:**
- Modify: `dbx` (add `cmd_host`, the `host)` case in main, the help text)

- [ ] **Step 1: Write the failing test**

Append to `tests/unit/host_add.bats`:

```bash
@test "dbx host (no action) prints usage" {
  run "$DBX_BIN" host
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Usage: dbx host" ]]
}

@test "dbx host bogus errors with unknown-action" {
  run "$DBX_BIN" host bogus
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Unknown host action: bogus" ]]
}

@test "dbx host remove errors with not-yet-implemented" {
  run "$DBX_BIN" host remove
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not yet implemented" ]]
}

@test "dbx host add errors with not-yet-implemented (placeholder)" {
  run "$DBX_BIN" host add
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not yet implemented" ]]
}

@test "dbx help mentions host add" {
  run "$DBX_BIN" help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "host add" ]]
}
```

The last "add" test will be replaced when Task 5 lands the real implementation — for now it asserts the dispatcher routes correctly to a stub.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/host_add.bats`
Expected: The five new tests fail because `dbx host` is currently an unknown command.

- [ ] **Step 3: Add the dispatcher to `dbx`**

In `dbx`, just before `cmd_help()` (currently around line 1208), add:

```bash
cmd_host() {
  local action="${1:-}"; shift || true
  case "$action" in
    add)
      die "host add: not yet implemented"
      ;;
    remove|rm|delete|list|ls|test|edit)
      die "host $action: not yet implemented"
      ;;
    ""|help)
      die "Usage: dbx host <action>
  Actions:
    add        Interactively add a new backup host"
      ;;
    *)
      die "Unknown host action: $action (use: add)"
      ;;
  esac
}
```

- [ ] **Step 4: Wire it into the main case**

In `dbx`, in the main `case` block (around line 1351, near `cmd_test`), add a new case:

```bash
    host)
      shift; cmd_host "$@"
      ;;
```

The exact placement: add it directly after the `test)` case, before `update)`.

- [ ] **Step 5: Add help text**

In `cmd_help()`, in the `COMMANDS:` block (around line 1216-1225), add **after** the existing `test` line:

```
  host add                     Interactively add a host (alias, creds, validate, pick dbs)
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bats tests/unit/host_add.bats`
Expected: All host-dispatcher tests pass.

- [ ] **Step 7: Run the shellcheck/syntax sweep**

```bash
bash -n dbx && for f in lib/*.sh; do bash -n "$f"; done
shellcheck -S error dbx lib/*.sh
```
Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add dbx tests/unit/host_add.bats
git commit -m "feat(host): add cmd_host dispatcher scaffold

New top-level surface: \`dbx host <action>\`. Only \`add\` is wired up,
and it currently dies with 'not yet implemented' — the wizard body
lands in follow-up commits. Reserved actions (remove/list/edit/test)
return the same not-yet-implemented error so the surface is stable for
later expansion without re-breaking callers."
```

---

## Task 5: Wizard — identity step (alias, type, user)

**Goal:** Real `host_add` function starts here. By end of this task, `dbx host add` prompts for the three identity fields, validates the alias (regex + collision), and exits without writing anything. No network/creds/validation yet.

**Files:**
- Modify: `dbx` (replace the `add` stub in `cmd_host` with a real call into `host_add`; define `host_add`)

- [ ] **Step 1: Update the dispatcher to call `host_add`**

In `dbx`, replace the existing `add) die "host add: not yet implemented" ;;` line in `cmd_host` with:

```bash
    add)
      host_add "$@"
      ;;
```

- [ ] **Step 2: Implement the identity step of `host_add`**

In `dbx`, immediately above `cmd_host` (so `cmd_host` can call it), add:

```bash
host_add() {
  require_config
  require_jq
  require_docker
  require_gum

  local alias new_type new_user
  while :; do
    alias=$(gum input --header "Host alias:" --placeholder "production")
    [[ -z "$alias" ]] && { log_info "Aborted."; return 0; }
    if ! host_alias_valid "$alias"; then
      log_warn "Alias must start with a letter or digit and use only letters, digits, '_', or '-'."
      continue
    fi
    if host_exists "$alias"; then
      local existing_type existing_user
      existing_type=$(get_config_value ".hosts[\"$alias\"].type")
      existing_user=$(get_config_value ".hosts[\"$alias\"].user")
      log_warn "Host '$alias' already exists (type=$existing_type, user=$existing_user)."
      continue
    fi
    break
  done

  new_type=$(gum choose --header "Database type:" "postgres" "mysql")
  [[ -z "$new_type" ]] && { log_info "Aborted."; return 0; }

  new_user=$(gum input --header "Database user:" --placeholder "postgres")
  [[ -z "$new_user" ]] && { log_info "Aborted."; return 0; }

  log_info "Identity collected: alias=$alias type=$new_type user=$new_user"
  log_warn "Wizard incomplete — network/credentials/validation land in follow-up commits."
  # TODO(Task 6): continue into network step.
}
```

`require_gum` is already available to `host_add` — `dbx:43` sources `lib/tui.sh`, which defines it at line 90. No new helper needed.

- [ ] **Step 3: Update the placeholder test from Task 4**

In `tests/unit/host_add.bats`, replace the `"dbx host add errors with not-yet-implemented (placeholder)"` test with:

```bash
@test "dbx host add: empty alias aborts cleanly" {
  # Pipe empty stdin so gum receives no input and exits with empty result.
  run bash -c "echo '' | '$DBX_BIN' host add"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Aborted" ]]
}
```

This is the only assertion we can make at the unit level for the wizard right now without a TTY emulator. The remaining flow gets covered by integration tests in Task 13.

- [ ] **Step 4: Manual verification**

```bash
dbx config init || true   # ensure a config exists
dbx host add
```

Expected behavior:
- Prompts for alias. Try entering `-bad` → warning shown, re-prompts.
- Try entering an alias of an existing host → warning shown with type/user, re-prompts.
- Enter a valid new alias → proceeds.
- Prompts for type (postgres / mysql), then user.
- After user is entered, prints `Identity collected:` + the "wizard incomplete" warning.

- [ ] **Step 5: Commit**

```bash
git add dbx lib/core.sh tests/unit/host_add.bats
git commit -m "feat(host): wizard identity step (alias, type, user)

\`dbx host add\` now collects the three identity fields, validates the
alias regex, and rejects collisions with existing hosts. No config
writes yet — network/creds/validation land in follow-up commits."
```

---

## Task 6: Wizard — network branch (direct vs SSH tunnel)

**Goal:** After identity, ask whether the host is reachable directly or via SSH tunnel; collect the right fields. Still no config writes — accumulate into shell vars.

**Files:**
- Modify: `dbx` (extend `host_add`)

- [ ] **Step 1: Extend `host_add` with the network branch**

In `dbx`, replace the `# TODO(Task 6): continue into network step.` placeholder (and the surrounding `log_warn` line) with:

```bash
  local network_mode
  network_mode=$(gum choose --header "How does dbx reach this database?" \
    "Direct connection" "SSH tunnel (jump host)")
  [[ -z "$network_mode" ]] && { log_info "Aborted."; return 0; }

  local default_port direct_host direct_port
  local tunnel_jump tunnel_target tunnel_port
  default_port=$([[ "$new_type" == "postgres" ]] && echo "5432" || echo "3306")

  if [[ "$network_mode" == "Direct connection" ]]; then
    direct_host=$(gum input --header "Host address:" --value "localhost")
    [[ -z "$direct_host" ]] && { log_info "Aborted."; return 0; }
    direct_port=$(gum input --header "Port:" --value "$default_port")
    [[ -z "$direct_port" ]] && { log_info "Aborted."; return 0; }
  else
    tunnel_jump=$(gum input --header "SSH jump host (from your ~/.ssh/config):" \
                            --placeholder "bastion")
    [[ -z "$tunnel_jump" ]] && { log_info "Aborted."; return 0; }
    tunnel_target=$(gum input --header "Database hostname (as seen from the jump host):" \
                              --placeholder "db.internal")
    [[ -z "$tunnel_target" ]] && { log_info "Aborted."; return 0; }
    tunnel_port=$(gum input --header "Database port (on the jump-side network):" \
                            --value "$default_port")
    [[ -z "$tunnel_port" ]] && { log_info "Aborted."; return 0; }
  fi

  log_info "Network collected: mode=$network_mode"
  log_warn "Wizard incomplete — credentials/validation land in follow-up commits."
  # TODO(Task 7): continue into credentials step.
```

- [ ] **Step 2: Manual verification**

```bash
dbx host add
# Walk through: alias=test-pg, type=postgres, user=postgres
# Pick "Direct connection", host=localhost, port=5432
# Expect: prints "Network collected: mode=Direct connection" + the warning
#
# Run again, pick "SSH tunnel" branch
# Walk through jump/target/port
# Expect: prints "Network collected: mode=SSH tunnel (jump host)" + the warning
```

- [ ] **Step 3: Commit**

```bash
git add dbx
git commit -m "feat(host): wizard network branch (direct vs SSH tunnel)

Collects either host/port or jump_host/target_host/target_port. Still no
config writes — values accumulate in shell locals until the provisional
write in a later commit."
```

---

## Task 7: Wizard — credentials step (vault_set + existing-entry check)

**Goal:** After network, prompt for the password and store it via the active vault backend. If the alias already has a vault entry (from a prior failed run), offer to keep or replace.

**Files:**
- Modify: `dbx` (extend `host_add`)

- [ ] **Step 1: Extend `host_add` with the credentials step**

Replace the network-step `log_info`/`log_warn`/TODO trailer with:

```bash
  # Credentials. vault_set persists via the active backend (Keychain on
  # macOS, pass on Linux, age fallback) so the password never lands in
  # config.json.
  local existing_pass
  existing_pass=$(get_password "$alias" 2>/dev/null || true)
  if [[ -n "$existing_pass" ]]; then
    local creds_choice
    creds_choice=$(gum choose --header "Vault already has a password for '$alias'." \
                              "Use existing" "Replace")
    [[ -z "$creds_choice" ]] && { log_info "Aborted."; return 0; }
    if [[ "$creds_choice" == "Replace" ]]; then
      local new_pass
      new_pass=$(gum input --password --header "New password for '$alias':")
      [[ -z "$new_pass" ]] && { log_info "Aborted."; return 0; }
      keychain_set "$alias" "$new_pass"
    fi
  else
    local new_pass
    new_pass=$(gum input --password --header "Password for '$alias':")
    [[ -z "$new_pass" ]] && { log_info "Aborted."; return 0; }
    keychain_set "$alias" "$new_pass"
  fi

  log_info "Credentials stored."
  log_warn "Wizard incomplete — validation lands in the next commit."
  # TODO(Task 8): continue into provisional write + cmd_test.
```

**Note on the storage call:** the codebase's existing setter is `keychain_set` (`lib/core.sh:364`), which routes to the active backend behind the scenes (keychain, pass, age, etc. via `detect_vault_backend`). It reads the secret from stdin — that's the API used by `dbx vault set` too.

- [ ] **Step 2: Manual verification**

```bash
# Fresh alias (no vault entry yet)
dbx host add
# Walk to credentials → enter a password → expect "Credentials stored."
dbx vault get <alias>   # verify the password round-trips

# Second run with the same alias
dbx host add
# Walk to credentials → expect "Use existing / Replace" prompt
# Pick "Use existing" → no prompt for new password, proceeds
```

- [ ] **Step 3: Commit**

```bash
git add dbx
git commit -m "feat(host): wizard credentials step (vault_set with collision handling)

Stores the password via the active vault backend. If an entry exists
for this alias already (prior failed run), the user can keep or
replace it instead of being silently overwritten."
```

---

## Task 8: Wizard — provisional write + `cmd_test` validation

**Goal:** First config write. After credentials, atomically add the host block to `config.json`, then run `cmd_test "$alias"` and check the exit code. On success, advance to the database picker (next task). On failure, the user is told the test failed — retry logic lands in Task 9.

**Files:**
- Modify: `dbx` (extend `host_add`)

- [ ] **Step 1: Add the provisional-write helper inline**

Just above `host_add`, add:

```bash
# Write a host block to $CONFIG_FILE atomically via jq + temp-file.
# Args: alias, type, user, then either:
#   "direct" <host> <port>
#   "tunnel" <jump_host> <target_host> <target_port>
host_write_block() {
  local alias="$1" type="$2" user="$3" mode="$4"
  local tmp; tmp=$(mktemp)
  if [[ "$mode" == "direct" ]]; then
    local h="$5" p="$6"
    jq --arg a "$alias" --arg t "$type" --arg u "$user" \
       --arg h "$h" --argjson p "$p" \
       '.hosts[$a] = {type: $t, host: $h, port: $p, user: $u, databases: {}}' \
       "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
  else
    local jh="$5" th="$6" tp="$7"
    jq --arg a "$alias" --arg t "$type" --arg u "$user" \
       --arg jh "$jh" --arg th "$th" --argjson tp "$tp" \
       '.hosts[$a] = {type: $t, user: $u, ssh_tunnel: {jump_host: $jh, target_host: $th, target_port: $tp}, databases: {}}' \
       "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
  fi
  secure_file "$CONFIG_FILE"
}

# Delete a host block from $CONFIG_FILE. Used by the wizard's rollback path.
host_delete_block() {
  local alias="$1"
  local tmp; tmp=$(mktemp)
  jq --arg a "$alias" 'del(.hosts[$a])' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
  secure_file "$CONFIG_FILE"
}
```

- [ ] **Step 2: Extend `host_add` with the provisional-write + validation call**

Replace the credentials-step `log_info "Credentials stored."` and surrounding placeholder/TODO with:

```bash
  log_info "Credentials stored."

  log_step "Writing provisional host block and validating..."
  if [[ "$network_mode" == "Direct connection" ]]; then
    host_write_block "$alias" "$new_type" "$new_user" direct "$direct_host" "$direct_port"
  else
    host_write_block "$alias" "$new_type" "$new_user" tunnel \
      "$tunnel_jump" "$tunnel_target" "$tunnel_port"
  fi

  if cmd_test "$alias"; then
    log_success "Connection validated."
  else
    log_error "Connection validation failed."
    log_warn "Wizard incomplete — retry/abort flow lands in the next commit."
    # TODO(Task 9): retry loop here.
    return 1
  fi

  log_warn "Wizard incomplete — database picker lands in the next commit."
  # TODO(Task 10): continue into database picker.
```

- [ ] **Step 3: Manual verification — happy path**

Have a local postgres container running. Then:

```bash
dbx host add
# alias: smoketest1; type: postgres; user: postgres
# Direct connection; host: localhost; port: 5432
# Password: devpassword (or whatever)
# Expect: provisional write happens, then cmd_test runs and prints its
# 5-step output, ending with "All connection tests passed for: smoketest1"
# and then "Connection validated." + the incomplete-wizard warning.

# Verify the host was actually written
jq '.hosts.smoketest1' ~/.config/dbx/config.json
```

Cleanup: `jq 'del(.hosts.smoketest1)' ~/.config/dbx/config.json > /tmp/c && mv /tmp/c ~/.config/dbx/config.json && dbx vault delete smoketest1`.

- [ ] **Step 4: Manual verification — failure path**

```bash
dbx host add
# alias: smoketest2; type: postgres; user: postgres
# Direct connection; host: localhost; port: 5432
# Password: WRONG_PASSWORD
# Expect: provisional write happens, cmd_test runs, fails at "Database
# connection successful" or similar, prints "Connection validation failed"
# plus the incomplete-wizard warning, and exits 1.

# Important: at this point the broken host IS still in config.json (rollback
# lands in Task 9). Clean up manually for now:
jq 'del(.hosts.smoketest2)' ~/.config/dbx/config.json > /tmp/c && mv /tmp/c ~/.config/dbx/config.json
dbx vault delete smoketest2
```

- [ ] **Step 5: Commit**

```bash
git add dbx
git commit -m "feat(host): wizard provisional write + cmd_test validation

Writes the host block via atomic jq+temp-file and runs the existing
\`cmd_test\` pipeline against it. On success, prints 'Connection
validated.' and stops (database picker + retry loop land in follow-up
commits). On failure, leaves the broken host in config for now (clean
rollback lands with the retry loop)."
```

---

## Task 9: Wizard — retry loop (re-creds / re-host / save-anyway / abort+rollback)

**Goal:** Replace the bare "Connection validation failed → exit 1" path from Task 8 with the four-option retry loop from the spec. On abort, rolls back the config and the vault entry.

**Files:**
- Modify: `dbx` (rework `host_add` validation section into a loop)

- [ ] **Step 1: Refactor validation into a labeled loop**

In `dbx`, replace the entire `log_step "Writing provisional host block..."` block from Task 8 (down through the `return 1` after the failure log) with:

```bash
  while :; do
    log_step "Writing provisional host block and validating..."
    if [[ "$network_mode" == "Direct connection" ]]; then
      host_write_block "$alias" "$new_type" "$new_user" direct "$direct_host" "$direct_port"
    else
      host_write_block "$alias" "$new_type" "$new_user" tunnel \
        "$tunnel_jump" "$tunnel_target" "$tunnel_port"
    fi

    if cmd_test "$alias"; then
      log_success "Connection validated."
      break
    fi

    log_error "Connection validation failed."
    local recover
    recover=$(gum choose --header "What now?" \
      "Re-enter credentials and retry" \
      "Re-enter host fields and retry" \
      "Save anyway (broken host kept in config)" \
      "Abort and roll back")

    case "$recover" in
      "Re-enter credentials and retry")
        local new_pass
        new_pass=$(gum input --password --header "New password for '$alias':")
        [[ -z "$new_pass" ]] && { log_info "Aborted."; host_delete_block "$alias"; keychain_delete "$alias" 2>/dev/null || true; return 1; }
        keychain_set "$alias" "$new_pass"
        continue
        ;;
      "Re-enter host fields and retry")
        # Re-collect network branch only; identity stays.
        network_mode=$(gum choose --header "How does dbx reach this database?" \
          "Direct connection" "SSH tunnel (jump host)")
        [[ -z "$network_mode" ]] && { log_info "Aborted."; host_delete_block "$alias"; keychain_delete "$alias" 2>/dev/null || true; return 1; }
        if [[ "$network_mode" == "Direct connection" ]]; then
          direct_host=$(gum input --header "Host address:" --value "${direct_host:-localhost}")
          direct_port=$(gum input --header "Port:" --value "${direct_port:-$default_port}")
        else
          tunnel_jump=$(gum input --header "SSH jump host:" --value "${tunnel_jump:-}")
          tunnel_target=$(gum input --header "Database hostname:" --value "${tunnel_target:-}")
          tunnel_port=$(gum input --header "Database port:" --value "${tunnel_port:-$default_port}")
        fi
        continue
        ;;
      "Save anyway (broken host kept in config)")
        log_warn "Host '$alias' saved with failing connection test. Fix it with: dbx config edit"
        return 0
        ;;
      "Abort and roll back"|"")
        log_info "Rolling back..."
        host_delete_block "$alias"
        keychain_delete "$alias" 2>/dev/null || true
        log_info "Rolled back. Config and vault unchanged."
        return 1
        ;;
    esac
  done
```

The trailing `# TODO(Task 10): continue into database picker.` line and the `log_warn "Wizard incomplete..."` from Task 8 stay as-is *after* the loop — they get replaced in Task 10.

- [ ] **Step 2: Manual verification — abort rollback**

```bash
dbx host add
# alias: rolltest1; postgres; user=postgres
# Direct; localhost; 5432
# Password: WRONG
# Wait for failure → pick "Abort and roll back"
# Expect: "Rolling back..." then "Rolled back. Config and vault unchanged."

jq '.hosts.rolltest1' ~/.config/dbx/config.json  # → null
dbx vault get rolltest1                          # → no entry
```

- [ ] **Step 3: Manual verification — retry creds then succeed**

```bash
dbx host add
# alias: retrytest1; postgres; user=postgres
# Direct; localhost; 5432
# Password: WRONG
# Failure → pick "Re-enter credentials and retry" → enter correct password
# Expect: validation re-runs and succeeds; "Connection validated."

# Cleanup
jq 'del(.hosts.retrytest1)' ~/.config/dbx/config.json > /tmp/c && mv /tmp/c ~/.config/dbx/config.json
dbx vault delete retrytest1
```

- [ ] **Step 4: Manual verification — save anyway**

```bash
dbx host add
# alias: saveanyway1; postgres; user=postgres
# Direct; localhost; 9999  (wrong port)
# Password: anything
# Failure → pick "Save anyway"
# Expect: warning that host is saved with failing test; exit 0.

jq '.hosts.saveanyway1' ~/.config/dbx/config.json  # → block exists

# Cleanup
jq 'del(.hosts.saveanyway1)' ~/.config/dbx/config.json > /tmp/c && mv /tmp/c ~/.config/dbx/config.json
dbx vault delete saveanyway1 2>/dev/null || true
```

- [ ] **Step 5: Commit**

```bash
git add dbx
git commit -m "feat(host): wizard validation retry loop with rollback

Replaces the bare validation-fail-and-exit path with a four-choice
recovery prompt: re-enter creds, re-enter host fields, save-anyway, or
abort. Abort restores both the config and vault to their pre-wizard
state."
```

---

## Task 10: Wizard — database picker

**Goal:** After a successful validation, list the user-visible databases on the server and let the user multi-select which ones to back up. Empty selection is fine — write `databases: {}`.

**Files:**
- Modify: `dbx` (extend `host_add` after the validation loop)

- [ ] **Step 1: Add the database picker**

Replace the trailing `log_warn "Wizard incomplete — database picker lands..."` line and its TODO with:

```bash
  local remote_dbs picked
  remote_dbs=$(list_remote_databases "$alias" 2>/dev/null | grep -v '^$' || true)

  if [[ -z "$remote_dbs" ]]; then
    log_warn "No user databases found on '$alias' (or list query failed)."
    log_info "Continuing with empty database list — add them later via the TUI."
    picked=""
  else
    picked=$(echo "$remote_dbs" | gum choose --no-limit \
      --header "Pick databases to back up (space to toggle, enter to confirm):")
    if [[ -z "$picked" ]]; then
      log_info "No databases selected."
    fi
  fi

  log_warn "Wizard incomplete — per-database options + summary land in the next commit."
  # TODO(Task 11): per-database exclude + definer; write databases block; print summary.
```

- [ ] **Step 2: Manual verification**

```bash
# Have a postgres-dbx container with a couple of databases.
docker exec postgres-dbx createdb -U postgres pickerdb1 >/dev/null 2>&1 || true
docker exec postgres-dbx createdb -U postgres pickerdb2 >/dev/null 2>&1 || true

dbx host add
# Walk through to validation success
# Expect: a gum multi-select listing postgres, pickerdb1, pickerdb2
# Pick pickerdb1 + pickerdb2 → message about wizard incomplete

# Cleanup
docker exec postgres-dbx dropdb -U postgres pickerdb1 >/dev/null 2>&1 || true
docker exec postgres-dbx dropdb -U postgres pickerdb2 >/dev/null 2>&1 || true
```

- [ ] **Step 3: Commit**

```bash
git add dbx
git commit -m "feat(host): wizard database picker

After successful validation, list user-visible databases on the server
and let the user multi-select via gum. Empty selection writes
\`databases: {}\` and lets the user add later via the TUI."
```

---

## Task 11: Wizard — per-database options + final summary

**Goal:** Loop over each picked database, prompt for excludes; once per host, prompt for definer handling (MySQL only); write the `databases` block and definer; print summary; exit 0.

**Files:**
- Modify: `dbx` (extend `host_add`)

- [ ] **Step 1: Replace the picker's trailing placeholder**

Replace the `log_warn "Wizard incomplete — per-database options..."` and TODO with:

```bash
  # Per-database exclude tables.
  if [[ -n "$picked" ]]; then
    while IFS= read -r db; do
      [[ -z "$db" ]] && continue
      local excl
      excl=$(gum input --header "Tables to exclude data from in '$db' (comma-separated, blank for none):")
      local tmp; tmp=$(mktemp)
      if [[ -n "$excl" ]]; then
        local excl_json
        excl_json=$(printf '%s' "$excl" | tr ',' '\n' \
          | awk 'NF { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0); print }' \
          | jq -R . | jq -s .)
        jq --arg a "$alias" --arg d "$db" --argjson e "$excl_json" \
           '.hosts[$a].databases[$d] = {exclude_data: $e}' \
           "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
      else
        jq --arg a "$alias" --arg d "$db" \
           '.hosts[$a].databases[$d] = {}' \
           "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
      fi
      secure_file "$CONFIG_FILE"
    done <<< "$picked"
  fi

  # MySQL-only: strip DEFINER clauses? Default yes.
  if [[ "$new_type" == "mysql" ]]; then
    local definer_value
    if gum confirm --default=true "Strip DEFINER clauses from MySQL dumps?"; then
      definer_value="strip"
    else
      definer_value="keep"
    fi
    local tmp; tmp=$(mktemp)
    jq --arg a "$alias" --arg dh "$definer_value" \
       '.hosts[$a].definer_handling = $dh' \
       "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    secure_file "$CONFIG_FILE"
  fi

  # Summary.
  local db_count
  db_count=$(printf '%s' "$picked" | grep -c . || true)
  echo
  log_success "Host '$alias' added."
  log_info "  Type:      $new_type"
  if [[ "$network_mode" == "Direct connection" ]]; then
    log_info "  Network:   direct ($direct_host:$direct_port)"
  else
    log_info "  Network:   ssh tunnel via $tunnel_jump to $tunnel_target:$tunnel_port"
  fi
  log_info "  Databases: ${db_count:-0}"
  log_info "Try: dbx backup $alias"
}
```

- [ ] **Step 2: Manual verification — postgres happy path**

```bash
docker exec postgres-dbx createdb -U postgres summarydb1 >/dev/null 2>&1 || true
dbx host add
# alias=summarytest; postgres; postgres; direct; localhost; 5432; correct password
# Pick summarydb1 only
# When asked for excludes, leave blank
# Expect: summary "Host 'summarytest' added", Databases: 1
jq '.hosts.summarytest' ~/.config/dbx/config.json
# Cleanup
jq 'del(.hosts.summarytest)' ~/.config/dbx/config.json > /tmp/c && mv /tmp/c ~/.config/dbx/config.json
dbx vault delete summarytest
docker exec postgres-dbx dropdb -U postgres summarydb1 >/dev/null 2>&1 || true
```

- [ ] **Step 3: Manual verification — MySQL definer prompt**

```bash
dbx host add
# alias=mysqltest; mysql; root; direct; localhost; 3306; devpassword
# Pick at least one db, leave excludes blank
# Definer prompt: confirm yes
# Expect: jq shows .hosts.mysqltest.definer_handling == "strip"

# Re-run; this time confirm no for definer prompt
# Expect: .definer_handling == "keep"

# Cleanup similarly.
```

- [ ] **Step 4: Manual verification — end-to-end with backup**

```bash
# After a happy-path add, prove the new host actually works for backup:
dbx backup <alias>
# Expect: backup succeeds, file shows up under DBX_DATA_DIR/<alias>/<db>/
```

- [ ] **Step 5: Commit**

```bash
git add dbx
git commit -m "feat(host): wizard per-database options + summary

For each picked database, prompts for tables to exclude from data dumps.
On MySQL hosts, prompts once for DEFINER handling (strip/keep). Writes
final config block, prints summary, and points the user at \`dbx backup\`.
End-to-end wizard is now functional."
```

---

## Task 12: TUI consolidation — `tui_config_add_host` calls `dbx host add`

**Goal:** Replace the existing 30-line `tui_config_add_host` body with a shell-out to the new wizard, matching the surrounding pattern (`dbx vault set`, `dbx config edit`).

**Files:**
- Modify: `lib/tui.sh` (function body at line 673)

- [ ] **Step 1: Replace the function body**

In `lib/tui.sh`, replace the entire `tui_config_add_host` function (lines 673-699) with:

```bash
tui_config_add_host() {
  echo
  dbx host add
  sleep 1
}
```

- [ ] **Step 2: Manual verification**

```bash
dbx tui
# Navigate: Config → Add host
# Expect: drops out of the TUI menu rendering into the wizard; wizard
# behaves exactly as `dbx host add` does standalone; on completion (or
# abort), control returns to the TUI menu.
```

- [ ] **Step 3: Run the existing TUI unit tests for regressions**

Run: `bats tests/unit/tui.bats`
Expected: clean (the file doesn't currently assert on the old add-host gum prompts, so the change shouldn't break unit coverage).

- [ ] **Step 4: Commit**

```bash
git add lib/tui.sh
git commit -m "refactor(tui): consolidate add-host onto \`dbx host add\`

Drops the gum-prompt-and-jq block in tui_config_add_host in favor of
shelling out to the wizard. One implementation; matches the file's
existing pattern for \`dbx vault set\` and \`dbx config edit\`."
```

---

## Task 13: Integration tests

**Goal:** Drive `dbx host add` end-to-end against the real `postgres-dbx` / `mysql-dbx` containers, covering happy paths and the validation-retry path. Use stdin scripting (gum falls back to reading stdin when no controlling TTY is available); if any case proves unreliable, mark it with `# bats test_tags=needs-pty` and document the limitation.

**Files:**
- Create: `tests/integration/host_add.bats`

- [ ] **Step 1: Write the test file**

Create `tests/integration/host_add.bats`:

```bash
#!/usr/bin/env bats
# Integration tests for `dbx host add` wizard.
load '../helpers/integration'

setup() {
  setup_dbx_env
  require_docker
  command -v gum >/dev/null 2>&1 || skip "gum not installed"
  ensure_postgres_container
  # Fresh config; the wizard requires it to exist.
  echo '{"hosts": {}}' > "$DBX_CONFIG_DIR/config.json"
}

# Helper: drive the wizard with a multi-line stdin script.
# Args: each arg is one line of input (newline-separated when piped).
run_wizard() {
  local input
  input=$(printf '%s\n' "$@")
  echo "$input" | "$DBX_BIN" host add
}

@test "host add: postgres happy path, direct connection, one database" {
  docker exec postgres-dbx createdb -U postgres itdb1 >/dev/null 2>&1 || true

  run run_wizard \
    "ithappy1" \
    "postgres" \
    "postgres" \
    "Direct connection" \
    "127.0.0.1" \
    "5432" \
    "devpassword" \
    "itdb1" \
    "" \
    ""
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Connection validated" ]]
  [[ "$output" =~ "Host 'ithappy1' added" ]]

  # Config now contains the host
  result=$(jq -r '.hosts.ithappy1.type' "$DBX_CONFIG_DIR/config.json")
  [ "$result" = "postgres" ]
  result=$(jq -r '.hosts.ithappy1.databases.itdb1 | type' "$DBX_CONFIG_DIR/config.json")
  [ "$result" = "object" ]

  # Cleanup
  docker exec postgres-dbx dropdb -U postgres itdb1 >/dev/null 2>&1 || true
}

@test "host add: postgres bad password, abort, rolls back" {
  run run_wizard \
    "itabort1" \
    "postgres" \
    "postgres" \
    "Direct connection" \
    "127.0.0.1" \
    "5432" \
    "WRONG_PASSWORD" \
    "Abort and roll back"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Rolling back" ]]

  # Config has no record of the alias
  result=$(jq -r '.hosts | has("itabort1")' "$DBX_CONFIG_DIR/config.json")
  [ "$result" = "false" ]
}

@test "host add: postgres bad password, retry creds, succeeds" {
  docker exec postgres-dbx createdb -U postgres itretrydb1 >/dev/null 2>&1 || true

  run run_wizard \
    "itretry1" \
    "postgres" \
    "postgres" \
    "Direct connection" \
    "127.0.0.1" \
    "5432" \
    "WRONG_PASSWORD" \
    "Re-enter credentials and retry" \
    "devpassword" \
    "itretrydb1" \
    "" \
    ""
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Host 'itretry1' added" ]]

  # Cleanup
  docker exec postgres-dbx dropdb -U postgres itretrydb1 >/dev/null 2>&1 || true
}

@test "host add: collision with existing alias re-prompts" {
  # Pre-populate a host
  jq '.hosts.existing = {type: "postgres", user: "postgres"}' \
    "$DBX_CONFIG_DIR/config.json" > "$DBX_CONFIG_DIR/c" \
    && mv "$DBX_CONFIG_DIR/c" "$DBX_CONFIG_DIR/config.json"

  # First-attempt alias collides, second is unique → wizard proceeds
  # past identity step. We abort early at the network choice by sending
  # empty input.
  run run_wizard \
    "existing" \
    "freshalias" \
    "postgres" \
    "postgres" \
    ""
  # Empty input at network choice should abort cleanly.
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already exists" ]]
  [[ "$output" =~ "Aborted" ]]
}
```

- [ ] **Step 2: Run the integration tests**

```bash
bats tests/integration/host_add.bats
```

Expected: all four pass. If any case shows flakiness around gum's stdin handling, add `# bats test_tags=needs-pty` to that case and add a brief skip line at the top of the test (`skip "needs PTY emulator; run manually"`). Open a follow-up issue noting which case was deferred.

- [ ] **Step 3: Confirm CI config picks them up**

```bash
grep -A 5 "Integration tests" .github/workflows/ci.yml
```

The existing integration job globs `tests/integration/*.bats`, so the new file is picked up automatically. No CI changes needed.

- [ ] **Step 4: Commit**

```bash
git add tests/integration/host_add.bats
git commit -m "test(host): integration tests for \`dbx host add\` wizard

Covers postgres happy path, abort+rollback, retry-creds-then-succeed,
and alias collision. Drives gum via piped stdin against the existing
postgres-dbx integration container."
```

---

## Task 14: `storage_test_roundtrip` helper

**Goal:** New helper in `lib/storage.sh` that proves the current S3 config works end-to-end: upload a 1-byte file → list it → download it (byte-identical) → delete it. Used by `dbx storage add` for live validation; available standalone for a future `dbx storage test` action.

**Files:**
- Create: `tests/unit/storage_add.bats`
- Modify: `lib/storage.sh` (append helper)

- [ ] **Step 1: Write the failing test**

```bash
# tests/unit/storage_add.bats
#!/usr/bin/env bats
load '../helpers/common'
setup() { setup_dbx_env; source_dbx_libs; }

# Stub storage_upload/list/download/delete so we can test the
# orchestration logic of storage_test_roundtrip without a real S3.
stub_storage_ok() {
  storage_upload()   { echo "uploaded:$1:$2"; return 0; }
  storage_list()     { echo ".dbx-test/probe"; return 0; }
  storage_download() {
    local remote="$1" local_file="$2"
    cp "${UPLOAD_SRC:-/dev/null}" "$local_file" 2>/dev/null
    return 0
  }
  storage_delete()   { return 0; }
}
stub_storage_upload_fail()   { storage_upload()   { return 1; }; stub_storage_ok_rest; }
stub_storage_list_missing()  { storage_list()     { echo "other-file"; }; stub_storage_ok_rest; }
stub_storage_download_fail() { storage_download() { return 1; }; stub_storage_ok_rest; }
stub_storage_delete_fail()   { storage_delete()   { return 1; }; stub_storage_ok_rest; }
stub_storage_ok_rest() {
  storage_upload()   { echo "uploaded"; return 0; } unless_defined
  storage_list()     { echo ".dbx-test/probe"; }    unless_defined
  storage_download() { cp "${UPLOAD_SRC:-/dev/null}" "$2"; return 0; } unless_defined
  storage_delete()   { return 0; }                   unless_defined
}
# Helper to no-op if the stub above already defined the function
unless_defined() { :; }

@test "storage_test_roundtrip: all steps succeed -> exit 0" {
  stub_storage_ok
  export UPLOAD_SRC=""
  : > "$BATS_TEST_TMPDIR/probesrc"
  export UPLOAD_SRC="$BATS_TEST_TMPDIR/probesrc"
  run storage_test_roundtrip
  [ "$status" -eq 0 ]
}

@test "storage_test_roundtrip: upload failure -> non-zero" {
  stub_storage_upload_fail
  run storage_test_roundtrip
  [ "$status" -ne 0 ]
  [[ "$output" =~ "upload" ]]
}

@test "storage_test_roundtrip: list doesn't contain probe -> non-zero" {
  stub_storage_list_missing
  run storage_test_roundtrip
  [ "$status" -ne 0 ]
  [[ "$output" =~ "list" ]]
}

@test "storage_test_roundtrip: download byte-mismatch -> non-zero" {
  stub_storage_ok
  export UPLOAD_SRC="$BATS_TEST_TMPDIR/probesrc"
  echo "WRONG" > "$BATS_TEST_TMPDIR/probesrc"
  # Override download to write a different byte
  storage_download() { echo "different" > "$2"; return 0; }
  run storage_test_roundtrip
  [ "$status" -ne 0 ]
  [[ "$output" =~ "mismatch" ]]
}

@test "storage_test_roundtrip: delete failure -> non-zero" {
  stub_storage_ok
  export UPLOAD_SRC="$BATS_TEST_TMPDIR/probesrc"
  : > "$BATS_TEST_TMPDIR/probesrc"
  storage_delete() { return 1; }
  run storage_test_roundtrip
  [ "$status" -ne 0 ]
  [[ "$output" =~ "delete" ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/storage_add.bats`
Expected: All fail with `command not found: storage_test_roundtrip`.

- [ ] **Step 3: Implement the helper**

Append to `lib/storage.sh`:

```bash
# End-to-end validation of the configured S3 storage. Uploads a 1-byte
# probe file to .dbx-test/<timestamp>, lists the prefix to confirm,
# downloads it and checks byte-identity, then deletes it. Returns 0
# only if all four steps succeed; returns 1 with the failing step
# logged. Side effects on the bucket are cleaned up unless delete fails.
storage_test_roundtrip() {
  is_storage_configured || { log_error "storage not configured"; return 1; }

  local ts probe_src probe_local probe_remote
  ts=$(date +%s)
  probe_src=$(mktemp)
  printf '.' > "$probe_src"   # 1-byte payload
  probe_remote=".dbx-test/probe-${ts}"
  probe_local=$(mktemp)

  log_info "storage test: upload"
  if ! storage_upload "$probe_src" "$probe_remote" >/dev/null 2>&1; then
    log_error "storage test: upload failed"
    rm -f "$probe_src" "$probe_local"
    return 1
  fi

  log_info "storage test: list"
  if ! storage_list ".dbx-test" 2>/dev/null | grep -q "probe-${ts}"; then
    log_error "storage test: list did not contain the uploaded probe"
    storage_delete "$probe_remote" >/dev/null 2>&1 || true
    rm -f "$probe_src" "$probe_local"
    return 1
  fi

  log_info "storage test: download"
  if ! storage_download "$probe_remote" "$probe_local" >/dev/null 2>&1; then
    log_error "storage test: download failed"
    storage_delete "$probe_remote" >/dev/null 2>&1 || true
    rm -f "$probe_src" "$probe_local"
    return 1
  fi

  if ! cmp -s "$probe_src" "$probe_local"; then
    log_error "storage test: downloaded bytes mismatch original"
    storage_delete "$probe_remote" >/dev/null 2>&1 || true
    rm -f "$probe_src" "$probe_local"
    return 1
  fi

  log_info "storage test: delete"
  if ! storage_delete "$probe_remote" >/dev/null 2>&1; then
    log_error "storage test: delete failed (probe left in bucket)"
    rm -f "$probe_src" "$probe_local"
    return 1
  fi

  rm -f "$probe_src" "$probe_local"
  log_success "storage test: round-trip OK"
  return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/unit/storage_add.bats`
Expected: 5/5 pass.

- [ ] **Step 5: Commit**

```bash
git add tests/unit/storage_add.bats lib/storage.sh
git commit -m "feat(storage): add storage_test_roundtrip helper

Proves the current S3 config works end-to-end: upload-list-download-
delete a 1-byte probe under .dbx-test/<ts>. Catches the
read-but-no-write IAM case that a bare list-bucket check would miss.
Used by the upcoming storage-add wizard for live validation."
```

---

## Task 15: `cmd_storage add` dispatcher slot + `storage_add` scaffold

**Goal:** Add an `add` action to the existing `cmd_storage` dispatcher in `dbx`. Initial implementation calls a `storage_add` stub that errors. Subsequent tasks fill in the wizard body.

**Files:**
- Modify: `dbx` (extend `cmd_storage`, add `storage_add` stub, help text)

- [ ] **Step 1: Write the failing test**

Append to `tests/unit/storage_add.bats`:

```bash
@test "dbx storage add errors with not-yet-implemented (placeholder)" {
  run "$DBX_BIN" storage add
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not yet implemented" ]]
}

@test "dbx help mentions storage add" {
  run "$DBX_BIN" help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "storage add" ]]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/unit/storage_add.bats -f "storage add"`
Expected: both fail (dispatch returns "unknown action" today).

- [ ] **Step 3: Extend `cmd_storage`**

In `dbx`, find the existing `cmd_storage()` (around line 972). In its `case "$action"` block, add a new branch **before** the `*)` catch-all:

```bash
    add)
      storage_add "$@"
      ;;
```

Also update the error message in the catch-all to include `add`:

```bash
    *)
      die "Unknown storage action: $action (use: upload, download, list, delete, sync, info, add)"
      ;;
```

- [ ] **Step 4: Add the `storage_add` stub above `cmd_storage`**

```bash
storage_add() {
  require_config
  require_jq
  require_gum
  require_s3_client
  die "storage add: not yet implemented"
}
```

- [ ] **Step 5: Update help text**

In `cmd_help`, in the `SCHEDULING & STORAGE:` block (around line 1233-1236), add **after** the existing storage lines:

```
  storage add                  Interactively configure remote storage (S3/MinIO) + live test
```

- [ ] **Step 6: Verify tests pass + shellcheck**

```bash
bats tests/unit/storage_add.bats
bash -n dbx && shellcheck -S error dbx lib/*.sh
```
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add dbx tests/unit/storage_add.bats
git commit -m "feat(storage): add cmd_storage 'add' dispatcher slot

Stub for the upcoming interactive wizard. Currently dies with 'not yet
implemented'; the wizard body lands in follow-up commits."
```

---

## Task 16: Storage wizard — provider branch + bucket + prefix

**Goal:** Real `storage_add` starts here. Collects provider (AWS S3 vs S3-compatible), endpoint (S3-compatible only), region (required for AWS, optional for S3-compatible), bucket, prefix. No config writes yet — accumulate in locals.

**Files:**
- Modify: `dbx` (extend `storage_add`)

- [ ] **Step 1: Implement the provider/bucket/prefix steps**

Replace the `die "storage add: not yet implemented"` line in `storage_add` with:

```bash
  # If storage is already configured, ask whether to replace.
  if is_storage_configured; then
    local existing
    existing=$(get_config_value ".storage.s3.endpoint" 2>/dev/null || echo "AWS S3")
    if ! gum confirm --default=false "Storage is already configured (${existing}). Replace?"; then
      log_info "Keeping existing storage config."
      return 0
    fi
  fi

  # Provider branch
  local provider endpoint region bucket prefix
  provider=$(gum choose --header "Storage provider:" \
    "AWS S3" "S3-compatible (MinIO, R2, B2, ...)")
  [[ -z "$provider" ]] && { log_info "Aborted."; return 0; }

  if [[ "$provider" == "AWS S3" ]]; then
    endpoint=""   # signal "no endpoint" → aws CLI uses default
    region=$(gum input --header "AWS region:" --placeholder "us-east-1")
    [[ -z "$region" ]] && { log_info "Aborted."; return 0; }
  else
    endpoint=$(gum input --header "Endpoint URL:" --placeholder "https://minio.example.com")
    [[ -z "$endpoint" ]] && { log_info "Aborted."; return 0; }
    region=$(gum input --header "Region (optional, blank to skip):")
    # blank region OK for S3-compatible
  fi

  bucket=$(gum input --header "Bucket:" --placeholder "backups")
  [[ -z "$bucket" ]] && { log_info "Aborted."; return 0; }

  prefix=$(gum input --header "Prefix / path (blank for bucket root):")
  # blank prefix OK

  log_info "Collected: provider=$provider bucket=$bucket prefix='${prefix}' region='${region}' endpoint='${endpoint}'"
  log_warn "Wizard incomplete — credentials + validation land in follow-up commits."
  # TODO(Task 17): credentials step
```

- [ ] **Step 2: Manual verification**

```bash
dbx storage add
# Pick "AWS S3" → enter region "us-east-1" → bucket "mybucket" → prefix "dbx"
# Expect: prints "Collected: provider=AWS S3 ..." + incomplete warning

dbx storage add
# Pick S3-compatible → endpoint "http://localhost:9000" → blank region → bucket "test"
# Expect: similar message
```

- [ ] **Step 3: Commit**

```bash
git add dbx
git commit -m "feat(storage): wizard provider branch + bucket + prefix

Collects provider type, endpoint (S3-compatible only), region (required
for AWS, optional otherwise), bucket, prefix. No config writes yet."
```

---

## Task 17: Storage wizard — credentials step

**Goal:** Prompt for access_key (visible) and secret_key (hidden), store secret in vault under `s3-secret-key`.

**Files:**
- Modify: `dbx` (extend `storage_add`)

- [ ] **Step 1: Implement the credentials step**

Replace the trailing `log_info "Collected: ..."` / `log_warn` / TODO from Task 16 with:

```bash
  local access_key
  access_key=$(gum input --header "Access key:" --placeholder "AKIA…")
  [[ -z "$access_key" ]] && { log_info "Aborted."; return 0; }

  # Vault may already contain a secret from a prior run.
  local existing_secret
  existing_secret=$(keychain_get "s3-secret-key" 2>/dev/null || true)
  if [[ -n "$existing_secret" ]]; then
    local secret_choice
    secret_choice=$(gum choose --header "Vault already has an S3 secret key." \
                               "Use existing" "Replace")
    [[ -z "$secret_choice" ]] && { log_info "Aborted."; return 0; }
    if [[ "$secret_choice" == "Replace" ]]; then
      local new_secret
      new_secret=$(gum input --password --header "New S3 secret key:")
      [[ -z "$new_secret" ]] && { log_info "Aborted."; return 0; }
      keychain_set "s3-secret-key" "$new_secret"
    fi
  else
    local new_secret
    new_secret=$(gum input --password --header "S3 secret key:")
    [[ -z "$new_secret" ]] && { log_info "Aborted."; return 0; }
    keychain_set "s3-secret-key" "$new_secret"
  fi

  log_info "Credentials collected (secret stored in vault)."
  log_warn "Wizard incomplete — validation + write land in the next commit."
  # TODO(Task 18): provisional write + round-trip test
```

- [ ] **Step 2: Manual verification**

```bash
dbx vault delete s3-secret-key 2>/dev/null || true
dbx storage add
# Walk through to credentials
# Enter access "AKIA_TEST", secret "test_secret"
# Expect: "Credentials collected" message

dbx vault get s3-secret-key   # verify round-trip

dbx storage add
# Walk to credentials → expect Use existing / Replace prompt
```

- [ ] **Step 3: Commit**

```bash
git add dbx
git commit -m "feat(storage): wizard credentials step

Prompts for access key (visible) and secret key (hidden), stores secret
in the vault under 's3-secret-key' (existing storage.sh convention).
Offers Use existing / Replace on collision."
```

---

## Task 18: Storage wizard — provisional write + round-trip + retry/save-anyway/abort

**Goal:** Write the `.storage` block, run `storage_test_roundtrip`, and on failure offer the same four-choice recovery loop as the host wizard.

**Files:**
- Modify: `dbx` (extend `storage_add`; add `storage_write_block` + `storage_delete_block` helpers above it)

- [ ] **Step 1: Add the write/delete helpers above `storage_add`**

```bash
# Atomically write the .storage.s3 block to $CONFIG_FILE.
# Args: provider ("AWS S3"|"S3-compatible"), endpoint, region, bucket, prefix, access_key
storage_write_block() {
  local provider="$1" endpoint="$2" region="$3" bucket="$4" prefix="$5" access_key="$6"
  local tmp; tmp=$(mktemp)
  jq --arg ep "$endpoint" --arg rg "$region" --arg bk "$bucket" \
     --arg px "$prefix" --arg ak "$access_key" \
     '.storage = {type: "s3", s3: ({endpoint: $ep, region: $rg, bucket: $bk, prefix: $px, access_key: $ak} | with_entries(select(.value != "")))}' \
     "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
  secure_file "$CONFIG_FILE"
}

# Delete the .storage block. Used by the rollback path.
storage_delete_block() {
  local tmp; tmp=$(mktemp)
  jq 'del(.storage)' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
  secure_file "$CONFIG_FILE"
}
```

- [ ] **Step 2: Replace the trailing placeholder in `storage_add`**

Replace the `log_info "Credentials collected..."` / `log_warn` / TODO from Task 17 with:

```bash
  while :; do
    log_step "Writing provisional storage config and running round-trip test..."
    storage_write_block "$provider" "$endpoint" "$region" "$bucket" "$prefix" "$access_key"

    if storage_test_roundtrip; then
      log_success "Storage validated."
      break
    fi

    log_error "Storage validation failed."
    local recover
    recover=$(gum choose --header "What now?" \
      "Re-enter credentials and retry" \
      "Re-enter all storage fields and retry" \
      "Save anyway (broken storage kept in config)" \
      "Abort and roll back")

    case "$recover" in
      "Re-enter credentials and retry")
        access_key=$(gum input --header "Access key:" --value "$access_key")
        [[ -z "$access_key" ]] && { log_info "Aborted."; storage_delete_block; keychain_delete "s3-secret-key" 2>/dev/null || true; return 1; }
        local new_secret
        new_secret=$(gum input --password --header "S3 secret key:")
        [[ -z "$new_secret" ]] && { log_info "Aborted."; storage_delete_block; keychain_delete "s3-secret-key" 2>/dev/null || true; return 1; }
        keychain_set "s3-secret-key" "$new_secret"
        continue
        ;;
      "Re-enter all storage fields and retry")
        # Re-run provider branch with previous values as defaults.
        provider=$(gum choose --header "Storage provider:" "AWS S3" "S3-compatible (MinIO, R2, B2, ...)")
        if [[ "$provider" == "AWS S3" ]]; then
          endpoint=""
          region=$(gum input --header "AWS region:" --value "${region:-us-east-1}")
        else
          endpoint=$(gum input --header "Endpoint URL:" --value "${endpoint:-}")
          region=$(gum input --header "Region (optional):" --value "${region:-}")
        fi
        bucket=$(gum input --header "Bucket:" --value "${bucket:-}")
        prefix=$(gum input --header "Prefix:" --value "${prefix:-}")
        continue
        ;;
      "Save anyway (broken storage kept in config)")
        log_warn "Storage saved with failing round-trip test. Fix it with: dbx config edit"
        return 0
        ;;
      "Abort and roll back"|"")
        log_info "Rolling back..."
        storage_delete_block
        keychain_delete "s3-secret-key" 2>/dev/null || true
        log_info "Rolled back. Config and vault unchanged."
        return 1
        ;;
    esac
  done

  log_warn "Wizard incomplete — summary lands in the next commit."
  # TODO(Task 19): summary
```

- [ ] **Step 3: Manual verification (happy path)**

If you have a real S3 / MinIO available:

```bash
dbx storage add
# Walk through full flow with valid creds
# Expect: "Writing provisional storage config..."
# storage test prints: upload, list, download, delete, "round-trip OK"
# Then "Storage validated."
# Then the incomplete-wizard warning (summary lands next).

# Cleanup
jq 'del(.storage)' ~/.config/dbx/config.json > /tmp/c && mv /tmp/c ~/.config/dbx/config.json
dbx vault delete s3-secret-key
```

- [ ] **Step 4: Manual verification (abort rollback)**

```bash
dbx storage add
# Use deliberately wrong endpoint or wrong secret → wait for failure
# Pick "Abort and roll back"
# Expect: "Rolling back..." → "Rolled back. Config and vault unchanged."
jq '.storage' ~/.config/dbx/config.json   # → null
dbx vault get s3-secret-key                 # → no entry
```

- [ ] **Step 5: Commit**

```bash
git add dbx
git commit -m "feat(storage): wizard provisional write + round-trip + retry loop

Atomic write of .storage block, then storage_test_roundtrip against the
live bucket. Four-choice recovery on failure (re-creds / re-fields /
save-anyway / abort). Abort restores both config and vault."
```

---

## Task 19: Storage wizard — summary

**Goal:** Print a short summary after a successful validation and exit 0.

**Files:**
- Modify: `dbx` (extend `storage_add`)

- [ ] **Step 1: Replace the trailing placeholder**

Replace the `log_warn "Wizard incomplete — summary lands..."` and TODO with:

```bash
  echo
  log_success "Remote storage configured."
  if [[ "$provider" == "AWS S3" ]]; then
    log_info "  Provider:  AWS S3 (region: $region)"
  else
    log_info "  Provider:  S3-compatible ($endpoint)"
  fi
  log_info "  Bucket:    $bucket"
  log_info "  Prefix:    ${prefix:-(root)}"
  log_info "Try: dbx storage list   (after your first backup uploads)"
}
```

(Closing `}` of `storage_add` goes here.)

- [ ] **Step 2: Manual verification**

```bash
dbx storage add
# Full happy-path run → expect summary lines + exit 0
```

- [ ] **Step 3: Commit**

```bash
git add dbx
git commit -m "feat(storage): wizard final summary

Prints provider/bucket/prefix after a successful round-trip and exits 0.
End-to-end storage wizard is now functional."
```

---

## Task 20: MinIO test helper + storage integration tests

**Goal:** Add a reusable `ensure_minio_container` helper to `tests/helpers/integration.bash` and write end-to-end tests for `dbx storage add` against it.

**Files:**
- Modify: `tests/helpers/integration.bash`
- Create: `tests/integration/storage_add.bats`

- [ ] **Step 1: Add the MinIO helper**

In `tests/helpers/integration.bash`, after `ensure_mysql_container` (find by grep), append:

```bash
# Boot a minio-dbx container if it isn't running. Idempotent.
# Exposes :9100 (S3 API) on 127.0.0.1. Root creds: minioadmin / minioadmin.
ensure_minio_container() {
  if ! docker ps --format '{{.Names}}' | grep -q '^minio-dbx$'; then
    if docker ps -a --format '{{.Names}}' | grep -q '^minio-dbx$'; then
      docker start minio-dbx >/dev/null
    else
      docker run -d --name minio-dbx \
        -p 127.0.0.1:9100:9000 \
        -e MINIO_ROOT_USER=minioadmin \
        -e MINIO_ROOT_PASSWORD=minioadmin \
        minio/minio:latest server /data >/dev/null
    fi
    # Wait for ready
    for _ in $(seq 1 30); do
      curl -fsS http://127.0.0.1:9100/minio/health/live >/dev/null 2>&1 && return 0
      sleep 1
    done
    echo "minio-dbx failed to become ready" >&2
    return 1
  fi
}

# Create a bucket on the local MinIO via mc, idempotently.
ensure_minio_bucket() {
  local bucket="$1"
  command -v mc >/dev/null 2>&1 || skip "mc not installed"
  mc alias set dbxtest http://127.0.0.1:9100 minioadmin minioadmin --api S3v4 >/dev/null 2>&1
  mc mb --ignore-existing "dbxtest/$bucket" >/dev/null 2>&1
}
```

- [ ] **Step 2: Write the integration test**

Create `tests/integration/storage_add.bats`:

```bash
#!/usr/bin/env bats
# Integration tests for `dbx storage add` wizard.
load '../helpers/integration'

setup() {
  setup_dbx_env
  require_docker
  command -v gum >/dev/null 2>&1 || skip "gum not installed"
  command -v mc >/dev/null 2>&1 || skip "mc not installed (S3 client)"
  ensure_minio_container
  ensure_minio_bucket "dbxtest-bucket"
  echo '{"hosts": {}}' > "$DBX_CONFIG_DIR/config.json"
}

run_wizard() {
  local input
  input=$(printf '%s\n' "$@")
  echo "$input" | "$DBX_BIN" storage add
}

@test "storage add: happy path against local MinIO" {
  run run_wizard \
    "S3-compatible (MinIO, R2, B2, ...)" \
    "http://127.0.0.1:9100" \
    "" \
    "dbxtest-bucket" \
    "smoketest" \
    "minioadmin" \
    "minioadmin"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "round-trip OK" ]]
  [[ "$output" =~ "Remote storage configured" ]]

  result=$(jq -r '.storage.s3.bucket' "$DBX_CONFIG_DIR/config.json")
  [ "$result" = "dbxtest-bucket" ]
  result=$(jq -r '.storage.s3.endpoint' "$DBX_CONFIG_DIR/config.json")
  [ "$result" = "http://127.0.0.1:9100" ]
}

@test "storage add: wrong secret key, abort, rolls back" {
  run run_wizard \
    "S3-compatible (MinIO, R2, B2, ...)" \
    "http://127.0.0.1:9100" \
    "" \
    "dbxtest-bucket" \
    "" \
    "minioadmin" \
    "WRONG_SECRET" \
    "Abort and roll back"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Rolling back" ]]

  result=$(jq -r '.storage // "null"' "$DBX_CONFIG_DIR/config.json")
  [ "$result" = "null" ]
}

@test "storage add: wrong secret, retry, succeeds" {
  run run_wizard \
    "S3-compatible (MinIO, R2, B2, ...)" \
    "http://127.0.0.1:9100" \
    "" \
    "dbxtest-bucket" \
    "" \
    "minioadmin" \
    "WRONG_SECRET" \
    "Re-enter credentials and retry" \
    "minioadmin" \
    "minioadmin"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Remote storage configured" ]]
}

@test "storage add: replace-existing prompt declines, no change" {
  # Pre-populate a config
  jq '.storage = {type: "s3", s3: {endpoint: "http://old", bucket: "old", access_key: "oldkey"}}' \
    "$DBX_CONFIG_DIR/config.json" > "$DBX_CONFIG_DIR/c" \
    && mv "$DBX_CONFIG_DIR/c" "$DBX_CONFIG_DIR/config.json"

  # First prompt is the "Replace?" confirm — pick No
  run run_wizard "n"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Keeping existing" ]]

  result=$(jq -r '.storage.s3.bucket' "$DBX_CONFIG_DIR/config.json")
  [ "$result" = "old" ]
}
```

- [ ] **Step 3: Run the integration tests**

```bash
bats tests/integration/storage_add.bats
```

Expected: 4/4 pass. If any test flakes on the MinIO container startup window, bump the 30-iteration wait loop.

- [ ] **Step 4: Commit**

```bash
git add tests/helpers/integration.bash tests/integration/storage_add.bats
git commit -m "test(storage): integration tests for \`dbx storage add\` wizard

Adds ensure_minio_container helper and full end-to-end coverage:
MinIO happy path, abort+rollback, retry-creds-then-succeed, and the
'replace existing storage' decline path. Skips cleanly if mc isn't
installed on the runner."
```

---

## Task 21: Chain `dbx host add` into the storage flow

**Goal:** After `host_add` prints its summary (Task 11), branch on `is_storage_configured`: offer to run `storage_add` if not configured, or flip per-host `auto_upload` if already configured.

**Files:**
- Modify: `dbx` (extend the tail of `host_add`; add to summary)

- [ ] **Step 1: Append the chain logic to `host_add`**

In `dbx`, the very last lines of `host_add` currently are (from Task 11):

```bash
  log_info "  Databases: ${db_count:-0}"
  log_info "Try: dbx backup $alias"
}
```

Replace the closing `}` and the line above it with:

```bash
  log_info "  Databases: ${db_count:-0}"

  # Storage chain (conditional). See spec: "Step 7 — Storage chain".
  if is_storage_configured; then
    if gum confirm --default=false "Enable auto-upload to remote storage for '$alias' backups?"; then
      local tmp; tmp=$(mktemp)
      jq --arg a "$alias" '.hosts[$a].auto_upload = true' \
        "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
      secure_file "$CONFIG_FILE"
      log_info "  Storage:   auto-upload enabled for $alias"
    else
      log_info "  Storage:   configured globally (auto-upload off for $alias)"
    fi
  else
    if gum confirm --default=true "Configure remote storage for these backups now?"; then
      storage_add
    else
      log_info "  Storage:   not configured (skipped). Set up later with: dbx storage add"
    fi
  fi

  log_info "Try: dbx backup $alias"
}
```

- [ ] **Step 2: Manual verification (no storage configured)**

```bash
# Wipe any existing storage
jq 'del(.storage)' ~/.config/dbx/config.json > /tmp/c && mv /tmp/c ~/.config/dbx/config.json

dbx host add
# Walk happy path → at end, expect "Configure remote storage..." confirm
# Pick Yes → drops into the storage wizard
# Walk through that → expect summary + "Try: dbx backup <alias>"
```

- [ ] **Step 3: Manual verification (storage configured)**

```bash
# Storage already set up from previous step
dbx host add
# Walk happy path with a second alias → at end, expect
# "Enable auto-upload to remote storage..." confirm
# Pick Yes → check config

jq '.hosts.<alias>.auto_upload' ~/.config/dbx/config.json   # → true
```

- [ ] **Step 4: Add an integration test for the chain**

Append to `tests/integration/host_add.bats`:

```bash
@test "host add: auto-upload prompt when storage already configured" {
  # Pre-populate storage
  jq '.storage = {type: "s3", s3: {endpoint: "http://127.0.0.1:9100", bucket: "x", access_key: "k", prefix: ""}}' \
    "$DBX_CONFIG_DIR/config.json" > "$DBX_CONFIG_DIR/c" \
    && mv "$DBX_CONFIG_DIR/c" "$DBX_CONFIG_DIR/config.json"

  docker exec postgres-dbx createdb -U postgres chaindb1 >/dev/null 2>&1 || true
  run run_wizard \
    "chainalias1" \
    "postgres" \
    "postgres" \
    "Direct connection" \
    "127.0.0.1" \
    "5432" \
    "devpassword" \
    "chaindb1" \
    "" \
    "y"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "auto-upload enabled for chainalias1" ]]

  result=$(jq -r '.hosts.chainalias1.auto_upload' "$DBX_CONFIG_DIR/config.json")
  [ "$result" = "true" ]

  docker exec postgres-dbx dropdb -U postgres chaindb1 >/dev/null 2>&1 || true
}
```

- [ ] **Step 5: Run all integration tests**

```bash
bats tests/integration/host_add.bats tests/integration/storage_add.bats
```
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add dbx tests/integration/host_add.bats
git commit -m "feat(host): chain into storage wizard / auto-upload prompt

End of \`dbx host add\` now: if no remote storage is configured, offers
to run \`storage_add\` inline; otherwise asks whether to enable
per-host auto_upload. Either way, one extra prompt before the wizard
finishes."
```

---

## Task 22: Docs + CHANGELOG

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add documentation for both wizards to `README.md`**

Find the section that documents `dbx config init` / editing the config. Add immediately after:

```markdown
### Adding a host

\`\`\`bash
dbx host add
\`\`\`

Interactive wizard that walks through alias → database type → user →
network (direct or SSH tunnel) → credentials → live connection test →
pick databases → per-database options. On test failure you can re-enter
credentials, re-enter host fields, save anyway, or abort (which rolls
back the config and vault). If remote storage isn't configured yet, the
wizard offers to set that up too; if it is, it offers to flip
auto-upload on for the new host.

Requires \`gum\`. The same flow runs from the TUI under
**Config → Add host**.

### Adding remote storage

\`\`\`bash
dbx storage add
\`\`\`

Interactive wizard for S3 / S3-compatible remote storage (MinIO, R2,
Backblaze B2, etc.). Collects provider, endpoint, bucket, prefix, and
credentials, then proves the config works with an upload → list →
download → delete round-trip against the configured bucket. The
secret key lives in the vault, never plaintext in \`config.json\`.
Re-running the wizard with storage already configured asks before
replacing.
```

- [ ] **Step 2: Note the new dispatcher pattern in `AGENTS.md`**

Find the "Project Structure" section. Update the `dbx` line and add a note:

```diff
- dbx                    # Main entrypoint script (~1900 lines)
+ dbx                    # Main entrypoint script (~2400 lines), houses cmd_* dispatchers (config, vault, schedule, storage, host)
```

- [ ] **Step 3: Add a `CHANGELOG.md` entry**

Under `## [Unreleased]`:

```markdown
### Added

- `dbx host add` — interactive wizard for adding a backup host. Prompts
  for connection details, validates against the live database, lets you
  pick which databases to back up, and chains into storage setup if it
  isn't already configured.
- `dbx storage add` — interactive wizard for configuring S3 /
  S3-compatible remote storage. Validates the config with a real
  upload-list-download-delete round-trip before committing — catches the
  read-but-no-write IAM case that a plain credentials check would miss.
- TUI's **Config → Add host** menu now drives the same `dbx host add`
  wizard.
```

- [ ] **Step 4: Run full smoke**

```bash
bash -n dbx && for f in lib/*.sh; do bash -n "$f"; done
shellcheck -S error dbx lib/*.sh
bats tests/unit/
bats tests/integration/host_add.bats tests/integration/storage_add.bats
```
Expected: all clean.

- [ ] **Step 5: Commit**

```bash
git add README.md AGENTS.md CHANGELOG.md
git commit -m "docs: \`dbx host add\` and \`dbx storage add\` interactive wizards

README, AGENTS structure note, and CHANGELOG entries for both wizards
and the host→storage chain."
```

---

## Final smoke

After Task 22, the branch should be ready to PR. Smoke check before opening the PR:

- [ ] `bash -n dbx && for f in lib/*.sh; do bash -n "$f"; done` — clean
- [ ] `shellcheck -S error dbx lib/*.sh` — clean
- [ ] `bats tests/unit/` — all pass
- [ ] `bats tests/integration/host_add.bats` — all pass (or marked as `needs-pty` with a follow-up issue)
- [ ] `dbx host add` walks through identity → network → creds → validation → picker → summary on a real postgres container
- [ ] `dbx tui` → Config → Add host runs the same wizard
- [ ] `dbx help` shows the new `host add` line
- [ ] `git log --oneline origin/main..HEAD` shows clean per-task commits (14 commits)

Open the PR using the commit-commands skill once the smoke is clean.
