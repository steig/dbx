#!/usr/bin/env bats
#
# Tests for pg_ignored_extensions list normalization and
# pg_filter_ignored_statements (lib/postgres.sh) — the streaming-restore
# filter that drops CREATE/COMMENT statements for ignored extensions
# without touching COPY data blocks.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
  write_config '{"hosts":{}}'
}

# Build the statement pattern the way pg_restore_backup_streaming does.
_pat_for() {
  local list="$1"
  printf '%s' "^(CREATE EXTENSION( IF NOT EXISTS)?|COMMENT ON EXTENSION) \"?(${list// /|})\"?[ ;]"
}

@test "pg_ignored_extensions: comma+space list collapses to single-space tokens" {
  export DBX_IGNORE_EXTENSIONS="pg_repack, pg_squeeze"
  run pg_ignored_extensions
  [ "$status" -eq 0 ]
  [ "$output" = "pg_repack pg_squeeze" ]
}

@test "pg_ignored_extensions: doubled separators produce no empty tokens" {
  export DBX_IGNORE_EXTENSIONS=" pg_repack,,pg_cron ,  pg_squeeze "
  run pg_ignored_extensions
  [ "$status" -eq 0 ]
  [ "$output" = "pg_repack pg_cron pg_squeeze" ]
}

@test "filter: drops CREATE/COMMENT statements for the ignored extension" {
  pat=$(_pat_for "pg_repack")
  out=$(printf '%s\n' \
    'CREATE EXTENSION IF NOT EXISTS "pg_repack" WITH SCHEMA public;' \
    'CREATE EXTENSION pg_repack;' \
    "COMMENT ON EXTENSION pg_repack IS 'Reorganize tables';" \
    'CREATE TABLE public.t (id integer);' \
    | pg_filter_ignored_statements "$pat")
  [ "$out" = "CREATE TABLE public.t (id integer);" ]
}

@test "filter: keeps statements for extensions not on the list" {
  pat=$(_pat_for "pg_repack")
  out=$(printf '%s\n' \
    'CREATE EXTENSION IF NOT EXISTS pg_trgm;' \
    'CREATE EXTENSION pg_repack_helper;' \
    | pg_filter_ignored_statements "$pat")
  [ "$out" = 'CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION pg_repack_helper;' ]
}

@test "filter: COPY data rows matching the pattern pass through untouched" {
  pat=$(_pat_for "pg_repack")
  input=$(printf '%s\n' \
    'CREATE EXTENSION pg_repack;' \
    'COPY public.notes (body) FROM stdin;' \
    'CREATE EXTENSION pg_repack; -- this is table data' \
    '\.' \
    'CREATE EXTENSION pg_repack;')
  out=$(printf '%s\n' "$input" | pg_filter_ignored_statements "$pat")
  expected=$(printf '%s\n' \
    'COPY public.notes (body) FROM stdin;' \
    'CREATE EXTENSION pg_repack; -- this is table data' \
    '\.')
  [ "$out" = "$expected" ]
}

@test "filter: pattern from a comma+space env list is a valid awk regex" {
  # "pg_repack, pg_cron" once produced "(pg_repack||pg_cron)" — an empty
  # alternation branch that BSD awk rejects ("illegal primary").
  export DBX_IGNORE_EXTENSIONS="pg_repack, pg_cron"
  pat=$(_pat_for "$(pg_ignored_extensions)")
  out=$(printf '%s\n' \
    'CREATE EXTENSION pg_cron;' \
    'SELECT 1;' \
    | pg_filter_ignored_statements "$pat")
  [ "$out" = "SELECT 1;" ]
}
