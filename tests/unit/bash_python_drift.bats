#!/usr/bin/env bats
#
# Contract tests for logic dbx implements twice — once in bash (dbx,
# lib/*.sh) and once in Python (lib/wizard-server.py, which backs `dbx
# wizard` and `dbx serve`). Issue #144.
#
# When one side changes and the other doesn't, the web UI and the CLI
# silently disagree: the wizard writes a manifest `dbx scrub` then rejects,
# offers a strategy the CLI has never heard of, or can't filter for an audit
# action the CLI emits. Nothing else in the suite catches that.
#
# Each test either derives the expected value from one side and asserts the
# other matches it, or runs both implementations over the same inputs and
# compares. Nothing here restates a value that lives in the production
# source — a copied constant drifts in lockstep with the bug it should
# catch. Where a test does pin a literal, it says so and explains why.
#
# Host aliases are deliberately absent: tests/unit/alias_validation.bats
# already covers HOST_ALIAS_RE vs core.sh:host_alias_valid.

load '../helpers/common'

# Importing lib/wizard-server.py needs a working python3. Probe once so a
# broken interpreter is one clear error rather than a failure per test.
setup_file() {
  local err
  if ! err=$(python3 -c 'import re, json, importlib.util' 2>&1); then
    echo "python3 cannot import the wizard server's stdlib deps; every test" >&2
    echo "in this file would fail identically." >&2
    echo "$err" >&2
    return 1
  fi
}

setup() {
  setup_dbx_env
  source_dbx_libs
}

# Run the Python snippet on stdin with lib/wizard-server.py imported as `ws`,
# so a test reads the server's real constants and functions rather than a
# copy. Extra arguments arrive as sys.argv[1:].
#
# PYTHONDONTWRITEBYTECODE: importing by path would otherwise drop a
# lib/__pycache__ into the working tree on every run.
wizard_py() {
  PYTHONDONTWRITEBYTECODE=1 python3 -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("ws", sys.argv.pop(1))
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)
exec(sys.stdin.read())' "$DBX_REPO_ROOT/lib/wizard-server.py" "$@"
}

# ----------------------------------------------------------------------------
# Scrub strategy allowlist
#   lib/scrub.sh:SCRUB_VALID_STRATEGIES  vs  wizard-server.py:SCRUB_STRATEGIES
# ----------------------------------------------------------------------------

@test "drift: scrub strategy allowlist agrees between scrub.sh and the wizard" {
  # SCRUB_VALID_STRATEGIES comes from the sourced lib, not from parsing —
  # this compares the two live definitions.
  local bash_side py_side
  bash_side=$(printf '%s\n' "${SCRUB_VALID_STRATEGIES[@]}" | sort)
  py_side=$(wizard_py <<'PY'
for s in sorted(ws.SCRUB_STRATEGIES):
    print(s)
PY
)
  if [ "$bash_side" != "$py_side" ]; then
    echo "SCRUB_VALID_STRATEGIES (lib/scrub.sh) and SCRUB_STRATEGIES"
    echo "(lib/wizard-server.py) have drifted. '<' = bash only, '>' = wizard only:"
    diff <(printf '%s\n' "$bash_side") <(printf '%s\n' "$py_side") || true
    return 1
  fi
}

# ----------------------------------------------------------------------------
# Manifest-shape validation
#   lib/scrub.sh:scrub_validate_manifest  vs  wizard-server.py:_validate_manifest_shape
#
# The wizard's check is documented as a lightweight pre-validation, so it is
# allowed to be LOOSER than the CLI — a manifest it accepts may still fail
# `dbx scrub validate`, and the user finds out on the next CLI run. What it
# must never be is STRICTER: rejecting a manifest the CLI is perfectly happy
# with means the wizard refuses to save valid work, with no CLI error to
# point at. So the contract asserted here is directional:
#
#     bash accepts  =>  the wizard must not reject
#
# Both sides run over the same corpus; no verdict is written down.
# ----------------------------------------------------------------------------

# A manifest exercising every strategy with the parameters scrub.sh requires
# for it. Fixture data, not a duplicated allowlist — the test below asserts
# its strategy set equals SCRUB_VALID_STRATEGIES, so adding a strategy to
# bash forces this to grow and be checked against the wizard.
manifest_all_strategies() {
  cat <<'JSON'
{
  "version": "1",
  "seed_env": "DBX_SCRUB_SEED",
  "dictionary": { "extend": ["mrn"], "exclude": ["addr"] },
  "tables": {
    "users": {
      "columns": {
        "email":    { "strategy": "fake_email" },
        "phone":    { "strategy": "fake_phone" },
        "last_ip":  { "strategy": "fake_ip" },
        "full_name":{ "strategy": "fake_name" },
        "ssn":      { "strategy": "redact", "replacement": "REDACTED" },
        "bio":      { "strategy": "truncate", "length": 20 },
        "dob":      { "strategy": "shift_date", "max_days": 30 },
        "tenant_id":{ "strategy": "passthrough", "reason": "FK, carries no PII" },
        "prefs":    { "strategy": "jsonb_scrub_paths",
                      "paths": { "$.contact.email": "fake_email" } }
      }
    },
    "audit_events": { "no_pii": true, "reason": "FK columns and timestamps only" }
  }
}
JSON
}

@test "drift: the all-strategies fixture covers every strategy scrub.sh knows" {
  # Guards the corpus below: if bash learns a strategy and the fixture
  # doesn't, the wizard would never be tested against a manifest using it.
  local in_fixture in_bash
  in_fixture=$(manifest_all_strategies | jq -r '
    [.tables[].columns // {} | .[].strategy] | unique | .[]')
  in_bash=$(printf '%s\n' "${SCRUB_VALID_STRATEGIES[@]}" | sort)
  if [ "$in_fixture" != "$in_bash" ]; then
    echo "manifest_all_strategies() no longer covers SCRUB_VALID_STRATEGIES."
    echo "Add the missing strategy (with the params scrub.sh requires) to the fixture."
    echo "'<' = in the fixture only, '>' = in scrub.sh only:"
    diff <(printf '%s\n' "$in_fixture") <(printf '%s\n' "$in_bash") || true
    return 1
  fi
}

# Manifests the CLI accepts. The wizard must accept all of them.
# Format: <label>|<json>
manifest_corpus() {
  cat <<JSON
all strategies with valid params|$(manifest_all_strategies | jq -c .)
minimal single-column manifest|{"version":"1","tables":{"t":{"columns":{"c":{"strategy":"redact"}}}}}
table declared no_pii with a reason|{"version":"1","tables":{"t":{"no_pii":true,"reason":"lookup table"}}}
explicit no_pii false alongside columns|{"version":"1","tables":{"t":{"no_pii":false,"columns":{"c":{"strategy":"fake_email"}}}}}
empty tables object|{"version":"1","tables":{}}
version as a JSON number|{"version":1,"tables":{"t":{"columns":{"c":{"strategy":"redact"}}}}}
JSON
}

# Corpus entries the wizard is known to reject despite the CLI accepting them
# — i.e. live bugs, listed so the contract test stays useful instead of being
# switched off. The test asserts each STILL diverges, so fixing one fails here
# and forces the entry to be deleted rather than quietly outliving the bug.
#
# "version as a JSON number": _validate_manifest_shape requires
# manifest["version"] to be a str, but scrub.sh accepts anything jq -r
# renders as "1" — and scrub.sh:scrub_init_draft_from_schema emits
# `{version: 1, ...}` as a JSON number. So `dbx scrub init` writes a manifest
# the wizard then refuses to save. Not fixed here: this is a test-only change
# and lib/wizard-server.py is being refactored elsewhere.
manifest_known_divergence() {
  cat <<'JSON'
version as a JSON number
JSON
}

@test "drift: the wizard never rejects a scrub manifest the CLI accepts" {
  local line label json bash_verdict py_verdict expect_divergent failures=0
  local mf="$BATS_TEST_TMPDIR/manifest.json"

  # Read the corpus into an array first: the loop body runs jq and python3,
  # which would otherwise eat the loop's stdin.
  local -a corpus=()
  while IFS= read -r line; do
    [ -n "$line" ] && corpus+=("$line")
  done < <(manifest_corpus)
  [ "${#corpus[@]}" -gt 0 ] || { echo "corpus came back empty"; return 1; }

  for line in "${corpus[@]}"; do
    label="${line%%|*}"
    json="${line#*|}"
    printf '%s' "$json" > "$mf"

    if scrub_validate_manifest "$mf" >/dev/null 2>&1; then
      bash_verdict=accept
    else
      bash_verdict=reject
    fi

    # Manifest goes in via argv: the snippet itself arrives on stdin.
    py_verdict=$(wizard_py "$json" <<'PY'
import json, sys
err = ws._validate_manifest_shape(json.loads(sys.argv[1]))
print("accept" if err is None else "reject: " + err)
PY
)

    if printf '%s\n' "$(manifest_known_divergence)" | grep -Fxq "$label"; then
      expect_divergent=yes
    else
      expect_divergent=no
    fi

    if [ "$bash_verdict" != "accept" ]; then
      echo "corpus entry '$label' is supposed to be CLI-valid but scrub.sh rejected it:"
      scrub_validate_manifest "$mf" 2>&1 | head -5
      failures=$((failures + 1))
      continue
    fi

    case "$expect_divergent:$py_verdict" in
      no:accept)  ;;
      yes:reject*)
        ;;
      no:reject*)
        echo "DRIFT: '$label' — scrub.sh accepts this manifest but the wizard"
        echo "  refuses to save it, so the UI blocks work the CLI allows."
        echo "  wizard said: ${py_verdict#reject: }"
        failures=$((failures + 1))
        ;;
      yes:accept)
        echo "'$label' is listed in manifest_known_divergence() but the wizard"
        echo "  now accepts it — the bug is fixed. Delete that entry."
        failures=$((failures + 1))
        ;;
    esac
  done

  [ "$failures" -eq 0 ]
}

# ----------------------------------------------------------------------------
# Scrub manifest path resolution
#   lib/scrub.sh:scrub_manifest_path  vs  wizard-server.py:_scrub_manifest_path_for
#
# Both read hosts.<alias>.scrub.manifest out of the same config.json and
# resolve a relative value against the config file's directory. Run both.
# ----------------------------------------------------------------------------

@test "drift: manifest path resolves the same in scrub.sh and the wizard" {
  local cfg="$DBX_CONFIG_DIR/config.json"
  write_config '{
    "hosts": {
      "abs":     { "scrub": { "manifest": "/etc/dbx/abs.json" } },
      "rel":     { "scrub": { "manifest": "scrub/rel.json" } },
      "noscrub": { "type": "postgres" },
      "empty":   { "scrub": {} }
    }
  }'

  local alias bash_path py_path failures=0
  for alias in abs rel noscrub empty; do
    bash_path=$(scrub_manifest_path "$alias")
    py_path=$(wizard_py "$cfg" "$alias" <<'PY'
import json, sys
cfg_path, alias = sys.argv[1], sys.argv[2]
with open(cfg_path) as f:
    block = json.load(f)["hosts"].get(alias)
print(ws._scrub_manifest_path_for(cfg_path, block) or "")
PY
)
    if [ "$bash_path" != "$py_path" ]; then
      echo "DRIFT for host '$alias': scrub.sh gave '$bash_path', wizard gave '$py_path'"
      failures=$((failures + 1))
    fi
  done
  [ "$failures" -eq 0 ]
}

# ----------------------------------------------------------------------------
# Audit action allowlist
#   the actions core.sh/dbx actually emit  vs  wizard-server.py:AUDIT_ACTION_ALLOWLIST
#
# The wizard 400s on an action outside its allowlist, so an action bash emits
# but the wizard doesn't list is a filter the UI can never apply. The reverse
# (an allowlisted action nothing emits yet) is harmless, so this is a
# superset check, not equality.
# ----------------------------------------------------------------------------

@test "drift: every audit action bash emits is filterable in the wizard" {
  # audit_log's first argument at every call site. One call site builds the
  # action dynamically (audit_log "vault_$operation" in core.sh:audit_vault);
  # its values come from the audit_vault call sites instead.
  local all_sites dynamic literal from_vault emitted allowlist missing
  all_sites=$(grep -hoE 'audit_log "[^"]*"' \
    "$DBX_REPO_ROOT/dbx" "$DBX_REPO_ROOT"/lib/*.sh | sort -u)
  [ -n "$all_sites" ] || {
    echo "found no audit_log call sites — the extraction below is broken, not the code"
    return 1
  }

  dynamic=$(printf '%s\n' "$all_sites" | grep -F '$' || true)
  if [ "$dynamic" != 'audit_log "vault_$operation"' ]; then
    echo "audit_log is called with an interpolated action this test can't read:"
    printf '%s\n' "$dynamic"
    echo "Extend the extraction to enumerate its values, or this check silently"
    echo "stops covering that action."
    return 1
  fi

  literal=$(printf '%s\n' "$all_sites" | grep -vF '$' | cut -d'"' -f2)
  from_vault=$(grep -hoE 'audit_vault "[a-z]+"' \
    "$DBX_REPO_ROOT/dbx" "$DBX_REPO_ROOT"/lib/*.sh \
    | cut -d'"' -f2 | awk '{ print "vault_" $0 }')
  emitted=$(printf '%s\n%s\n' "$literal" "$from_vault" | sort -u)

  allowlist=$(wizard_py <<'PY'
for a in sorted(ws.AUDIT_ACTION_ALLOWLIST):
    print(a)
PY
)
  missing=$(comm -23 <(printf '%s\n' "$emitted") <(printf '%s\n' "$allowlist"))
  if [ -n "$missing" ]; then
    echo "bash emits these audit actions but AUDIT_ACTION_ALLOWLIST"
    echo "(lib/wizard-server.py) omits them, so the UI cannot filter for them:"
    printf '%s\n' "$missing"
    return 1
  fi
}

# ----------------------------------------------------------------------------
# Flavor -> managed container
#   core.sh:POSTGRES_CONTAINER/MYSQL_CONTAINER + dbx's case arms
#   vs  wizard-server.py:_FLAVOR_TO_CONTAINER
# ----------------------------------------------------------------------------

# bash's flavor -> container mapping, obtained by calling the function that
# owns it (engine_container, lib/core.sh) once per flavor named on stdin.
# This used to scrape the `ho_container="$VAR"` case arms out of dbx's
# --hooks-only path, because that was the only place bash wrote the mapping
# down; #143 gave it a single home, so the test can exercise the real thing
# instead of pattern-matching source. Env overrides are cleared because the
# wizard's map is a literal, so the defaults are what it has to match.
# Emits "<flavor> <container>", or "<flavor> UNMAPPED" when bash rejects it.
# Runs in a subshell: core.sh only assigns at top level, nothing to clean up.
bash_flavor_containers() (
  unset DBX_POSTGRES_CONTAINER DBX_MYSQL_CONTAINER
  # shellcheck source=/dev/null
  source "$DBX_REPO_ROOT/lib/core.sh"
  local flavor container
  while IFS= read -r flavor; do
    [ -n "$flavor" ] || continue
    if container=$(engine_container "$flavor"); then
      printf '%s %s\n' "$flavor" "$container"
    else
      printf '%s UNMAPPED\n' "$flavor"
    fi
  done
)

@test "drift: wizard flavor map resolves to the containers bash would use" {
  local py_map bash_map line flavor want got failures=0

  py_map=$(wizard_py <<'PY'
for flavor, container in sorted(ws._FLAVOR_TO_CONTAINER.items()):
    print(flavor, container)
PY
)
  [ -n "$py_map" ] || {
    echo "wizard-server.py exposed no _FLAVOR_TO_CONTAINER entries to compare."
    return 1
  }

  # Ask bash for a container for exactly the flavors the wizard claims to know.
  bash_map=$(printf '%s\n' "$py_map" | awk '{print $1}' | bash_flavor_containers)

  local -a entries=()
  while IFS= read -r line; do
    [ -n "$line" ] && entries+=("$line")
  done < <(printf '%s\n' "$py_map")

  for line in "${entries[@]}"; do
    flavor="${line%% *}"
    got="${line#* }"
    want=$(printf '%s\n' "$bash_map" | awk -v f="$flavor" '$1 == f { print $2; exit }')
    if [ "$want" = "UNMAPPED" ]; then
      echo "DRIFT: the wizard maps flavor '$flavor' but engine_container rejects it"
      failures=$((failures + 1))
      continue
    fi
    if [ "$got" != "$want" ]; then
      echo "DRIFT: flavor '$flavor' — wizard says '$got', engine_container says '$want'"
      failures=$((failures + 1))
    fi
  done
  [ "$failures" -eq 0 ]
}

# ----------------------------------------------------------------------------
# Backup filename extensions accepted by the `latest` rule
#   lib/storage.sh:storage_resolve_remote_path  (remote /latest)
#   dbx's local `latest` glob                   (local host/db/latest)
#   wizard-server.py:SOURCE_HOSTDB_RE           (wizard restore source)
#
# All three answer "which files count as a backup". dbx's interactive fzf
# picker knows a wider legacy set (.sql, .sql.gz and their encrypted forms);
# that's a different rule and is not compared here.
# ----------------------------------------------------------------------------

@test "drift: the three latest-resolution sites accept the same backup extensions" {
  local storage_exts dbx_exts ext failures=0

  # storage.sh: the case arm inside storage_resolve_remote_path.
  storage_exts=$(awk '/^storage_resolve_remote_path\(\)/,/^}/' \
    "$DBX_REPO_ROOT/lib/storage.sh" \
    | grep -oE '\*\.sql\.zst[a-z.]*' | cut -c2- | sort -u)

  # dbx: the glob list feeding `ls -t` when the selector is `latest`.
  dbx_exts=$(grep -F 'ls -t "$backup_dir"' "$DBX_REPO_ROOT/dbx" \
    | grep -oE '\.sql\.zst[a-z.]*' | sort -u)

  [ -n "$storage_exts" ] && [ -n "$dbx_exts" ] || {
    echo "could not read the backup-extension list out of the bash sources;"
    echo "storage.sh gave '$storage_exts', dbx gave '$dbx_exts'."
    return 1
  }

  if [ "$storage_exts" != "$dbx_exts" ]; then
    echo "DRIFT between the two bash latest-resolution sites."
    echo "'<' = storage_resolve_remote_path only, '>' = dbx's local glob only:"
    diff <(printf '%s\n' "$storage_exts") <(printf '%s\n' "$dbx_exts") || true
    failures=$((failures + 1))
  fi

  # No stdin consumed by the loop itself, so wizard_py's heredoc is safe.
  for ext in $storage_exts; do
    if [ "$(wizard_py "$ext" <<'PY'
import sys
src = "prod/myapp/myapp_20260101_000000" + sys.argv[1]
print("yes" if ws.SOURCE_HOSTDB_RE.match(src) else "no")
PY
)" != "yes" ]; then
      echo "DRIFT: bash treats '$ext' as a backup for host/db/latest, but"
      echo "  SOURCE_HOSTDB_RE rejects it — the wizard can't restore those."
      failures=$((failures + 1))
    fi
  done

  # And not vacuously permissive: .sql.gz is a real dbx extension (the fzf
  # picker lists it) that both latest-resolution sites exclude.
  if [ "$(wizard_py <<'PY'
print("yes" if ws.SOURCE_HOSTDB_RE.match("prod/myapp/myapp_20260101_000000.sql.gz") else "no")
PY
)" != "no" ]; then
    echo "SOURCE_HOSTDB_RE accepts .sql.gz, which neither bash latest rule does."
    failures=$((failures + 1))
  fi

  [ "$failures" -eq 0 ]
}
