#!/usr/bin/env bash
#
# dbx installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/steig/dbx/main/install.sh | bash
#
set -euo pipefail

REPO="steig/dbx"
INSTALL_DIR="${DBX_INSTALL_DIR:-$HOME/.local/bin}"
LIB_DIR="${DBX_LIB_DIR:-$HOME/.local/lib/dbx}"
MAN_DIR="${DBX_MAN_DIR:-$HOME/.local/share/man/man1}"

# Hand-maintained list of man pages to fetch. Kept in sync by hand with
# the files under `man/man1/` in the repo; reviewers should add to this
# list when adding a new subcommand man page.
MAN_PAGES=(
  dbx.1
  dbx-backup.1
  dbx-restore.1
  dbx-verify.1
  dbx-list.1
  dbx-clean.1
  dbx-query.1
  dbx-test.1
  dbx-analyze.1
  dbx-host.1
  dbx-config.1
  dbx-vault.1
  dbx-wizard.1
  dbx-schedule.1
  dbx-storage.1
  dbx-scrub.1
  dbx-completion.1
)

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Check dependencies
check_deps() {
  local missing=()
  for cmd in docker jq zstd ssh curl; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  # Check for credential storage
  if [[ "$(uname)" == "Linux" ]] && ! command -v secret-tool &>/dev/null; then
    missing+=("libsecret-tools")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo ""
    echo -e "${RED}Missing dependencies:${NC} ${missing[*]}"
    echo ""
    echo "Install them first:"
    if [[ "$(uname)" == "Darwin" ]]; then
      echo "  brew install ${missing[*]}"
    else
      echo "  apt install ${missing[*]}  # or equivalent"
    fi
    echo ""
  fi
}

main() {
  echo ""
  echo "Installing dbx..."
  echo ""

  # Create directories
  mkdir -p "$INSTALL_DIR" "$LIB_DIR" "$MAN_DIR"

  # Download files
  info "Downloading from github.com/$REPO..."

  curl -fsSL "https://raw.githubusercontent.com/$REPO/main/dbx" -o "$INSTALL_DIR/dbx"
  chmod +x "$INSTALL_DIR/dbx"

  for lib in core.sh tunnel.sh encrypt.sh postgres.sh mysql.sh post_restore.sh scrub.sh scrub_strategies.sh notify.sh schedule.sh storage.sh update.sh wizard.sh completion.sh; do
    curl -fsSL "https://raw.githubusercontent.com/$REPO/main/lib/$lib" -o "$LIB_DIR/$lib"
  done

  # HTML assets for the browser-based `dbx wizard` config builder. Same
  # form fragment also powers the static docs builder; downloading both
  # gives offline-capable wizard mode.
  for asset in wizard.html wizard-form.html wizard-backups.html wizard-backup.html wizard-restore.html wizard-schedule.html wizard-runs.html wizard-dashboard.html; do
    curl -fsSL "https://raw.githubusercontent.com/$REPO/main/lib/$asset" -o "$LIB_DIR/$asset"
  done

  # Python HTTP server backing the wizard. Standalone file so it stays
  # readable and unit-testable; lib/wizard.sh spawns it via argparse flags.
  curl -fsSL "https://raw.githubusercontent.com/$REPO/main/lib/wizard-server.py" -o "$LIB_DIR/wizard-server.py"

  # Man pages. `man dbx` should work right after install. Skip silently
  # on per-page download failure (e.g. the file doesn't exist yet at
  # main) so a partial release doesn't kill the whole install.
  info "Installing man pages to $MAN_DIR..."
  for page in "${MAN_PAGES[@]}"; do
    curl -fsSL "https://raw.githubusercontent.com/$REPO/main/man/man1/$page" \
      -o "$MAN_DIR/$page" 2>/dev/null || true
  done

  # Update lib path in main script to use installed location.
  # Avoid `sed -i` — its argument shape differs between BSD and GNU sed, and
  # `uname` can't tell us which is actually first in PATH (e.g. GNU sed via
  # Nix or Homebrew on macOS). A temp-file rewrite works with either.
  sed "s|LIB_DIR=\"\$SCRIPT_DIR/lib\"|LIB_DIR=\"$LIB_DIR\"|" "$INSTALL_DIR/dbx" > "$INSTALL_DIR/dbx.tmp"
  mv "$INSTALL_DIR/dbx.tmp" "$INSTALL_DIR/dbx"
  chmod +x "$INSTALL_DIR/dbx"

  # Extract and show version
  local version
  version=$(grep '^VERSION=' "$INSTALL_DIR/dbx" | cut -d'"' -f2)
  success "Installed dbx $version to $INSTALL_DIR/dbx"

  # Check if install dir is in PATH
  if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo ""
    echo -e "${BLUE}Add to your PATH:${NC}"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
    echo ""
  fi

  # If the man page directory isn't already on MANPATH, point the user
  # at how to add it. `manpath` is a portable enough check (BSD on
  # macOS, GNU on Linux), and we look at the parent ($HOME/.local/share/man)
  # because manpath usually returns the section parent, not man1.
  local man_parent
  man_parent="$(dirname "$MAN_DIR")"
  if command -v manpath >/dev/null 2>&1; then
    if ! manpath 2>/dev/null | tr ':' '\n' | grep -Fxq "$man_parent"; then
      echo ""
      echo -e "${BLUE}Add to your MANPATH so 'man dbx' works:${NC}"
      echo "  export MANPATH=\"$man_parent:\$MANPATH\""
      echo "  # (add this to your ~/.bashrc / ~/.zshrc)"
      echo ""
    fi
  fi

  check_deps

  echo ""
  success "Installation complete!"
  echo ""
  echo "Get started:"
  echo "  dbx config init    # Create config"
  echo "  dbx help           # Show all commands"
  echo ""
}

main "$@"
