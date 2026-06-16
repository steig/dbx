#!/usr/bin/env bash
# Scrub manifest: schema + dictionary + drift detection primitives.
#
# This module is the load-bearing artifact for dbx's PII-handling story.
# The manifest declares EVERY column whose contents are PII (or
# explicitly affirms that a table has none); drift detection compares
# the manifest to the live source schema and refuses to proceed when
# the schema has columns the manifest doesn't know about.
#
# This file is pure jq/bash — no docker, no engine queries. The
# engine-aware bits (SQL emission, sniff verification) live in
# lib/scrub_strategies.sh. Live-schema querying lives in lib/postgres.sh
# / lib/mysql.sh (added by the init/check command implementations).
#
# Public surface (functions other modules depend on):
#   scrub_manifest_path          — resolve the manifest file path
#   scrub_manifest_exists        — does the file resolve and exist
#   scrub_read_manifest          — echo the manifest JSON (or {})
#   scrub_get_strategy           — echo strategy JSON for (table, column)
#   scrub_table_no_pii           — is the table marked no_pii: true
#   scrub_seed_value             — read the seed from $seed_env
#   scrub_dict_default_patterns  — built-in dictionary patterns
#   scrub_dict_effective         — dictionary after extend/exclude
#   scrub_dict_matches           — match a column name → pattern
#   scrub_dict_suggested         — suggested strategy for a pattern
#   scrub_normalize_col          — lowercase + strip _/- (matching key)
#   scrub_validate_manifest      — full schema validation, logs + 0/1
#   scrub_required_for           — list destinations gated for a host
#   scrub_destination_required   — is this (host, dest) gated

# ============================================================================
# Manifest location
# ============================================================================

# Resolve the manifest path relative to the directory containing
# $CONFIG_FILE (same rule used for post-restore hook files). Echoes the
# absolute path. Echoes empty when the host has no scrub block.
# Args: $1 host alias
scrub_manifest_path() {
  local host="$1"
  [[ -f "$CONFIG_FILE" ]] || return 0
  local raw
  raw=$(jq -r ".hosts[\"$host\"].scrub.manifest // empty" "$CONFIG_FILE" 2>/dev/null || true)
  [[ -z "$raw" || "$raw" == "null" ]] && return 0
  if [[ "$raw" = /* ]]; then
    printf '%s\n' "$raw"
  else
    printf '%s\n' "$(dirname "$CONFIG_FILE")/$raw"
  fi
}

# 0 iff the host has a manifest configured AND the resolved file exists.
scrub_manifest_exists() {
  local host="$1"
  local p
  p=$(scrub_manifest_path "$host")
  [[ -n "$p" && -f "$p" ]]
}

# Echo the parsed manifest JSON. Returns `{}` when no manifest is
# configured or the file is missing — callers that care must use
# scrub_manifest_exists to distinguish.
scrub_read_manifest() {
  local host="$1"
  local p
  p=$(scrub_manifest_path "$host")
  if [[ -n "$p" && -f "$p" ]]; then
    jq -c '.' "$p" 2>/dev/null || printf '{}\n'
  else
    printf '{}\n'
  fi
}

# ============================================================================
# Manifest accessors
# ============================================================================

# Echo the column strategy entry as compact JSON, or empty if undeclared.
# Args: $1 host, $2 table, $3 column
scrub_get_strategy() {
  local host="$1" table="$2" col="$3"
  local m
  m=$(scrub_read_manifest "$host")
  jq -c --arg t "$table" --arg c "$col" \
    '.tables[$t].columns[$c] // empty' <<<"$m" 2>/dev/null || true
}

# 0 iff the table is explicitly marked `no_pii: true` in the manifest.
# Args: $1 host, $2 table
scrub_table_no_pii() {
  local host="$1" table="$2"
  local m flag
  m=$(scrub_read_manifest "$host")
  flag=$(jq -r --arg t "$table" \
    '.tables[$t].no_pii // false' <<<"$m" 2>/dev/null || echo "false")
  [[ "$flag" == "true" ]]
}

# Echo the seed value (read from the env var named in the manifest).
# Echoes empty when the manifest doesn't declare seed_env, or the env
# var is unset. Callers that require a seed must enforce non-empty.
# Args: $1 host
scrub_seed_value() {
  local host="$1"
  local m env_name
  m=$(scrub_read_manifest "$host")
  env_name=$(jq -r '.seed_env // empty' <<<"$m" 2>/dev/null || true)
  [[ -z "$env_name" || "$env_name" == "null" ]] && return 0
  printf '%s\n' "${!env_name:-}"
}

# Echo the list of destinations that REQUIRE scrub when restoring from
# this host. One destination per line. Empty output = scrub not gated.
# Args: $1 host
scrub_required_for() {
  local host="$1"
  [[ -f "$CONFIG_FILE" ]] || return 0
  jq -r ".hosts[\"$host\"].scrub.required_for // [] | .[]" \
    "$CONFIG_FILE" 2>/dev/null || true
}

# 0 iff the (host, destination) pair is in scrub.required_for.
# Args: $1 host, $2 destination
scrub_destination_required() {
  local host="$1" dest="$2"
  local d
  while IFS= read -r d; do
    [[ "$d" == "$dest" ]] && return 0
  done < <(scrub_required_for "$host")
  return 1
}

# ============================================================================
# Built-in PII dictionary
# ============================================================================
#
# Matching rule: each column name is normalized (lowercased, `_` and
# `-` stripped) and then checked for SUBSTRING containment of each
# pattern below. So `recovery_email` → `recoveryemail` matches `email`,
# `backup-phone` → `backupphone` matches `phone`. This catches the
# common variations without per-name maintenance.
#
# The cost is false positives (`bitcoin_address` matches `address`).
# Those get suppressed via `dictionary.exclude` in the manifest, with a
# stated reason so the next reader knows why.
#
# Format: each entry is `pattern:strategy[:param]`. The strategy is the
# suggestion shown by `dbx scrub init`/`dbx scrub check`; the user can
# accept it or override. `param` is strategy-specific (only used for
# shift_date today: number of max ± days).

scrub_dict_default_patterns() {
  cat <<'EOF'
email:fake_email
mail:fake_email
phone:fake_phone
tel:fake_phone
mobile:fake_phone
fax:fake_phone
ssn:redact
socialsecurity:redact
dob:shift_date:30
birthdate:shift_date:30
dateofbirth:shift_date:30
birthday:shift_date:30
taxid:redact
ein:redact
vatnumber:redact
ccnumber:redact
creditcard:redact
cardnumber:redact
pan:redact
cvv:redact
cvc:redact
passport:redact
driverlicense:redact
driverslicense:redact
address:redact
addr:redact
street:redact
line1:redact
line2:redact
linea:redact
lineb:redact
zip:redact
zipcode:redact
postcode:redact
postalcode:redact
ipaddress:fake_ip
ipv4:fake_ip
ipv6:fake_ip
passwordhash:passthrough
password:redact
passwd:redact
pwd:redact
apikey:redact
secret:redact
token:redact
accesstoken:redact
refreshtoken:redact
firstname:fake_name
lastname:fake_name
fullname:fake_name
givenname:fake_name
familyname:fake_name
middlename:fake_name
mrn:redact
medicalrecordnumber:redact
iban:redact
swift:redact
bic:redact
routing:redact
routingnumber:redact
accountnumber:redact
sortcode:redact
imei:redact
imsi:redact
deviceid:redact
udid:redact
advertisingid:redact
dni:redact
nie:redact
nif:redact
cpf:redact
cnpj:redact
aadhaar:redact
nino:redact
sin:redact
EOF
}

# Normalize a column name for dictionary matching: lowercase and strip
# `_` and `-`. Does not touch other characters (digits, dots, etc.).
scrub_normalize_col() {
  local c="$1"
  c=$(printf '%s' "$c" | tr '[:upper:]' '[:lower:]')
  c="${c//_/}"
  c="${c//-/}"
  printf '%s' "$c"
}

# Echo the effective dictionary (default patterns + extend - exclude),
# one `pattern:strategy[:param]` per line. The manifest's extend
# entries can either be `pattern` (defaults to `redact` strategy) or
# the full `pattern:strategy[:param]` form.
# Args: $1 manifest JSON (compact)
scrub_dict_effective() {
  local manifest="${1:-{\}}"
  local default extend exclude pat name

  default=$(scrub_dict_default_patterns)
  extend=$(jq -r '.dictionary.extend // [] | .[]' <<<"$manifest" 2>/dev/null || true)
  exclude=$(jq -r '.dictionary.exclude // [] | .[]' <<<"$manifest" 2>/dev/null || true)

  # Combine default + extend, then filter excludes. Each excluded entry
  # is matched against the pattern portion (before the first `:`) so the
  # user writes `address` not `address:redact`.
  {
    printf '%s\n' "$default"
    if [[ -n "$extend" ]]; then
      while IFS= read -r pat; do
        [[ -z "$pat" ]] && continue
        # If no `:`, default the strategy to `redact`.
        if [[ "$pat" != *:* ]]; then
          printf '%s:redact\n' "$pat"
        else
          printf '%s\n' "$pat"
        fi
      done <<<"$extend"
    fi
  } | {
    if [[ -z "$exclude" ]]; then
      cat
    else
      # Build a fixed-string awk filter rejecting lines whose pattern
      # column (before `:`) matches any excluded name.
      local -a excl_args=()
      while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        excl_args+=("$name")
      done <<<"$exclude"
      awk -F: -v excludes="${excl_args[*]}" '
        BEGIN { n = split(excludes, e, " "); for (i=1; i<=n; i++) bad[e[i]] = 1 }
        !($1 in bad) { print }
      '
    fi
  }
}

# Match a (raw) column name against the effective dictionary. Echoes
# the matched pattern (just the pattern portion, no strategy) on
# success, empty on no match. First match wins; iteration order is the
# order returned by scrub_dict_effective (defaults first, then extends).
# Args: $1 raw column name, $2 manifest JSON
scrub_dict_matches() {
  local col="$1" manifest="${2:-{\}}"
  local norm pat entry
  norm=$(scrub_normalize_col "$col")
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    pat="${entry%%:*}"
    if [[ "$norm" == *"$pat"* ]]; then
      printf '%s' "$pat"
      return 0
    fi
  done < <(scrub_dict_effective "$manifest")
  return 0
}

# Given a pattern (the bare pattern, no `:strategy` suffix), echo the
# suggested strategy in compact JSON form, e.g. `{"strategy":"fake_email"}`
# or `{"strategy":"shift_date","max_days":30}`. Empty on no match.
# Args: $1 pattern, $2 manifest JSON
scrub_dict_suggested() {
  local pat="$1" manifest="${2:-{\}}"
  local entry strategy param
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    if [[ "${entry%%:*}" == "$pat" ]]; then
      strategy="${entry#*:}"
      strategy="${strategy%%:*}"
      if [[ "$entry" == *:*:* ]]; then
        param="${entry##*:}"
        case "$strategy" in
          shift_date)
            jq -c -n --arg s "$strategy" --argjson m "$param" \
              '{strategy:$s, max_days:$m}'
            ;;
          truncate)
            jq -c -n --arg s "$strategy" --argjson n "$param" \
              '{strategy:$s, length:$n}'
            ;;
          *)
            jq -c -n --arg s "$strategy" '{strategy:$s}'
            ;;
        esac
      else
        jq -c -n --arg s "$strategy" '{strategy:$s}'
      fi
      return 0
    fi
  done < <(scrub_dict_effective "$manifest")
  return 0
}

# ============================================================================
# Manifest validation
# ============================================================================
#
# Schema-level checks. Engine-aware checks (do the strategies make
# sense for this engine) live in scrub_strategies.sh.
#
# Returns 0 on success, non-zero on any error. Logs each error via
# log_error. Designed to be invoked by `dbx config validate`.

# Recognized strategy names. Mirrored in lib/scrub_strategies.sh which
# owns the per-strategy SQL emitters and sniff predicates. Keep both
# in sync — `scrub_validate_manifest` checks against this list, and
# `scrub_strategies_list` (in scrub_strategies.sh) authoritatively
# defines which ones can actually emit SQL.
SCRUB_VALID_STRATEGIES=(
  fake_email
  fake_phone
  fake_ip
  fake_name
  redact
  truncate
  shift_date
  passthrough
  jsonb_scrub_paths
)

# 0 iff $1 is one of SCRUB_VALID_STRATEGIES.
scrub_strategy_known() {
  local name="$1" s
  for s in "${SCRUB_VALID_STRATEGIES[@]}"; do
    [[ "$s" == "$name" ]] && return 0
  done
  return 1
}

# Validate a manifest file. Logs each error; returns the error count
# via the exit status (0 = clean, >0 = number of errors capped at 255).
# Args: $1 manifest file path
scrub_validate_manifest() {
  local mf="$1"
  local errors=0

  if [[ ! -f "$mf" ]]; then
    log_error "Scrub manifest not found: $mf"
    return 1
  fi

  if ! jq empty "$mf" 2>/dev/null; then
    log_error "Scrub manifest is not valid JSON: $mf"
    return 1
  fi

  local m
  m=$(jq -c '.' "$mf")

  # version
  local version
  version=$(jq -r '.version // empty' <<<"$m")
  if [[ -z "$version" ]]; then
    log_error "manifest: missing required field 'version'"
    errors=$((errors + 1))
  elif [[ "$version" != "1" ]]; then
    log_error "manifest: unsupported version '$version' (only '1' is supported)"
    errors=$((errors + 1))
  fi

  # seed_env (optional but if present must be a non-empty string)
  if jq -e 'has("seed_env")' <<<"$m" >/dev/null 2>&1; then
    local env_name
    env_name=$(jq -r '.seed_env // ""' <<<"$m")
    if [[ -z "$env_name" ]]; then
      log_error "manifest: seed_env is set but empty"
      errors=$((errors + 1))
    elif ! [[ "$env_name" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
      log_error "manifest: seed_env '$env_name' is not a valid env-var name"
      errors=$((errors + 1))
    fi
  fi

  # dictionary.extend / dictionary.exclude must be string arrays if present
  local kind
  for kind in extend exclude; do
    if jq -e ".dictionary | has(\"$kind\")" <<<"$m" >/dev/null 2>&1; then
      local is_arr
      is_arr=$(jq -r ".dictionary.$kind | type" <<<"$m")
      if [[ "$is_arr" != "array" ]]; then
        log_error "manifest: dictionary.$kind must be an array (got $is_arr)"
        errors=$((errors + 1))
      fi
    fi
  done

  # tables must be an object
  local tables_type
  tables_type=$(jq -r '.tables | type' <<<"$m" 2>/dev/null || echo "null")
  if [[ "$tables_type" == "null" ]]; then
    log_error "manifest: missing required field 'tables'"
    errors=$((errors + 1))
  elif [[ "$tables_type" != "object" ]]; then
    log_error "manifest: 'tables' must be an object (got $tables_type)"
    errors=$((errors + 1))
  fi

  # Per-table validation. Each table entry must have either no_pii=true
  # or a non-empty columns object. Mixing both is allowed (no_pii=false
  # + columns is the common case) — the explicit no_pii=true short-circuits.
  local table
  while IFS= read -r table; do
    [[ -z "$table" ]] && continue
    scrub_validate_table "$m" "$table" || errors=$((errors + $?))
  done < <(jq -r '.tables // {} | keys[]?' <<<"$m" 2>/dev/null || true)

  if [[ "$errors" -gt 0 ]]; then
    return 1
  fi
  return 0
}

# Validate a single table block. Echoes errors via log_error; returns
# the local error count. Intended to be called only by
# scrub_validate_manifest.
# Args: $1 manifest JSON, $2 table name
scrub_validate_table() {
  local m="$1" table="$2"
  local errors=0
  local entry
  entry=$(jq -c --arg t "$table" '.tables[$t]' <<<"$m")

  local no_pii_flag
  no_pii_flag=$(jq -r '.no_pii // false' <<<"$entry")

  if [[ "$no_pii_flag" == "true" ]]; then
    # no_pii: true requires a reason (audit trail) and forbids columns.
    local reason has_cols
    reason=$(jq -r '.reason // empty' <<<"$entry")
    has_cols=$(jq -r 'has("columns")' <<<"$entry")
    if [[ -z "$reason" ]]; then
      log_error "manifest: table '$table' has no_pii=true but no 'reason' field (audit trail required)"
      errors=$((errors + 1))
    fi
    if [[ "$has_cols" == "true" ]]; then
      log_error "manifest: table '$table' has no_pii=true but also declares 'columns' (mutually exclusive)"
      errors=$((errors + 1))
    fi
    [[ "$errors" -gt 0 ]] && return "$errors"
    return 0
  fi

  # Has columns. Validate every column entry.
  local cols
  cols=$(jq -r '.columns // {} | keys[]?' <<<"$entry" 2>/dev/null || true)
  if [[ -z "$cols" ]]; then
    log_error "manifest: table '$table' has neither no_pii=true nor a 'columns' object"
    return 1
  fi

  local col col_entry strategy
  while IFS= read -r col; do
    [[ -z "$col" ]] && continue
    col_entry=$(jq -c --arg c "$col" '.columns[$c]' <<<"$entry")
    strategy=$(jq -r '.strategy // empty' <<<"$col_entry")
    if [[ -z "$strategy" ]]; then
      log_error "manifest: table '$table' column '$col' is missing 'strategy'"
      errors=$((errors + 1))
      continue
    fi
    if ! scrub_strategy_known "$strategy"; then
      log_error "manifest: table '$table' column '$col' has unknown strategy '$strategy' (valid: ${SCRUB_VALID_STRATEGIES[*]})"
      errors=$((errors + 1))
      continue
    fi
    # Strategy-specific parameter checks.
    case "$strategy" in
      truncate)
        local len
        len=$(jq -r '.length // empty' <<<"$col_entry")
        if [[ -z "$len" || ! "$len" =~ ^[0-9]+$ ]] || [[ "$len" -lt 1 ]]; then
          log_error "manifest: table '$table' column '$col' strategy 'truncate' requires positive integer 'length' (got '$len')"
          errors=$((errors + 1))
        fi
        ;;
      shift_date)
        local days
        days=$(jq -r '.max_days // empty' <<<"$col_entry")
        if [[ -z "$days" || ! "$days" =~ ^[0-9]+$ ]] || [[ "$days" -lt 1 ]]; then
          log_error "manifest: table '$table' column '$col' strategy 'shift_date' requires positive integer 'max_days' (got '$days')"
          errors=$((errors + 1))
        fi
        ;;
      jsonb_scrub_paths)
        local path_type path_count
        path_type=$(jq -r '.paths | type' <<<"$col_entry" 2>/dev/null || echo "null")
        if [[ "$path_type" != "object" ]]; then
          log_error "manifest: table '$table' column '$col' strategy 'jsonb_scrub_paths' requires 'paths' object (got $path_type)"
          errors=$((errors + 1))
        else
          path_count=$(jq -r '.paths | length' <<<"$col_entry")
          if [[ "$path_count" -eq 0 ]]; then
            log_error "manifest: table '$table' column '$col' strategy 'jsonb_scrub_paths' has empty 'paths' object"
            errors=$((errors + 1))
          else
            # Each path KEY must be a syntactically-valid JSONpath made
            # of dotted identifiers (no operators, no quoted strings, no
            # array indices). This is a hard block against SQL injection
            # — paths land in emitted SQL as quoted literals, and an
            # attacker who can edit the manifest would otherwise break
            # out via `'); DROP TABLE ...; --` inside a key.
            local path_key
            while IFS= read -r path_key; do
              [[ -z "$path_key" ]] && continue
              if ! [[ "$path_key" =~ ^\$(\.[A-Za-z_][A-Za-z0-9_]*)+$ ]]; then
                log_error "manifest: table '$table' column '$col' jsonb_scrub_paths has invalid path '$path_key' (must be \$.field.subfield with identifier components only)"
                errors=$((errors + 1))
              fi
            done < <(jq -r '.paths | keys[]?' <<<"$col_entry" 2>/dev/null || true)

            # Each path value must be a known strategy.
            local sub_strategy
            while IFS= read -r sub_strategy; do
              [[ -z "$sub_strategy" ]] && continue
              if ! scrub_strategy_known "$sub_strategy"; then
                log_error "manifest: table '$table' column '$col' jsonb_scrub_paths contains unknown sub-strategy '$sub_strategy'"
                errors=$((errors + 1))
              fi
              # Nested jsonb_scrub_paths would require a path object,
              # which doesn't make sense at a JSON leaf. Reject.
              if [[ "$sub_strategy" == "jsonb_scrub_paths" ]]; then
                log_error "manifest: table '$table' column '$col' jsonb_scrub_paths cannot nest jsonb_scrub_paths as a sub-strategy"
                errors=$((errors + 1))
              fi
            done < <(jq -r '.paths | to_entries[]?.value' <<<"$col_entry" 2>/dev/null || true)
          fi
        fi
        ;;
      passthrough)
        # passthrough requires a reason — it's an explicit acknowledgement,
        # not a silent skip.
        local pt_reason
        pt_reason=$(jq -r '.reason // empty' <<<"$col_entry")
        if [[ -z "$pt_reason" ]]; then
          log_error "manifest: table '$table' column '$col' strategy 'passthrough' requires 'reason' field"
          errors=$((errors + 1))
        fi
        ;;
      redact)
        # Optional 'replacement' — must be a string when present.
        # An int/bool here would be quoted via _scrub_sql_string and
        # produce the right SQL anyway, but be strict: a typo like
        # `"replacement": null` should fail loud, not silently apply
        # the wrong escape.
        if jq -e 'has("replacement")' <<<"$col_entry" >/dev/null 2>&1; then
          local repl_type
          repl_type=$(jq -r '.replacement | type' <<<"$col_entry")
          if [[ "$repl_type" != "string" ]]; then
            log_error "manifest: table '$table' column '$col' strategy 'redact' has non-string 'replacement' (got $repl_type)"
            errors=$((errors + 1))
          fi
        fi
        ;;
    esac
  done <<<"$cols"

  [[ "$errors" -gt 0 ]] && return "$errors"
  return 0
}

# ============================================================================
# Schema queries (live information_schema)
# ============================================================================
#
# These wrappers run inside the local postgres-dbx / mysql-dbx container
# but connect OUT to the source host (mirroring the pattern used by
# pg_backup / mysql_backup / analyze_postgres). They honor SSH tunnels
# via get_effective_host / get_effective_port.
#
# Output shape is TSV with these columns, one row per column:
#   table_name TAB column_name TAB data_type TAB is_nullable[YES|NO]
#
# Conversion to JSON is handled by scrub_schema_tsv_to_json below.

# Query Postgres information_schema.columns for the given (host, database).
# Schema: 'public' only by default. To audit other schemas the caller
# would need to expand the WHERE clause; we limit to public to match
# the dbx backup model.
# Args: $1 host alias, $2 database name
scrub_schema_query_pg() {
  local host="$1" db="$2"

  if has_ssh_tunnel "$host"; then
    create_ssh_tunnel "$host"
  fi

  local db_host db_port db_user db_pass
  db_host=$(get_effective_host "$host")
  db_port=$(get_effective_port "$host")
  db_user=$(get_config_value ".hosts[\"$host\"].user")
  db_pass=$(get_password "$host")

  # Backups route through create_postgres_credential_file / pg_dump which
  # have their own engine-default fallbacks; this helper invokes psql
  # directly with -p on argv, so an empty $db_port becomes the literal
  # `-p ""` which postgres rejects. Mirror the cred-file default here.
  [[ -z "$db_port" ]] && db_port=5432

  require_container "$POSTGRES_CONTAINER"

  local query="
    SELECT table_name, column_name, data_type, is_nullable
    FROM information_schema.columns
    WHERE table_schema = 'public'
    ORDER BY table_name, ordinal_position;
  "
  docker exec -i -e PGPASSWORD="$db_pass" "$POSTGRES_CONTAINER" \
    psql -h "$db_host" -p "$db_port" -U "$db_user" -d "$db" \
    -tA -F $'\t' -c "$query"
}

# Query MySQL information_schema.columns for the given (host, database).
# Filters to the named database (table_schema = ?). Includes is_nullable.
# Args: $1 host alias, $2 database name
scrub_schema_query_mysql() {
  local host="$1" db="$2"

  if has_ssh_tunnel "$host"; then
    create_ssh_tunnel "$host"
  fi

  local db_host db_port db_user db_pass
  db_host=$(get_effective_host "$host")
  db_port=$(get_effective_port "$host")
  db_user=$(get_config_value ".hosts[\"$host\"].user")
  db_pass=$(get_password "$host")

  # Backups route through create_mysql_credential_file whose port arg
  # defaults to 3306 — but this helper invokes the mysql CLI directly
  # with -P on argv, so an empty $db_port becomes the literal `-P ""`
  # which mysql rejects ("Empty value for 'port' specified."). Match
  # the cred-file default so a host with port unset still works.
  [[ -z "$db_port" ]] && db_port=3306

  require_container "$MYSQL_CONTAINER"

  # MySQL doesn't have psql's `-F` separator option; we use the default
  # tab output from `-B` (batch/tab mode) and strip the header row.
  local query="
    SELECT table_name, column_name, data_type, is_nullable
    FROM information_schema.columns
    WHERE table_schema = '$db'
    ORDER BY table_name, ordinal_position;
  "
  docker exec -i -e MYSQL_PWD="$db_pass" "$MYSQL_CONTAINER" \
    mysql -h "$db_host" -P "$db_port" -u "$db_user" -B -N -e "$query"
}

# Convert TSV output of the schema queries above to compact schema JSON:
#   {
#     "tables": {
#       "<table>": {
#         "columns": {
#           "<col>": {"type": "<data_type>", "nullable": <bool>}
#         }
#       }
#     }
#   }
# Reads stdin (TSV); echoes JSON.
scrub_schema_tsv_to_json() {
  jq -Rsc '
    split("\n")
    | map(select(length > 0))
    | map(split("\t"))
    | reduce .[] as $r ({tables: {}};
        .tables[$r[0]].columns[$r[1]] = {
          type: $r[2],
          nullable: (($r[3] // "YES") == "YES")
        }
      )
  '
}

# ============================================================================
# Draft manifest synthesis (pure)
# ============================================================================

# Given live-schema JSON, produce a draft manifest JSON.
# Args: $1 schema JSON (compact), $2 seed_env name (defaults to DBX_SCRUB_SEED),
#       $3 "true"/"false" include_empty (add no_pii markers for unmatched tables)
# Echoes the manifest JSON.
scrub_init_draft_from_schema() {
  local schema="$1"
  local seed_env="${2:-DBX_SCRUB_SEED}"
  local include_empty="${3:-false}"

  # Start with the manifest skeleton.
  local manifest
  manifest=$(jq -nc --arg env "$seed_env" \
    '{version: 1, seed_env: $env, tables: {}}')

  local table cols col col_type pattern suggested
  while IFS= read -r table; do
    [[ -z "$table" ]] && continue
    local table_entry='{"columns":{}}'
    local has_match=false

    cols=$(jq -r --arg t "$table" '.tables[$t].columns | keys[]?' <<<"$schema" 2>/dev/null || true)
    while IFS= read -r col; do
      [[ -z "$col" ]] && continue
      col_type=$(jq -r --arg t "$table" --arg c "$col" '.tables[$t].columns[$c].type' <<<"$schema")
      pattern=$(scrub_dict_matches "$col" '{}')

      # JSON columns: implicit-deny. If not dictionary-matched, still
      # emit a placeholder so the user has to declare a stance.
      if [[ "$col_type" == json || "$col_type" == jsonb ]]; then
        suggested='{"strategy":"jsonb_scrub_paths","paths":{},"_TODO":"declare paths (init found JSON column; no auto-suggestion)"}'
        table_entry=$(jq --arg c "$col" --argjson s "$suggested" \
          '.columns[$c] = $s' <<<"$table_entry")
        has_match=true
        continue
      fi

      if [[ -n "$pattern" ]]; then
        suggested=$(scrub_dict_suggested "$pattern" '{}')
        [[ -z "$suggested" ]] && continue
        table_entry=$(jq --arg c "$col" --argjson s "$suggested" \
          '.columns[$c] = $s' <<<"$table_entry")
        has_match=true
      fi
    done <<<"$cols"

    if [[ "$has_match" == "true" ]]; then
      manifest=$(jq --arg t "$table" --argjson e "$table_entry" \
        '.tables[$t] = $e' <<<"$manifest")
    elif [[ "$include_empty" == "true" ]]; then
      manifest=$(jq --arg t "$table" \
        '.tables[$t] = {no_pii: true, reason: "init: no dictionary matches"}' \
        <<<"$manifest")
    fi
  done < <(jq -r '.tables | keys[]?' <<<"$schema" 2>/dev/null || true)

  printf '%s\n' "$manifest"
}

# ============================================================================
# Drift detection (pure)
# ============================================================================

# Compare a live schema JSON against a manifest JSON. Emits a drift
# report JSON. Exit status is information-only; callers decide policy.
#
# Report shape:
#   {
#     "ok": <bool>,
#     "new_columns_with_dict_match": [
#       {"table":..., "column":..., "type":..., "pattern":..., "suggested":...}
#     ],
#     "new_tables_with_dict_matches": [
#       {"table":..., "matches": [{...}, ...]}
#     ],
#     "missing_declared_columns": [
#       {"table":..., "column":...}
#     ],
#     "json_columns_undeclared": [
#       {"table":..., "column":...}
#     ]
#   }
#
# Args: $1 schema JSON, $2 manifest JSON
scrub_check_diff() {
  local schema="$1" manifest="$2"

  local new_cols='[]' new_tables='[]' missing='[]' json_undeclared='[]'

  local table cols col col_type entry strategy pattern suggested table_known cols_in_manifest_table

  # Pass 1: for each (table, column) in schema, classify.
  while IFS= read -r table; do
    [[ -z "$table" ]] && continue

    table_known=$(jq --arg t "$table" 'has("tables") and (.tables | has($t))' <<<"$manifest")
    local table_no_pii
    table_no_pii=$(jq -r --arg t "$table" '.tables[$t].no_pii // false' <<<"$manifest")

    # If the table is declared no_pii: true, the user took
    # responsibility. We don't fail the check on PII-looking columns
    # in this table (that would defeat the affirmation), but we DO
    # still scan and report them — a `no_pii` table that grew an
    # `email` column probably needs the affirmation revisited.
    # These appear in `no_pii_table_dict_matches` as warnings; they
    # do not flip `.ok` to false.
    if [[ "$table_no_pii" == "true" ]]; then
      local warn_cols
      warn_cols=$(jq -r --arg t "$table" '.tables[$t].columns | keys[]?' <<<"$schema" 2>/dev/null || true)
      while IFS= read -r col; do
        [[ -z "$col" ]] && continue
        pattern=$(scrub_dict_matches "$col" "$manifest")
        if [[ -n "$pattern" ]]; then
          # Append to a warning bucket via a global-ish accumulator.
          # Using a side variable so the diff stays small.
          NO_PII_WARNINGS=$(jq --arg t "$table" --arg c "$col" --arg p "$pattern" \
            '. + [{table:$t, column:$c, pattern:$p}]' <<<"${NO_PII_WARNINGS:-[]}")
        fi
      done <<<"$warn_cols"
      continue
    fi

    local table_matches='[]'
    cols=$(jq -r --arg t "$table" '.tables[$t].columns | keys[]?' <<<"$schema" 2>/dev/null || true)
    while IFS= read -r col; do
      [[ -z "$col" ]] && continue
      col_type=$(jq -r --arg t "$table" --arg c "$col" '.tables[$t].columns[$c].type' <<<"$schema")

      # Is this column already declared in the manifest?
      entry=$(jq -c --arg t "$table" --arg c "$col" \
        '.tables[$t].columns[$c] // empty' <<<"$manifest" 2>/dev/null || true)
      if [[ -n "$entry" && "$entry" != "null" ]]; then
        continue
      fi

      # JSON column with no declared strategy → implicit-deny.
      if [[ "$col_type" == json || "$col_type" == jsonb ]]; then
        json_undeclared=$(jq --arg t "$table" --arg c "$col" \
          '. + [{table: $t, column: $c}]' <<<"$json_undeclared")
        continue
      fi

      # Dictionary match → drift if undeclared.
      pattern=$(scrub_dict_matches "$col" "$manifest")
      if [[ -n "$pattern" ]]; then
        suggested=$(scrub_dict_suggested "$pattern" "$manifest")
        local match_entry
        match_entry=$(jq -c -n --arg t "$table" --arg c "$col" --arg p "$pattern" \
          --arg ty "$col_type" --argjson sg "${suggested:-null}" \
          '{table: $t, column: $c, type: $ty, pattern: $p, suggested: $sg}')

        if [[ "$table_known" == "true" ]]; then
          new_cols=$(jq --argjson e "$match_entry" '. + [$e]' <<<"$new_cols")
        else
          table_matches=$(jq --argjson e "$match_entry" '. + [$e]' <<<"$table_matches")
        fi
      fi
    done <<<"$cols"

    if [[ "$table_known" != "true" ]]; then
      local match_count
      match_count=$(jq 'length' <<<"$table_matches")
      if [[ "$match_count" -gt 0 ]]; then
        new_tables=$(jq --arg t "$table" --argjson m "$table_matches" \
          '. + [{table: $t, matches: $m}]' <<<"$new_tables")
      fi
    fi
  done < <(jq -r '.tables | keys[]?' <<<"$schema" 2>/dev/null || true)

  # Pass 2: declared columns that no longer exist in the schema.
  while IFS= read -r table; do
    [[ -z "$table" ]] && continue
    cols_in_manifest_table=$(jq -r --arg t "$table" \
      '.tables[$t].columns | keys[]?' <<<"$manifest" 2>/dev/null || true)
    while IFS= read -r col; do
      [[ -z "$col" ]] && continue
      local exists
      exists=$(jq --arg t "$table" --arg c "$col" \
        'has("tables") and (.tables | has($t)) and (.tables[$t].columns | has($c))' \
        <<<"$schema")
      if [[ "$exists" != "true" ]]; then
        missing=$(jq --arg t "$table" --arg c "$col" \
          '. + [{table: $t, column: $c}]' <<<"$missing")
      fi
    done <<<"$cols_in_manifest_table"
  done < <(jq -r '.tables | keys[]?' <<<"$manifest" 2>/dev/null || true)

  # Assemble final report. Any non-empty category trips ok=false.
  # Missing declared columns are NOT warnings — a renamed prod column
  # silently turns the scrub into a no-op, which is exactly the manifest-
  # rot failure mode we're trying to prevent. Treat as drift.
  local ok="true"
  local nc nt nm nju
  nc=$(jq 'length' <<<"$new_cols")
  nt=$(jq 'length' <<<"$new_tables")
  nm=$(jq 'length' <<<"$missing")
  nju=$(jq 'length' <<<"$json_undeclared")
  if [[ "$nc" -gt 0 || "$nt" -gt 0 || "$nm" -gt 0 || "$nju" -gt 0 ]]; then
    ok="false"
  fi

  local warnings="${NO_PII_WARNINGS:-[]}"
  unset NO_PII_WARNINGS
  jq -c -n \
    --argjson ok "$ok" \
    --argjson nc "$new_cols" \
    --argjson nt "$new_tables" \
    --argjson m "$missing" \
    --argjson j "$json_undeclared" \
    --argjson w "$warnings" \
    '{
      ok: $ok,
      new_columns_with_dict_match: $nc,
      new_tables_with_dict_matches: $nt,
      missing_declared_columns: $m,
      json_columns_undeclared: $j,
      no_pii_table_dict_matches: $w
    }'
}

# ============================================================================
# Declarative masking executor + sniff runner
# ============================================================================
#
# Given a host (which resolves to a manifest), generate and execute the
# scrub UPDATEs against a target_db, then run the sniff SELECTs to
# prove each strategy applied. The two phases are deliberately
# separable so the wrapper can DROP the target on sniff failure.
#
# UPDATEs run in a single transaction (psql -1; MySQL START/COMMIT).
# A failure during UPDATE rolls back the entire scrub — never produce
# a partially-scrubbed DB. The sniff phase runs SELECTs only and
# accumulates a per-column report; the wrapper decides whether to drop.

# Echo the combined UPDATE SQL stream for every (table, column,
# strategy) tuple in the manifest. Skips tables marked no_pii=true
# and columns whose strategy emits nothing (passthrough).
# Args: $1 host, $2 engine, $3 seed
scrub_emit_all_updates() {
  local host="$1" engine="$2" seed="$3"
  local manifest
  manifest=$(scrub_read_manifest "$host")

  local table no_pii col entry sql
  while IFS= read -r table; do
    [[ -z "$table" ]] && continue
    no_pii=$(jq -r --arg t "$table" '.tables[$t].no_pii // false' <<<"$manifest")
    [[ "$no_pii" == "true" ]] && continue
    while IFS= read -r col; do
      [[ -z "$col" ]] && continue
      entry=$(jq -c --arg t "$table" --arg c "$col" '.tables[$t].columns[$c]' <<<"$manifest")
      sql=$(scrub_strategy_emit_update "$engine" "$table" "$col" "$entry" "$seed")
      [[ -n "$sql" ]] && printf '%s\n' "$sql"
    done < <(jq -r --arg t "$table" '.tables[$t].columns | keys[]?' <<<"$manifest" 2>/dev/null || true)
  done < <(jq -r '.tables | keys[]?' <<<"$manifest" 2>/dev/null || true)
}

# Run all UPDATEs in one engine-side transaction. Returns 0 on
# success, non-zero on any execution error (the engine wrappers wrap
# the stream in a single tx, so a failure rolls back atomically).
#
# CRITICAL: psql/mysql echo the failing statement to stderr on error,
# and our emitted UPDATEs embed the seed literal. Without redaction
# the seed would leak via the wrapper's log. We pipe stderr through
# an awk filter that does a fixed-string replacement of the seed.
# Args: $1 host, $2 target_db, $3 engine, $4 seed
scrub_run_updates() {
  local host="$1" target="$2" engine="$3" seed="$4"
  local stream
  stream=$(scrub_emit_all_updates "$host" "$engine" "$seed")
  if [[ -z "$stream" ]]; then
    log_info "scrub: no UPDATEs to run (manifest declares only no_pii / passthrough)"
    return 0
  fi
  log_step "scrub: applying $(printf '%s\n' "$stream" | grep -c '^UPDATE' || true) UPDATE(s)..."
  local rc=0
  case "$engine" in
    postgres|postgresql)
      printf '%s' "$stream" \
        | pg_run_sql_stream "$target" \
          2> >(scrub_redact_seed_stream "$seed" >&2) \
        || rc=$?
      ;;
    mysql|mariadb)
      printf '%s' "$stream" \
        | mysql_run_sql_stream "$target" \
          2> >(scrub_redact_seed_stream "$seed" >&2) \
        || rc=$?
      ;;
    *) die "scrub_run_updates: unknown engine '$engine'" ;;
  esac
  return $rc
}

# Filter stdin → stdout, replacing every occurrence of $1 with the
# sentinel <SCRUB_SEED_REDACTED>. Uses awk's index() rather than sed
# so the seed is treated as a fixed string (any regex metacharacter in
# the seed would otherwise misbehave). No-op when $1 is empty.
# Args: $1 seed
scrub_redact_seed_stream() {
  local seed="$1"
  if [[ -z "$seed" ]]; then
    cat
    return 0
  fi
  awk -v s="$seed" '{
    line = $0
    out = ""
    while ((p = index(line, s)) > 0) {
      out = out substr(line, 1, p - 1) "<SCRUB_SEED_REDACTED>"
      line = substr(line, p + length(s))
    }
    print out line
  }'
}

# Run sniff SELECTs one-at-a-time and accumulate a per-column report.
# Echoes JSON to stdout:
#   {
#     ok: <bool>,
#     verified: [
#       {table, column, strategy, sniff_count, pass}
#     ]
#   }
# `pass` is true iff sniff_count == 0. `ok` is the AND of all `pass`
# fields. Caller (e.g. the restore-time gate) decides what to do.
# Args: $1 host, $2 target_db, $3 engine
scrub_run_sniffs() {
  local host="$1" target="$2" engine="$3"
  local manifest
  manifest=$(scrub_read_manifest "$host")

  local report='{"ok":true,"verified":[]}'
  local table no_pii col entry strategy sql count pass

  while IFS= read -r table; do
    [[ -z "$table" ]] && continue
    no_pii=$(jq -r --arg t "$table" '.tables[$t].no_pii // false' <<<"$manifest")
    [[ "$no_pii" == "true" ]] && continue
    while IFS= read -r col; do
      [[ -z "$col" ]] && continue
      entry=$(jq -c --arg t "$table" --arg c "$col" '.tables[$t].columns[$c]' <<<"$manifest")
      strategy=$(jq -r '.strategy' <<<"$entry")

      sql=$(scrub_strategy_emit_sniff "$engine" "$table" "$col" "$entry")
      # Run the sniff and capture the single count value.
      count=$(scrub_run_count_query "$target" "$engine" "$sql" 2>/dev/null || echo "-1")
      # Treat parse failure (-1) as a failed sniff so the wrapper drops.
      if [[ "$count" =~ ^-?[0-9]+$ ]] && [[ "$count" -eq 0 ]]; then
        pass=true
      else
        pass=false
        report=$(jq '.ok = false' <<<"$report")
      fi
      report=$(jq --arg t "$table" --arg c "$col" --arg s "$strategy" \
        --argjson cnt "$count" --argjson p "$pass" \
        '.verified += [{table:$t, column:$c, strategy:$s, sniff_count:$cnt, pass:$p}]' \
        <<<"$report")
    done < <(jq -r --arg t "$table" '.tables[$t].columns | keys[]?' <<<"$manifest" 2>/dev/null || true)
  done < <(jq -r '.tables | keys[]?' <<<"$manifest" 2>/dev/null || true)

  printf '%s\n' "$report"
}

# Query the LOCAL container's information_schema for a freshly-restored
# DB. Mirrors scrub_schema_query_pg but skips tunneling — the target
# database lives inside POSTGRES_CONTAINER itself.
# Args: $1 target_db (already in postgres-dbx)
scrub_schema_query_pg_local() {
  local target="$1"
  require_container "$POSTGRES_CONTAINER"
  local query="
    SELECT table_name, column_name, data_type, is_nullable
    FROM information_schema.columns
    WHERE table_schema = 'public'
    ORDER BY table_name, ordinal_position;
  "
  docker exec -i "$POSTGRES_CONTAINER" \
    psql -U postgres -d "$target" -tA -F $'\t' -c "$query"
}

# Same for the local mysql container.
# Args: $1 target_db (already in mysql-dbx)
scrub_schema_query_mysql_local() {
  local target="$1"
  require_container "$MYSQL_CONTAINER"
  local root_pass
  root_pass=$(docker exec "$MYSQL_CONTAINER" printenv MYSQL_ROOT_PASSWORD 2>/dev/null || echo "")
  local query="
    SELECT table_name, column_name, data_type, is_nullable
    FROM information_schema.columns
    WHERE table_schema = '$target'
    ORDER BY table_name, ordinal_position;
  "
  docker exec -i -e MYSQL_PWD="$root_pass" "$MYSQL_CONTAINER" \
    mysql -u root -B -N -e "$query"
}

# Execute a single-row, single-column count SELECT inside the local
# engine container and echo the integer. Used by scrub_run_sniffs to
# get one count per (table, column) sniff. Echoes "-1" on any error
# (caller treats as failure).
#
# Note: DO NOT pass `-i` to docker exec here. This function is called
# from inside a `while read` loop; `-i` allocates stdin and would steal
# the loop's input, silently skipping every column after the first.
# We pass SQL via `-c`/`-e` so no stdin is required.
# Args: $1 target_db, $2 engine, $3 sql
scrub_run_count_query() {
  local target="$1" engine="$2" sql="$3"
  case "$engine" in
    postgres|postgresql)
      docker exec "${POSTGRES_CONTAINER:-postgres-dbx}" \
        psql -U postgres -d "$target" -tA -c "$sql" 2>/dev/null | tr -d '[:space:]'
      ;;
    mysql|mariadb)
      local root_pass
      root_pass=$(docker exec "${MYSQL_CONTAINER:-mysql-dbx}" printenv MYSQL_ROOT_PASSWORD 2>/dev/null || echo "")
      docker exec -e MYSQL_PWD="$root_pass" "${MYSQL_CONTAINER:-mysql-dbx}" \
        mysql -u root "$target" -B -N -e "$sql" 2>/dev/null | tr -d '[:space:]'
      ;;
    *)
      printf '%s\n' "-1"
      ;;
  esac
}

# ============================================================================
# Local-container source resolution (for `dbx scrub <action> local/<db>`)
# ============================================================================
#
# Lets scrub init/check run against a database that already lives inside
# postgres-dbx / mysql-dbx without configuring a real host. Two helpers:
#   scrub_local_db_engine    — detect which managed container owns the db
#   scrub_local_schema_tsv   — emit the engine-specific schema TSV

# 0 iff $1 is the local-container pseudo-host name (`local` or `localhost`).
# Centralized so callers don't drift on which spellings are accepted.
# Args: $1 host alias
scrub_is_local_host() {
  local host="$1"
  [[ "$host" == "local" || "$host" == "localhost" ]]
}

# Detect which managed container holds a database with the given name.
# Echoes `postgres` or `mysql` on stdout, or empty on no match. When the
# db lives in BOTH containers, postgres wins (deterministic).
# Args: $1 db name
scrub_local_db_engine() {
  local db="$1"
  [[ -z "$db" ]] && return 0

  # Postgres: look up by name in pg_database.
  local pg_match=""
  if docker inspect "${POSTGRES_CONTAINER:-postgres-dbx}" >/dev/null 2>&1; then
    local pg_root_pass
    pg_root_pass=$(docker exec "${POSTGRES_CONTAINER:-postgres-dbx}" \
      printenv POSTGRES_PASSWORD 2>/dev/null || echo "")
    pg_match=$(docker exec -e PGPASSWORD="$pg_root_pass" \
      "${POSTGRES_CONTAINER:-postgres-dbx}" \
      psql -U postgres -tA -c \
      "SELECT 1 FROM pg_database WHERE datname='$db' LIMIT 1" \
      2>/dev/null | tr -d '[:space:]')
  fi
  if [[ "$pg_match" == "1" ]]; then
    printf '%s\n' "postgres"
    return 0
  fi

  # MySQL.
  local my_match=""
  if docker inspect "${MYSQL_CONTAINER:-mysql-dbx}" >/dev/null 2>&1; then
    local my_root_pass
    my_root_pass=$(docker exec "${MYSQL_CONTAINER:-mysql-dbx}" \
      printenv MYSQL_ROOT_PASSWORD 2>/dev/null || echo "")
    my_match=$(docker exec -e MYSQL_PWD="$my_root_pass" \
      "${MYSQL_CONTAINER:-mysql-dbx}" \
      mysql -u root -B -N -e \
      "SELECT 1 FROM information_schema.schemata WHERE schema_name='$db' LIMIT 1" \
      2>/dev/null | tr -d '[:space:]')
  fi
  if [[ "$my_match" == "1" ]]; then
    printf '%s\n' "mysql"
    return 0
  fi

  return 0
}

# Schema TSV (table, column, data_type, is_nullable) for a local-container
# database. Picks the engine via scrub_local_db_engine. Dies cleanly when
# the db is in neither container.
# Args: $1 db name
scrub_local_schema_tsv() {
  local db="$1"
  local engine
  engine=$(scrub_local_db_engine "$db")
  case "$engine" in
    postgres) scrub_schema_query_pg_local "$db" ;;
    mysql)    scrub_schema_query_mysql_local "$db" ;;
    *)
      die "scrub: database '$db' not found in ${POSTGRES_CONTAINER:-postgres-dbx} or ${MYSQL_CONTAINER:-mysql-dbx} (restore it first, or pass a configured <host>)"
      ;;
  esac
}

# ============================================================================
# PII summary for `dbx analyze` (PR-E)
# ============================================================================
#
# Given a schema JSON (output of scrub_schema_tsv_to_json), emit a TSV
# of (table\tcomma-separated-pii-cols) — one row per table that has at
# least one dictionary-matching column. Pure jq+bash; no docker.
# Args: $1 schema JSON, $2 manifest JSON (optional; defaults to {})
scrub_pii_summary_tsv() {
  local schema="$1" manifest="${2:-{\}}"
  local table col matches pat
  while IFS= read -r table; do
    [[ -z "$table" ]] && continue
    matches=""
    while IFS= read -r col; do
      [[ -z "$col" ]] && continue
      pat=$(scrub_dict_matches "$col" "$manifest")
      if [[ -n "$pat" ]]; then
        if [[ -z "$matches" ]]; then
          matches="$col"
        else
          matches="$matches,$col"
        fi
      fi
    done < <(jq -r --arg t "$table" '.tables[$t].columns | keys[]?' <<<"$schema" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
      printf '%s\t%s\n' "$table" "$matches"
    fi
  done < <(jq -r '.tables | keys[]?' <<<"$schema" 2>/dev/null || true)
}

# Echo PII candidate columns (comma-separated) for a single table from
# a TSV produced by scrub_pii_summary_tsv. Empty if the table has none.
# Args: $1 TSV, $2 table name
scrub_pii_for_table() {
  local tsv="$1" table="$2"
  printf '%s\n' "$tsv" | awk -F'\t' -v t="$table" '$1 == t { print $2; exit }'
}

# ============================================================================
# Restore-time gate
# ============================================================================
#
# When hosts.<h>.scrub.required is true, dbx restore wraps the
# post-restore phase with:
#   1. Schema diff against the restored DB → abort if drift
#   2. Apply declarative UPDATEs from the manifest
#   3. Run sniff SELECTs → drop the DB on any failure
#   4. Emit scrub_report.json next to the backup
#
# The sequencing is deliberately fail-closed: partial scrub is worse
# than no scrub (a half-scrubbed clone looks safe but isn't), so any
# failure during steps 1-3 results in the target DB being DROPPED.
# This inverts the policy used by post_restore hooks, which leave the
# DB in place for inspection — appropriate for hooks that touch
# config rows, but wrong for PII scrub.

# Pre-flight drift check. Reads the schema captured in the backup's
# .meta.json at backup time and diffs against the host's manifest. Used
# by cmd_restore to abort the restore BEFORE any data hits the local
# container — avoids the brief "data exists, then gets dropped"
# window of the post-restore check.
#
# Exit codes:
#   0 — clean (or backup pre-dates the schema-capture feature; caller
#       should fall through to the post-restore check)
#   2 — drift detected (caller MUST abort the restore)
#   1 — error (manifest missing, malformed, or unreadable)
#
# Args: $1 host, $2 meta_file path
scrub_preflight_drift_check() {
  local host="$1" meta_file="$2"

  scrub_manifest_exists "$host" || return 1

  if [[ ! -f "$meta_file" ]]; then
    log_warn "scrub preflight: no meta.json next to backup — falling back to post-restore drift check"
    return 0
  fi

  # Backups taken before the scrub_schema field was added have no
  # captured schema. Skip pre-flight (clean) and let the post-restore
  # check pick it up. Don't fail — old backups must remain restorable.
  local schema
  schema=$(jq -c '.scrub_schema // null' "$meta_file" 2>/dev/null || echo "null")
  if [[ "$schema" == "null" ]] || [[ "$schema" == "{}" ]]; then
    log_info "scrub preflight: backup lacks captured schema (older backup); deferring to post-restore drift check"
    return 0
  fi

  local manifest report
  manifest=$(scrub_read_manifest "$host")
  report=$(scrub_check_diff "$schema" "$manifest")

  if [[ "$(jq -r '.ok' <<<"$report")" == "true" ]]; then
    log_success "scrub preflight: meta.json schema matches manifest (no drift); restore may proceed"
    return 0
  fi

  log_error "scrub preflight: DRIFT DETECTED in backup's captured schema vs manifest"
  jq -r '
    if (.new_columns_with_dict_match | length) > 0 then
      "  New dictionary-matching columns:",
      (.new_columns_with_dict_match[] |
        "    \(.table).\(.column) (pattern: \(.pattern); suggested: \(.suggested.strategy))")
    else empty end,
    if (.new_tables_with_dict_matches | length) > 0 then
      "  New tables with dictionary matches:",
      (.new_tables_with_dict_matches[] |
        "    \(.table): \([.matches[].column] | join(", "))")
    else empty end,
    if (.missing_declared_columns | length) > 0 then
      "  Manifest references columns not in backup (rotting manifest):",
      (.missing_declared_columns[] | "    \(.table).\(.column)")
    else empty end,
    if (.json_columns_undeclared | length) > 0 then
      "  Undeclared JSON columns (implicit-deny):",
      (.json_columns_undeclared[] | "    \(.table).\(.column)")
    else empty end
  ' <<<"$report" >&2
  log_error "scrub preflight: refusing to restore — manifest does not cover this backup's schema"
  log_error "  Run: dbx scrub check $host/<db>   to triage; update dbx.scrub.json and re-run"
  return 2
}

# 0 iff scrub is configured AND required for this host.
# The gate is host-wide: it fires for every restore from this source. It is
# active when `scrub.required` is true OR `scrub.required_for` is a non-empty
# array. Honoring a non-empty `required_for` here is deliberate — a host
# configured with only `required_for` used to get NO gate at all (a silent
# PII-leak path), since dbx restores always land in a local container and
# there is no per-destination filtering to apply.
# Args: $1 host
scrub_gate_active() {
  local host="$1"
  scrub_manifest_exists "$host" || return 1
  local required required_for_count
  required=$(jq -r ".hosts[\"$host\"].scrub.required // false" "$CONFIG_FILE" 2>/dev/null || echo "false")
  required_for_count=$(jq -r ".hosts[\"$host\"].scrub.required_for // [] | length" "$CONFIG_FILE" 2>/dev/null || echo "0")
  [[ "$required" == "true" || "$required_for_count" -gt 0 ]]
}

# DROP a database in the local container. Used to fail-closed after
# any scrub error.
#
# CRITICAL: the MySQL branch MUST authenticate. Without MYSQL_PWD the
# DROP returns access-denied, the `|| true` swallows it, and the
# leaky clone stays in place — the exact failure this function exists
# to prevent. Failures are surfaced via log_error (not silently
# squelched) so a misconfigured container becomes visible.
# Args: $1 target_db, $2 engine
scrub_drop_local_db() {
  local target="$1" engine="$2"
  case "$engine" in
    postgres|postgresql)
      if ! docker exec "${POSTGRES_CONTAINER:-postgres-dbx}" \
          psql -U postgres -c "DROP DATABASE IF EXISTS \"$target\"" >/dev/null 2>&1; then
        log_error "scrub_drop_local_db: failed to drop '$target' from $POSTGRES_CONTAINER — INVESTIGATE, unscrubbed clone may persist"
      fi
      ;;
    mysql|mariadb)
      local root_pass
      root_pass=$(docker exec "${MYSQL_CONTAINER:-mysql-dbx}" \
        printenv MYSQL_ROOT_PASSWORD 2>/dev/null || echo "")
      if ! docker exec -e MYSQL_PWD="$root_pass" "${MYSQL_CONTAINER:-mysql-dbx}" \
          mysql -u root -e "DROP DATABASE IF EXISTS \`$target\`" >/dev/null 2>&1; then
        log_error "scrub_drop_local_db: failed to drop '$target' from $MYSQL_CONTAINER — INVESTIGATE, unscrubbed clone may persist"
      fi
      ;;
  esac
}

# Run the full gate against a freshly-restored target DB. Returns 0 on
# success (target is scrubbed + verified). On failure: DROPS the target,
# emits a report, and returns non-zero. The wrapper (cmd_restore)
# decides how loud to be about the failure.
#
# Side effects on success:
#   - target_db has its PII columns scrubbed
#   - scrub_report.json written to $report_dir
#
# Args: $1 source_host (manifest source)
#       $2 source_db (informational only)
#       $3 target_db (the just-restored local DB)
#       $4 engine
#       $5 report_dir (where to write scrub_report.json; mkdir -p'd)
scrub_run_gate() {
  local host="$1" db="$2" target="$3" engine="$4" report_dir="$5"

  log_step "scrub gate: validating manifest, applying scrub, verifying..."

  # Seed must be present BEFORE we touch the DB. A missing seed
  # silently producing zero-salt hashes would make every restore use
  # the same fake values across environments — defeats stable masking.
  local seed seed_env
  seed_env=$(jq -r '.seed_env // empty' < <(scrub_read_manifest "$host"))
  if [[ -n "$seed_env" ]]; then
    seed=$(scrub_seed_value "$host")
    if [[ -z "$seed" ]]; then
      log_error "scrub gate: seed_env '$seed_env' is unset. Set the env var or remove scrub.required from the host config."
      scrub_drop_local_db "$target" "$engine"
      return 1
    fi
  else
    log_warn "scrub gate: manifest does not declare seed_env; faked values will not be stable across restores."
    seed=""
  fi

  # 1. Drift check against the just-restored target's actual schema.
  local tsv schema manifest report
  case "$engine" in
    postgres|postgresql) tsv=$(scrub_schema_query_pg_local "$target") ;;
    mysql|mariadb)       tsv=$(scrub_schema_query_mysql_local "$target") ;;
    *)
      log_error "scrub gate: unknown engine '$engine' — dropping target as fail-safe"
      scrub_drop_local_db "$target" "$engine"
      return 1
      ;;
  esac
  schema=$(printf '%s\n' "$tsv" | scrub_schema_tsv_to_json)
  manifest=$(scrub_read_manifest "$host")
  report=$(scrub_check_diff "$schema" "$manifest")

  if [[ "$(jq -r '.ok' <<<"$report")" != "true" ]]; then
    log_error "scrub gate: DRIFT DETECTED — restored schema is not fully covered by the manifest"
    log_error "  Run: dbx scrub check $host/$db   for details"
    log_error "  Dropping target DB '$target' (no clone is safer than a leaky clone)"
    scrub_drop_local_db "$target" "$engine"
    mkdir -p "$report_dir"
    jq -n --argjson drift "$report" \
      '{ok:false, phase:"drift", drift:$drift}' > "$report_dir/scrub_report.json"
    return 1
  fi
  log_success "scrub gate: schema matches manifest"

  # 2. Apply scrub UPDATEs in a single transaction.
  if ! scrub_run_updates "$host" "$target" "$engine" "$seed"; then
    log_error "scrub gate: UPDATE phase FAILED (rolled back). Dropping target DB '$target'."
    scrub_drop_local_db "$target" "$engine"
    mkdir -p "$report_dir"
    jq -n '{ok:false, phase:"update"}' > "$report_dir/scrub_report.json"
    return 1
  fi
  log_success "scrub gate: UPDATEs applied"

  # 3. Sniff verification per (table, column).
  log_step "scrub gate: verifying scrub via sniff predicates..."
  local sniff
  sniff=$(scrub_run_sniffs "$host" "$target" "$engine")
  if [[ "$(jq -r '.ok' <<<"$sniff")" != "true" ]]; then
    local fails
    fails=$(jq -r '.verified[] | select(.pass == false) | "    \(.table).\(.column)\t(strategy: \(.strategy), sniff_count: \(.sniff_count))"' <<<"$sniff")
    log_error "scrub gate: SNIFF VERIFICATION FAILED — strategies did not match post-conditions:"
    printf '%s\n' "$fails" >&2
    log_error "  Dropping target DB '$target' (clone is not verifiably scrubbed)"
    scrub_drop_local_db "$target" "$engine"
    mkdir -p "$report_dir"
    jq -n --argjson sniff "$sniff" \
      '{ok:false, phase:"sniff", sniff:$sniff}' > "$report_dir/scrub_report.json"
    return 1
  fi
  log_success "scrub gate: all sniff predicates passed"

  # 4. Emit success report. Flatten the sniff payload so consumers
  # don't have to traverse `.sniff.verified` — `.verified` is the
  # per-column audit trail compliance teams want.
  mkdir -p "$report_dir"
  jq -n --argjson v "$(jq -c '.verified' <<<"$sniff")" \
        --arg host "$host" --arg db "$db" \
        --arg target "$target" --arg ts "$(date -u +%FT%TZ)" \
    '{ok:true, host:$host, source_db:$db, target_db:$target, verified_at:$ts, verified:$v}' \
    > "$report_dir/scrub_report.json"
  log_info "scrub_report.json written to: $report_dir/scrub_report.json"
  return 0
}
