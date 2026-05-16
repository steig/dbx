#!/usr/bin/env bats
#
# End-to-end mysql backup → list → verify → restore round-trip.

load '../helpers/integration'

setup_file() {
  require_docker
  ensure_mysql_container
}

setup() {
  setup_dbx_env
  write_local_config
  TEST_DB="dbx_my_test_$$_${BATS_TEST_NUMBER}"
  RESTORE_DB="${TEST_DB}_restored"
}

teardown() {
  mysql_drop_db "$TEST_DB"
  mysql_drop_db "$RESTORE_DB"
}

@test "mysql: backup creates .sql.zst + .meta.json with matching checksum" {
  seed_mysql_db "$TEST_DB"

  dbx_run backup local-mysql "$TEST_DB"
  [ "$status" -eq 0 ]

  local files
  files=("$DBX_DATA_DIR/local-mysql/$TEST_DB"/*.sql.zst)
  [ -f "${files[0]}" ]
  [ -f "${files[0]}.meta.json" ]

  local expected actual
  expected=$(jq -r '.checksums.sha256' "${files[0]}.meta.json")
  actual=$(sha256sum "${files[0]}" | cut -d' ' -f1)
  [ "$expected" = "$actual" ]
}

@test "mysql: metadata records type=mysql" {
  seed_mysql_db "$TEST_DB"
  dbx_run backup local-mysql "$TEST_DB"
  [ "$status" -eq 0 ]

  local meta
  meta=$(ls "$DBX_DATA_DIR/local-mysql/$TEST_DB"/*.meta.json | head -1)
  [ "$(jq -r '.type' "$meta")" = "mysql" ]
}

@test "mysql: restore round-trips data correctly" {
  seed_mysql_db "$TEST_DB" "CREATE TABLE widgets(id INT PRIMARY KEY, name VARCHAR(100));
  INSERT INTO widgets VALUES (1,'a'),(2,'b'),(3,'c'),(4,'d'),(5,'e');"

  dbx_run backup local-mysql "$TEST_DB"
  [ "$status" -eq 0 ]

  dbx_run restore "local-mysql/$TEST_DB/latest" --name "$RESTORE_DB"
  [ "$status" -eq 0 ]

  local rows
  rows=$(mysql_row_count "$RESTORE_DB" "widgets" || true)
  [ "$rows" = "5" ]
}

@test "mysql: list shows real on-disk filename" {
  seed_mysql_db "$TEST_DB"
  dbx_run backup local-mysql "$TEST_DB"
  [ "$status" -eq 0 ]

  local real_name
  real_name=$(basename "$DBX_DATA_DIR/local-mysql/$TEST_DB"/*.sql.zst)

  dbx_run list local-mysql "$TEST_DB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "$real_name"
}

@test "mysql: mariadb source → backup uses mariadb image and writes mariadb flavor" {
  ensure_mariadb_source

  # Resolve the source's Docker bridge IP so mysql-dbx can reach it.
  local maria_ip
  maria_ip=$(docker inspect dbx-mariadb-source \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

  # Override the config to point at the mariadb source on the bridge IP.
  cat > "$DBX_CONFIG_DIR/config.json" <<EOF
{
  "hosts": {
    "local-mariadb": {
      "type": "mysql",
      "host": "$maria_ip",
      "port": 3306,
      "user": "root",
      "password_cmd": "echo devpassword"
    }
  },
  "defaults": { "compression_level": 1, "keep_backups": 10 }
}
EOF

  # Seed a DB on the MariaDB source.
  docker exec -e MYSQL_PWD=devpassword dbx-mariadb-source \
    mariadb -u root -e "DROP DATABASE IF EXISTS mariatest; CREATE DATABASE mariatest; CREATE TABLE mariatest.t (id int); INSERT INTO mariatest.t VALUES (1),(2);" >/dev/null

  dbx_run backup local-mariadb mariatest
  [ "$status" -eq 0 ]

  local meta
  meta=$(ls "$DBX_DATA_DIR/local-mariadb/mariatest"/*.sql.zst.meta.json | head -1)
  [ "$(jq -r .source_flavor "$meta")" = "mariadb" ]
  [ "$(jq -r .source_major_version "$meta")" = "10" ]

  # The mysql-dbx container should now be running mariadb, not mysql:8.0
  result=$(docker inspect --format '{{.Config.Image}}' mysql-dbx 2>/dev/null)
  [[ "$result" =~ ^mariadb: ]]
}
