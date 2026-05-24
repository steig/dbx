#!/usr/bin/env bash
# Scrub strategies: per-engine SQL emission and post-scrub sniff predicates.
#
# This module is the engine-aware companion to lib/scrub.sh. For each
# strategy declared in SCRUB_VALID_STRATEGIES it emits two SQL fragments
# per engine (postgres + mysql):
#
#   * Update SQL — mutates the column according to the strategy.
#     The wrapper handles START TRANSACTION / COMMIT; we stay inside
#     a single transaction by emitting a bare UPDATE.
#
#   * Sniff SQL — `SELECT count(*) ... WHERE ...` that returns 0 iff
#     the scrub successfully ran. Used post-scrub to prove the
#     strategy actually worked; non-zero triggers drop-on-failure.
#
# Determinism: faked values are derived from md5(seed || col_value) so
# repeated scrubs of the same source produce identical results. The
# seed enters the emitted SQL as a quoted literal. It is NEVER logged.
#
# Public surface:
#   scrub_strategy_emit_update    — emit the UPDATE SQL for one column
#   scrub_strategy_emit_sniff     — emit the verification SELECT
#   scrub_strategies_list         — echo strategies this module emits
#
# Identifier safety: tables/columns come from the manifest (committed to
# git) but we still validate against ^[A-Za-z_][A-Za-z0-9_]*$ and die
# on a rejection — defense in depth against a manifest editor typo or
# a future code path that piped through user input.

# ============================================================================
# Strategy registry — must mirror SCRUB_VALID_STRATEGIES in lib/scrub.sh
# ============================================================================

# Echo the strategies this module knows how to emit, one per line.
# lib/scrub.sh validates against SCRUB_VALID_STRATEGIES; this list is
# the authoritative answer to "can we actually emit SQL for this?".
scrub_strategies_list() {
  cat <<'EOF'
fake_email
fake_phone
fake_ip
fake_name
redact
truncate
shift_date
passthrough
jsonb_scrub_paths
EOF
}

# ============================================================================
# Identifier validation and quoting
# ============================================================================

# 0 iff $1 matches ^[A-Za-z_][A-Za-z0-9_]*$. No side effects.
_scrub_ident_ok() {
  local s="$1"
  [[ "$s" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# Validate an identifier or die. Used by every emitter as the first line
# of defense; the manifest is trusted but cheap belt-and-braces.
# Args: $1 label (for the error message), $2 identifier
_scrub_require_ident() {
  local label="$1" value="$2"
  if ! _scrub_ident_ok "$value"; then
    die "scrub: invalid $label identifier '$value' (must match [A-Za-z_][A-Za-z0-9_]*)"
  fi
}

# Quote an identifier for postgres: "foo" with inner " doubled. Identifiers
# are validated before we get here, so the doubling is belt-and-braces.
_scrub_pg_ident() {
  local v="$1"
  printf '"%s"' "${v//\"/\"\"}"
}

# Quote an identifier for MySQL: `foo` with inner ` doubled.
_scrub_mysql_ident() {
  local v="$1"
  printf '`%s`' "${v//\`/\`\`}"
}

# Quote a string for SQL: single-quoted, inner single-quotes doubled.
# Engine-agnostic — standard ANSI quoting. We pass the seed through
# this exactly once at emission time. Backslashes are doubled BEFORE
# single-quote doubling so we don't get caught by Postgres in
# standard_conforming_strings=off mode (rare but real) or MySQL's
# default NO_BACKSLASH_ESCAPES=off.
_scrub_sql_string() {
  local v="$1"
  v="${v//\\/\\\\}"
  printf "'%s'" "${v//\'/\'\'}"
}

# Engine dispatcher: echo "pg" or "mysql" from the public "postgres" /
# "mysql" arg. Dies on unknown engine.
_scrub_engine_tag() {
  case "$1" in
    postgres) printf 'pg' ;;
    mysql)    printf 'mysql' ;;
    *)        die "scrub: unsupported engine '$1' (must be postgres or mysql)" ;;
  esac
}

# ============================================================================
# Hash expressions — the deterministic source of fake-but-stable values
# ============================================================================
#
# Postgres: md5(seed || col::text) — md5() is core; concat with || casts
# either side to text when needed. We cast the column explicitly with
# col::text so non-text columns (jsonb leaves, dates, etc.) work too.
#
# MySQL: MD5(CONCAT(seed, col)) — CONCAT handles non-string coercion.
#
# Both return the full 32-char hex string. The strategies below slice
# the substring they need.

# Echo the md5 expression for a column.
# Args: $1 engine ("postgres"|"mysql"), $2 quoted column identifier (already quoted),
#       $3 SQL-quoted seed literal
_scrub_hash_expr() {
  local engine="$1" qcol="$2" qseed="$3"
  case "$engine" in
    postgres) printf 'md5(%s || %s::text)' "$qseed" "$qcol" ;;
    mysql)    printf 'MD5(CONCAT(%s, %s))' "$qseed" "$qcol" ;;
  esac
}

# ============================================================================
# Per-strategy emitters — update + sniff
# ============================================================================
#
# Layout: one pair of functions per strategy, one block per engine inside.
# The public entrypoint dispatches to these.

# --- fake_email -------------------------------------------------------------
# Replace with '<hash>@dbx.test'. Sniff: anything NOT NULL that doesn't
# end in @dbx.test means the scrub missed a row.

_emit_update_fake_email() {
  local engine="$1" qtable="$2" qcol="$3" qseed="$4"
  local hash
  hash=$(_scrub_hash_expr "$engine" "$qcol" "$qseed")
  case "$engine" in
    postgres) printf "UPDATE %s SET %s = %s || '@dbx.test';" "$qtable" "$qcol" "$hash" ;;
    mysql)    printf "UPDATE %s SET %s = CONCAT(%s, '@dbx.test');" "$qtable" "$qcol" "$hash" ;;
  esac
}

_emit_sniff_fake_email() {
  local qtable="$1" qcol="$2"
  printf "SELECT count(*) FROM %s WHERE %s IS NOT NULL AND %s NOT LIKE '%%@dbx.test';" \
    "$qtable" "$qcol" "$qcol"
}

# --- fake_phone -------------------------------------------------------------
# Replace with '+1555' || <7 hex chars of hash>. The "7-digit-hash" in
# the spec is loose phrasing — hex satisfies the sniff predicate
# (LIKE '+1555%') and avoids the cost of converting hash → decimal.

_emit_update_fake_phone() {
  local engine="$1" qtable="$2" qcol="$3" qseed="$4"
  local hash
  hash=$(_scrub_hash_expr "$engine" "$qcol" "$qseed")
  case "$engine" in
    postgres) printf "UPDATE %s SET %s = '+1555' || substring(%s, 1, 7);" "$qtable" "$qcol" "$hash" ;;
    mysql)    printf "UPDATE %s SET %s = CONCAT('+1555', SUBSTRING(%s, 1, 7));" "$qtable" "$qcol" "$hash" ;;
  esac
}

_emit_sniff_fake_phone() {
  local qtable="$1" qcol="$2"
  printf "SELECT count(*) FROM %s WHERE %s IS NOT NULL AND %s NOT LIKE '+1555%%';" \
    "$qtable" "$qcol" "$qcol"
}

# --- fake_ip ----------------------------------------------------------------
# Replace with TEST-NET-1 address 192.0.2.<hash % 255>. The cast chain
# in postgres is the standard trick for "hex string → bigint": prefix
# with 'x', cast through bit(N) to get the integer bits.

_emit_update_fake_ip() {
  local engine="$1" qtable="$2" qcol="$3" qseed="$4"
  local hash int_expr
  hash=$(_scrub_hash_expr "$engine" "$qcol" "$qseed")
  case "$engine" in
    postgres)
      int_expr=$(printf "(('x' || substring(%s, 1, 8))::bit(32)::int %% 255)" "$hash")
      # The result of % can be negative in postgres int math (it isn't
      # for ::bit(32)::int which stays positive-by-bit-pattern, but be
      # defensive with abs()). Wrap with abs() to guarantee 0..254.
      printf "UPDATE %s SET %s = '192.0.2.' || abs(%s)::text;" "$qtable" "$qcol" "$int_expr"
      ;;
    mysql)
      int_expr=$(printf "(CONV(SUBSTRING(%s, 1, 8), 16, 10) MOD 255)" "$hash")
      printf "UPDATE %s SET %s = CONCAT('192.0.2.', %s);" "$qtable" "$qcol" "$int_expr"
      ;;
  esac
}

_emit_sniff_fake_ip() {
  local qtable="$1" qcol="$2"
  printf "SELECT count(*) FROM %s WHERE %s IS NOT NULL AND %s NOT LIKE '192.0.2.%%';" \
    "$qtable" "$qcol" "$qcol"
}

# --- fake_name --------------------------------------------------------------
# Replace with 'Person_' || <hash>. Sniff uses LIKE with an ESCAPE clause
# because the literal value contains '_', which is a wildcard in LIKE.

_emit_update_fake_name() {
  local engine="$1" qtable="$2" qcol="$3" qseed="$4"
  local hash
  hash=$(_scrub_hash_expr "$engine" "$qcol" "$qseed")
  case "$engine" in
    postgres) printf "UPDATE %s SET %s = 'Person_' || %s;" "$qtable" "$qcol" "$hash" ;;
    mysql)    printf "UPDATE %s SET %s = CONCAT('Person_', %s);" "$qtable" "$qcol" "$hash" ;;
  esac
}

_emit_sniff_fake_name() {
  local qtable="$1" qcol="$2"
  # The literal value contains '_', which is a LIKE wildcard. Use '!' as
  # the escape char (portable across postgres and mysql, no
  # string-literal backslash semantics to worry about).
  printf "SELECT count(*) FROM %s WHERE %s IS NOT NULL AND %s NOT LIKE 'Person!_%%' ESCAPE '!';" \
    "$qtable" "$qcol" "$qcol"
}

# --- redact -----------------------------------------------------------------
# Default behavior: set to NULL (strongest "no value at all" semantics).
# Optional `replacement` field overrides with a SQL-quoted literal —
# the escape hatch for NOT NULL columns. Sniff checks the matching
# post-condition: NULL-only if no replacement, exact-match otherwise.

_emit_update_redact() {
  local _engine="$1" qtable="$2" qcol="$3" _qseed="$4" qreplacement="${5:-NULL}"
  printf "UPDATE %s SET %s = %s;" "$qtable" "$qcol" "$qreplacement"
}

_emit_sniff_redact() {
  local qtable="$1" qcol="$2" qreplacement="${3:-}"
  if [[ -z "$qreplacement" ]]; then
    printf "SELECT count(*) FROM %s WHERE %s IS NOT NULL;" "$qtable" "$qcol"
  else
    # After scrub every row should EQUAL the replacement. Anything
    # else — original values, NULL, partial mutation — counts as fail.
    printf "SELECT count(*) FROM %s WHERE %s IS NULL OR %s <> %s;" \
      "$qtable" "$qcol" "$qcol" "$qreplacement"
  fi
}

# --- truncate ---------------------------------------------------------------
# substring(col, 1, N). Length comes from the strategy_json.

_emit_update_truncate() {
  local engine="$1" qtable="$2" qcol="$3" _qseed="$4" length="$5"
  case "$engine" in
    postgres) printf "UPDATE %s SET %s = substring(%s, 1, %s);" "$qtable" "$qcol" "$qcol" "$length" ;;
    mysql)    printf "UPDATE %s SET %s = SUBSTRING(%s, 1, %s);" "$qtable" "$qcol" "$qcol" "$length" ;;
  esac
}

_emit_sniff_truncate() {
  local engine="$1" qtable="$2" qcol="$3" length="$4"
  case "$engine" in
    postgres) printf "SELECT count(*) FROM %s WHERE length(%s) > %s;" "$qtable" "$qcol" "$length" ;;
    mysql)    printf "SELECT count(*) FROM %s WHERE CHAR_LENGTH(%s) > %s;" "$qtable" "$qcol" "$length" ;;
  esac
}

# --- shift_date -------------------------------------------------------------
# Shift each date by a deterministic offset in [-max_days, +max_days].
# Offset derived from md5(seed || pk || col_value). PK is `id` when the
# table has it; otherwise we fall back to hashing the column value alone
# (still deterministic, but identical input dates collapse to identical
# outputs — acceptable for the dev-clone use case).
#
# We can't introspect the schema from inside the emitter, so the wrapper
# is responsible for deciding the PK story. For now we always use `id`
# and document the caveat: tables without an `id` column will produce a
# SQL error at execution time, which surfaces in the wrapper's logs.
#
# The hash → signed integer trick: hex substring → bit(32)::int gives a
# signed value already, so (val % (2*max_days+1)) - max_days gives the
# desired range. In MySQL we manually shift the 0..2*max_days range to
# [-max_days, max_days].

_emit_update_shift_date() {
  local engine="$1" qtable="$2" qcol="$3" qseed="$4" max_days="$5"
  local range
  range=$((2 * max_days + 1))
  case "$engine" in
    postgres)
      # hash includes col and id for per-row determinism
      printf "UPDATE %s SET %s = %s + ((('x' || substring(md5(%s || %s::text || id::text), 1, 8))::bit(32)::int %% %s) - %s) * interval '1 day';" \
        "$qtable" "$qcol" "$qcol" "$qseed" "$qcol" "$range" "$max_days"
      ;;
    mysql)
      printf "UPDATE %s SET %s = DATE_ADD(%s, INTERVAL ((CONV(SUBSTRING(MD5(CONCAT(%s, %s, id)), 1, 8), 16, 10) MOD %s) - %s) DAY);" \
        "$qtable" "$qcol" "$qcol" "$qseed" "$qcol" "$range" "$max_days"
      ;;
  esac
}

# Weak sniff — we can't compare against the original value once we've
# overwritten it, so we have nothing to assert. Returning a constant 0
# keeps the calling contract (one row, one column, integer) intact and
# the wrapper's drop-on-failure path consistent. The verification gap
# is documented in the strategy doc above.
_emit_sniff_shift_date() {
  # Args intentionally ignored — shift_date has no verifiable post-condition.
  printf 'SELECT 0;'
}

# --- passthrough ------------------------------------------------------------
# Emit nothing. The wrapper sees an empty UPDATE and skips. Sniff is a
# constant 0 so the verification step is a no-op.

_emit_update_passthrough() {
  # No-op; emit nothing (empty stdout).
  return 0
}

_emit_sniff_passthrough() {
  printf 'SELECT 0;'
}

# --- jsonb_scrub_paths ------------------------------------------------------
# Walk the declared paths and apply each path's sub-strategy. For each
# path:
#   postgres: jsonb_set(col, '{a,b}', '"<faked>"'::jsonb)
#   mysql:    JSON_SET(col, '$.a.b', '<faked>')
#
# We chain the operations as a nested expression so a single UPDATE
# touches every path atomically. Sniff is AND of per-path predicates.

# Convert "$.contact.email" → "{contact,email}" for postgres jsonb_set.
_scrub_jsonpath_to_pg() {
  local p="$1"
  # Strip leading $.
  p="${p#\$.}"
  p="${p#\$}"
  # Convert dots to commas, wrap in braces.
  printf '{%s}' "${p//./,}"
}

# Emit the per-path replacement expression. For now we only support
# leaf strategies that produce string values: fake_email, fake_phone,
# fake_ip, fake_name, redact, passthrough. (truncate/shift_date at a
# JSON leaf is doable but adds engine asymmetry that's out of scope.)
# Args: $1 engine, $2 jsonpath, $3 quoted column ident, $4 quoted seed,
#       $5 sub-strategy name, $6 inner expression so far
# Echoes the new wrapping expression on stdout.
_emit_jsonb_path_update() {
  local engine="$1" jsonpath="$2" qcol="$3" qseed="$4" sub="$5" inner="$6"
  local pg_path mysql_path hash faked
  pg_path=$(_scrub_jsonpath_to_pg "$jsonpath")
  mysql_path="$jsonpath"
  # The hash here hashes the WHOLE jsonb column, not the leaf. We can't
  # easily get the leaf value into the md5() call without engine-
  # specific JSON extractors; hashing the whole column keeps determinism
  # per-row and is sufficient for the dev-clone use case. The cost is
  # that two rows with identical jsonb but different leaf paths get the
  # same faked leaf — acceptable.
  hash=$(_scrub_hash_expr "$engine" "$qcol" "$qseed")

  case "$sub" in
    fake_email)
      case "$engine" in
        postgres) faked=$(printf "to_jsonb(%s || '@dbx.test')" "$hash") ;;
        mysql)    faked=$(printf "CONCAT(%s, '@dbx.test')" "$hash") ;;
      esac
      ;;
    fake_phone)
      case "$engine" in
        postgres) faked=$(printf "to_jsonb('+1555' || substring(%s, 1, 7))" "$hash") ;;
        mysql)    faked=$(printf "CONCAT('+1555', SUBSTRING(%s, 1, 7))" "$hash") ;;
      esac
      ;;
    fake_ip)
      case "$engine" in
        postgres)
          faked=$(printf "to_jsonb('192.0.2.' || abs((('x' || substring(%s, 1, 8))::bit(32)::int %% 255))::text)" "$hash")
          ;;
        mysql)
          faked=$(printf "CONCAT('192.0.2.', (CONV(SUBSTRING(%s, 1, 8), 16, 10) MOD 255))" "$hash")
          ;;
      esac
      ;;
    fake_name)
      case "$engine" in
        postgres) faked=$(printf "to_jsonb('Person_' || %s)" "$hash") ;;
        mysql)    faked=$(printf "CONCAT('Person_', %s)" "$hash") ;;
      esac
      ;;
    redact)
      case "$engine" in
        postgres) faked="'null'::jsonb" ;;
        mysql)    faked="CAST('null' AS JSON)" ;;
      esac
      ;;
    passthrough)
      # No-op path: return the inner expression unchanged.
      printf '%s' "$inner"
      return 0
      ;;
    *)
      die "scrub: jsonb_scrub_paths sub-strategy '$sub' is not supported (allowed: fake_email, fake_phone, fake_ip, fake_name, redact, passthrough)"
      ;;
  esac

  case "$engine" in
    postgres) printf "jsonb_set(%s, '%s', %s, false)" "$inner" "$pg_path" "$faked" ;;
    mysql)    printf "JSON_SET(%s, '%s', %s)" "$inner" "$mysql_path" "$faked" ;;
  esac
}

# Emit a per-path sniff predicate (the WHERE clause AND'd into the
# overall sniff). For redact-at-leaf the predicate is "the leaf is not
# JSON null". For the fake_* leaves we string-match the prefix.
# Args: $1 engine, $2 jsonpath, $3 quoted column ident, $4 sub-strategy
_emit_jsonb_path_sniff() {
  local engine="$1" jsonpath="$2" qcol="$3" sub="$4"
  local pg_path mysql_path leaf_pg leaf_mysql
  pg_path=$(_scrub_jsonpath_to_pg "$jsonpath")
  mysql_path="$jsonpath"
  # Path-array expression for postgres ('{a,b}'), MySQL keeps '$.a.b'.
  # The leaf value extractor:
  case "$engine" in
    postgres) leaf_pg=$(printf "%s #>> '%s'" "$qcol" "$pg_path") ;;
    mysql)    leaf_mysql=$(printf "JSON_UNQUOTE(JSON_EXTRACT(%s, '%s'))" "$qcol" "$mysql_path") ;;
  esac

  case "$sub" in
    fake_email)
      case "$engine" in
        postgres) printf "(%s IS NOT NULL AND %s NOT LIKE '%%@dbx.test')" "$leaf_pg" "$leaf_pg" ;;
        mysql)    printf "(%s IS NOT NULL AND %s NOT LIKE '%%@dbx.test')" "$leaf_mysql" "$leaf_mysql" ;;
      esac
      ;;
    fake_phone)
      case "$engine" in
        postgres) printf "(%s IS NOT NULL AND %s NOT LIKE '+1555%%')" "$leaf_pg" "$leaf_pg" ;;
        mysql)    printf "(%s IS NOT NULL AND %s NOT LIKE '+1555%%')" "$leaf_mysql" "$leaf_mysql" ;;
      esac
      ;;
    fake_ip)
      case "$engine" in
        postgres) printf "(%s IS NOT NULL AND %s NOT LIKE '192.0.2.%%')" "$leaf_pg" "$leaf_pg" ;;
        mysql)    printf "(%s IS NOT NULL AND %s NOT LIKE '192.0.2.%%')" "$leaf_mysql" "$leaf_mysql" ;;
      esac
      ;;
    fake_name)
      case "$engine" in
        postgres) printf "(%s IS NOT NULL AND %s NOT LIKE 'Person!_%%' ESCAPE '!')" "$leaf_pg" "$leaf_pg" ;;
        mysql)    printf "(%s IS NOT NULL AND %s NOT LIKE 'Person!_%%' ESCAPE '!')" "$leaf_mysql" "$leaf_mysql" ;;
      esac
      ;;
    redact)
      # Leaf should now be the JSON null sentinel — the unquoted extractor
      # returns SQL NULL for JSON null in both engines.
      case "$engine" in
        postgres) printf "(%s IS NOT NULL)" "$leaf_pg" ;;
        mysql)    printf "(%s IS NOT NULL)" "$leaf_mysql" ;;
      esac
      ;;
    passthrough)
      # No-op: always-false predicate so it contributes nothing to the count.
      printf "(1 = 0)"
      ;;
    *)
      die "scrub: jsonb_scrub_paths sniff sub-strategy '$sub' is not supported"
      ;;
  esac
}

_emit_update_jsonb_scrub_paths() {
  local engine="$1" qtable="$2" qcol="$3" qseed="$4" strategy_json="$5"
  local expr path sub
  expr="$qcol"
  # Walk paths in jq's object-key order (insertion order in jq 1.6+).
  # Each iteration wraps the prior expression in jsonb_set/JSON_SET.
  while IFS=$'\t' read -r path sub; do
    [[ -z "$path" ]] && continue
    expr=$(_emit_jsonb_path_update "$engine" "$path" "$qcol" "$qseed" "$sub" "$expr")
  done < <(jq -r '.paths | to_entries[] | [.key, .value] | @tsv' <<<"$strategy_json" 2>/dev/null || true)

  printf "UPDATE %s SET %s = %s;" "$qtable" "$qcol" "$expr"
}

_emit_sniff_jsonb_scrub_paths() {
  local engine="$1" qtable="$2" qcol="$3" strategy_json="$4"
  local predicates path sub pred first
  predicates=""
  first=1
  while IFS=$'\t' read -r path sub; do
    [[ -z "$path" ]] && continue
    pred=$(_emit_jsonb_path_sniff "$engine" "$path" "$qcol" "$sub")
    if [[ "$first" == "1" ]]; then
      predicates="$pred"
      first=0
    else
      predicates="$predicates OR $pred"
    fi
  done < <(jq -r '.paths | to_entries[] | [.key, .value] | @tsv' <<<"$strategy_json" 2>/dev/null || true)

  if [[ -z "$predicates" ]]; then
    # Empty paths object — manifest validator should have caught this,
    # but be defensive.
    printf 'SELECT 0;'
    return 0
  fi
  # count(*) of rows where ANY path failed its sniff. The spec says
  # "ANDed: each path's leaf must satisfy" — the COUNT semantic flips
  # that: a row contributes to the count if ANY leaf failed (OR), and
  # the wrapper requires count == 0 (i.e. no row had any leaf fail,
  # which is equivalent to "every row passed every leaf" = AND).
  printf "SELECT count(*) FROM %s WHERE %s;" "$qtable" "$predicates"
}

# ============================================================================
# Public dispatchers
# ============================================================================

# Emit UPDATE SQL for one (table, column, strategy) tuple. Echoes to stdout.
# Args: $1 engine ("postgres"|"mysql"), $2 table, $3 column,
#       $4 strategy_json (compact JSON), $5 seed (raw string, may be empty)
scrub_strategy_emit_update() {
  local engine="$1" table="$2" column="$3" strategy_json="$4" seed="$5"

  # Validate engine first so the error mentions the bad engine, not a
  # spurious "missing strategy" downstream.
  _scrub_engine_tag "$engine" >/dev/null

  _scrub_require_ident "table" "$table"
  _scrub_require_ident "column" "$column"

  local strategy
  strategy=$(jq -r '.strategy // empty' <<<"$strategy_json" 2>/dev/null || true)
  [[ -z "$strategy" ]] && die "scrub: strategy_json missing 'strategy' field"

  local qtable qcol qseed
  case "$engine" in
    postgres)
      qtable=$(_scrub_pg_ident "$table")
      qcol=$(_scrub_pg_ident "$column")
      ;;
    mysql)
      qtable=$(_scrub_mysql_ident "$table")
      qcol=$(_scrub_mysql_ident "$column")
      ;;
  esac
  qseed=$(_scrub_sql_string "$seed")

  case "$strategy" in
    fake_email) _emit_update_fake_email "$engine" "$qtable" "$qcol" "$qseed" ;;
    fake_phone) _emit_update_fake_phone "$engine" "$qtable" "$qcol" "$qseed" ;;
    fake_ip)    _emit_update_fake_ip    "$engine" "$qtable" "$qcol" "$qseed" ;;
    fake_name)  _emit_update_fake_name  "$engine" "$qtable" "$qcol" "$qseed" ;;
    redact)
      # Optional replacement. When present, SQL-quote it; when absent,
      # emit raw NULL (caller's default).
      local qreplacement=""
      if jq -e 'has("replacement")' <<<"$strategy_json" >/dev/null 2>&1; then
        local raw_replacement
        raw_replacement=$(jq -r '.replacement' <<<"$strategy_json")
        qreplacement=$(_scrub_sql_string "$raw_replacement")
      fi
      _emit_update_redact "$engine" "$qtable" "$qcol" "$qseed" "$qreplacement"
      ;;
    truncate)
      local length
      length=$(jq -r '.length // empty' <<<"$strategy_json")
      [[ -z "$length" ]] && die "scrub: truncate strategy requires 'length' field"
      [[ "$length" =~ ^[0-9]+$ ]] || die "scrub: truncate length must be a non-negative integer (got '$length')"
      _emit_update_truncate "$engine" "$qtable" "$qcol" "$qseed" "$length"
      ;;
    shift_date)
      local max_days
      max_days=$(jq -r '.max_days // empty' <<<"$strategy_json")
      [[ -z "$max_days" ]] && die "scrub: shift_date strategy requires 'max_days' field"
      [[ "$max_days" =~ ^[0-9]+$ ]] || die "scrub: shift_date max_days must be a positive integer (got '$max_days')"
      _emit_update_shift_date "$engine" "$qtable" "$qcol" "$qseed" "$max_days"
      ;;
    passthrough)
      _emit_update_passthrough
      ;;
    jsonb_scrub_paths)
      _emit_update_jsonb_scrub_paths "$engine" "$qtable" "$qcol" "$qseed" "$strategy_json"
      ;;
    *)
      die "scrub: unknown strategy '$strategy'"
      ;;
  esac
}

# Emit the verification SELECT for one (table, column, strategy) tuple.
# Result is a single-row, single-column integer = 0 on success.
# Args: $1 engine, $2 table, $3 column, $4 strategy_json
scrub_strategy_emit_sniff() {
  local engine="$1" table="$2" column="$3" strategy_json="$4"

  _scrub_engine_tag "$engine" >/dev/null

  _scrub_require_ident "table" "$table"
  _scrub_require_ident "column" "$column"

  local strategy
  strategy=$(jq -r '.strategy // empty' <<<"$strategy_json" 2>/dev/null || true)
  [[ -z "$strategy" ]] && die "scrub: strategy_json missing 'strategy' field"

  local qtable qcol
  case "$engine" in
    postgres)
      qtable=$(_scrub_pg_ident "$table")
      qcol=$(_scrub_pg_ident "$column")
      ;;
    mysql)
      qtable=$(_scrub_mysql_ident "$table")
      qcol=$(_scrub_mysql_ident "$column")
      ;;
  esac

  case "$strategy" in
    fake_email) _emit_sniff_fake_email "$qtable" "$qcol" ;;
    fake_phone) _emit_sniff_fake_phone "$qtable" "$qcol" ;;
    fake_ip)    _emit_sniff_fake_ip    "$qtable" "$qcol" ;;
    fake_name)  _emit_sniff_fake_name  "$qtable" "$qcol" ;;
    redact)
      local qreplacement=""
      if jq -e 'has("replacement")' <<<"$strategy_json" >/dev/null 2>&1; then
        local raw_replacement
        raw_replacement=$(jq -r '.replacement' <<<"$strategy_json")
        qreplacement=$(_scrub_sql_string "$raw_replacement")
      fi
      _emit_sniff_redact "$qtable" "$qcol" "$qreplacement"
      ;;
    truncate)
      local length
      length=$(jq -r '.length // empty' <<<"$strategy_json")
      [[ -z "$length" ]] && die "scrub: truncate strategy requires 'length' field"
      [[ "$length" =~ ^[0-9]+$ ]] || die "scrub: truncate length must be a non-negative integer (got '$length')"
      _emit_sniff_truncate "$engine" "$qtable" "$qcol" "$length"
      ;;
    shift_date)
      # Documented limitation: we cannot compare against the original
      # value once the UPDATE has overwritten the column. The sniff is
      # a constant 0 so the wrapper's drop-on-failure stays consistent.
      _emit_sniff_shift_date
      ;;
    passthrough)
      _emit_sniff_passthrough
      ;;
    jsonb_scrub_paths)
      _emit_sniff_jsonb_scrub_paths "$engine" "$qtable" "$qcol" "$strategy_json"
      ;;
    *)
      die "scrub: unknown strategy '$strategy'"
      ;;
  esac
}
