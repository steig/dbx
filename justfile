# dbx task runner — wraps the exact commands CI runs (.github/workflows/ci.yml)
# so `just <target>` locally matches CI. Requires: just, bats, shellcheck.

# List available targets
help:
    @just --list

# Run the full test suite (unit + integration)
test: test-unit test-integration

# Unit tests — pure functions, no docker (~1s)
test-unit:
    bats tests/unit/

# Integration tests — boots postgres + mysql in docker (~30s)
test-integration:
    bats tests/integration/

# ShellCheck at CI severity (error) on dbx + all libs
lint:
    shellcheck -S error dbx lib/*.sh

# Bash syntax check on dbx + all libs (CI: test-syntax)
syntax:
    bash -n dbx
    for f in lib/*.sh; do bash -n "$f"; done
