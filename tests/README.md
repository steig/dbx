# dbx tests

Two-tier test suite using [bats-core](https://github.com/bats-core/bats-core).

## Layout

```
tests/
├── helpers/
│   ├── common.bash        # source dbx libs into a test shell, isolate paths
│   └── integration.bash   # docker container fixtures, seed/drop helpers
├── unit/                  # pure-function tests, no docker
│   ├── core.bats
│   ├── encrypt.bats
│   ├── notify.bats
│   ├── schedule.bats
│   └── storage.bats
└── integration/           # CLI round-trip tests against real postgres/mysql
    ├── postgres_roundtrip.bats
    ├── mysql_roundtrip.bats
    ├── encryption.bats
    ├── multi_database.bats
    └── clean.bats
```

## Run locally

```bash
# Install bats
brew install bats-core            # macOS
sudo apt install bats              # Ubuntu/Debian

# Unit tests (fast, no docker)
bats tests/unit/

# Integration tests (requires docker; will create postgres-dbx + mysql-dbx
# containers if missing). Each test isolates its config/data under
# BATS_TEST_TMPDIR; only the database/container state is shared.
bats tests/integration/

# Both
bats tests/unit/ tests/integration/
```

## Conventions

- Helpers live in `tests/helpers/` and are loaded with `load '../helpers/common'`.
- Each test isolates `DBX_DATA_DIR`, `DBX_CONFIG_DIR`, `DBX_AUDIT_DIR` under `BATS_TEST_TMPDIR` so tests never touch the user's real config or backup tree.
- Integration tests share the `postgres-dbx` and `mysql-dbx` containers across tests for speed; each test uses a uniquely-named database (`dbx_*_test_$$_${BATS_TEST_NUMBER}`) and drops it in `teardown`.
- Integration tests bypass the system keychain by setting `password_cmd: "echo devpassword"` in the test config.
- Tests that need optional tooling (age, gpg) `skip` cleanly when the binary isn't installed.

## Adding a test

For a pure function:
```bash
# tests/unit/<lib>.bats
load '../helpers/common'
setup() { setup_dbx_env; source_dbx_libs; }

@test "describe what is being tested" {
  result=$(your_function arg)
  [ "$result" = "expected" ]
}
```

For end-to-end behavior:
```bash
# tests/integration/<feature>.bats
load '../helpers/integration'
setup_file() { require_docker; ensure_postgres_container; }
setup() { setup_dbx_env; write_local_config; }

@test "behavior under <condition>" {
  dbx_run backup local-pg some_db
  [ "$status" -eq 0 ]
}
```
