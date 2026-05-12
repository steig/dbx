# Version-aware Docker images Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make dbx detect the source database's version (and Postgres extensions) and select a matching Docker image for the restore container, with a clean failure path when no match is available and explicit `--recreate-container` opt-in when an existing restore container holds user databases.

**Architecture:** Three pure layers (image selection, version parsing, container introspection) sit underneath two integration points: backup (writes new metadata fields) and restore (reads metadata, picks image, ensures container matches). No new commands, no state files. Spec lives at https://github.com/steig/dbx/issues/28.

**Tech Stack:** Bash, jq, Docker, bats for tests.

---

## File Structure

| File | Change | Responsibility |
|------|--------|----------------|
| `lib/core.sh` | Modify | Add `pick_postgres_image`, `pick_mysql_image`, `container_image`, `container_has_user_dbs`, `ensure_container_image` |
| `lib/postgres.sh` | Modify | Add `pg_detect_server_version`, `pg_detect_extensions`; enrich meta in `pg_backup`; consume meta in `pg_restore_backup` |
| `lib/mysql.sh` | Modify | Add `mysql_detect_server_version` (returns flavor+major+minor); enrich meta in `mysql_backup`; consume meta in `mysql_restore_backup`; match image at backup time |
| `dbx` | Modify | Add `--recreate-container` flag to `cmd_restore` |
| `tests/unit/image_selection.bats` | Create | Pure logic tests for `pick_postgres_image` / `pick_mysql_image` |
| `tests/unit/version_parsing.bats` | Create | Pure logic tests for parsing helpers |
| `tests/helpers/integration.bash` | Modify | Add `ensure_alt_postgres_container`, `ensure_mariadb_container` helpers |
| `tests/integration/version_aware.bats` | Create | End-to-end: PG 13 source → matching restore container; MariaDB source → mariadb image; recreate-flag flow |
| `README.md` | Modify | Document `DBX_POSTGRES_IMAGE` / `DBX_MYSQL_IMAGE`, recreate-container flag, extension allowlist |
| `AGENTS.md` | Modify | Lessons section entry on version-detection footguns (server_version_num encoding, MariaDB version strings) |
| `CHANGELOG.md` | Modify | Unreleased entry |

---

## Task 1: Pure image selection — Postgres, no extensions

**Files:**
- Create: `tests/unit/image_selection.bats`
- Modify: `lib/core.sh` (append `pick_postgres_image` function)

- [ ] **Step 1: Write the failing test**

```bash
# tests/unit/image_selection.bats
#!/usr/bin/env bats
load '../helpers/common'
setup() { setup_dbx_env; source_dbx_libs; }

@test "pick_postgres_image: bare PG returns postgres:N-alpine" {
  result=$(pick_postgres_image 15 "" "")
  [ "$result" = "postgres:15-alpine" ]
}

@test "pick_postgres_image: PG 17 with no extensions" {
  result=$(pick_postgres_image 17 "" "")
  [ "$result" = "postgres:17-alpine" ]
}

@test "pick_postgres_image: PG 13 with no extensions" {
  result=$(pick_postgres_image 13 "" "")
  [ "$result" = "postgres:13-alpine" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/unit/image_selection.bats`
Expected: 3 failures, all "command not found: pick_postgres_image"

- [ ] **Step 3: Implement minimal function**

Append to `lib/core.sh`:

```bash
# ============================================================================
# Image Selection
# ============================================================================

# Choose a Postgres Docker image for the given major version and extension set.
# Args:
#   $1: major version (e.g. "15"). May be "unknown".
#   $2: space-separated extension names (e.g. "vector postgis"). May be empty.
#   $3: override template (e.g. "myrepo/pg:{major}"). May be empty.
# Returns: image string on stdout, exit 1 with message on stderr if no mapping.
pick_postgres_image() {
  local major="$1"
  local extensions="$2"
  local override="$3"

  if [[ -n "$override" ]]; then
    # Substitute {major} and {version} (alias for {major}).
    local out="$override"
    out="${out//\{major\}/$major}"
    out="${out//\{version\}/$major}"
    echo "$out"
    return 0
  fi

  if [[ "$major" == "unknown" || -z "$major" ]]; then
    echo "postgres:17-alpine"
    return 0
  fi

  echo "postgres:${major}-alpine"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/unit/image_selection.bats`
Expected: 3 passing

- [ ] **Step 5: Commit**

```bash
git add tests/unit/image_selection.bats lib/core.sh
git commit -m "feat: add pick_postgres_image for bare PG versions"
```

---

## Task 2: Pure image selection — Postgres with extension allowlist

**Files:**
- Modify: `tests/unit/image_selection.bats`
- Modify: `lib/core.sh` (extend `pick_postgres_image`)

- [ ] **Step 1: Append failing tests**

```bash
@test "pick_postgres_image: vector extension → pgvector image" {
  result=$(pick_postgres_image 17 "vector" "")
  [ "$result" = "pgvector/pgvector:pg17" ]
}

@test "pick_postgres_image: postgis extension → postgis image" {
  result=$(pick_postgres_image 16 "postgis" "")
  [ "$result" = "postgis/postgis:16-3.5" ]
}

@test "pick_postgres_image: timescaledb → timescale image" {
  result=$(pick_postgres_image 14 "timescaledb" "")
  [ "$result" = "timescale/timescaledb:latest-pg14" ]
}

@test "pick_postgres_image: unknown extension fails with override hint" {
  run pick_postgres_image 15 "pg_partman" ""
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "DBX_POSTGRES_IMAGE"
  echo "$output" | grep -q "pg_partman"
}

@test "pick_postgres_image: two conflicting allowlisted extensions fails" {
  run pick_postgres_image 17 "vector postgis" ""
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "DBX_POSTGRES_IMAGE"
}

@test "pick_postgres_image: override template with {major}" {
  result=$(pick_postgres_image 15 "vector" "myrepo/pg:{major}")
  [ "$result" = "myrepo/pg:15" ]
}
```

- [ ] **Step 2: Run tests to verify new ones fail**

Run: `bats tests/unit/image_selection.bats`
Expected: 6 failures on the new tests, 3 still passing.

- [ ] **Step 3: Extend implementation**

Replace the `pick_postgres_image` body in `lib/core.sh` with:

```bash
pick_postgres_image() {
  local major="$1"
  local extensions="$2"
  local override="$3"

  if [[ -n "$override" ]]; then
    local out="$override"
    out="${out//\{major\}/$major}"
    out="${out//\{version\}/$major}"
    echo "$out"
    return 0
  fi

  if [[ "$major" == "unknown" || -z "$major" ]]; then
    major="17"
  fi

  # Filter out plpgsql (always present, not a real extension for our purposes).
  local ext_list=()
  local ext
  for ext in $extensions; do
    [[ "$ext" == "plpgsql" ]] && continue
    ext_list+=("$ext")
  done

  if [[ ${#ext_list[@]} -eq 0 ]]; then
    echo "postgres:${major}-alpine"
    return 0
  fi

  # Multi-extension case: every requested extension must be satisfiable by a
  # single image. We don't currently know of any image that satisfies more
  # than one of our allowlist mappings, so any combination here is an error.
  if [[ ${#ext_list[@]} -gt 1 ]]; then
    log_error "Source database uses multiple extensions that map to different specialized images: ${ext_list[*]}."
    log_error "Set DBX_POSTGRES_IMAGE to an image that includes all of them, or in config:"
    log_error '  { "defaults": { "postgres_image": "your-registry/your-image:tag" } }'
    return 1
  fi

  case "${ext_list[0]}" in
    vector)       echo "pgvector/pgvector:pg${major}" ;;
    postgis)      echo "postgis/postgis:${major}-3.5" ;;
    timescaledb)  echo "timescale/timescaledb:latest-pg${major}" ;;
    *)
      log_error "Source database uses extension '${ext_list[0]}' which dbx doesn't have a known image for."
      log_error "Set DBX_POSTGRES_IMAGE to an image that includes it, or in config:"
      log_error '  { "defaults": { "postgres_image": "your-registry/your-image:tag" } }'
      return 1
      ;;
  esac
}
```

- [ ] **Step 4: Run tests**

Run: `bats tests/unit/image_selection.bats`
Expected: 9 passing.

- [ ] **Step 5: Commit**

```bash
git add tests/unit/image_selection.bats lib/core.sh
git commit -m "feat: extension-aware Postgres image selection with override + fail-fast"
```

---

## Task 3: Pure image selection — MySQL and MariaDB

**Files:**
- Modify: `tests/unit/image_selection.bats`
- Modify: `lib/core.sh` (add `pick_mysql_image`)

- [ ] **Step 1: Append failing tests**

```bash
@test "pick_mysql_image: mysql 8.0" {
  result=$(pick_mysql_image mysql 8 0 "")
  [ "$result" = "mysql:8.0" ]
}

@test "pick_mysql_image: mysql 8.4" {
  result=$(pick_mysql_image mysql 8 4 "")
  [ "$result" = "mysql:8.4" ]
}

@test "pick_mysql_image: mariadb 10.11" {
  result=$(pick_mysql_image mariadb 10 11 "")
  [ "$result" = "mariadb:10.11" ]
}

@test "pick_mysql_image: mariadb 11.4" {
  result=$(pick_mysql_image mariadb 11 4 "")
  [ "$result" = "mariadb:11.4" ]
}

@test "pick_mysql_image: unknown flavor falls back to mysql 8.0" {
  result=$(pick_mysql_image unknown "" "" "")
  [ "$result" = "mysql:8.0" ]
}

@test "pick_mysql_image: override template with {version}" {
  result=$(pick_mysql_image mariadb 10 11 "myrepo/mariadb:{version}")
  [ "$result" = "myrepo/mariadb:10.11" ]
}
```

- [ ] **Step 2: Run to verify failures**

Run: `bats tests/unit/image_selection.bats`
Expected: 6 new failures.

- [ ] **Step 3: Implement**

Append to `lib/core.sh`:

```bash
# Choose a MySQL/MariaDB Docker image.
# Args:
#   $1: flavor ("mysql" | "mariadb" | "unknown")
#   $2: major version (e.g. "8", "10"). May be empty.
#   $3: minor version (e.g. "0", "11"). May be empty.
#   $4: override template. May be empty.
pick_mysql_image() {
  local flavor="$1"
  local major="$2"
  local minor="$3"
  local override="$4"

  local version="${major}.${minor}"

  if [[ -n "$override" ]]; then
    local out="$override"
    out="${out//\{major\}/$major}"
    out="${out//\{minor\}/$minor}"
    out="${out//\{version\}/$version}"
    echo "$out"
    return 0
  fi

  case "$flavor" in
    mariadb)  echo "mariadb:${version}" ;;
    mysql)    echo "mysql:${version}" ;;
    *)        echo "mysql:8.0" ;;
  esac
}
```

- [ ] **Step 4: Run tests**

Run: `bats tests/unit/image_selection.bats`
Expected: 15 passing.

- [ ] **Step 5: Commit**

```bash
git add tests/unit/image_selection.bats lib/core.sh
git commit -m "feat: add pick_mysql_image for mysql + mariadb flavors"
```

---

## Task 4: Postgres version parsing

**Files:**
- Create: `tests/unit/version_parsing.bats`
- Modify: `lib/postgres.sh` (add `pg_parse_server_version_num`)

Background: Postgres exposes the version as `server_version_num`, an integer. For PG ≥ 10 the format is `MMMmmmm` where the first 1-2 digits are major (130000 = 13, 160003 = 16). For PG < 10 it was `MMmmm` (90605 = 9.6) — we don't need to support that.

- [ ] **Step 1: Write the failing test**

```bash
# tests/unit/version_parsing.bats
#!/usr/bin/env bats
load '../helpers/common'
setup() { setup_dbx_env; source_dbx_libs; }

@test "pg_parse_server_version_num: 130000 → 13" {
  [ "$(pg_parse_server_version_num 130000)" = "13" ]
}

@test "pg_parse_server_version_num: 150004 → 15" {
  [ "$(pg_parse_server_version_num 150004)" = "15" ]
}

@test "pg_parse_server_version_num: 170001 → 17" {
  [ "$(pg_parse_server_version_num 170001)" = "17" ]
}

@test "pg_parse_server_version_num: empty input → unknown" {
  [ "$(pg_parse_server_version_num '')" = "unknown" ]
}

@test "pg_parse_server_version_num: non-numeric → unknown" {
  [ "$(pg_parse_server_version_num 'NaN')" = "unknown" ]
}
```

- [ ] **Step 2: Run to verify failures**

Run: `bats tests/unit/version_parsing.bats`
Expected: 5 failures.

- [ ] **Step 3: Implement**

Append to `lib/postgres.sh`:

```bash
# Parse server_version_num integer → major version string.
# PG 10+: MMMmmmm encoding (130000 → 13, 160003 → 16).
# Returns "unknown" if input isn't a non-empty integer.
pg_parse_server_version_num() {
  local raw="$1"
  [[ -z "$raw" ]] && { echo "unknown"; return 0; }
  [[ "$raw" =~ ^[0-9]+$ ]] || { echo "unknown"; return 0; }
  echo "$((raw / 10000))"
}
```

- [ ] **Step 4: Run tests**

Run: `bats tests/unit/version_parsing.bats`
Expected: 5 passing.

- [ ] **Step 5: Commit**

```bash
git add tests/unit/version_parsing.bats lib/postgres.sh
git commit -m "feat: parse Postgres server_version_num to major version"
```

---

## Task 5: MySQL/MariaDB version parsing

**Files:**
- Modify: `tests/unit/version_parsing.bats`
- Modify: `lib/mysql.sh` (add `mysql_parse_version_string`)

- [ ] **Step 1: Append failing tests**

```bash
@test "mysql_parse_version_string: 8.0.35 → mysql 8 0" {
  result=$(mysql_parse_version_string "8.0.35")
  [ "$result" = "mysql 8 0" ]
}

@test "mysql_parse_version_string: 8.4.2 → mysql 8 4" {
  result=$(mysql_parse_version_string "8.4.2")
  [ "$result" = "mysql 8 4" ]
}

@test "mysql_parse_version_string: 10.11.6-MariaDB-1:10.11 → mariadb 10 11" {
  result=$(mysql_parse_version_string "10.11.6-MariaDB-1:10.11.6+maria~ubu2204")
  [ "$result" = "mariadb 10 11" ]
}

@test "mysql_parse_version_string: 11.4.2-MariaDB → mariadb 11 4" {
  result=$(mysql_parse_version_string "11.4.2-MariaDB")
  [ "$result" = "mariadb 11 4" ]
}

@test "mysql_parse_version_string: empty → unknown 0 0" {
  result=$(mysql_parse_version_string "")
  [ "$result" = "unknown 0 0" ]
}
```

- [ ] **Step 2: Run to verify failures**

Run: `bats tests/unit/version_parsing.bats`
Expected: 5 new failures.

- [ ] **Step 3: Implement**

Append to `lib/mysql.sh`:

```bash
# Parse a VERSION() string into "flavor major minor".
# MariaDB version strings contain "MariaDB"; everything else is treated as
# MySQL. Patch level is discarded — major.minor is the image tag granularity.
mysql_parse_version_string() {
  local raw="$1"
  [[ -z "$raw" ]] && { echo "unknown 0 0"; return 0; }

  local flavor="mysql"
  [[ "$raw" == *MariaDB* ]] && flavor="mariadb"

  # First numeric component "X.Y" anchored at the start of the string.
  local major minor
  if [[ "$raw" =~ ^([0-9]+)\.([0-9]+) ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
  else
    echo "unknown 0 0"
    return 0
  fi

  echo "$flavor $major $minor"
}
```

- [ ] **Step 4: Run tests**

Run: `bats tests/unit/version_parsing.bats`
Expected: 10 passing.

- [ ] **Step 5: Commit**

```bash
git add tests/unit/version_parsing.bats lib/mysql.sh
git commit -m "feat: parse MySQL/MariaDB VERSION() strings into flavor+major+minor"
```

---

## Task 6: Container image introspection

**Files:**
- Modify: `lib/core.sh` (add `container_image`)
- Test: integration-only (skipped if no docker)

- [ ] **Step 1: Write test in a new integration file**

Create `tests/integration/container_introspection.bats`:

```bash
#!/usr/bin/env bats
load '../helpers/integration'

setup_file() {
  require_docker
  # Use a throwaway container name so we don't disturb postgres-dbx.
  TEST_CONTAINER="dbx_introspect_test_$$"
  docker run -d --name "$TEST_CONTAINER" \
    -e POSTGRES_PASSWORD=devpassword \
    postgres:15-alpine >/dev/null
  for _ in $(seq 1 30); do
    docker exec "$TEST_CONTAINER" pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 1
  done
}

teardown_file() {
  docker rm -f "$TEST_CONTAINER" >/dev/null 2>&1 || true
}

setup() {
  setup_dbx_env
  source_dbx_libs
}

@test "container_image returns the image tag for a running container" {
  result=$(container_image "$TEST_CONTAINER")
  [ "$result" = "postgres:15-alpine" ]
}

@test "container_image returns empty for a nonexistent container" {
  result=$(container_image "this_container_does_not_exist_xyz")
  [ -z "$result" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/integration/container_introspection.bats`
Expected: 2 failures, "command not found: container_image".

- [ ] **Step 3: Implement**

Append to `lib/core.sh`:

```bash
# Return the Docker image string of a container, or empty if it doesn't exist.
container_image() {
  local name="$1"
  docker inspect --format '{{.Config.Image}}' "$name" 2>/dev/null || true
}
```

- [ ] **Step 4: Run tests**

Run: `bats tests/integration/container_introspection.bats`
Expected: 2 passing.

- [ ] **Step 5: Commit**

```bash
git add tests/integration/container_introspection.bats lib/core.sh
git commit -m "feat: container_image helper for inspecting running container images"
```

---

## Task 7: Container emptiness check

**Files:**
- Modify: `tests/integration/container_introspection.bats`
- Modify: `lib/core.sh` (add `pg_container_has_user_dbs`, `mysql_container_has_user_dbs`)

- [ ] **Step 1: Append failing tests**

Append to `tests/integration/container_introspection.bats`:

```bash
@test "pg_container_has_user_dbs: empty container returns 1" {
  # Fresh container with no user DBs created
  run pg_container_has_user_dbs "$TEST_CONTAINER" devpassword
  [ "$status" -ne 0 ]
}

@test "pg_container_has_user_dbs: user DB present returns 0" {
  docker exec -e PGPASSWORD=devpassword "$TEST_CONTAINER" \
    psql -U postgres -c "CREATE DATABASE check_me" >/dev/null
  run pg_container_has_user_dbs "$TEST_CONTAINER" devpassword
  [ "$status" -eq 0 ]
  docker exec -e PGPASSWORD=devpassword "$TEST_CONTAINER" \
    psql -U postgres -c "DROP DATABASE check_me" >/dev/null
}
```

- [ ] **Step 2: Run to verify failures**

Run: `bats tests/integration/container_introspection.bats`
Expected: 2 new failures, prior 2 still passing.

- [ ] **Step 3: Implement**

Append to `lib/core.sh`:

```bash
# Return 0 if the postgres container has at least one non-system database
# (anything other than postgres/template0/template1), 1 otherwise.
pg_container_has_user_dbs() {
  local container="$1"
  local password="${2:-${DBX_PG_PASSWORD:-devpassword}}"
  local count
  count=$(docker exec -e PGPASSWORD="$password" "$container" \
    psql -U postgres -tA -c \
    "SELECT count(*) FROM pg_database WHERE datname NOT IN ('postgres','template0','template1')" \
    2>/dev/null || echo 0)
  [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -gt 0 ]]
}

# Return 0 if the mysql container has at least one non-system database, else 1.
mysql_container_has_user_dbs() {
  local container="$1"
  local password="${2:-${DBX_MYSQL_PASSWORD:-devpassword}}"
  local count
  count=$(docker exec -e MYSQL_PWD="$password" "$container" \
    mysql -u root -N -e \
    "SELECT count(*) FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys')" \
    2>/dev/null || echo 0)
  [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -gt 0 ]]
}
```

- [ ] **Step 4: Run tests**

Run: `bats tests/integration/container_introspection.bats`
Expected: 4 passing.

- [ ] **Step 5: Commit**

```bash
git add tests/integration/container_introspection.bats lib/core.sh
git commit -m "feat: detect whether a DB container holds user databases"
```

---

## Task 8: ensure_container_image — the recreation decision

**Files:**
- Modify: `tests/integration/container_introspection.bats`
- Modify: `lib/core.sh` (add `ensure_container_image`)

This is the operational core of the feature. Given a desired image, decide whether to leave the current container alone, recreate silently (because empty), or fail (because user DBs would be lost).

- [ ] **Step 1: Append failing tests**

```bash
@test "ensure_container_image: matching image is a no-op" {
  run ensure_container_image "$TEST_CONTAINER" "postgres:15-alpine" "false"
  [ "$status" -eq 0 ]
}

@test "ensure_container_image: empty container + mismatch + no flag → recreates" {
  # Container is empty; mismatched image; no --recreate flag → should still rebuild
  run ensure_container_image "$TEST_CONTAINER" "postgres:13-alpine" "false"
  [ "$status" -eq 0 ]
  result=$(container_image "$TEST_CONTAINER")
  [ "$result" = "postgres:13-alpine" ]
}

@test "ensure_container_image: user DBs + mismatch + no flag → fails with DB list" {
  # Recreate as PG 15 first
  docker rm -f "$TEST_CONTAINER" >/dev/null 2>&1
  docker run -d --name "$TEST_CONTAINER" \
    -e POSTGRES_PASSWORD=devpassword \
    postgres:15-alpine >/dev/null
  for _ in $(seq 1 30); do
    docker exec "$TEST_CONTAINER" pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 1
  done
  docker exec -e PGPASSWORD=devpassword "$TEST_CONTAINER" \
    psql -U postgres -c "CREATE DATABASE myapp_v1_test" >/dev/null

  run ensure_container_image "$TEST_CONTAINER" "postgres:13-alpine" "false"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "myapp_v1_test"
  echo "$output" | grep -q -- "--recreate-container"
}

@test "ensure_container_image: user DBs + mismatch + flag set → recreates" {
  # State from previous test: PG 15 with myapp_v1_test inside
  run ensure_container_image "$TEST_CONTAINER" "postgres:13-alpine" "true"
  [ "$status" -eq 0 ]
  result=$(container_image "$TEST_CONTAINER")
  [ "$result" = "postgres:13-alpine" ]
}
```

- [ ] **Step 2: Run to verify failures**

Run: `bats tests/integration/container_introspection.bats`
Expected: 4 new failures.

- [ ] **Step 3: Implement**

Append to `lib/core.sh`:

```bash
# Given a container name and a desired image, ensure the container is running
# the desired image. Possible outcomes:
#   - image matches → no-op, return 0
#   - container doesn't exist → caller should use require_container, return 0
#   - image mismatch + container has no user DBs → recreate silently
#   - image mismatch + has user DBs + recreate=true → recreate
#   - image mismatch + has user DBs + recreate=false → die with DB list
#
# Args:
#   $1: container name (postgres-dbx or mysql-dbx)
#   $2: desired image
#   $3: recreate flag ("true" or "false")
ensure_container_image() {
  local container="$1"
  local desired_image="$2"
  local recreate="$3"

  local current_image
  current_image=$(container_image "$container")

  # Nothing there → let require_container create it later with the right image.
  [[ -z "$current_image" ]] && { export DBX_FORCE_IMAGE="$desired_image"; return 0; }

  # Already on the right image.
  [[ "$current_image" == "$desired_image" ]] && return 0

  # Mismatch. Check for user DBs.
  local has_dbs="false"
  case "$container" in
    *postgres*)
      pg_container_has_user_dbs "$container" && has_dbs="true"
      ;;
    *mysql*)
      mysql_container_has_user_dbs "$container" && has_dbs="true"
      ;;
  esac

  if [[ "$has_dbs" == "false" ]]; then
    log_info "Recreating $container: $current_image → $desired_image (no user DBs present)"
    _recreate_container "$container" "$desired_image"
    return $?
  fi

  if [[ "$recreate" == "true" ]]; then
    log_warn "Recreating $container: $current_image → $desired_image (user DBs will be destroyed)"
    _recreate_container "$container" "$desired_image"
    return $?
  fi

  # User DBs + no flag: fail with the DB list.
  log_error "$container is running $current_image but this restore needs $desired_image."
  log_error "The container has user databases that would be destroyed:"
  _list_user_dbs "$container" | sed 's/^/  - /' >&2
  log_error ""
  log_error "Recreate the container (destroys these DBs):"
  log_error "  dbx restore <source> --recreate-container"
  log_error ""
  log_error "Or save them first with: dbx backup <local-host> <db> for each."
  return 1
}

# Stop, remove, and recreate a managed container with a new image.
# Reuses the same require_container logic so port + flags stay consistent —
# we set DBX_FORCE_IMAGE before calling so require_container picks it up.
_recreate_container() {
  local container="$1"
  local image="$2"
  docker rm -f "$container" >/dev/null 2>&1 || true
  export DBX_FORCE_IMAGE="$image"
  require_container "$container"
}

# List user (non-system) databases on a managed container.
_list_user_dbs() {
  local container="$1"
  case "$container" in
    *postgres*)
      docker exec -e PGPASSWORD="${DBX_PG_PASSWORD:-devpassword}" "$container" \
        psql -U postgres -tA -c \
        "SELECT datname FROM pg_database WHERE datname NOT IN ('postgres','template0','template1') ORDER BY datname" \
        2>/dev/null
      ;;
    *mysql*)
      docker exec -e MYSQL_PWD="${DBX_MYSQL_PASSWORD:-devpassword}" "$container" \
        mysql -u root -N -e \
        "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys') ORDER BY schema_name" \
        2>/dev/null
      ;;
  esac
}
```

Then modify `require_container` in `lib/core.sh` to honor `DBX_FORCE_IMAGE` when creating a new container. Find the `case "$container" in` block in `require_container` and replace the hard-coded image references with `"${DBX_FORCE_IMAGE:-postgres:17-alpine}"` and `"${DBX_FORCE_IMAGE:-mysql:8.0}"` respectively. Clear `DBX_FORCE_IMAGE` after creation:

```bash
# Inside require_container, after the docker run:
unset DBX_FORCE_IMAGE
```

- [ ] **Step 4: Run tests**

Run: `bats tests/integration/container_introspection.bats`
Expected: 8 passing total.

- [ ] **Step 5: Commit**

```bash
git add tests/integration/container_introspection.bats lib/core.sh
git commit -m "feat: ensure_container_image with empty-auto-recreate + opt-in destructive recreate"
```

---

## Task 9: pg_detect_server_version + pg_detect_extensions

**Files:**
- Modify: `lib/postgres.sh` (add detection helpers)
- Modify: `tests/integration/container_introspection.bats` (add coverage)

These run over an existing connection — psql via the dbx-managed container. Tested through integration only since they require a live server.

- [ ] **Step 1: Append failing tests**

```bash
@test "pg_detect_server_version: against PG 15 source" {
  # TEST_CONTAINER is currently postgres:13-alpine from task 8. Reset to 15.
  docker rm -f "$TEST_CONTAINER" >/dev/null 2>&1
  docker run -d --name "$TEST_CONTAINER" \
    -p 127.0.0.1:5499:5432 \
    -e POSTGRES_PASSWORD=devpassword \
    postgres:15-alpine >/dev/null
  for _ in $(seq 1 30); do
    docker exec "$TEST_CONTAINER" pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 1
  done

  result=$(pg_detect_server_version 127.0.0.1 5499 postgres devpassword)
  [ "$result" = "15" ]
}

@test "pg_detect_extensions: empty database returns empty" {
  docker exec -e PGPASSWORD=devpassword "$TEST_CONTAINER" \
    psql -U postgres -c "CREATE DATABASE detect_ext_test" >/dev/null

  result=$(pg_detect_extensions 127.0.0.1 5499 postgres devpassword detect_ext_test)
  # plpgsql is always present but we filter it out
  [ -z "$result" ]
}
```

- [ ] **Step 2: Run to verify failures**

Run: `bats tests/integration/container_introspection.bats`
Expected: 2 new failures.

- [ ] **Step 3: Implement**

Append to `lib/postgres.sh`:

```bash
# Detect the major version of a remote Postgres server. Returns "unknown" on
# any failure (connection, permissions, parse error) — callers fall back to
# the default image.
# Args: $1=host $2=port $3=user $4=password [$5=database, default "postgres"]
pg_detect_server_version() {
  local host="$1" port="$2" user="$3" password="$4" db="${5:-postgres}"
  local raw
  raw=$(PGPASSWORD="$password" docker exec -i -e PGPASSWORD="$password" \
    "${POSTGRES_CONTAINER:-postgres-dbx}" \
    psql -h "$host" -p "$port" -U "$user" -d "$db" -tA -c \
    "SELECT current_setting('server_version_num')" 2>/dev/null \
    | tr -d '[:space:]')
  pg_parse_server_version_num "$raw"
}

# Detect extensions installed in a specific database. Returns a space-separated
# list with plpgsql filtered out. Empty string when none or on failure.
# Args: $1=host $2=port $3=user $4=password $5=database
pg_detect_extensions() {
  local host="$1" port="$2" user="$3" password="$4" db="$5"
  docker exec -i -e PGPASSWORD="$password" \
    "${POSTGRES_CONTAINER:-postgres-dbx}" \
    psql -h "$host" -p "$port" -U "$user" -d "$db" -tA -c \
    "SELECT extname FROM pg_extension WHERE extname != 'plpgsql' ORDER BY extname" \
    2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}
```

- [ ] **Step 4: Run tests**

Run: `bats tests/integration/container_introspection.bats`
Expected: 10 passing.

- [ ] **Step 5: Commit**

```bash
git add tests/integration/container_introspection.bats lib/postgres.sh
git commit -m "feat: detect Postgres server version and per-database extensions"
```

---

## Task 10: mysql_detect_server_version

**Files:**
- Modify: `lib/mysql.sh` (add detection helper)
- Modify: `tests/integration/container_introspection.bats` (add coverage)

- [ ] **Step 1: Append failing tests**

```bash
@test "mysql_detect_server_version: detects mysql flavor + version" {
  # Spin up a temporary mysql 8.0 container alongside the postgres one
  MYSQL_TEST_CONTAINER="dbx_mysql_introspect_test_$$"
  docker run -d --name "$MYSQL_TEST_CONTAINER" \
    -p 127.0.0.1:5498:3306 \
    -e MYSQL_ROOT_PASSWORD=devpassword \
    mysql:8.0 >/dev/null
  for _ in $(seq 1 60); do
    docker exec -e MYSQL_PWD=devpassword "$MYSQL_TEST_CONTAINER" \
      mysql -u root -e 'SELECT 1' >/dev/null 2>&1 && break
    sleep 1
  done

  result=$(mysql_detect_server_version 127.0.0.1 5498 root devpassword)
  [ "$result" = "mysql 8 0" ]

  docker rm -f "$MYSQL_TEST_CONTAINER" >/dev/null 2>&1
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/integration/container_introspection.bats`
Expected: 1 new failure.

- [ ] **Step 3: Implement**

Append to `lib/mysql.sh`:

```bash
# Detect flavor + major + minor of a remote MySQL or MariaDB server.
# Returns "flavor major minor" or "unknown 0 0" on any failure.
# Uses the dbx-managed mysql container as the client to avoid needing a
# local mysql binary.
# Args: $1=host $2=port $3=user $4=password
mysql_detect_server_version() {
  local host="$1" port="$2" user="$3" password="$4"
  local raw
  raw=$(docker exec -i -e MYSQL_PWD="$password" \
    "${MYSQL_CONTAINER:-mysql-dbx}" \
    mysql -h "$host" -P "$port" -u "$user" -N -e 'SELECT VERSION()' \
    2>/dev/null | tr -d '\r')
  mysql_parse_version_string "$raw"
}
```

- [ ] **Step 4: Run tests**

Run: `bats tests/integration/container_introspection.bats`
Expected: 11 passing.

- [ ] **Step 5: Commit**

```bash
git add tests/integration/container_introspection.bats lib/mysql.sh
git commit -m "feat: detect MySQL/MariaDB flavor and version over the wire"
```

---

## Task 11: Enrich backup metadata with version + extensions

**Files:**
- Modify: `lib/postgres.sh` (`pg_backup` writes new meta fields)
- Modify: `lib/mysql.sh` (`mysql_backup` writes new meta fields)
- Modify: `tests/integration/postgres_roundtrip.bats` (assert new fields)

- [ ] **Step 1: Append failing test**

In `tests/integration/postgres_roundtrip.bats`:

```bash
@test "postgres: backup meta contains source_version and source_extensions" {
  seed_postgres_db "$TEST_DB"
  dbx_run backup local-pg "$TEST_DB"
  [ "$status" -eq 0 ]

  local meta
  meta=$(ls "$DBX_DATA_DIR/local-pg/$TEST_DB"/*.sql.zst.meta.json | head -1)

  # source_flavor must be "postgres"
  [ "$(jq -r .source_flavor "$meta")" = "postgres" ]
  # source_major_version should match the postgres-dbx version (17 default)
  [ -n "$(jq -r .source_major_version "$meta")" ]
  [ "$(jq -r .source_major_version "$meta")" != "null" ]
  # source_extensions must be an array (possibly empty)
  [ "$(jq -r '.source_extensions | type' "$meta")" = "array" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/integration/postgres_roundtrip.bats`
Expected: 1 new failure (the new test).

- [ ] **Step 3: Modify the meta-write block in `lib/postgres.sh`**

Find the `jq -n` invocation in `pg_backup` (around line 131) and extend it. Locate the line with `local meta_file="${output_file}.meta.json"` and add detection before it:

```bash
  # Detect source server version + extensions for restore-time image picking.
  local src_major src_exts_raw
  src_major=$(pg_detect_server_version "$host_addr" "$port" "$user" "$password" "$database")
  src_exts_raw=$(pg_detect_extensions "$host_addr" "$port" "$user" "$password" "$database")
  # Build a JSON array from the space-separated list.
  local src_exts_json="[]"
  if [[ -n "$src_exts_raw" ]]; then
    src_exts_json=$(printf '%s\n' "$src_exts_raw" | tr ' ' '\n' \
      | jq -R . | jq -s 'map(select(length > 0))')
  fi
```

(`$host_addr`, `$port`, `$user`, `$password` need to be in scope — they are in `pg_backup`. If their names differ, use the right local names; check by reading `pg_backup` first.)

Then replace the `jq -n` invocation with:

```bash
  jq -n \
    --arg host "$host" \
    --arg database "$database" \
    --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg size "$file_size" \
    --arg checksum "$checksum" \
    --arg encryption "$enc_type" \
    --arg dbx_version "${VERSION:-unknown}" \
    --arg src_flavor "postgres" \
    --arg src_major "$src_major" \
    --argjson src_exts "$src_exts_json" \
    '{
      host: $host,
      database: $database,
      timestamp: $timestamp,
      size: ($size | tonumber),
      checksums: { sha256: $checksum },
      encryption: $encryption,
      dbx_version: $dbx_version,
      source_flavor: $src_flavor,
      source_major_version: $src_major,
      source_extensions: $src_exts
    }' > "$meta_file"
```

Mirror the same change in `mysql_backup` (`lib/mysql.sh`):

```bash
  # Detect source flavor + version for image picking at backup AND restore.
  local mysql_ver flavor src_major src_minor
  mysql_ver=$(mysql_detect_server_version "$host_addr" "$port" "$user" "$password")
  read -r flavor src_major src_minor <<<"$mysql_ver"
```

Then in the `jq -n` block add `--arg src_flavor "$flavor"`, `--arg src_major "$src_major"`, `--arg src_minor "$src_minor"`, and write them into the meta object as `source_flavor`, `source_major_version`, `source_minor_version`. MySQL has no extension concept; set `source_extensions: []` for shape parity.

- [ ] **Step 4: Run tests**

Run: `bats tests/integration/postgres_roundtrip.bats`
Expected: all passing.

- [ ] **Step 5: Commit**

```bash
git add lib/postgres.sh lib/mysql.sh tests/integration/postgres_roundtrip.bats
git commit -m "feat: write source version, flavor, and extensions into backup metadata"
```

---

## Task 12: Use detected version to pick the MySQL dumper image at backup time

**Files:**
- Modify: `lib/mysql.sh` (`mysql_backup` calls `ensure_container_image` before dumping)
- Modify: `tests/helpers/integration.bash` (add `ensure_mariadb_source`)
- Modify: `tests/integration/mysql_roundtrip.bats`

- [ ] **Step 1: Add helper**

Append to `tests/helpers/integration.bash`:

```bash
# Spin up a MariaDB source on port 33099 for testing flavor detection.
# The dbx-managed `mysql-dbx` stays on port 3306; this is a separate source.
ensure_mariadb_source() {
  if ! docker ps --format '{{.Names}}' | grep -q '^dbx-mariadb-source$'; then
    docker rm -f dbx-mariadb-source >/dev/null 2>&1
    docker run -d --name dbx-mariadb-source \
      -e MARIADB_ROOT_PASSWORD=devpassword \
      -p 127.0.0.1:33099:3306 \
      mariadb:10.11 >/dev/null
    for _ in $(seq 1 60); do
      if docker exec -e MYSQL_PWD=devpassword dbx-mariadb-source \
           mariadb -u root -e 'SELECT 1' >/dev/null 2>&1; then
        return 0
      fi
      sleep 1
    done
    echo "dbx-mariadb-source failed to become ready" >&2
    return 1
  fi
}
```

- [ ] **Step 2: Write failing test**

In `tests/integration/mysql_roundtrip.bats`:

```bash
@test "mysql: mariadb source → backup uses mariadb image and writes mariadb flavor" {
  ensure_mariadb_source

  # Override the config to point at the mariadb source
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-mariadb": {
      "type": "mysql",
      "host": "127.0.0.1",
      "port": 33099,
      "user": "root",
      "password_cmd": "echo devpassword"
    }
  },
  "defaults": { "compression_level": 1, "keep_backups": 10 }
}
EOF

  # Seed a DB
  docker exec -e MYSQL_PWD=devpassword dbx-mariadb-source \
    mariadb -u root -e "CREATE DATABASE mariatest; CREATE TABLE mariatest.t (id int); INSERT INTO mariatest.t VALUES (1),(2);" >/dev/null

  dbx_run backup local-mariadb mariatest
  [ "$status" -eq 0 ]

  local meta
  meta=$(ls "$DBX_DATA_DIR/local-mariadb/mariatest"/*.sql.zst.meta.json | head -1)
  [ "$(jq -r .source_flavor "$meta")" = "mariadb" ]
  [ "$(jq -r .source_major_version "$meta")" = "10" ]

  # The mysql container should now be running mariadb, not mysql:8.0
  result=$(container_image mysql-dbx 2>/dev/null)
  [[ "$result" =~ ^mariadb: ]]
}
```

- [ ] **Step 3: Run to verify failure**

Run: `bats tests/integration/mysql_roundtrip.bats`
Expected: 1 new failure.

- [ ] **Step 4: Implement**

In `lib/mysql.sh`, modify `mysql_backup`. After detecting the version (added in Task 11) and before invoking mysqldump, call `ensure_container_image`:

```bash
  # Match the dumper container to the source flavor/version. mysqldump grammar
  # drifts across major versions, and Oracle mysqldump doesn't speak MariaDB.
  local override
  override="${DBX_MYSQL_IMAGE:-$(get_config_value '.defaults.mysql_image' 2>/dev/null || echo '')}"
  local desired_image
  desired_image=$(pick_mysql_image "$flavor" "$src_major" "$src_minor" "$override")
  # Backup direction: this is the dumper container; we always recreate if
  # mismatched because nothing valuable lives in mysql-dbx during a backup.
  ensure_container_image "$MYSQL_CONTAINER" "$desired_image" "true" || return 1
  # Ensure container is up with the (possibly new) image.
  require_container "$MYSQL_CONTAINER"
```

- [ ] **Step 5: Run tests**

Run: `bats tests/integration/mysql_roundtrip.bats`
Expected: all passing.

- [ ] **Step 6: Commit**

```bash
git add lib/mysql.sh tests/helpers/integration.bash tests/integration/mysql_roundtrip.bats
git commit -m "feat: match the MySQL dumper image to source flavor and version"
```

---

## Task 13: Use detected version + extensions to pick the Postgres restore image

**Files:**
- Modify: `lib/postgres.sh` (`pg_restore_backup` reads meta, picks image, ensures container)
- Modify: `dbx` (`cmd_restore` plumbs `--recreate-container` to `pg_restore_backup`)
- Modify: `tests/helpers/integration.bash` (add `ensure_pg13_source`)
- Modify: `tests/integration/version_aware.bats` (new file)

- [ ] **Step 1: Add helper**

Append to `tests/helpers/integration.bash`:

```bash
ensure_pg13_source() {
  if ! docker ps --format '{{.Names}}' | grep -q '^dbx-pg13-source$'; then
    docker rm -f dbx-pg13-source >/dev/null 2>&1
    docker run -d --name dbx-pg13-source \
      -e POSTGRES_PASSWORD=devpassword \
      -p 127.0.0.1:54399:5432 \
      postgres:13-alpine >/dev/null
    for _ in $(seq 1 30); do
      docker exec dbx-pg13-source pg_isready -U postgres >/dev/null 2>&1 && return 0
      sleep 1
    done
    echo "dbx-pg13-source failed to become ready" >&2
    return 1
  fi
}
```

- [ ] **Step 2: Write failing test**

Create `tests/integration/version_aware.bats`:

```bash
#!/usr/bin/env bats
load '../helpers/integration'

setup_file() {
  require_docker
  ensure_postgres_container
  ensure_pg13_source
}

setup() {
  setup_dbx_env
  # Point dbx at the PG 13 source
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "pg13": {
      "type": "postgres",
      "host": "127.0.0.1",
      "port": 54399,
      "user": "postgres",
      "password_cmd": "echo devpassword"
    }
  },
  "defaults": { "compression_level": 1, "keep_backups": 10 }
}
EOF
  TEST_DB="dbx_va_test_$$_${BATS_TEST_NUMBER}"
  RESTORE_DB="${TEST_DB}_restored"
}

teardown() {
  docker exec -e PGPASSWORD=devpassword dbx-pg13-source \
    psql -U postgres -c "DROP DATABASE IF EXISTS \"$TEST_DB\"" >/dev/null 2>&1 || true
  pg_drop_db "$RESTORE_DB"
}

@test "restoring a PG 13 backup recreates postgres-dbx as postgres:13-alpine" {
  # Seed PG 13 source
  docker exec -e PGPASSWORD=devpassword dbx-pg13-source \
    psql -U postgres -c "CREATE DATABASE \"$TEST_DB\"" >/dev/null
  docker exec -e PGPASSWORD=devpassword dbx-pg13-source \
    psql -U postgres -d "$TEST_DB" -c "CREATE TABLE t(id int); INSERT INTO t VALUES (1),(2),(3);" >/dev/null

  dbx_run backup pg13 "$TEST_DB"
  [ "$status" -eq 0 ]

  # postgres-dbx is currently postgres:17-alpine and has user DBs from other
  # tests — restore should fail without --recreate-container.
  if pg_container_has_user_dbs postgres-dbx; then
    dbx_run restore "pg13/$TEST_DB/latest" --name "$RESTORE_DB"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q -- "--recreate-container"
  fi

  dbx_run restore "pg13/$TEST_DB/latest" --name "$RESTORE_DB" --recreate-container
  [ "$status" -eq 0 ]

  result=$(container_image postgres-dbx)
  [ "$result" = "postgres:13-alpine" ]
}
```

- [ ] **Step 3: Run to verify failure**

Run: `bats tests/integration/version_aware.bats`
Expected: failure ("unknown flag --recreate-container" or similar).

- [ ] **Step 4: Implement — `cmd_restore` flag plumbing**

In `dbx`, find the `cmd_restore` arg-parse loop (line ~187) and add:

```bash
      --recreate-container)
        export DBX_RECREATE_CONTAINER=true
        shift
        ;;
```

- [ ] **Step 5: Implement — restore picks image based on meta**

In `lib/postgres.sh`, modify `pg_restore_backup`. After the function reads the meta file (the existing code that parses backup metadata to determine source DB, etc.) and BEFORE invoking pg_restore against postgres-dbx, add:

```bash
  # Determine the right container image based on backup metadata.
  local src_major src_exts override desired_image
  local meta_file="${backup_file%.zst}.meta.json"
  [[ ! -f "$meta_file" ]] && meta_file="${backup_file}.meta.json"

  if [[ -f "$meta_file" ]]; then
    src_major=$(jq -r '.source_major_version // "unknown"' "$meta_file")
    src_exts=$(jq -r '.source_extensions // [] | join(" ")' "$meta_file")
  else
    src_major="unknown"
    src_exts=""
  fi

  override="${DBX_POSTGRES_IMAGE:-$(get_config_value '.defaults.postgres_image' 2>/dev/null || echo '')}"
  if ! desired_image=$(pick_postgres_image "$src_major" "$src_exts" "$override"); then
    return 1
  fi

  # If the running container doesn't match, gate on user DBs unless flag set.
  local recreate="${DBX_RECREATE_CONTAINER:-false}"
  ensure_container_image "$POSTGRES_CONTAINER" "$desired_image" "$recreate" || return 1
  require_container "$POSTGRES_CONTAINER"
```

- [ ] **Step 6: Run tests**

Run: `bats tests/integration/version_aware.bats`
Expected: passing.

- [ ] **Step 7: Commit**

```bash
git add dbx lib/postgres.sh tests/helpers/integration.bash tests/integration/version_aware.bats
git commit -m "feat: restore picks PG image from meta and honors --recreate-container"
```

---

## Task 14: Extension-aware restore (pgvector path)

**Files:**
- Modify: `tests/integration/version_aware.bats`

The existing `pick_postgres_image` already returns `pgvector/pgvector:pg<major>` for `vector`. The Task 13 restore logic already calls it. This task verifies the end-to-end path with a real extension.

- [ ] **Step 1: Add helper**

In `tests/helpers/integration.bash`:

```bash
ensure_pgvector_source() {
  if ! docker ps --format '{{.Names}}' | grep -q '^dbx-pgvector-source$'; then
    docker rm -f dbx-pgvector-source >/dev/null 2>&1
    docker run -d --name dbx-pgvector-source \
      -e POSTGRES_PASSWORD=devpassword \
      -p 127.0.0.1:54398:5432 \
      pgvector/pgvector:pg16 >/dev/null
    for _ in $(seq 1 30); do
      docker exec dbx-pgvector-source pg_isready -U postgres >/dev/null 2>&1 && return 0
      sleep 1
    done
    return 1
  fi
}
```

- [ ] **Step 2: Append failing test**

In `tests/integration/version_aware.bats`:

```bash
@test "restoring a backup with pgvector extension uses pgvector image" {
  ensure_pgvector_source

  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "pgvec": {
      "type": "postgres",
      "host": "127.0.0.1",
      "port": 54398,
      "user": "postgres",
      "password_cmd": "echo devpassword"
    }
  },
  "defaults": { "compression_level": 1, "keep_backups": 10 }
}
EOF

  local vec_db="vec_test_$$"
  docker exec -e PGPASSWORD=devpassword dbx-pgvector-source \
    psql -U postgres -c "CREATE DATABASE \"$vec_db\"" >/dev/null
  docker exec -e PGPASSWORD=devpassword dbx-pgvector-source \
    psql -U postgres -d "$vec_db" -c "CREATE EXTENSION vector;" >/dev/null

  dbx_run backup pgvec "$vec_db"
  [ "$status" -eq 0 ]

  local meta
  meta=$(ls "$DBX_DATA_DIR/pgvec/$vec_db"/*.sql.zst.meta.json | head -1)
  [ "$(jq -r '.source_extensions | join(",")' "$meta")" = "vector" ]

  dbx_run restore "pgvec/$vec_db/latest" --name "${vec_db}_r" --recreate-container
  [ "$status" -eq 0 ]

  result=$(container_image postgres-dbx)
  [ "$result" = "pgvector/pgvector:pg16" ]

  pg_drop_db "${vec_db}_r"
  docker exec -e PGPASSWORD=devpassword dbx-pgvector-source \
    psql -U postgres -c "DROP DATABASE IF EXISTS \"$vec_db\"" >/dev/null 2>&1 || true
}
```

- [ ] **Step 3: Run to verify failure or success**

Run: `bats tests/integration/version_aware.bats`
Expected: passing (logic from Task 13 should handle this; if not, debug `pg_detect_extensions` round-trip).

- [ ] **Step 4: Commit**

```bash
git add tests/helpers/integration.bash tests/integration/version_aware.bats
git commit -m "test: end-to-end pgvector extension detection and image switch"
```

---

## Task 15: Unknown-extension failure mode

**Files:**
- Modify: `tests/integration/version_aware.bats`

- [ ] **Step 1: Append failing test**

```bash
@test "unknown extension during restore fails with override hint" {
  # Fake a meta with an unsupported extension by editing meta directly.
  # First, take a normal backup.
  seed_postgres_db "$TEST_DB"

  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-pg": {
      "type": "postgres",
      "host": "127.0.0.1",
      "port": 5432,
      "user": "postgres",
      "password_cmd": "echo devpassword"
    }
  },
  "defaults": { "compression_level": 1, "keep_backups": 10 }
}
EOF
  dbx_run backup local-pg "$TEST_DB"
  [ "$status" -eq 0 ]

  # Inject an unsupported extension into the meta
  local meta
  meta=$(ls "$DBX_DATA_DIR/local-pg/$TEST_DB"/*.sql.zst.meta.json | head -1)
  jq '.source_extensions = ["pg_partman"]' "$meta" > "$meta.tmp" && mv "$meta.tmp" "$meta"

  dbx_run restore "local-pg/$TEST_DB/latest" --name "$RESTORE_DB"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "pg_partman"
  echo "$output" | grep -q "DBX_POSTGRES_IMAGE"

  pg_drop_db "$TEST_DB"
}
```

- [ ] **Step 2: Run**

Run: `bats tests/integration/version_aware.bats`
Expected: passing (no implementation change needed — Task 2 handles this).

- [ ] **Step 3: Commit**

```bash
git add tests/integration/version_aware.bats
git commit -m "test: unknown extension at restore time fails with override hint"
```

---

## Task 16: Backwards compat — backups without source fields still restore

**Files:**
- Modify: `tests/integration/version_aware.bats`

- [ ] **Step 1: Append failing test**

```bash
@test "backups missing source fields restore using default image" {
  seed_postgres_db "$TEST_DB"

  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-pg": {
      "type": "postgres",
      "host": "127.0.0.1",
      "port": 5432,
      "user": "postgres",
      "password_cmd": "echo devpassword"
    }
  },
  "defaults": { "compression_level": 1, "keep_backups": 10 }
}
EOF
  dbx_run backup local-pg "$TEST_DB"
  [ "$status" -eq 0 ]

  # Strip the new fields from meta to simulate a pre-feature backup
  local meta
  meta=$(ls "$DBX_DATA_DIR/local-pg/$TEST_DB"/*.sql.zst.meta.json | head -1)
  jq 'del(.source_flavor, .source_major_version, .source_extensions)' "$meta" \
    > "$meta.tmp" && mv "$meta.tmp" "$meta"

  dbx_run restore "local-pg/$TEST_DB/latest" --name "$RESTORE_DB" --recreate-container
  [ "$status" -eq 0 ]
  # Should use the default image (postgres:17-alpine)
  result=$(container_image postgres-dbx)
  [ "$result" = "postgres:17-alpine" ]
}
```

- [ ] **Step 2: Run**

Run: `bats tests/integration/version_aware.bats`
Expected: passing (Task 13's `// "unknown"` fallbacks should handle this).

- [ ] **Step 3: Commit**

```bash
git add tests/integration/version_aware.bats
git commit -m "test: legacy backups without source metadata restore using default image"
```

---

## Task 17: Documentation

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: README — add to Environment Variables table**

Insert rows in the `## Environment Variables` table (around line 347–362):

```markdown
| `DBX_POSTGRES_IMAGE` | unset | Docker image for the auto-managed PG container. Supports `{major}` template. |
| `DBX_MYSQL_IMAGE` | unset | Docker image for the auto-managed MySQL container. Supports `{version}` template. |
| `DBX_RECREATE_CONTAINER` | unset | Set to `true` (or pass `--recreate-container`) to allow destroying user DBs when the container's version doesn't match the backup. |
```

- [ ] **Step 2: README — add restore commands documentation**

In the `## Commands` table, change the restore row:

```markdown
| `dbx restore <source> [--name N] [--recreate-container]` | Restore to a local container; recreate the container if its version differs |
```

- [ ] **Step 3: README — add a section on image selection**

Add after the "How Restore Works" section:

```markdown
## Image Selection

dbx auto-picks a Docker image for the restore container based on the source database's version and extensions, recorded in `.meta.json` at backup time:

- **Postgres, no extensions** → `postgres:<major>-alpine`
- **Postgres + `vector`** → `pgvector/pgvector:pg<major>`
- **Postgres + `postgis`** → `postgis/postgis:<major>-3.5`
- **Postgres + `timescaledb`** → `timescale/timescaledb:latest-pg<major>`
- **MySQL** → `mysql:<major>.<minor>`
- **MariaDB** → `mariadb:<major>.<minor>`

For anything outside the known list, set `DBX_POSTGRES_IMAGE` / `DBX_MYSQL_IMAGE` (or the `defaults.postgres_image` / `defaults.mysql_image` config key). The template supports `{major}` and `{version}` substitution:

\```bash
export DBX_POSTGRES_IMAGE='myregistry/pg-everything:{major}'
\```

If the existing restore container's image doesn't match what's needed, dbx will:
- Silently recreate when the container has no user databases.
- Fail with a list of restored DBs and instructions to pass `--recreate-container` when there are user DBs to preserve.
```

- [ ] **Step 4: AGENTS.md — Lessons section entry**

Append to the "Lessons / patterns to follow" list:

```markdown
- **Postgres `server_version_num` is `MMMmmmm` for PG 10+** (130000 = 13, 160003 = 16), not `MMmmm` like older versions. Parsing via `(raw / 10000)` gives the major. For pre-10 you'd need different logic, but dbx only targets supported versions.
- **MariaDB's `VERSION()` output contains the literal string "MariaDB"** (e.g. `10.11.6-MariaDB-1:10.11.6+maria~ubu2204`). Test for that substring; don't trust the first numeric component to indicate flavor.
- **`docker exec -i` runs against the dbx-managed container as a remote psql client** for version/extension detection. This avoids needing a local psql binary on the user's host and is the same pattern used elsewhere in the codebase.
```

- [ ] **Step 5: CHANGELOG entry**

Add to the top of `CHANGELOG.md` under `## Unreleased`:

```markdown
### Added
- Version-aware image selection: restore containers now match the source database's major version. Postgres extensions (`vector`, `postgis`, `timescaledb`) auto-select the right specialized image.
- `--recreate-container` flag on `dbx restore` for explicit consent to destroy user DBs when switching versions.
- `DBX_POSTGRES_IMAGE` / `DBX_MYSQL_IMAGE` env vars and matching config keys for override.
- New metadata fields in `.meta.json`: `source_flavor`, `source_major_version`, `source_extensions` (and `source_minor_version` for MySQL).

### Changed
- MariaDB sources now use the `mariadb:X.Y` image for backups, replacing the Oracle `mysql:8.0` image that previously caused subtle definer/encoding drift.
```

- [ ] **Step 6: Verify docs render**

Skim README and CHANGELOG for broken markdown. Run any markdown linter if installed.

- [ ] **Step 7: Commit**

```bash
git add README.md AGENTS.md CHANGELOG.md
git commit -m "docs: document version-aware image selection and recreate-container flag"
```

---

## Task 18: Full test pass + CI smoke

- [ ] **Step 1: Run the full smoke check from AGENTS.md**

Run: `bash -n dbx && for f in lib/*.sh; do bash -n "$f"; done`
Expected: no output, exit 0.

Run: `shellcheck -S error dbx lib/*.sh`
Expected: no errors.

Run: `bats tests/unit/`
Expected: all passing (including the new `image_selection.bats` and `version_parsing.bats`).

Run: `bats tests/integration/`
Expected: all passing (including `container_introspection.bats` and `version_aware.bats`).

- [ ] **Step 2: Clean up test containers**

```bash
docker rm -f dbx-pg13-source dbx-pgvector-source dbx-mariadb-source 2>/dev/null || true
```

- [ ] **Step 3: Final commit (if any test fixes were needed)**

If iterations were needed for cross-task interaction, commit:

```bash
git add -A
git commit -m "test: fix cross-task interactions revealed by full sweep"
```

If no fixes needed, skip this step.

- [ ] **Step 4: Link back to the issue**

Push the branch and reference `#28` in the PR description so the issue auto-closes on merge.

---

## Self-Review Notes

**Spec coverage check (against issue #28):**
- Version detection (PG + MySQL/MariaDB): Tasks 4, 5, 9, 10 ✓
- Image selection w/ extension allowlist: Tasks 1, 2, 3 ✓
- Asymmetric backup direction (PG latest, MySQL match): Task 12 ✓ (PG backup unchanged; MySQL backup matches)
- Container lifecycle + `--recreate-container` flag: Tasks 8, 13 ✓
- Extension detection: Task 9 ✓
- Metadata changes: Task 11 ✓
- Failure modes (unknown extension, mismatch + DBs, etc.): Tasks 2, 8, 15 ✓
- Backwards compat (old backups without fields): Task 16 ✓
- Override env vars + config keys: Tasks 2, 3, 13 ✓
- Documentation: Task 17 ✓

**Open question from the issue (`{major}` vs `{version}` template substitution):** resolved in Tasks 2/3 — Postgres supports `{major}` and `{version}` (aliases). MySQL supports `{major}`, `{minor}`, `{version}` (where version is `major.minor`).

**Per-host `hosts.<name>.image` override:** noted in the spec, not yet wired. Add as a follow-up if it's needed; the env-var + defaults paths cover the common case and adding per-host is a small follow-up task.
