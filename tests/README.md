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

## Debugging a failing test

bats prints `not ok N` for failures plus the assertion line that fired. If the test exits cleanly but bats reports `Executed M instead of expected N`, several real things to check:

### "Executed X of Y" with a missing test number

Usually means a library being sourced has installed an `EXIT` trap that clobbers bats's own. The trap prevents bats from recording the failure as TAP output, so the test "vanishes." `lib/core.sh` no longer auto-installs its trap on source for this reason — if a future module does, move the call out to `dbx`.

### `set -e` killing the test mid-body

Tests inherit the harness's `set -e` rules. If your assertion writes to a variable from a function that exits non-zero (e.g. `count=$(some_cmd)`), the script exits before bats sees the failure. Wrap with `|| true` or use `run` so bats captures the exit code.

### `gh pr view` / `dbx` returning unexpected exit codes

Probably a polluted environment. `setup_dbx_env` already unsets `DEV_SERVICES_MODE`, `DEV_PG_*`, `DEV_MYSQL_*`. If the test depends on another env var that the dev shell leaks, add it to that unset list.

### Integration test "container failed to become ready"

`ensure_mysql_container` polls for an authenticated `mysql -u root` (not just `mysqladmin ping` — ping returns success before the root password is initialised). If you get this, check `docker logs mysql-dbx` directly. If postgres-dbx is the issue, `pg_isready` is usually accurate; check the docker daemon and that port 5432 isn't already bound on the host.

### Inspecting a test's working directory

Each test gets `BATS_TEST_TMPDIR`. To preserve it for inspection:

```bash
bats --no-tempdir-cleanup tests/integration/<file>.bats
```

bats prints the kept tmpdir path; backup files, configs, and meta.json fixtures are all under there.

### Running just one test

Filter by name (substring match):

```bash
bats --filter 'restore round-trips' tests/integration/postgres_roundtrip.bats
```

### Adding diagnostic output without breaking the test

bats redirects stdout/stderr; use FD 3 for "always-visible" output:

```bash
echo "saw value: $result" >&3
```

It surfaces in the test log without contaminating `$output` (which `run` captures from FDs 1/2).
