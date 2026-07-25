#!/usr/bin/env bash
#
# check-integration-coverage.sh — fail if an integration run skipped everything.
#
# The macOS integration job runs the whole of tests/integration/, and the
# Docker-dependent files skip themselves via require_docker (GitHub's macOS
# runners ship no Docker daemon — see #142). bats reports a run where every
# test skipped as a pass, so without this guard the job would report green
# while testing nothing, and would keep reporting green if the Docker-free
# tests were later deleted, renamed, or accidentally gated behind Docker.
#
# So: assert that at least MIN_EXECUTED tests actually ran. The floor is a
# lower bound, not an exact count — adding Docker-free tests raises the real
# number and never fails this check. Only losing coverage does.
#
# Usage: check-integration-coverage.sh <tap-file> [min-executed]
#
# Portable to macOS bash 3.2 / BSD tools: no GNU-isms.

set -euo pipefail

TAP_FILE="${1:?usage: check-integration-coverage.sh <tap-file> [min-executed]}"
MIN_EXECUTED="${2:-10}"

[ -f "$TAP_FILE" ] || { echo "FAIL: no TAP output at $TAP_FILE" >&2; exit 1; }

# TAP marks a skipped test as `ok N description # skip reason`, so executed
# passes are the `ok` lines without a `# skip` directive.
executed=$(grep '^ok' "$TAP_FILE" | grep -vc '# skip' || true)
skipped=$(grep -c '# skip' "$TAP_FILE" || true)
failed=$(grep -c '^not ok' "$TAP_FILE" || true)

echo "integration coverage: ${executed} executed, ${skipped} skipped, ${failed} failed"

if [ "$failed" -ne 0 ]; then
  echo "FAIL: ${failed} test(s) failed" >&2
  exit 1
fi

if [ "$executed" -lt "$MIN_EXECUTED" ]; then
  cat >&2 <<EOF
FAIL: only ${executed} test(s) actually executed, expected at least ${MIN_EXECUTED}.

This job exists to catch macOS-specific breakage. A run where everything
skipped proves nothing, so it is treated as a failure rather than a pass.

Likely causes:
  - a Docker-free test file was deleted or renamed
  - a Docker-free test gained a require_docker gate
  - bats/jq/zstd failed to install, so the tests could not run

Skip reasons seen in this run:
EOF
  grep -oE '# skip.*' "$TAP_FILE" | sort | uniq -c | sort -rn >&2
  exit 1
fi

echo "OK: at least ${MIN_EXECUTED} integration tests executed on $(uname -s)."
