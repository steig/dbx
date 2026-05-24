#!/usr/bin/env bats
#
# Tests for lib/scrub_strategies.sh — per-engine SQL emission for the
# update + sniff fragments of each scrub strategy. Pure string-matching
# against the emitted SQL; no docker, no live engine.
#
# Conventions in these tests:
#   * SEED is a fixed string so we can assert on it appearing as a quoted
#     literal in the output.
#   * Table / column names are simple identifiers so the quoted form is
#     stable across runs.
#   * For each strategy we cover: postgres update, postgres sniff,
#     mysql update, mysql sniff. Plus negative paths (bad ident, missing
#     param) where they apply.

load '../helpers/common'

setup() {
  setup_dbx_env
  source_dbx_libs
}

SEED='salty-secret'

# ----------------------------------------------------------------------------
# scrub_strategies_list
# ----------------------------------------------------------------------------

@test "scrub_strategies_list: returns all canonical strategy names" {
  result=$(scrub_strategies_list)
  for s in fake_email fake_phone fake_ip fake_name redact truncate shift_date passthrough jsonb_scrub_paths; do
    echo "$result" | grep -q "^${s}$"
  done
}

@test "scrub_strategies_list: list matches SCRUB_VALID_STRATEGIES" {
  list=$(scrub_strategies_list | sort)
  expected=$(printf '%s\n' "${SCRUB_VALID_STRATEGIES[@]}" | sort)
  [ "$list" = "$expected" ]
}

# ----------------------------------------------------------------------------
# Identifier validation rejection path
# ----------------------------------------------------------------------------

@test "emit_update: rejects table with semicolon" {
  run scrub_strategy_emit_update postgres "users; DROP TABLE x" email '{"strategy":"fake_email"}' "$SEED"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "invalid table identifier"
}

@test "emit_update: rejects column with quote" {
  run scrub_strategy_emit_update postgres users 'em"ail' '{"strategy":"fake_email"}' "$SEED"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "invalid column identifier"
}

@test "emit_update: rejects column starting with digit" {
  run scrub_strategy_emit_update postgres users 1email '{"strategy":"fake_email"}' "$SEED"
  [ "$status" -ne 0 ]
}

@test "emit_sniff: rejects table with backtick" {
  run scrub_strategy_emit_sniff mysql 'us`ers' email '{"strategy":"fake_email"}'
  [ "$status" -ne 0 ]
}

@test "emit_update: rejects unknown engine" {
  run scrub_strategy_emit_update sqlite users email '{"strategy":"fake_email"}' "$SEED"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "unsupported engine"
}

@test "emit_update: rejects unknown strategy" {
  run scrub_strategy_emit_update postgres users email '{"strategy":"hocus_pocus"}' "$SEED"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "unknown strategy"
}

@test "emit_update: rejects strategy_json missing strategy field" {
  run scrub_strategy_emit_update postgres users email '{}' "$SEED"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "missing 'strategy'"
}

# ----------------------------------------------------------------------------
# fake_email
# ----------------------------------------------------------------------------

@test "fake_email: postgres update uses md5(seed || col::text) and @dbx.test" {
  result=$(scrub_strategy_emit_update postgres users email '{"strategy":"fake_email"}' "$SEED")
  echo "$result" | grep -q 'UPDATE "users" SET "email"'
  echo "$result" | grep -q "md5('salty-secret' || \"email\"::text)"
  echo "$result" | grep -q "@dbx.test"
}

@test "fake_email: mysql update uses MD5(CONCAT(seed, col)) and CONCAT(..., '@dbx.test')" {
  result=$(scrub_strategy_emit_update mysql users email '{"strategy":"fake_email"}' "$SEED")
  echo "$result" | grep -q 'UPDATE `users` SET `email`'
  echo "$result" | grep -q "MD5(CONCAT('salty-secret', \`email\`))"
  echo "$result" | grep -q "'@dbx.test'"
}

@test "fake_email: postgres sniff checks NOT LIKE %@dbx.test" {
  result=$(scrub_strategy_emit_sniff postgres users email '{"strategy":"fake_email"}')
  [ "$result" = "SELECT count(*) FROM \"users\" WHERE \"email\" IS NOT NULL AND \"email\" NOT LIKE '%@dbx.test';" ]
}

@test "fake_email: mysql sniff checks NOT LIKE %@dbx.test" {
  result=$(scrub_strategy_emit_sniff mysql users email '{"strategy":"fake_email"}')
  [ "$result" = "SELECT count(*) FROM \`users\` WHERE \`email\` IS NOT NULL AND \`email\` NOT LIKE '%@dbx.test';" ]
}

@test "fake_email: seed with apostrophe is SQL-escaped" {
  result=$(scrub_strategy_emit_update postgres users email '{"strategy":"fake_email"}' "it's-a-secret")
  echo "$result" | grep -q "'it''s-a-secret'"
}

# ----------------------------------------------------------------------------
# fake_phone
# ----------------------------------------------------------------------------

@test "fake_phone: postgres update prefixes +1555 with 7-char hash slice" {
  result=$(scrub_strategy_emit_update postgres people phone '{"strategy":"fake_phone"}' "$SEED")
  echo "$result" | grep -q "UPDATE \"people\" SET \"phone\""
  echo "$result" | grep -q "'+1555' || substring(md5('salty-secret' || \"phone\"::text), 1, 7)"
}

@test "fake_phone: mysql update prefixes +1555 with SUBSTRING(MD5(...), 1, 7)" {
  result=$(scrub_strategy_emit_update mysql people phone '{"strategy":"fake_phone"}' "$SEED")
  echo "$result" | grep -q 'UPDATE `people` SET `phone`'
  echo "$result" | grep -q "CONCAT('+1555', SUBSTRING(MD5(CONCAT('salty-secret', \`phone\`)), 1, 7))"
}

@test "fake_phone: postgres sniff requires +1555 prefix" {
  result=$(scrub_strategy_emit_sniff postgres people phone '{"strategy":"fake_phone"}')
  echo "$result" | grep -q "NOT LIKE '+1555%'"
}

@test "fake_phone: mysql sniff requires +1555 prefix" {
  result=$(scrub_strategy_emit_sniff mysql people phone '{"strategy":"fake_phone"}')
  echo "$result" | grep -q "NOT LIKE '+1555%'"
}

# ----------------------------------------------------------------------------
# fake_ip
# ----------------------------------------------------------------------------

@test "fake_ip: postgres update produces 192.0.2.<int>" {
  result=$(scrub_strategy_emit_update postgres conns ip '{"strategy":"fake_ip"}' "$SEED")
  echo "$result" | grep -q "'192.0.2.' || abs"
  # Uses the hex->bit(32)->int trick, mod 255
  echo "$result" | grep -q "::bit(32)::int % 255"
}

@test "fake_ip: mysql update produces 192.0.2.<int> via CONV+MOD" {
  result=$(scrub_strategy_emit_update mysql conns ip '{"strategy":"fake_ip"}' "$SEED")
  echo "$result" | grep -q "CONCAT('192.0.2.'"
  echo "$result" | grep -q "CONV(SUBSTRING(MD5(CONCAT('salty-secret', \`ip\`)), 1, 8), 16, 10) MOD 255"
}

@test "fake_ip: postgres sniff requires 192.0.2. prefix" {
  result=$(scrub_strategy_emit_sniff postgres conns ip '{"strategy":"fake_ip"}')
  echo "$result" | grep -q "NOT LIKE '192.0.2.%'"
}

@test "fake_ip: mysql sniff requires 192.0.2. prefix" {
  result=$(scrub_strategy_emit_sniff mysql conns ip '{"strategy":"fake_ip"}')
  echo "$result" | grep -q "NOT LIKE '192.0.2.%'"
}

# ----------------------------------------------------------------------------
# fake_name
# ----------------------------------------------------------------------------

@test "fake_name: postgres update prefixes Person_ with full md5 hash" {
  result=$(scrub_strategy_emit_update postgres users name '{"strategy":"fake_name"}' "$SEED")
  echo "$result" | grep -q "'Person_' || md5('salty-secret' || \"name\"::text)"
}

@test "fake_name: mysql update prefixes Person_ with MD5(...)" {
  result=$(scrub_strategy_emit_update mysql users name '{"strategy":"fake_name"}' "$SEED")
  echo "$result" | grep -q "CONCAT('Person_', MD5(CONCAT('salty-secret', \`name\`)))"
}

@test "fake_name: postgres sniff escapes underscore wildcard via ESCAPE '!'" {
  result=$(scrub_strategy_emit_sniff postgres users name '{"strategy":"fake_name"}')
  # Use '!' as escape char — portable across postgres/mysql, no
  # string-literal backslash issues. The pattern is Person!_% (literal _).
  [ "$result" = "SELECT count(*) FROM \"users\" WHERE \"name\" IS NOT NULL AND \"name\" NOT LIKE 'Person!_%' ESCAPE '!';" ]
}

@test "fake_name: mysql sniff escapes underscore wildcard via ESCAPE '!'" {
  result=$(scrub_strategy_emit_sniff mysql users name '{"strategy":"fake_name"}')
  [ "$result" = "SELECT count(*) FROM \`users\` WHERE \`name\` IS NOT NULL AND \`name\` NOT LIKE 'Person!_%' ESCAPE '!';" ]
}

# ----------------------------------------------------------------------------
# redact
# ----------------------------------------------------------------------------

@test "redact: postgres update sets column to NULL" {
  result=$(scrub_strategy_emit_update postgres logs body '{"strategy":"redact"}' "$SEED")
  [ "$result" = 'UPDATE "logs" SET "body" = NULL;' ]
}

@test "redact: mysql update sets column to NULL" {
  result=$(scrub_strategy_emit_update mysql logs body '{"strategy":"redact"}' "$SEED")
  [ "$result" = 'UPDATE `logs` SET `body` = NULL;' ]
}

@test "redact: postgres sniff counts non-null rows" {
  result=$(scrub_strategy_emit_sniff postgres logs body '{"strategy":"redact"}')
  [ "$result" = 'SELECT count(*) FROM "logs" WHERE "body" IS NOT NULL;' ]
}

@test "redact: mysql sniff counts non-null rows" {
  result=$(scrub_strategy_emit_sniff mysql logs body '{"strategy":"redact"}')
  [ "$result" = 'SELECT count(*) FROM `logs` WHERE `body` IS NOT NULL;' ]
}

@test "redact with replacement: postgres update writes the literal" {
  result=$(scrub_strategy_emit_update postgres users name '{"strategy":"redact","replacement":""}' "$SEED")
  [ "$result" = 'UPDATE "users" SET "name" = '"''"';' ]
}

@test "redact with replacement: mysql update writes the literal" {
  result=$(scrub_strategy_emit_update mysql users name '{"strategy":"redact","replacement":"X"}' "$SEED")
  [ "$result" = 'UPDATE `users` SET `name` = '"'X'"';' ]
}

@test "redact with replacement: postgres sniff requires exact match" {
  result=$(scrub_strategy_emit_sniff postgres users name '{"strategy":"redact","replacement":""}')
  [ "$result" = 'SELECT count(*) FROM "users" WHERE "name" IS NULL OR "name" <> '"''"';' ]
}

@test "redact with replacement: replacement with apostrophe is SQL-escaped" {
  result=$(scrub_strategy_emit_update postgres users name "$(printf '{"strategy":"redact","replacement":"O%sBrien"}' "'")" "$SEED")
  # Single-quote in the replacement → doubled inside the SQL literal
  [ "$result" = 'UPDATE "users" SET "name" = '"'O''Brien'"';' ]
}

# ----------------------------------------------------------------------------
# truncate
# ----------------------------------------------------------------------------

@test "truncate: postgres update uses substring(col, 1, N)" {
  result=$(scrub_strategy_emit_update postgres logs body '{"strategy":"truncate","length":10}' "$SEED")
  [ "$result" = 'UPDATE "logs" SET "body" = substring("body", 1, 10);' ]
}

@test "truncate: mysql update uses SUBSTRING(col, 1, N)" {
  result=$(scrub_strategy_emit_update mysql logs body '{"strategy":"truncate","length":10}' "$SEED")
  [ "$result" = 'UPDATE `logs` SET `body` = SUBSTRING(`body`, 1, 10);' ]
}

@test "truncate: postgres sniff uses length(col) > N" {
  result=$(scrub_strategy_emit_sniff postgres logs body '{"strategy":"truncate","length":10}')
  [ "$result" = 'SELECT count(*) FROM "logs" WHERE length("body") > 10;' ]
}

@test "truncate: mysql sniff uses CHAR_LENGTH(col) > N" {
  result=$(scrub_strategy_emit_sniff mysql logs body '{"strategy":"truncate","length":10}')
  [ "$result" = 'SELECT count(*) FROM `logs` WHERE CHAR_LENGTH(`body`) > 10;' ]
}

@test "truncate: missing length field is an error" {
  run scrub_strategy_emit_update postgres logs body '{"strategy":"truncate"}' "$SEED"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "requires 'length'"
}

@test "truncate: non-integer length is an error" {
  run scrub_strategy_emit_update postgres logs body '{"strategy":"truncate","length":"oops"}' "$SEED"
  [ "$status" -ne 0 ]
}

# ----------------------------------------------------------------------------
# shift_date
# ----------------------------------------------------------------------------

@test "shift_date: postgres update uses interval arithmetic with id-based hash" {
  result=$(scrub_strategy_emit_update postgres events occurred_at '{"strategy":"shift_date","max_days":30}' "$SEED")
  echo "$result" | grep -q "UPDATE \"events\" SET \"occurred_at\" = \"occurred_at\" +"
  # Range is 2*max_days + 1 = 61
  echo "$result" | grep -q "% 61"
  # `--` so grep doesn't interpret -30 as a flag
  echo "$result" | grep -q -- "- 30) \* interval '1 day'"
  # PK-aware hash includes id::text
  echo "$result" | grep -q "id::text"
}

@test "shift_date: mysql update uses DATE_ADD with id-based hash" {
  result=$(scrub_strategy_emit_update mysql events occurred_at '{"strategy":"shift_date","max_days":30}' "$SEED")
  echo "$result" | grep -q "DATE_ADD(\`occurred_at\`, INTERVAL"
  echo "$result" | grep -q "MOD 61"
  echo "$result" | grep -q -- "- 30) DAY"
}

@test "shift_date: sniff is the weak constant 0 (documented limitation)" {
  # The verification can't compare against the (now overwritten) original
  # value. The contract is "return one row, one column, integer = 0 on
  # success" — a constant 0 satisfies that. Documented in the module header.
  result=$(scrub_strategy_emit_sniff postgres events occurred_at '{"strategy":"shift_date","max_days":30}')
  [ "$result" = 'SELECT 0;' ]
  result=$(scrub_strategy_emit_sniff mysql events occurred_at '{"strategy":"shift_date","max_days":30}')
  [ "$result" = 'SELECT 0;' ]
}

@test "shift_date: missing max_days is an error" {
  run scrub_strategy_emit_update postgres events occurred_at '{"strategy":"shift_date"}' "$SEED"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "requires 'max_days'"
}

# ----------------------------------------------------------------------------
# passthrough
# ----------------------------------------------------------------------------

@test "passthrough: postgres update emits nothing" {
  result=$(scrub_strategy_emit_update postgres logs body '{"strategy":"passthrough"}' "$SEED")
  [ -z "$result" ]
}

@test "passthrough: mysql update emits nothing" {
  result=$(scrub_strategy_emit_update mysql logs body '{"strategy":"passthrough"}' "$SEED")
  [ -z "$result" ]
}

@test "passthrough: sniff is constant 0" {
  result=$(scrub_strategy_emit_sniff postgres logs body '{"strategy":"passthrough"}')
  [ "$result" = 'SELECT 0;' ]
  result=$(scrub_strategy_emit_sniff mysql logs body '{"strategy":"passthrough"}')
  [ "$result" = 'SELECT 0;' ]
}

# ----------------------------------------------------------------------------
# jsonb_scrub_paths
# ----------------------------------------------------------------------------

@test "jsonb_scrub_paths: postgres update chains jsonb_set per path" {
  json='{"strategy":"jsonb_scrub_paths","paths":{"$.contact.email":"fake_email","$.contact.phone":"fake_phone"}}'
  result=$(scrub_strategy_emit_update postgres users prefs "$json" "$SEED")
  # Both paths are present
  echo "$result" | grep -q "jsonb_set"
  echo "$result" | grep -q "'{contact,email}'"
  echo "$result" | grep -q "'{contact,phone}'"
  # Leaf strategies show up
  echo "$result" | grep -q "@dbx.test"
  echo "$result" | grep -q "+1555"
  # Single UPDATE statement
  count=$(echo "$result" | grep -c "UPDATE \"users\"" || true)
  [ "$count" = "1" ]
}

@test "jsonb_scrub_paths: mysql update chains JSON_SET per path" {
  json='{"strategy":"jsonb_scrub_paths","paths":{"$.contact.email":"fake_email","$.contact.phone":"fake_phone"}}'
  result=$(scrub_strategy_emit_update mysql users prefs "$json" "$SEED")
  echo "$result" | grep -q "JSON_SET"
  echo "$result" | grep -q "'\$.contact.email'"
  echo "$result" | grep -q "'\$.contact.phone'"
  echo "$result" | grep -q "@dbx.test"
  echo "$result" | grep -q "+1555"
  count=$(echo "$result" | grep -c "UPDATE \`users\`" || true)
  [ "$count" = "1" ]
}

@test "jsonb_scrub_paths: postgres sniff ORs predicates for each path" {
  json='{"strategy":"jsonb_scrub_paths","paths":{"$.contact.email":"fake_email","$.contact.phone":"fake_phone"}}'
  result=$(scrub_strategy_emit_sniff postgres users prefs "$json")
  # Both leaves represented
  echo "$result" | grep -q "@dbx.test"
  echo "$result" | grep -q "+1555"
  # OR-combined (so count is rows-with-any-failure; wrapper checks count == 0)
  echo "$result" | grep -q " OR "
  echo "$result" | grep -q '#>> '
}

@test "jsonb_scrub_paths: mysql sniff ORs predicates for each path" {
  json='{"strategy":"jsonb_scrub_paths","paths":{"$.contact.email":"fake_email","$.contact.phone":"fake_phone"}}'
  result=$(scrub_strategy_emit_sniff mysql users prefs "$json")
  echo "$result" | grep -q "@dbx.test"
  echo "$result" | grep -q "+1555"
  echo "$result" | grep -q " OR "
  echo "$result" | grep -q 'JSON_UNQUOTE(JSON_EXTRACT'
}

@test "jsonb_scrub_paths: empty paths object yields SELECT 0" {
  json='{"strategy":"jsonb_scrub_paths","paths":{}}'
  result=$(scrub_strategy_emit_sniff postgres users prefs "$json")
  [ "$result" = 'SELECT 0;' ]
}
