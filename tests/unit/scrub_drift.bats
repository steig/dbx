#!/usr/bin/env bats
#
# Tests for the pure schema/draft/drift functions in lib/scrub.sh:
#   - scrub_schema_tsv_to_json
#   - scrub_init_draft_from_schema
#   - scrub_check_diff
#
# These functions take JSON in, produce JSON out. No docker, no live DB.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
}

# ----------------------------------------------------------------------------
# scrub_schema_tsv_to_json
# ----------------------------------------------------------------------------

@test "scrub_schema_tsv_to_json: turns TSV into table-keyed JSON" {
  result=$(printf 'users\temail\tcharacter varying\tYES\nusers\tid\tinteger\tNO\n' \
    | scrub_schema_tsv_to_json)
  [ "$(jq -r '.tables.users.columns.email.type' <<<"$result")" = "character varying" ]
  [ "$(jq -r '.tables.users.columns.email.nullable' <<<"$result")" = "true" ]
  [ "$(jq -r '.tables.users.columns.id.type' <<<"$result")" = "integer" ]
  [ "$(jq -r '.tables.users.columns.id.nullable' <<<"$result")" = "false" ]
}

@test "scrub_schema_tsv_to_json: empty input → empty tables object" {
  result=$(printf '' | scrub_schema_tsv_to_json)
  [ "$(jq -r '.tables | length' <<<"$result")" = "0" ]
}

@test "scrub_schema_tsv_to_json: multiple tables coexist" {
  result=$(printf 'a\tx\tinteger\tNO\nb\ty\ttext\tYES\n' | scrub_schema_tsv_to_json)
  [ "$(jq -r '.tables | keys | join(",")' <<<"$result")" = "a,b" ]
}

# ----------------------------------------------------------------------------
# scrub_init_draft_from_schema
# ----------------------------------------------------------------------------

@test "scrub_init_draft_from_schema: dictionary-matching columns get suggested strategies" {
  schema='{"tables":{"users":{"columns":{
    "id":{"type":"integer","nullable":false},
    "email":{"type":"character varying","nullable":true},
    "phone":{"type":"character varying","nullable":true}
  }}}}'
  result=$(scrub_init_draft_from_schema "$schema")
  [ "$(jq -r '.tables.users.columns.email.strategy' <<<"$result")" = "fake_email" ]
  [ "$(jq -r '.tables.users.columns.phone.strategy' <<<"$result")" = "fake_phone" ]
  # id is not in the dictionary; should not appear
  [ "$(jq -r '.tables.users.columns | has("id")' <<<"$result")" = "false" ]
}

@test "scrub_init_draft_from_schema: shift_date carries max_days param" {
  schema='{"tables":{"users":{"columns":{"dob":{"type":"date","nullable":true}}}}}'
  result=$(scrub_init_draft_from_schema "$schema")
  [ "$(jq -r '.tables.users.columns.dob.strategy' <<<"$result")" = "shift_date" ]
  [ "$(jq -r '.tables.users.columns.dob.max_days' <<<"$result")" = "30" ]
}

@test "scrub_init_draft_from_schema: JSON columns get jsonb_scrub_paths placeholder" {
  schema='{"tables":{"meta":{"columns":{"prefs":{"type":"jsonb","nullable":true}}}}}'
  result=$(scrub_init_draft_from_schema "$schema")
  [ "$(jq -r '.tables.meta.columns.prefs.strategy' <<<"$result")" = "jsonb_scrub_paths" ]
  # Placeholder marker so the user knows they have to fill this in
  [ "$(jq -r '.tables.meta.columns.prefs._TODO // empty' <<<"$result")" != "" ]
}

@test "scrub_init_draft_from_schema: include_empty=false omits tables with no matches" {
  schema='{"tables":{"geocodes":{"columns":{"lat":{"type":"double precision","nullable":false}}}}}'
  result=$(scrub_init_draft_from_schema "$schema" DBX_SCRUB_SEED false)
  [ "$(jq -r '.tables | has("geocodes")' <<<"$result")" = "false" ]
}

@test "scrub_init_draft_from_schema: include_empty=true adds no_pii markers for unmatched tables" {
  schema='{"tables":{"geocodes":{"columns":{"lat":{"type":"double precision","nullable":false}}}}}'
  result=$(scrub_init_draft_from_schema "$schema" DBX_SCRUB_SEED true)
  [ "$(jq -r '.tables.geocodes.no_pii' <<<"$result")" = "true" ]
  [ "$(jq -r '.tables.geocodes.reason' <<<"$result")" = "init: no dictionary matches" ]
}

@test "scrub_init_draft_from_schema: seed_env defaults to DBX_SCRUB_SEED, overrideable" {
  schema='{"tables":{}}'
  result=$(scrub_init_draft_from_schema "$schema" CUSTOM_SEED_VAR true)
  [ "$(jq -r '.seed_env' <<<"$result")" = "CUSTOM_SEED_VAR" ]
}

# ----------------------------------------------------------------------------
# scrub_check_diff
# ----------------------------------------------------------------------------

@test "scrub_check_diff: schema matches manifest exactly → ok:true, all lists empty" {
  schema='{"tables":{"users":{"columns":{
    "email":{"type":"character varying","nullable":true}
  }}}}'
  manifest='{"version":1,"tables":{"users":{"columns":{
    "email":{"strategy":"fake_email"}
  }}}}'
  result=$(scrub_check_diff "$schema" "$manifest")
  [ "$(jq -r '.ok' <<<"$result")" = "true" ]
  [ "$(jq -r '.new_columns_with_dict_match | length' <<<"$result")" = "0" ]
  [ "$(jq -r '.new_tables_with_dict_matches | length' <<<"$result")" = "0" ]
  [ "$(jq -r '.missing_declared_columns | length' <<<"$result")" = "0" ]
  [ "$(jq -r '.json_columns_undeclared | length' <<<"$result")" = "0" ]
}

@test "scrub_check_diff: new dictionary-matching column in known table → drift" {
  schema='{"tables":{"users":{"columns":{
    "email":{"type":"character varying","nullable":true},
    "backup_email":{"type":"character varying","nullable":true}
  }}}}'
  manifest='{"version":1,"tables":{"users":{"columns":{
    "email":{"strategy":"fake_email"}
  }}}}'
  result=$(scrub_check_diff "$schema" "$manifest")
  [ "$(jq -r '.ok' <<<"$result")" = "false" ]
  [ "$(jq -r '.new_columns_with_dict_match | length' <<<"$result")" = "1" ]
  [ "$(jq -r '.new_columns_with_dict_match[0].table' <<<"$result")" = "users" ]
  [ "$(jq -r '.new_columns_with_dict_match[0].column' <<<"$result")" = "backup_email" ]
  [ "$(jq -r '.new_columns_with_dict_match[0].pattern' <<<"$result")" = "email" ]
  [ "$(jq -r '.new_columns_with_dict_match[0].suggested.strategy' <<<"$result")" = "fake_email" ]
}

@test "scrub_check_diff: new table with dictionary matches → grouped into new_tables_with_dict_matches" {
  schema='{"tables":{"customer_profiles":{"columns":{
    "email":{"type":"character varying","nullable":true},
    "phone":{"type":"character varying","nullable":true}
  }}}}'
  manifest='{"version":1,"tables":{}}'
  result=$(scrub_check_diff "$schema" "$manifest")
  [ "$(jq -r '.ok' <<<"$result")" = "false" ]
  [ "$(jq -r '.new_tables_with_dict_matches | length' <<<"$result")" = "1" ]
  [ "$(jq -r '.new_tables_with_dict_matches[0].table' <<<"$result")" = "customer_profiles" ]
  [ "$(jq -r '.new_tables_with_dict_matches[0].matches | length' <<<"$result")" = "2" ]
  # Each match has the same envelope (table, column, pattern, suggested)
  [ "$(jq -r '.new_tables_with_dict_matches[0].matches[0].table' <<<"$result")" = "customer_profiles" ]
}

@test "scrub_check_diff: declared column missing from schema → reported" {
  schema='{"tables":{"users":{"columns":{
    "email":{"type":"character varying","nullable":true}
  }}}}'
  manifest='{"version":1,"tables":{"users":{"columns":{
    "email":{"strategy":"fake_email"},
    "fax_number":{"strategy":"fake_phone"}
  }}}}'
  result=$(scrub_check_diff "$schema" "$manifest")
  [ "$(jq -r '.ok' <<<"$result")" = "false" ]
  [ "$(jq -r '.missing_declared_columns | length' <<<"$result")" = "1" ]
  [ "$(jq -r '.missing_declared_columns[0].column' <<<"$result")" = "fax_number" ]
}

@test "scrub_check_diff: JSON column with no strategy → json_columns_undeclared" {
  schema='{"tables":{"meta":{"columns":{
    "prefs":{"type":"jsonb","nullable":true}
  }}}}'
  manifest='{"version":1,"tables":{}}'
  result=$(scrub_check_diff "$schema" "$manifest")
  [ "$(jq -r '.ok' <<<"$result")" = "false" ]
  [ "$(jq -r '.json_columns_undeclared | length' <<<"$result")" = "1" ]
  [ "$(jq -r '.json_columns_undeclared[0].table' <<<"$result")" = "meta" ]
  [ "$(jq -r '.json_columns_undeclared[0].column' <<<"$result")" = "prefs" ]
}

@test "scrub_check_diff: declared JSON column is NOT flagged as undeclared" {
  schema='{"tables":{"meta":{"columns":{
    "prefs":{"type":"jsonb","nullable":true}
  }}}}'
  manifest='{"version":1,"tables":{"meta":{"columns":{
    "prefs":{"strategy":"jsonb_scrub_paths","paths":{"$.contact.email":"fake_email"}}
  }}}}'
  result=$(scrub_check_diff "$schema" "$manifest")
  [ "$(jq -r '.ok' <<<"$result")" = "true" ]
  [ "$(jq -r '.json_columns_undeclared | length' <<<"$result")" = "0" ]
}

@test "scrub_check_diff: no_pii table accepts unknown columns without drift" {
  # Acknowledged-no-PII tables are accepted even if dictionary-matching
  # column names appear. The user took responsibility via no_pii: true.
  schema='{"tables":{"audit":{"columns":{
    "actor_email":{"type":"character varying","nullable":false}
  }}}}'
  manifest='{"version":1,"tables":{"audit":{"no_pii":true,"reason":"FKs only"}}}'
  result=$(scrub_check_diff "$schema" "$manifest")
  [ "$(jq -r '.ok' <<<"$result")" = "true" ]
}

@test "scrub_check_diff: dictionary-matching column already declared → not flagged" {
  schema='{"tables":{"users":{"columns":{
    "email":{"type":"character varying","nullable":true}
  }}}}'
  manifest='{"version":1,"tables":{"users":{"columns":{
    "email":{"strategy":"fake_email"}
  }}}}'
  result=$(scrub_check_diff "$schema" "$manifest")
  [ "$(jq -r '.ok' <<<"$result")" = "true" ]
}

@test "scrub_check_diff: multiple drift kinds combine; ok=false" {
  schema='{"tables":{
    "users":{"columns":{
      "email":{"type":"character varying","nullable":true},
      "alt_email":{"type":"character varying","nullable":true}
    }},
    "new_table":{"columns":{
      "phone":{"type":"character varying","nullable":true}
    }},
    "meta":{"columns":{
      "prefs":{"type":"jsonb","nullable":true}
    }}
  }}'
  manifest='{"version":1,"tables":{
    "users":{"columns":{
      "email":{"strategy":"fake_email"},
      "removed":{"strategy":"redact"}
    }}
  }}'
  result=$(scrub_check_diff "$schema" "$manifest")
  [ "$(jq -r '.ok' <<<"$result")" = "false" ]
  [ "$(jq -r '.new_columns_with_dict_match | length' <<<"$result")" = "1" ]
  [ "$(jq -r '.new_tables_with_dict_matches | length' <<<"$result")" = "1" ]
  [ "$(jq -r '.missing_declared_columns | length' <<<"$result")" = "1" ]
  [ "$(jq -r '.json_columns_undeclared | length' <<<"$result")" = "1" ]
}

@test "scrub_check_diff: dictionary.exclude in manifest suppresses the match" {
  schema='{"tables":{"users":{"columns":{
    "shipping_address":{"type":"text","nullable":true}
  }}}}'
  # Exclude both `address` and `addr` to fully suppress (documented contract).
  manifest='{"version":1,"dictionary":{"exclude":["address","addr"]},"tables":{}}'
  result=$(scrub_check_diff "$schema" "$manifest")
  [ "$(jq -r '.ok' <<<"$result")" = "true" ]
}

@test "scrub_check_diff: no_pii table with new dict-matching column → warning, not failure" {
  # H3 from the security review: a `no_pii: true` table that grows an
  # email column shouldn't silently bypass detection. We report it as
  # a warning in no_pii_table_dict_matches; .ok stays true (the user
  # affirmed the table is no-PII; flipping ok=false would defeat the
  # affirmation), but the warning is visible for review.
  schema='{"tables":{"audit":{"columns":{
    "actor_email":{"type":"character varying","nullable":false}
  }}}}'
  manifest='{"version":1,"tables":{"audit":{"no_pii":true,"reason":"FKs only"}}}'
  result=$(scrub_check_diff "$schema" "$manifest")
  [ "$(jq -r '.ok' <<<"$result")" = "true" ]
  [ "$(jq -r '.no_pii_table_dict_matches | length' <<<"$result")" = "1" ]
  [ "$(jq -r '.no_pii_table_dict_matches[0].table' <<<"$result")" = "audit" ]
  [ "$(jq -r '.no_pii_table_dict_matches[0].column' <<<"$result")" = "actor_email" ]
  [ "$(jq -r '.no_pii_table_dict_matches[0].pattern' <<<"$result")" = "email" ]
}

@test "scrub_redact_seed_stream: replaces every occurrence with sentinel" {
  result=$(printf 'UPDATE t SET c = md5(%s || c::text);\nERROR: bad value %s\n' \
    "my-secret-seed" "my-secret-seed" \
    | scrub_redact_seed_stream "my-secret-seed")
  # Two occurrences become two sentinels; original never appears.
  [ "$(echo "$result" | grep -c '<SCRUB_SEED_REDACTED>')" = "2" ]
  ! echo "$result" | grep -q "my-secret-seed"
}

@test "scrub_redact_seed_stream: empty seed is a no-op pass-through" {
  result=$(printf 'unchanged line\n' | scrub_redact_seed_stream "")
  [ "$result" = "unchanged line" ]
}

@test "scrub_redact_seed_stream: handles seed with regex metacharacters safely" {
  # Fixed-string replacement; metacharacters must be literal.
  local tricky='s+e[e]d.with*meta$chars'
  result=$(printf 'before %s after\n' "$tricky" | scrub_redact_seed_stream "$tricky")
  [ "$result" = "before <SCRUB_SEED_REDACTED> after" ]
}

@test "scrub_check_diff: dictionary.extend in manifest finds new patterns" {
  schema='{"tables":{"patients":{"columns":{
    "mrn":{"type":"character varying","nullable":false}
  }}}}'
  manifest='{"version":1,"dictionary":{"extend":["mrn"]},"tables":{}}'
  result=$(scrub_check_diff "$schema" "$manifest")
  # mrn is in default dictionary, so this still triggers — verify pattern
  [ "$(jq -r '.ok' <<<"$result")" = "false" ]
  [ "$(jq -r '.new_tables_with_dict_matches[0].matches[0].pattern' <<<"$result")" = "mrn" ]
}
