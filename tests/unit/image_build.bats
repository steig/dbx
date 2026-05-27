#!/usr/bin/env bats
load '../helpers/common'
setup() { setup_dbx_env; source_dbx_libs; }

# ---------------------------------------------------------------------------
# resolve_extension_registry
# ---------------------------------------------------------------------------

@test "resolve_extension_registry: built-in includes pg_partman" {
  run resolve_extension_registry ""
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^pg_partman:partman:'
}

@test "resolve_extension_registry: extra entry overrides built-in (single line)" {
  result=$(resolve_extension_registry "pg_cron:mycron:mypreload")
  [ "$(echo "$result" | grep -c '^pg_cron:')" -eq 1 ]
  echo "$result" | grep -q '^pg_cron:mycron:mypreload$'
}

@test "resolve_extension_registry: extra adds a brand-new extension" {
  result=$(resolve_extension_registry "pg_foo:foo:")
  echo "$result" | grep -q '^pg_foo:foo:'
  echo "$result" | grep -q '^pg_partman:partman:'
}

# ---------------------------------------------------------------------------
# resolve_ext_tuples
# ---------------------------------------------------------------------------

@test "resolve_ext_tuples: keeps only registry extensions, sorted" {
  result=$(resolve_ext_tuples "pg_partman btree_gin pg_cron" "")
  [ "$result" = "$(printf 'pg_cron:cron:pg_cron\npg_partman:partman:')" ]
}

@test "resolve_ext_tuples: order-independent output" {
  a=$(resolve_ext_tuples "pg_partman pg_cron" "")
  b=$(resolve_ext_tuples "pg_cron pg_partman" "")
  [ "$a" = "$b" ]
}

@test "resolve_ext_tuples: empty when no registry matches" {
  result=$(resolve_ext_tuples "btree_gin hstore" "")
  [ -z "$result" ]
}

@test "resolve_ext_tuples: honors escape-hatch extra entries" {
  result=$(resolve_ext_tuples "pg_madeup" "pg_madeup:madeup:")
  [ "$result" = "pg_madeup:madeup:" ]
}

# ---------------------------------------------------------------------------
# compute_custom_image_tag
# ---------------------------------------------------------------------------

@test "compute_custom_image_tag: deterministic dbx-pg tag" {
  resolved=$(resolve_ext_tuples "pg_partman" "")
  t1=$(compute_custom_image_tag 17 "$resolved")
  t2=$(compute_custom_image_tag 17 "$resolved")
  [ "$t1" = "$t2" ]
  echo "$t1" | grep -qE '^dbx-pg17:[0-9a-f]{12}$'
}

@test "compute_custom_image_tag: different extension sets differ" {
  a=$(compute_custom_image_tag 17 "$(resolve_ext_tuples "pg_partman" "")")
  b=$(compute_custom_image_tag 17 "$(resolve_ext_tuples "pg_cron" "")")
  [ "$a" != "$b" ]
}

@test "compute_custom_image_tag: epoch change invalidates tag" {
  resolved=$(resolve_ext_tuples "pg_partman" "")
  t1=$(compute_custom_image_tag 17 "$resolved")
  t2=$(DBX_IMAGE_REGISTRY_EPOCH=999 compute_custom_image_tag 17 "$resolved")
  [ "$t1" != "$t2" ]
}

# ---------------------------------------------------------------------------
# generate_pg_dockerfile
# ---------------------------------------------------------------------------

@test "generate_pg_dockerfile: Debian base + versioned package" {
  resolved=$(resolve_ext_tuples "pg_partman" "")
  result=$(generate_pg_dockerfile 16 "$resolved")
  echo "$result" | grep -q '^FROM postgres:16$'
  echo "$result" | grep -q 'postgresql-16-partman'
}

@test "generate_pg_dockerfile: preload line present for pg_cron" {
  resolved=$(resolve_ext_tuples "pg_cron" "")
  result=$(generate_pg_dockerfile 17 "$resolved")
  echo "$result" | grep -q "shared_preload_libraries = 'pg_cron'"
}

@test "generate_pg_dockerfile: no preload line for pg_partman only" {
  resolved=$(resolve_ext_tuples "pg_partman" "")
  result=$(generate_pg_dockerfile 17 "$resolved")
  ! echo "$result" | grep -q "shared_preload_libraries"
}

@test "generate_pg_dockerfile: multiple preloads comma-joined" {
  resolved=$(resolve_ext_tuples "pg_cron pg_hint_plan" "")
  result=$(generate_pg_dockerfile 17 "$resolved")
  echo "$result" | grep -q "shared_preload_libraries = 'pg_cron,pg_hint_plan'"
}

# ---------------------------------------------------------------------------
# normalize_pg_major
# ---------------------------------------------------------------------------

@test "normalize_pg_major: unknown becomes 17" {
  [ "$(normalize_pg_major unknown)" = "17" ]
  [ "$(normalize_pg_major '')" = "17" ]
}

@test "normalize_pg_major: known major passes through" {
  [ "$(normalize_pg_major 15)" = "15" ]
}
