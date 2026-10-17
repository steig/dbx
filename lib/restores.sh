#!/usr/bin/env bash
#
# lib/restores.sh - List and prune databases restored into the local containers
#
# Every `dbx restore` already writes an audit-log row (target_db, source file,
# timestamp). These helpers join those rows against the databases actually
# present in $POSTGRES_CONTAINER / $MYSQL_CONTAINER, so restores nobody uses
# any more can be found and dropped.
#
# Requires: core.sh sourced first (AUDIT_LOG_FILE, container names, logging).
#

# A restore becomes a prune candidate once it is this many days old AND a
# newer restore of the same source exists. `--older-than` overrides it.
RESTORES_DEFAULT_DAYS=30

# Emit "engine<TAB>name<TAB>bytes" for each user database in the running
# managed containers. A stopped or missing container contributes nothing.
restores_live_dbs() {
  local running
  running=$(docker ps --format '{{.Names}}' 2>/dev/null || true)

  if grep -Fxq "$POSTGRES_CONTAINER" <<< "$running"; then
    docker exec "$POSTGRES_CONTAINER" psql -U postgres -tA -F $'\t' \
      -c "SELECT datname, pg_database_size(datname) FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'" \
      </dev/null 2>/dev/null \
      | awk -F'\t' -v OFS='\t' 'NF >= 2 {print "postgres", $1, $2}' || true
  fi

  if grep -Fxq "$MYSQL_CONTAINER" <<< "$running"; then
    docker exec "$MYSQL_CONTAINER" mysql -u root -NB -e \
      "SELECT s.schema_name, COALESCE(SUM(t.data_length + t.index_length), 0)
         FROM information_schema.schemata s
         LEFT JOIN information_schema.tables t ON t.table_schema = s.schema_name
        WHERE s.schema_name NOT IN ('mysql','information_schema','performance_schema','sys')
        GROUP BY s.schema_name" \
      </dev/null 2>/dev/null \
      | awk -F'\t' -v OFS='\t' 'NF >= 2 {print "mysql", $1, $2}' || true
  fi
}

# Emit "target_db<TAB>epoch<TAB>file<TAB>db_host<TAB>database" for every
# successful restore in the audit log, oldest first. db_host/database are
# empty on rows written before dbx recorded them. `fromjson?` skips any
# malformed line instead of failing the whole read.
restores_audit_index() {
  [[ -f "$AUDIT_LOG_FILE" ]] || return 0
  jq -rR 'fromjson?
    | select(.action == "restore" and .outcome == "success" and (.target_db // "") != "")
    | [.target_db, ((.timestamp // "") | fromdateiso8601? // 0),
       (.file // ""), (.db_host // ""), (.database // "")]
    | @tsv' "$AUDIT_LOG_FILE" 2>/dev/null || true
}

# Classify each live database. Pure function: no docker, no clock.
# Args: $1=audit index file (restores_audit_index format)
#       $2=live dbs file (restores_live_dbs format)
#       $3=now (epoch seconds)  $4=age threshold in days
# Emits "engine<TAB>name<TAB>bytes<TAB>restored_epoch<TAB>source<TAB>status":
#   untracked - no restore record (created by tests, worktrees, by hand)
#   keep      - newest restore of its source, or younger than the threshold
#   prune     - older than the threshold and superseded by a newer restore
# Source is "host/database": from the audit row when present, else the two
# directories above the backup file ($DATA_DIR/<host>/<database>/<file>).
restores_classify() {
  awk -F'\t' -v OFS='\t' -v now="$3" -v days="$4" '
    function path_source(p,    parts, k) {
      k = split(p, parts, "/")
      return (k >= 3) ? parts[k-2] "/" parts[k-1] : "-"
    }
    FILENAME == ARGV[1] {
      at[$1] = $2
      from[$1] = ($4 != "" && $5 != "") ? $4 "/" $5 : path_source($3)
      next
    }
    NF >= 3 {
      n++; E[n] = $1; N[n] = $2; B[n] = $3
      if ($2 in at) {
        key = $1 SUBSEP from[$2]
        if (!(key in newest) || at[$2] > newest[key]) newest[key] = at[$2]
      }
    }
    END {
      cutoff = now - days * 86400
      for (i = 1; i <= n; i++) {
        if (!(N[i] in at)) { print E[i], N[i], B[i], 0, "-", "untracked"; continue }
        t = at[N[i]]; src = from[N[i]]
        st = (t == newest[E[i] SUBSEP src] || t > cutoff) ? "keep" : "prune"
        print E[i], N[i], B[i], t, src, st
      }
    }
  ' "$1" "$2"
}

# Classified rows for the live containers, grouped by source, newest first.
# Args: $1=age threshold in days
restores_rows() {
  restores_classify <(restores_audit_index) <(restores_live_dbs) "$(date +%s)" "$1" \
    | sort -t $'\t' -k5,5 -k4,4nr
}

# Drop one database from its managed container.
# Args: $1=engine (postgres|mysql)  $2=database name
restores_drop() {
  local engine="$1" name="$2" quoted
  case "$engine" in
    postgres)
      quoted="\"${name//\"/\"\"}\""
      docker exec "$POSTGRES_CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -qc \
        "DROP DATABASE $quoted" </dev/null
      ;;
    mysql)
      quoted="\`${name//\`/\`\`}\`"
      docker exec "$MYSQL_CONTAINER" mysql -u root -e "DROP DATABASE $quoted" </dev/null
      ;;
    *) log_error "Unknown engine for $name: $engine"; return 1 ;;
  esac
}

# One-line nudge after a restore when superseded restores are piling up.
# Silent when there is nothing to prune or anything fails along the way.
restores_nudge() {
  local summary count bytes
  summary=$(restores_rows "$RESTORES_DEFAULT_DAYS" 2>/dev/null \
    | awk -F'\t' '$6 == "prune" {c++; b += $3} END {if (c) printf "%d\t%.0f\n", c, b}') || return 0
  [[ -z "$summary" ]] && return 0
  IFS=$'\t' read -r count bytes <<< "$summary"
  log_warn "$count superseded restore(s) older than ${RESTORES_DEFAULT_DAYS}d are using $(human_size "$bytes") — review with 'dbx restores prune'"
}
