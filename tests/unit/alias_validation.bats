#!/usr/bin/env bats
# Guards issue #118: the wizard's host-alias regex (HOST_ALIAS_RE in
# lib/wizard-server.py) and the CLI's host_alias_valid (lib/core.sh) must
# agree on every alias, so an alias the wizard accepts is never rejected by
# `dbx host add` (and vice versa).
load '../helpers/common'
setup() { setup_dbx_env; source_dbx_libs; }

# Run lib/wizard-server.py's HOST_ALIAS_RE against an alias; echo "yes"/"no".
# Imports the module's compiled regex directly so the test exercises the exact
# pattern the server uses, not a copy.
wizard_alias_match() {
  python3 - "$DBX_REPO_ROOT/lib/wizard-server.py" "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("wizard_server", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print("yes" if mod.HOST_ALIAS_RE.match(sys.argv[2]) else "no")
PY
}

@test "host alias rule agrees between bash and wizard across cases" {
  cases=(
    "production" "prod-east-1" "db_2" "MixedCase" "a"
    "prod-" "prod_"
    "" "-prod" "_prod" "with space" "with/slash"
    "prod.east" "prod;rm" 'prod$x' 'a.b.c'
  )
  for c in "${cases[@]}"; do
    if host_alias_valid "$c"; then bash_ok="yes"; else bash_ok="no"; fi
    wiz_ok=$(wizard_alias_match "$c")
    [ "$bash_ok" = "$wiz_ok" ] || {
      echo "mismatch for alias '$c': bash=$bash_ok wizard=$wiz_ok"
      return 1
    }
  done
}

@test "wizard HOST_ALIAS_RE rejects dotted alias (the #118 regression)" {
  [ "$(wizard_alias_match 'prod.east')" = "no" ]
}

@test "wizard HOST_ALIAS_RE accepts a long alias (no length cap, matching CLI)" {
  long=$(printf 'a%.0s' {1..80})
  host_alias_valid "$long"
  [ "$(wizard_alias_match "$long")" = "yes" ]
}
