#!/usr/bin/env bats
#
# Tests for the exclude_data referential-integrity helpers (pure functions in
# lib/postgres.sh). FK edges are "child<TAB>parent" lines on stdin.
#
#   attachment -> message -> user ;  order -> user

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
}

EDGES=$'attachment\tmessage\nmessage\tuser\norder\tuser'

@test "fk_exclusion_closure: excluding 'message' pulls in its child 'attachment'" {
  result=$(printf '%s\n' "$EDGES" | fk_exclusion_closure "message")
  [ "$result" = $'attachment\nmessage' ]
}

@test "fk_exclusion_closure: excluding 'user' cascades transitively to all dependents" {
  result=$(printf '%s\n' "$EDGES" | fk_exclusion_closure "user")
  [ "$result" = $'attachment\nmessage\norder\nuser' ]
}

@test "fk_exclusion_closure: excluding a leaf (referenced by nobody) adds nothing" {
  result=$(printf '%s\n' "$EDGES" | fk_exclusion_closure "attachment")
  [ "$result" = "attachment" ]
}

@test "fk_dangling_pairs: kept child referencing an excluded parent is flagged" {
  result=$(printf '%s\n' "$EDGES" | fk_dangling_pairs "message" | sort)
  [ "$result" = $'attachment\tmessage' ]
}

@test "fk_dangling_pairs: excluding 'user' flags its direct referencers only" {
  result=$(printf '%s\n' "$EDGES" | fk_dangling_pairs "user" | sort)
  [ "$result" = $'message\tuser\norder\tuser' ]
}

@test "fk_dangling_pairs: none when excluding a leaf" {
  result=$(printf '%s\n' "$EDGES" | fk_dangling_pairs "attachment")
  [ -z "$result" ]
}
