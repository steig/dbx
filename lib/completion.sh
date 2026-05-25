#!/usr/bin/env bash
#
# lib/completion.sh - Shell completion support
#
# Two pieces:
#   1) dbx_completion_script_{bash,zsh,fish} - prints the completion
#      script the user `eval`s or sources.
#   2) dbx_complete <prev_words...> <current> - the "brain": emits one
#      candidate per stdout line for the current state.
#
# Performance note: dbx_complete is invoked on every TAB press, so it
# avoids docker / network / container work. Only jq + filesystem walks
# are allowed, and the filesystem walk is bounded to two directory
# levels under $DATA_DIR.
#
# Requires: core.sh sourced first (for CONFIG_FILE / DATA_DIR / is_macos).
#

# ============================================================================
# Canonical subcommand list
# ============================================================================

# Echo the canonical subcommands one per line. Used by dbx_complete for
# the top-level completion. Does NOT include alias forms (q, ls, cron,
# s3, ...) — those still work at the CLI but aren't suggested at TAB
# because suggesting both `query` and `q` is noise.
dbx_subcommands() {
  cat <<'EOF'
backup
restore
verify
query
analyze
test
host
wizard
list
clean
vault
schedule
storage
scrub
config
update
help
version
completion
EOF
}

# ============================================================================
# Sub-action lists per command (bash 3.2 — case statement, no `declare -A`)
# ============================================================================

# Echo the subactions for a given top-level command, one per line.
# Empty output means "no subactions, complete a positional / host instead".
_dbx_subactions() {
  case "$1" in
    vault)      printf '%s\n' set get delete list info set-encryption-key init-age ;;
    config)     printf '%s\n' init edit show validate ;;
    schedule)   printf '%s\n' add remove list run sync ;;
    storage)    printf '%s\n' upload download sync info add list delete ;;
    scrub)      printf '%s\n' init check validate ;;
    host)       printf '%s\n' add ;;
    completion) printf '%s\n' bash zsh fish ;;
    *) ;;
  esac
}

# Echo the relevant long flags for a given top-level command, one per
# line. Bash 3.2 — case statement, not `declare -A`. Kept in sync by
# hand with the argparse blocks in `dbx`; reviewers should add the new
# flag here whenever they add one to a `cmd_*` function.
_dbx_flags() {
  case "$1" in
    backup)
      printf '%s\n' --verbose --upload ;;
    restore)
      printf '%s\n' \
        --name --no-post-restore --hooks-only --no-scrub \
        --transform --transform-inherit-env --into \
        --from-remote --recreate-container --keep-download ;;
    clean)
      printf '%s\n' --keep --dry-run --older-than ;;
    schedule)
      # --dry-run is currently only valid on `schedule sync`, but
      # offering it under the parent is fine — bash completion is a
      # hint, not a parser.
      printf '%s\n' --dry-run --force ;;
    "scrub init")
      printf '%s\n' --include-empty --output ;;
    "scrub check")
      printf '%s\n' --quiet --json ;;
    wizard)
      printf '%s\n' --remote --port ;;
    *) ;;
  esac
}

# ============================================================================
# Data sources (read from $CONFIG_FILE, $DATA_DIR, installed units)
# ============================================================================

# Echo host aliases from .hosts in config.json, one per line. Empty
# output when config is missing or jq is unavailable.
_dbx_hosts() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '.hosts // {} | keys[]?' "$CONFIG_FILE" 2>/dev/null
}

# Echo database names declared under a given host in config.json.
_dbx_databases() {
  local host="$1"
  [[ -z "$host" ]] && return 0
  [[ -f "$CONFIG_FILE" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg h "$host" \
    '.hosts[$h].databases // {} | keys[]?' "$CONFIG_FILE" 2>/dev/null
}

# Echo schedule preset shorthands. Order matters — most-common first
# so the TAB ring promotes them.
_dbx_schedule_shorthands() {
  cat <<'EOF'
daily
hourly
weekly
daily@5
daily@2
weekly@1:3
EOF
}

# Echo restore candidates from $DATA_DIR. Two shapes per host/db pair:
#   <host>/<db>/latest             (the "newest backup" alias)
#   <host>/<db>/<backup-filename>  (the specific file shape)
# Walk is bounded to depth=2 under DATA_DIR (host/, host/db/) so this
# stays fast even with thousands of backups.
_dbx_restore_candidates() {
  [[ -d "$DATA_DIR" ]] || return 0
  local host_dir db_dir host db backup
  for host_dir in "$DATA_DIR"/*/; do
    [[ -d "$host_dir" ]] || continue
    host=$(basename "$host_dir")
    for db_dir in "$host_dir"*/; do
      [[ -d "$db_dir" ]] || continue
      db=$(basename "$db_dir")
      printf '%s/%s/latest\n' "$host" "$db"
      # List the actual backup files, but only emit the relative
      # `<host>/<db>/<filename>` form — absolute paths would clutter
      # the TAB ring without adding value for non-power-users.
      for backup in "$db_dir"*.sql.zst "$db_dir"*.sql.zst.age "$db_dir"*.sql.zst.gpg; do
        [[ -f "$backup" ]] || continue
        printf '%s/%s/%s\n' "$host" "$db" "$(basename "$backup")"
      done
    done
  done
}

# Echo "<host> <db>" pairs for currently-installed schedule units.
# Used by `dbx schedule remove <TAB>`. Reads from launchd plists on
# macOS or systemd .timer files on Linux via the existing helper.
_dbx_installed_schedule_pairs() {
  command -v jq >/dev/null 2>&1 || return 0
  # schedule_installed_read is sourced from lib/schedule.sh and emits
  # TSV: host\tdatabase\twhen. We only want the host+db.
  if declare -f schedule_installed_read >/dev/null 2>&1; then
    schedule_installed_read 2>/dev/null | awk -F'\t' '{print $1" "$2}'
  fi
}

# ============================================================================
# Brain: dbx_complete <prev_words...> <current>
# ============================================================================
#
# Argv is everything after `dbx` on the command line, including the
# trailing partial. The shell completion script always passes the
# partial as the last arg (it may be the empty string).
#
# Strategy: peel off the first arg as the subcommand. Inside that,
# look at how many words are present and where in the positional
# sequence we are. Bias toward suggesting host aliases when in doubt.
dbx_complete() {
  local words=( "$@" )
  local count=$#

  # Bare `dbx` (nothing typed yet, or partial first word).
  if [[ $count -le 1 ]]; then
    dbx_subcommands
    return 0
  fi

  local cmd="${words[0]}"
  local cur="${words[$((count - 1))]}"

  # Any flag-shaped current word collapses to the per-command flag list,
  # regardless of position. Keeps the brain simple.
  if [[ "$cur" == -* ]]; then
    # scrub init / scrub check have their own flag lists; everything
    # else looks at the top-level subcommand.
    if [[ "$cmd" == "scrub" && $count -ge 3 ]]; then
      _dbx_flags "scrub ${words[1]}"
    else
      _dbx_flags "$cmd"
    fi
    return 0
  fi

  case "$cmd" in
    backup)
      # `dbx backup <host>` or `dbx backup <host> <db>`
      if [[ $count -eq 2 ]]; then
        _dbx_hosts
      elif [[ $count -eq 3 ]]; then
        _dbx_databases "${words[1]}"
      fi
      ;;

    restore)
      # `dbx restore <source>` — source is `<host>/<db>/latest` or
      # a specific backup file under DATA_DIR.
      if [[ $count -eq 2 ]]; then
        _dbx_restore_candidates
      fi
      ;;

    test|ping|analyze|stats|query|q|shell)
      # `dbx <cmd> <host> [db]`
      if [[ $count -eq 2 ]]; then
        _dbx_hosts
      elif [[ $count -eq 3 ]]; then
        _dbx_databases "${words[1]}"
      fi
      ;;

    list|ls|clean|prune)
      # `dbx list [host] [db]` — host is optional but TAB still helps.
      if [[ $count -eq 2 ]]; then
        _dbx_hosts
      elif [[ $count -eq 3 ]]; then
        _dbx_databases "${words[1]}"
      fi
      ;;

    vault)
      # `dbx vault <action> [host]`
      if [[ $count -eq 2 ]]; then
        _dbx_subactions vault
      elif [[ $count -eq 3 ]]; then
        case "${words[1]}" in
          set|get|delete|rm) _dbx_hosts ;;
        esac
      fi
      ;;

    config|cfg)
      if [[ $count -eq 2 ]]; then
        _dbx_subactions config
      fi
      ;;

    schedule|cron)
      if [[ $count -eq 2 ]]; then
        _dbx_subactions schedule
      elif [[ $count -eq 3 ]]; then
        case "${words[1]}" in
          add|run)         _dbx_hosts ;;
          remove|rm|delete) _dbx_installed_schedule_pairs | awk '{print $1}' | sort -u ;;
        esac
      elif [[ $count -eq 4 ]]; then
        case "${words[1]}" in
          add|run)         _dbx_databases "${words[2]}" ;;
          remove|rm|delete) _dbx_installed_schedule_pairs \
                             | awk -v h="${words[2]}" '$1==h {print $2}' ;;
        esac
      elif [[ $count -eq 5 ]]; then
        case "${words[1]}" in
          add) _dbx_schedule_shorthands ;;
        esac
      fi
      ;;

    storage|s3)
      if [[ $count -eq 2 ]]; then
        _dbx_subactions storage
      elif [[ $count -eq 3 ]]; then
        case "${words[1]}" in
          sync) printf '%s\n' upload download ;;
        esac
      elif [[ $count -eq 4 ]]; then
        case "${words[1]}" in
          sync) _dbx_hosts ;;
        esac
      elif [[ $count -eq 5 ]]; then
        case "${words[1]}" in
          sync) _dbx_databases "${words[3]}" ;;
        esac
      fi
      ;;

    scrub)
      if [[ $count -eq 2 ]]; then
        _dbx_subactions scrub
      elif [[ $count -eq 3 ]]; then
        # `dbx scrub <action> <host>/<db>` — emit the host/db form.
        case "${words[1]}" in
          init|check) _dbx_restore_candidates | grep -v '/latest$' \
                        | awk -F'/' '{print $1"/"$2}' | sort -u ;;
          validate)   _dbx_hosts ;;
        esac
      fi
      ;;

    host)
      if [[ $count -eq 2 ]]; then
        _dbx_subactions host
      fi
      ;;

    completion)
      if [[ $count -eq 2 ]]; then
        _dbx_subactions completion
      fi
      ;;

    help|--help|-h|version|--version|-V|update|self-update|upgrade|wizard|verify)
      # No further completion — these take no positionals (or only
      # opaque ones like a backup-file path that the shell's default
      # file completion handles better than we can).
      ;;

    *)
      # Unknown subcommand → fall back to the subcommand list so the
      # user gets useful feedback if they typo'd.
      dbx_subcommands
      ;;
  esac
}

# ============================================================================
# Completion script generators
# ============================================================================

# Print the bash completion script to stdout. The script shells out to
# `dbx __complete` on every TAB press, so dynamic data (host list,
# backup files, installed schedules) stays fresh without needing the
# user to re-source.
dbx_completion_script_bash() {
  cat <<'BASH'
# dbx bash completion
# Source this file, or add `eval "$(dbx completion bash)"` to your ~/.bashrc.
_dbx_complete() {
  local cur prev_words IFS=$'\n'
  cur="${COMP_WORDS[COMP_CWORD]}"
  # Pass every word after `dbx` up to (but not including) the cursor,
  # plus the current partial as the final arg. dbx __complete uses the
  # word count to decide which positional slot we're in.
  prev_words=( "${COMP_WORDS[@]:1:COMP_CWORD-1}" )
  local candidates
  candidates=$(dbx __complete "${prev_words[@]}" "$cur" 2>/dev/null)
  COMPREPLY=( $(compgen -W "$candidates" -- "$cur") )
}
complete -F _dbx_complete dbx
BASH
}

# Print the zsh completion script. zsh accepts bash-style `complete`
# via bashcompinit, which is the simplest way to share one brain
# across both shells.
dbx_completion_script_zsh() {
  cat <<'ZSH'
# dbx zsh completion
# Source this file, or add `eval "$(dbx completion zsh)"` to your ~/.zshrc.
# Requires `autoload -U compinit && compinit` earlier in your zshrc.
if ! whence -w bashcompinit >/dev/null 2>&1; then
  autoload -U +X bashcompinit && bashcompinit
fi
_dbx_complete() {
  local cur prev_words IFS=$'\n'
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev_words=( "${COMP_WORDS[@]:1:COMP_CWORD-1}" )
  local candidates
  candidates=$(dbx __complete "${prev_words[@]}" "$cur" 2>/dev/null)
  COMPREPLY=( $(compgen -W "$candidates" -- "$cur") )
}
complete -F _dbx_complete dbx
compdef _dbx_complete dbx 2>/dev/null || true
ZSH
}

# Print the fish completion script. fish has a different completion
# model (per-token via `complete -c`); we still shell out to
# `dbx __complete` for the data and let fish's filter narrow it.
dbx_completion_script_fish() {
  cat <<'FISH'
# dbx fish completion
# Save to ~/.config/fish/completions/dbx.fish, or `dbx completion fish | source`.
function __dbx_complete
  set -l tokens (commandline -opc) (commandline -ct)
  # Strip the leading `dbx` token; pass the rest plus the partial.
  set -e tokens[1]
  dbx __complete $tokens 2>/dev/null
end
complete -c dbx -f -a '(__dbx_complete)'
FISH
}
