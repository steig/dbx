#!/usr/bin/env bats
#
# Tests for the shared `dbx analyze` tail in lib/core.sh (#143) — the totals,
# the listing and the exclusion-membership check that pg_analyze and
# mysql_analyze both feed a canonical "table<TAB>rows<TAB>size_bytes" TSV.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
  TSV="$BATS_TEST_TMPDIR/stats.tsv"
}

# Write the config's exclude_data list for host/db "h"/"d".
seed_exclusions() {
  local json
  json=$(printf '%s\n' "$@" | jq -R -s 'split("\n") | map(select(. != ""))')
  jq --argjson e "$json" \
    '.hosts.h.databases.d.exclude_data = $e' "$CONFIG_FILE" > "$CONFIG_FILE.tmp"
  mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
}

# Force the non-interactive branch regardless of whether fzf is installed.
no_fzf() {
  command() {
    if [ "$1" = "-v" ] && [ "$2" = "fzf" ]; then return 1; fi
    builtin command "$@"
  }
}

# ----------------------------------------------------------------------------
# analyze_interactive_exclusions — totals, listing, exclusion tagging
# ----------------------------------------------------------------------------

@test "analyze: totals sum rows and convert bytes to MB" {
  printf 'public.a\t100\t1048576\npublic.b\t50\t2097152\n' > "$TSV"
  no_fzf
  run analyze_interactive_exclusions h d "$TSV"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tables: 2"* ]]
  [[ "$output" == *"Total Size: 3.00MB"* ]]
  [[ "$output" == *"Total Rows: 150"* ]]
}

@test "analyze: an empty stats file yields zero totals rather than failing" {
  : > "$TSV"
  no_fzf
  run analyze_interactive_exclusions h d "$TSV"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tables: 0"* ]]
  [[ "$output" == *"Total Rows: 0"* ]]
}

@test "analyze: listing tags configured exclusions and only those" {
  printf 'public.keep\t10\t1048576\npublic.drop\t20\t2097152\n' > "$TSV"
  seed_exclusions "public.drop"
  no_fzf
  run analyze_interactive_exclusions h d "$TSV"
  [ "$status" -eq 0 ]
  [[ "$output" == *"public.drop"*"[EXCLUDED]"* ]]
  # The kept table's row must not carry the tag.
  local keep_line
  keep_line=$(printf '%s\n' "$output" | grep 'public.keep')
  [[ "$keep_line" != *"[EXCLUDED]"* ]]
}

@test "analyze: sizes render as MB to two decimals" {
  printf 'public.a\t1\t1572864\n' > "$TSV"
  no_fzf
  run analyze_interactive_exclusions h d "$TSV"
  [[ "$output" == *"1.50"* ]]
}

@test "analyze: advertises fzf when it is unavailable" {
  printf 'public.a\t1\t1024\n' > "$TSV"
  no_fzf
  run analyze_interactive_exclusions h d "$TSV"
  [[ "$output" == *"Install fzf for interactive table selection"* ]]
}

# Postgres table names are schema-qualified, so `.` is everywhere. The old
# per-engine checks tested membership with grep, where `.` is a regex wildcard
# that matches any character — so excluding `public.users` also tagged
# `publicXusers`. The awk index() the listing now uses is a literal substring
# search, which is why this holds.
@test "analyze: a dot in a table name is literal, not a regex wildcard" {
  printf 'public.users\t1\t1024\npublicXusers\t1\t1024\n' > "$TSV"
  seed_exclusions "public.users"
  no_fzf
  run analyze_interactive_exclusions h d "$TSV"
  [[ "$(printf '%s\n' "$output" | grep 'public\.users')" == *"[EXCLUDED]"* ]]
  [[ "$(printf '%s\n' "$output" | grep 'publicXusers')" != *"[EXCLUDED]"* ]]
}

# A name that is a prefix of an excluded one must not inherit the tag.
@test "analyze: a prefix of an excluded table is not itself tagged" {
  printf 'sessions_archive\t1\t1024\nsessions\t1\t1024\n' > "$TSV"
  seed_exclusions "sessions_archive"
  no_fzf
  run analyze_interactive_exclusions h d "$TSV"
  [[ "$(printf '%s\n' "$output" | grep '^sessions ')" != *"[EXCLUDED]"* ]]
}
