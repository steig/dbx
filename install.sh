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

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

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
  mkdir -p "$INSTALL_DIR" "$LIB_DIR"

  # Download files
  info "Downloading from github.com/$REPO..."

  curl -fsSL "https://raw.githubusercontent.com/$REPO/main/dbx" -o "$INSTALL_DIR/dbx"
  chmod +x "$INSTALL_DIR/dbx"

  for lib in core.sh tunnel.sh postgres.sh mysql.sh; do
    curl -fsSL "https://raw.githubusercontent.com/$REPO/main/lib/$lib" -o "$LIB_DIR/$lib"
  done

  # Update lib path in main script to use installed location
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "s|LIB_DIR=\"\$SCRIPT_DIR/lib\"|LIB_DIR=\"$LIB_DIR\"|" "$INSTALL_DIR/dbx"
  else
    sed -i "s|LIB_DIR=\"\$SCRIPT_DIR/lib\"|LIB_DIR=\"$LIB_DIR\"|" "$INSTALL_DIR/dbx"
  fi

  success "Installed to $INSTALL_DIR/dbx"

  # Check if install dir is in PATH
  if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo ""
    echo -e "${BLUE}Add to your PATH:${NC}"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
    echo ""
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
