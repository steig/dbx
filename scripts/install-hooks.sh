#!/usr/bin/env bash
#
# install-hooks.sh — point git at the repo's tracked .githooks/ directory.
#
# Git hooks live in .git/hooks, which is not version controlled, so a hook that
# guards a release is worthless unless every clone opts in. Setting
# core.hooksPath to a tracked directory makes the hooks travel with the repo.
#
# The directory is `.githooks/`, not `hooks/`: .gitignore reserves a top-level
# `/hooks/` for restore-prep operator artifacts, which must never reach this
# public repo, so a hook parked there would be silently untracked.
#
# Usage:
#   scripts/install-hooks.sh
#
# Undo:
#   git config --unset core.hooksPath

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

chmod +x .githooks/*
git config core.hooksPath .githooks

printf 'core.hooksPath -> .githooks/\n'
for hook in .githooks/*; do
  printf '  %s\n' "$(basename "$hook")"
done
