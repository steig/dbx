#!/usr/bin/env bash
#
# gen-shasums.sh — (re)write SHASUMS256.txt, the manifest install.sh verifies.
#
# Run it whenever you change a file that ships: `dbx`, any `lib/*`, any man
# page. scripts/check-release-consistency.sh fails the PR if you forget, and
# scripts/release.sh regenerates the manifest as part of the version bump.
#
# The file list is NOT defined here — this sources the drift guard and reuses
# release_shasums(), so the generator, the checker, and the release script can
# never disagree about what ships.
#
# Usage:
#   scripts/gen-shasums.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defines release_payload_files / release_shasums, sets ROOT, and cd's there.
# Sourcing runs no checks.
# shellcheck source=./check-release-consistency.sh
. "$SCRIPT_DIR/check-release-consistency.sh"

release_shasums > SHASUMS256.txt

printf 'Wrote SHASUMS256.txt (%s files).\n' "$(grep -c '' SHASUMS256.txt)"
