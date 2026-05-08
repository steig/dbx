#!/usr/bin/env bash
#
# lib/update.sh - Notify the user when a newer dbx release is available.
#
# The check hits GitHub's Releases API rather than scraping the VERSION
# constant from main, so it only fires on actually-tagged releases (not on
# every commit). Results are cached for UPDATE_CHECK_INTERVAL_SECONDS so
# subsequent invocations don't re-fetch.
#
# Requires: lib/core.sh sourced first (uses log_*, jq, $VERSION).
#

# Repo to look up. Override DBX_REPO_SLUG when working from a fork.
DBX_REPO_SLUG="${DBX_REPO_SLUG:-steig/dbx}"

# Where to cache the latest known release tag. Honors XDG_CACHE_HOME via
# DBX_CACHE_DIR if set.
UPDATE_CACHE_DIR="${DBX_CACHE_DIR:-$HOME/.cache/dbx}"
UPDATE_CACHE_FILE="$UPDATE_CACHE_DIR/latest-release"

# How long a cache entry stays valid before we re-fetch. Default 24h.
UPDATE_CHECK_INTERVAL_SECONDS="${DBX_UPDATE_CHECK_INTERVAL:-86400}"

# Compare two semver-ish version strings. Returns 0 if $1 is strictly
# greater than $2. Uses `sort -V` so "0.7.10" sorts above "0.7.2", and
# pre-release suffixes like "0.7.0-rc1" sort below "0.7.0".
version_gt() {
  local a="$1" b="$2"
  [[ "$a" != "$b" ]] && \
    [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n 1)" == "$a" ]]
}

# Decide whether we should attempt an update check at all. Skips when:
#   - DBX_NO_UPDATE_CHECK=1 is set (explicit opt-out)
#   - stdout isn't a TTY (cron / piped / scheduled use)
#   - jq or curl is missing (we can't fetch or parse)
update_check_enabled() {
  [[ "${DBX_NO_UPDATE_CHECK:-}" == "1" ]] && return 1
  [[ -t 1 ]] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  return 0
}

# Read the cached latest version if the cache file is younger than the
# configured interval. Echoes the cached value and returns 0 on hit;
# returns 1 when the cache is missing or stale so callers can refresh.
read_update_cache() {
  [[ -f "$UPDATE_CACHE_FILE" ]] || return 1
  local now mtime age
  now=$(date +%s)
  mtime=$(stat -f%m "$UPDATE_CACHE_FILE" 2>/dev/null \
       || stat -c%Y "$UPDATE_CACHE_FILE" 2>/dev/null \
       || echo 0)
  age=$((now - mtime))
  [[ $age -lt $UPDATE_CHECK_INTERVAL_SECONDS ]] || return 1
  cat "$UPDATE_CACHE_FILE"
}

# Persist the latest version to the cache. Best-effort — failures here
# only mean we'll re-fetch on the next invocation, which is harmless.
write_update_cache() {
  local version="$1"
  mkdir -p "$UPDATE_CACHE_DIR" 2>/dev/null || return 0
  printf '%s\n' "$version" > "$UPDATE_CACHE_FILE" 2>/dev/null || true
}

# Fetch the latest release tag from the GitHub Releases API and strip a
# leading "v" so callers can compare directly with $VERSION. Aggressive
# timeouts so dbx never feels slow when the user is offline. Returns 1
# (silently) on any network or parse failure.
fetch_latest_release() {
  local url resp tag
  url="https://api.github.com/repos/${DBX_REPO_SLUG}/releases/latest"
  resp=$(curl -fsSL --connect-timeout 2 --max-time 5 \
    -H 'Accept: application/vnd.github+json' \
    "$url" 2>/dev/null) || return 1
  tag=$(printf '%s' "$resp" | jq -r '.tag_name // empty' 2>/dev/null) || return 1
  [[ -n "$tag" ]] || return 1
  printf '%s' "${tag#v}"
}

# Print a single-line update notice if a newer release is available.
# Idempotent and self-gated — safe to call unconditionally at the end of
# main(). Cached so subsequent invocations don't hit the API.
maybe_notify_update() {
  update_check_enabled || return 0

  local latest
  latest=$(read_update_cache 2>/dev/null) || {
    latest=$(fetch_latest_release) || return 0
    write_update_cache "$latest"
  }

  if [[ -n "$latest" ]] && version_gt "$latest" "$VERSION"; then
    log_info "dbx $latest is available (you have $VERSION). Run 'dbx update' to upgrade."
  fi
}
