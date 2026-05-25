#!/usr/bin/env bats
#
# Tests for lib/completion.sh — shell completion brain & script generators.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
  LAUNCHD_DIR="$BATS_TEST_TMPDIR/LaunchAgents"
  SYSTEMD_DIR="$BATS_TEST_TMPDIR/systemd-user"
  mkdir -p "$LAUNCHD_DIR" "$SYSTEMD_DIR"
}

# Convenience: assert that a newline-delimited string contains a line
# matching the given value (exact).
assert_line_eq() {
  local needle="$1" haystack="$2"
  # `-- "$needle"` so a `--foo`-shaped expectation doesn't get parsed as
  # a grep flag on BSD grep (macOS).
  echo "$haystack" | grep -qxF -- "$needle" \
    || { echo "expected line '$needle' in:"; echo "$haystack"; return 1; }
}

# ----------------------------------------------------------------------------
# dbx_subcommands — canonical list
# ----------------------------------------------------------------------------

@test "dbx_subcommands includes backup, restore, wizard, schedule" {
  result=$(dbx_subcommands)
  assert_line_eq backup   "$result"
  assert_line_eq restore  "$result"
  assert_line_eq wizard   "$result"
  assert_line_eq schedule "$result"
}

@test "dbx_subcommands includes completion (the new subcommand)" {
  result=$(dbx_subcommands)
  assert_line_eq completion "$result"
}

# ----------------------------------------------------------------------------
# dbx_complete — top-level dispatch
# ----------------------------------------------------------------------------

@test "dbx_complete with no args returns the subcommand list" {
  result=$(dbx_complete "")
  assert_line_eq backup  "$result"
  assert_line_eq restore "$result"
  assert_line_eq vault   "$result"
}

@test "dbx_complete with partial first word returns subcommand list" {
  # The completion script filters via compgen on the caller side, so
  # the brain emits the full list and lets compgen narrow.
  result=$(dbx_complete "ba")
  assert_line_eq backup "$result"
}

# ----------------------------------------------------------------------------
# dbx_complete backup → host aliases, then databases under a host
# ----------------------------------------------------------------------------

@test "dbx_complete backup <empty> returns host aliases from config" {
  write_config '{"hosts":{"prod":{"type":"postgres","databases":{"app":{}}},"staging":{"type":"mysql","databases":{}}}}'
  result=$(dbx_complete backup "")
  assert_line_eq prod    "$result"
  assert_line_eq staging "$result"
}

@test "dbx_complete backup prod <empty> returns databases under prod" {
  write_config '{"hosts":{"prod":{"type":"postgres","databases":{"app":{},"users":{}}}}}'
  result=$(dbx_complete backup prod "")
  assert_line_eq app   "$result"
  assert_line_eq users "$result"
}

# ----------------------------------------------------------------------------
# dbx_complete vault set/get/delete → host aliases
# ----------------------------------------------------------------------------

@test "dbx_complete vault <empty> returns vault subactions" {
  result=$(dbx_complete vault "")
  assert_line_eq set    "$result"
  assert_line_eq get    "$result"
  assert_line_eq delete "$result"
  assert_line_eq list   "$result"
}

@test "dbx_complete vault set <empty> returns host aliases" {
  write_config '{"hosts":{"prod":{"type":"postgres"},"staging":{"type":"mysql"}}}'
  result=$(dbx_complete vault set "")
  assert_line_eq prod    "$result"
  assert_line_eq staging "$result"
}

@test "dbx_complete vault delete <empty> returns host aliases" {
  write_config '{"hosts":{"prod":{"type":"postgres"}}}'
  result=$(dbx_complete vault delete "")
  assert_line_eq prod "$result"
}

# ----------------------------------------------------------------------------
# dbx_complete test/query → host aliases, then databases
# ----------------------------------------------------------------------------

@test "dbx_complete test <empty> returns host aliases" {
  write_config '{"hosts":{"prod":{"type":"postgres"}}}'
  result=$(dbx_complete test "")
  assert_line_eq prod "$result"
}

@test "dbx_complete query prod <empty> returns databases under prod" {
  write_config '{"hosts":{"prod":{"type":"postgres","databases":{"app":{},"users":{}}}}}'
  result=$(dbx_complete query prod "")
  assert_line_eq app   "$result"
  assert_line_eq users "$result"
}

# ----------------------------------------------------------------------------
# dbx_complete restore → walks DATA_DIR for host/db/latest + filenames
# ----------------------------------------------------------------------------

@test "dbx_complete restore <empty> returns host/db/latest from DATA_DIR" {
  mkdir -p "$DBX_DATA_DIR/prod/app" "$DBX_DATA_DIR/prod/users" "$DBX_DATA_DIR/staging/cache"
  : > "$DBX_DATA_DIR/prod/app/2025-01-01.sql.zst"
  : > "$DBX_DATA_DIR/staging/cache/2025-02-02.sql.zst.age"
  result=$(dbx_complete restore "")
  assert_line_eq "prod/app/latest"     "$result"
  assert_line_eq "prod/users/latest"   "$result"
  assert_line_eq "staging/cache/latest" "$result"
}

@test "dbx_complete restore <empty> does NOT include specific backup filenames" {
  # The cluttery `<host>/<db>/<file>` rows used to dominate the TAB
  # ring and overwhelmed users. They're omitted by default; type the
  # `host/db/` prefix to drill down (see test below).
  mkdir -p "$DBX_DATA_DIR/prod/app"
  : > "$DBX_DATA_DIR/prod/app/2025-01-01.sql.zst"
  : > "$DBX_DATA_DIR/prod/app/2025-01-02.sql.zst.age"
  result=$(dbx_complete restore "")
  assert_line_eq "prod/app/latest" "$result"
  echo "$result" | grep -q "prod/app/2025-01-01.sql.zst" \
    && { echo "expected NO specific-file rows by default; got:"; echo "$result"; return 1; } || true
  echo "$result" | grep -q "prod/app/2025-01-02.sql.zst.age" \
    && { echo "expected NO specific-file rows by default; got:"; echo "$result"; return 1; } || true
}

@test "dbx_complete restore prod/app/ drills into specific filenames for that host/db" {
  # Once the user has typed `host/db/<anything>`, they've already
  # picked the host+db and are looking for a specific timestamp.
  # Emit the actual filenames AND keep the `latest` alias so they
  # can TAB to either shape.
  mkdir -p "$DBX_DATA_DIR/prod/app" "$DBX_DATA_DIR/prod/users"
  : > "$DBX_DATA_DIR/prod/app/2025-01-01.sql.zst"
  : > "$DBX_DATA_DIR/prod/app/2025-01-02.sql.zst.age"
  : > "$DBX_DATA_DIR/prod/users/should-not-appear.sql.zst"
  result=$(dbx_complete restore "prod/app/")
  assert_line_eq "prod/app/latest"             "$result"
  assert_line_eq "prod/app/2025-01-01.sql.zst" "$result"
  assert_line_eq "prod/app/2025-01-02.sql.zst.age" "$result"
  # Other host/db pairs must not leak into the drill-down output.
  echo "$result" | grep -q "should-not-appear" \
    && { echo "unrelated host/db leaked into drill-down:"; echo "$result"; return 1; } || true
  echo "$result" | grep -q "prod/users" \
    && { echo "unrelated host/db leaked into drill-down:"; echo "$result"; return 1; } || true
}

@test "dbx_complete restore drill-down handles age and gpg-encrypted backups" {
  mkdir -p "$DBX_DATA_DIR/prod/app"
  : > "$DBX_DATA_DIR/prod/app/2025-01-01.sql.zst.age"
  : > "$DBX_DATA_DIR/prod/app/2025-01-02.sql.zst.gpg"
  result=$(dbx_complete restore "prod/app/2025-01")
  assert_line_eq "prod/app/2025-01-01.sql.zst.age" "$result"
  assert_line_eq "prod/app/2025-01-02.sql.zst.gpg" "$result"
}

@test "dbx_complete restore prod/missing/ for unknown db falls back to host/db/latest list" {
  # If the partial points at a host/db that doesn't exist on disk,
  # fall back to the default (latest-per-pair) list. compgen on the
  # caller side filters against the partial so the user sees no
  # suggestions, which is the correct UX for a typo — but emitting
  # the default list also keeps the surface area predictable for
  # tools that drive completion programmatically.
  mkdir -p "$DBX_DATA_DIR/prod/app"
  : > "$DBX_DATA_DIR/prod/app/2025-01-01.sql.zst"
  result=$(dbx_complete restore "prod/nope/")
  assert_line_eq "prod/app/latest" "$result"
  # And no specific filenames leak in, even via the fallback.
  echo "$result" | grep -q ".sql.zst" \
    && { echo "specific filename leaked into fallback:"; echo "$result"; return 1; } || true
}

# ----------------------------------------------------------------------------
# Flag completion per subcommand
# ----------------------------------------------------------------------------

@test "dbx_complete backup --<partial> returns backup flags" {
  result=$(dbx_complete backup "--")
  assert_line_eq "--verbose" "$result"
  assert_line_eq "--upload"  "$result"
}

@test "dbx_complete restore --<partial> returns the restore flag set" {
  result=$(dbx_complete restore "--")
  assert_line_eq "--name"               "$result"
  assert_line_eq "--no-post-restore"    "$result"
  assert_line_eq "--hooks-only"         "$result"
  assert_line_eq "--no-scrub"           "$result"
  assert_line_eq "--transform"          "$result"
  assert_line_eq "--into"               "$result"
  assert_line_eq "--from-remote"        "$result"
  assert_line_eq "--recreate-container" "$result"
  assert_line_eq "--keep-download"      "$result"
}

@test "dbx_complete clean --<partial> returns clean flags" {
  result=$(dbx_complete clean "--")
  assert_line_eq "--keep"       "$result"
  assert_line_eq "--dry-run"    "$result"
  assert_line_eq "--older-than" "$result"
}

# ----------------------------------------------------------------------------
# Sub-action completion (config, schedule, scrub, storage, host, completion)
# ----------------------------------------------------------------------------

@test "dbx_complete config <empty> returns config subactions" {
  result=$(dbx_complete config "")
  assert_line_eq init     "$result"
  assert_line_eq edit     "$result"
  assert_line_eq show     "$result"
  assert_line_eq validate "$result"
}

@test "dbx_complete schedule <empty> returns schedule subactions" {
  result=$(dbx_complete schedule "")
  assert_line_eq add    "$result"
  assert_line_eq remove "$result"
  assert_line_eq list   "$result"
  assert_line_eq run    "$result"
  assert_line_eq sync   "$result"
}

@test "dbx_complete schedule add <empty> returns host aliases" {
  write_config '{"hosts":{"prod":{"type":"postgres","databases":{"app":{}}}}}'
  result=$(dbx_complete schedule add "")
  assert_line_eq prod "$result"
}

@test "dbx_complete schedule add prod <empty> returns databases under prod" {
  write_config '{"hosts":{"prod":{"type":"postgres","databases":{"app":{},"users":{}}}}}'
  result=$(dbx_complete schedule add prod "")
  assert_line_eq app   "$result"
  assert_line_eq users "$result"
}

@test "dbx_complete schedule add prod app <empty> returns schedule shorthands" {
  result=$(dbx_complete schedule add prod app "")
  assert_line_eq daily    "$result"
  assert_line_eq hourly   "$result"
  assert_line_eq weekly   "$result"
  assert_line_eq "daily@5" "$result"
}

@test "dbx_complete storage <empty> returns storage subactions" {
  result=$(dbx_complete storage "")
  assert_line_eq upload   "$result"
  assert_line_eq download "$result"
  assert_line_eq sync     "$result"
  assert_line_eq info     "$result"
  assert_line_eq add      "$result"
  assert_line_eq list     "$result"
}

@test "dbx_complete scrub <empty> returns scrub subactions" {
  result=$(dbx_complete scrub "")
  assert_line_eq init     "$result"
  assert_line_eq check    "$result"
  assert_line_eq validate "$result"
}

@test "dbx_complete host <empty> returns host subactions" {
  result=$(dbx_complete host "")
  assert_line_eq add "$result"
}

@test "dbx_complete completion <empty> returns shell names" {
  result=$(dbx_complete completion "")
  assert_line_eq bash "$result"
  assert_line_eq zsh  "$result"
  assert_line_eq fish "$result"
}

# ----------------------------------------------------------------------------
# Completion script generators — shape checks
# ----------------------------------------------------------------------------

@test "dbx_completion_script_bash emits _dbx_complete and complete -F" {
  script=$(dbx_completion_script_bash)
  echo "$script" | grep -q '_dbx_complete()'
  echo "$script" | grep -q 'complete -F _dbx_complete dbx'
  echo "$script" | grep -q 'dbx __complete'
}

@test "dbx_completion_script_zsh emits bashcompinit and complete -F" {
  script=$(dbx_completion_script_zsh)
  echo "$script" | grep -q 'bashcompinit'
  echo "$script" | grep -q 'compdef _dbx_complete dbx'
}

@test "dbx_completion_script_fish emits complete -c dbx" {
  script=$(dbx_completion_script_fish)
  echo "$script" | grep -q 'complete -c dbx'
  echo "$script" | grep -q 'dbx __complete'
}

# ----------------------------------------------------------------------------
# Empty-config robustness — no jq or no .hosts should not crash
# ----------------------------------------------------------------------------

@test "dbx_complete backup <empty> on empty config yields no output" {
  write_config '{}'
  result=$(dbx_complete backup "")
  [ -z "$result" ]
}

@test "dbx_complete restore <empty> on empty DATA_DIR yields no output" {
  result=$(dbx_complete restore "")
  [ -z "$result" ]
}

# ----------------------------------------------------------------------------
# End-to-end: `dbx completion bash` prints the script
# ----------------------------------------------------------------------------

@test "dbx completion bash prints a sourceable bash script" {
  run "$DBX_BIN" completion bash
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '_dbx_complete'
  echo "$output" | grep -q 'complete -F _dbx_complete dbx'
}

@test "dbx completion zsh prints a sourceable zsh script" {
  run "$DBX_BIN" completion zsh
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'bashcompinit'
}

@test "dbx __complete (no args) prints the subcommand list" {
  run "$DBX_BIN" __complete ""
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx backup
  echo "$output" | grep -qx restore
}
