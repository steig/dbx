#!/usr/bin/env bats
#
# Tests for lib/tui.sh — pure helpers only (display layout, dispatch).
# Doesn't exercise gum-driven flows; those are interactive.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
}

# ----------------------------------------------------------------------------
# tui_truncate — ellipsis-on-overflow, no-op when under the limit
# ----------------------------------------------------------------------------

@test "tui_truncate: short string passes through" {
  result=$(tui_truncate "hello" 10)
  [ "$result" = "hello" ]
}

@test "tui_truncate: at the limit passes through" {
  result=$(tui_truncate "abcdefghij" 10)
  [ "$result" = "abcdefghij" ]
}

@test "tui_truncate: over the limit gets ellipsized" {
  result=$(tui_truncate "abcdefghijklmnop" 10)
  [ "$result" = "abcdefghi…" ]
}

# ----------------------------------------------------------------------------
# tui_iso_date — epoch → YYYY-MM-DD
# ----------------------------------------------------------------------------

@test "tui_iso_date: epoch 0 is 1970-01-01" {
  [ "$(tui_iso_date 0)" = "1970-01-01" ]
}

@test "tui_iso_date: a known recent epoch" {
  # 2026-05-08 00:00:00 UTC = 1778198400
  [ "$(tui_iso_date 1778198400)" = "2026-05-08" ]
}

# ----------------------------------------------------------------------------
# tui_panel_width — clamps to [50, 100], otherwise COLUMNS-4
# ----------------------------------------------------------------------------

@test "tui_panel_width: caps at 100 on wide terminals" {
  COLUMNS=300 result=$(tui_panel_width)
  [ "$result" = "100" ]
}

@test "tui_panel_width: floors at 50 on narrow terminals" {
  COLUMNS=40 result=$(tui_panel_width)
  [ "$result" = "50" ]
}

@test "tui_panel_width: tracks COLUMNS-4 in the middle range" {
  COLUMNS=80 result=$(tui_panel_width)
  [ "$result" = "76" ]
}

# ----------------------------------------------------------------------------
# tui_dispatch — label-to-handler tuple lookup
# ----------------------------------------------------------------------------

@test "tui_dispatch: returns 1 on Quit (caller breaks the loop)" {
  ! tui_dispatch "❌ Quit"
}

@test "tui_dispatch: returns 1 on empty input (Esc on top menu)" {
  ! tui_dispatch ""
}

@test "tui_dispatch: returns 0 for an unknown label (no-op)" {
  tui_dispatch "Some unknown label that isn't in TUI_MENU"
}

@test "tui_dispatch: invokes the handler bound to the label" {
  # Stub the real handler to a sentinel value we can read back. The
  # handler in TUI_MENU is "tui_action_backup"; redefine it so we
  # don't actually shell out.
  tui_action_backup() { echo "backup-was-called" >&3; return 7; }
  run tui_dispatch "⬆  Backup database"
  # Dispatch swallows the handler's return, but `run` captured stdout
  # via fd 3 -> output won't include the sentinel. Instead, check the
  # handler ran via its side effect: redefine to write a flag file.
  tui_action_backup() { : > "$BATS_TEST_TMPDIR/handler_ran"; return 0; }
  tui_dispatch "⬆  Backup database"
  [ -f "$BATS_TEST_TMPDIR/handler_ran" ]
}

@test "tui_dispatch: every TUI_MENU entry has both label and handler" {
  local entry
  for entry in "${TUI_MENU[@]}"; do
    [[ "$entry" == *"|"* ]]
    [[ -n "${entry%%|*}" ]]
    [[ -n "${entry##*|}" ]]
  done
}

@test "tui_dispatch: every handler is a defined function" {
  local entry handler
  for entry in "${TUI_MENU[@]}"; do
    handler="${entry##*|}"
    declare -F "$handler" >/dev/null
  done
}

# ----------------------------------------------------------------------------
# Theme palette — single source of truth for colors
# ----------------------------------------------------------------------------

@test "theme: palette constants are set" {
  [[ -n "$TUI_PRIMARY" && -n "$TUI_SECONDARY" ]]
  [[ -n "$TUI_OK" && -n "$TUI_WARN" && -n "$TUI_ERR" && -n "$TUI_FAINT" ]]
}
