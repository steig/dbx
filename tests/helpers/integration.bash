#!/usr/bin/env bash
# Helpers for integration tests that exercise the real `dbx` CLI against
# real Docker containers. Containers are shared across tests in a file.

# Load the common helpers. `load` is relative to the test file, not this
# helper, so use an absolute path resolved from BATS_TEST_DIRNAME.
# shellcheck source=common.bash
source "${BATS_TEST_DIRNAME}/../helpers/common.bash"

# Skip the entire test if Docker isn't usable.
require_docker() {
  command -v docker >/dev/null 2>&1 || skip "docker not installed"
  docker info >/dev/null 2>&1 || skip "docker daemon not reachable"
}

# Run dbx with the test env and capture status + output. Sets `status`,
# `output`, `lines` like bats's `run`.
dbx_run() {
  run "$DBX_BIN" "$@"
}

# Boot postgres-dbx if it isn't running. Idempotent.
ensure_postgres_container() {
  if ! docker ps --format '{{.Names}}' | grep -q '^postgres-dbx$'; then
    if docker ps -a --format '{{.Names}}' | grep -q '^postgres-dbx$'; then
      docker start postgres-dbx >/dev/null
    else
      docker run -d --name postgres-dbx \
        --add-host=host.docker.internal:host-gateway \
        -e POSTGRES_PASSWORD=devpassword \
        -e POSTGRES_INITDB_ARGS="--encoding=UTF8 --locale=C.UTF-8" \
        -e LANG=C.UTF-8 \
        -p 127.0.0.1:5432:5432 \
        postgres:17-alpine >/dev/null
    fi
    # Wait for ready
    for _ in $(seq 1 30); do
      docker exec postgres-dbx pg_isready -U postgres >/dev/null 2>&1 && return 0
      sleep 1
    done
    echo "postgres-dbx failed to become ready" >&2
    return 1
  fi
}

# Boot mysql-dbx if it isn't running. Idempotent.
ensure_mysql_container() {
  if ! docker ps --format '{{.Names}}' | grep -q '^mysql-dbx$'; then
    if docker ps -a --format '{{.Names}}' | grep -q '^mysql-dbx$'; then
      docker start mysql-dbx >/dev/null
    else
      docker run -d --name mysql-dbx \
        --add-host=host.docker.internal:host-gateway \
        -e MYSQL_ROOT_PASSWORD=devpassword \
        -p 127.0.0.1:3306:3306 \
        mysql:8.0 >/dev/null
    fi
    # `mysqladmin ping` returns success before the root password is set,
    # so additionally verify a real authenticated query works.
    for _ in $(seq 1 60); do
      if docker exec -e MYSQL_PWD=devpassword mysql-dbx \
           mysql -u root -e 'SELECT 1' >/dev/null 2>&1; then
        return 0
      fi
      sleep 1
    done
    echo "mysql-dbx failed to become ready" >&2
    return 1
  fi
}

# Boot a minio-dbx container if it isn't running. Idempotent.
# Exposes :9100 (S3 API) on 127.0.0.1. Root creds: minioadmin / minioadmin.
ensure_minio_container() {
  if ! docker ps --format '{{.Names}}' | grep -q '^minio-dbx$'; then
    if docker ps -a --format '{{.Names}}' | grep -q '^minio-dbx$'; then
      docker start minio-dbx >/dev/null
    else
      docker run -d --name minio-dbx \
        -p 127.0.0.1:9100:9000 \
        -e MINIO_ROOT_USER=minioadmin \
        -e MINIO_ROOT_PASSWORD=minioadmin \
        minio/minio:latest server /data >/dev/null
    fi
    # Wait for ready
    for _ in $(seq 1 30); do
      curl -fsS http://127.0.0.1:9100/minio/health/live >/dev/null 2>&1 && return 0
      sleep 1
    done
    echo "minio-dbx failed to become ready" >&2
    return 1
  fi
}

# Create a bucket on the local MinIO via mc, idempotently.
ensure_minio_bucket() {
  local bucket="$1"
  command -v mc >/dev/null 2>&1 || skip "mc not installed"
  mc alias set dbxtest http://127.0.0.1:9100 minioadmin minioadmin --api S3v4 >/dev/null 2>&1
  mc mb --ignore-existing "dbxtest/$bucket" >/dev/null 2>&1
}

# Drop and recreate a postgres database with given seed SQL.
seed_postgres_db() {
  local db="$1" sql="${2:-CREATE TABLE t(id int);INSERT INTO t VALUES(1),(2),(3);}"
  docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -c "DROP DATABASE IF EXISTS \"$db\"" >/dev/null 2>&1
  docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -c "CREATE DATABASE \"$db\"" >/dev/null
  echo "$sql" | docker exec -i -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -d "$db" >/dev/null
}

# Drop and recreate a mysql database with given seed SQL.
seed_mysql_db() {
  local db="$1" sql="${2:-CREATE TABLE t(id INT);INSERT INTO t VALUES(1),(2),(3);}"
  docker exec -e MYSQL_PWD=devpassword mysql-dbx \
    mysql -u root -e "DROP DATABASE IF EXISTS \`$db\`; CREATE DATABASE \`$db\`;" >/dev/null
  echo "$sql" | docker exec -i -e MYSQL_PWD=devpassword mysql-dbx \
    mysql -u root "$db" >/dev/null
}

# Count rows in a postgres table.
pg_row_count() {
  local db="$1" table="$2"
  docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -d "$db" -t -A -c "SELECT count(*) FROM $table" 2>/dev/null
}

# Count rows in a mysql table.
mysql_row_count() {
  local db="$1" table="$2"
  docker exec -e MYSQL_PWD=devpassword mysql-dbx \
    mysql -u root -N -e "SELECT count(*) FROM \`$db\`.\`$table\`" 2>/dev/null
}

# Drop a postgres database (used to clean up restored DBs).
pg_drop_db() {
  docker exec -e PGPASSWORD=devpassword postgres-dbx \
    psql -U postgres -c "DROP DATABASE IF EXISTS \"$1\"" >/dev/null 2>&1 || true
}

# Drop a mysql database.
mysql_drop_db() {
  docker exec -e MYSQL_PWD=devpassword mysql-dbx \
    mysql -u root -e "DROP DATABASE IF EXISTS \`$1\`" >/dev/null 2>&1 || true
}

# Spin up a MariaDB 10.11 source for testing flavor detection + image match.
# Idempotent. Container name: dbx-mariadb-source. No host-port mapping —
# bats tests connect via the Docker bridge IP (firewall blocks host port
# forwarding from inside containers on this host).
ensure_mariadb_source() {
  if ! docker ps --format '{{.Names}}' | grep -q '^dbx-mariadb-source$'; then
    docker rm -f dbx-mariadb-source >/dev/null 2>&1
    docker run -d --name dbx-mariadb-source \
      -e MARIADB_ROOT_PASSWORD=devpassword \
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

# Spin up a Postgres 13 source for cross-version restore testing.
# Idempotent. Container name: dbx-pg13-source.
ensure_pg13_source() {
  if ! docker ps --format '{{.Names}}' | grep -q '^dbx-pg13-source$'; then
    docker rm -f dbx-pg13-source >/dev/null 2>&1
    docker run -d --name dbx-pg13-source \
      -e POSTGRES_PASSWORD=devpassword \
      postgres:13-alpine >/dev/null
    for _ in $(seq 1 30); do
      docker exec dbx-pg13-source pg_isready -U postgres >/dev/null 2>&1 && return 0
      sleep 1
    done
    echo "dbx-pg13-source failed to become ready" >&2
    return 1
  fi
}

# Spin up a Postgres 16 + pgvector source for extension-aware-restore tests.
# Idempotent. Container name: dbx-pgvector-source.
ensure_pgvector_source() {
  if ! docker ps --format '{{.Names}}' | grep -q '^dbx-pgvector-source$'; then
    docker rm -f dbx-pgvector-source >/dev/null 2>&1
    docker run -d --name dbx-pgvector-source \
      -e POSTGRES_PASSWORD=devpassword \
      pgvector/pgvector:pg16 >/dev/null
    for _ in $(seq 1 30); do
      docker exec dbx-pgvector-source pg_isready -U postgres >/dev/null 2>&1 && return 0
      sleep 1
    done
    return 1
  fi
}

# Write a config that points at the local containers and uses password_cmd
# (echo) to bypass the keychain.
write_local_config() {
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-pg": {
      "type": "postgres",
      "host": "127.0.0.1",
      "port": 5432,
      "user": "postgres",
      "password_cmd": "echo devpassword"
    },
    "local-mysql": {
      "type": "mysql",
      "host": "127.0.0.1",
      "port": 3306,
      "user": "root",
      "password_cmd": "echo devpassword"
    }
  },
  "defaults": {
    "compression_level": 1,
    "keep_backups": 10
  }
}
EOF
}
