#!/usr/bin/env bats
#
# Tests for cmd_backup's --schema-only / --data-only flag parsing (#129).
# The mutual-exclusion guard fires during argument parsing, before any
# docker/config requirement, so these run without containers.

load '../helpers/common'
load '../helpers/integration'

setup() {
  setup_dbx_env
  # A host entry is needed only so the flag-parse error is the first failure.
  cat > "$DBX_CONFIG_DIR/config.json" <<'EOF'
{
  "hosts": {
    "local-pg": { "type": "postgres", "host": "127.0.0.1", "port": 5432, "user": "postgres", "password_cmd": "echo x" }
  }
}
EOF
}

@test "backup: --schema-only and --data-only together is rejected" {
  dbx_run backup local-pg somedb --schema-only --data-only
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "mutually exclusive"
}

@test "backup: --data-only and --schema-only together is rejected (reverse order)" {
  dbx_run backup local-pg somedb --data-only --schema-only
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "mutually exclusive"
}

@test "backup: usage hint mentions schema-only/data-only" {
  dbx_run backup
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF -- "--schema-only"
  echo "$output" | grep -qF -- "--data-only"
}
