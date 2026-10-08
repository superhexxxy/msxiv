#!/bin/sh
# msxiv installer — builds (release, arm64) and installs binary + example config.
# Usage:
#   ./install.sh                    # install to /opt/homebrew (or /usr/local) + config
#   ./install.sh --prefix /tmp/test # custom prefix (binary -> $PREFIX/bin/msxiv)
#   ./install.sh --no-config        # skip config install
#   ./install.sh --force-config     # overwrite existing ~/.config/msxiv/config
#   ./install.sh --uninstall        # remove installed binary (keeps config + cache)
#   PREFIX=/custom ./install.sh     # env override
set -eu

PREFIX="${PREFIX:-}"
NO_CONFIG=0
FORCE_CONFIG=0
UNINSTALL=0

for arg in "$@"; do
  case "$arg" in
    --prefix) echo "usage: ./install.sh --prefix PATH (no space)" >&2; exit 1 ;;
    --prefix=*) PREFIX="${arg#--prefix=}" ;;
    --no-config) NO_CONFIG=1 ;;
    --force-config) FORCE_CONFIG=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)
      echo "Usage: ./install.sh [--prefix=PATH] [--no-config] [--force-config] [--uninstall]"
      exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 1 ;;
  esac
done

# Allow separate: ./install.sh --prefix /tmp/x
if [ "${1:-}" = "--prefix" ]; then
  PREFIX="${2:-}"
  if [ -z "$PREFIX" ]; then echo "--prefix needs a path" >&2; exit 1; fi
fi

if [ -z "$PREFIX" ]; then
  if [ -d /opt/homebrew ]; then PREFIX=/opt/homebrew; else PREFIX=/usr/local; fi
fi
BINDIR="$PREFIX/bin"
CONFDIR="$HOME/.config/msxiv"
CACHEDIR="$HOME/.cache/msxiv/thumbnails"

cd "$(dirname "$0")"

if [ "$UNINSTALL" -eq 1 ]; then
  echo "Removing $BINDIR/msxiv ..."
  rm -f "$BINDIR/msxiv"
  echo "Done. (Config kept at $CONFDIR, cache at $CACHEDIR)"
  exit 0
fi

command -v swift >/dev/null 2>&1 || { echo "error: swift not found (install Xcode CLT: xcode-select --install)" >&2; exit 1; }
command -v make >/dev/null 2>&1 || { echo "error: make not found" >&2; exit 1; }

echo "Building msxiv (release)..."
make

echo "Installing binary to $BINDIR/msxiv ..."
mkdir -p "$BINDIR"
install -m 755 .build/release/msxiv "$BINDIR/msxiv"

if [ "$NO_CONFIG" -eq 0 ]; then
  if [ -f "$CONFDIR/config" ] && [ "$FORCE_CONFIG" -eq 0 ]; then
    echo "Config exists at $CONFDIR/config (skipped, use --force-config to overwrite)"
  else
    echo "Installing config to $CONFDIR/config ..."
    mkdir -p "$CONFDIR"
    install -m 644 config.example "$CONFDIR/config"
  fi
else
  echo "Skipping config (--no-config)"
fi

mkdir -p "$CACHEDIR"

echo ""
echo "Done."
echo "  binary: $BINDIR/msxiv"
echo "  config: $CONFDIR/config"
echo "  thumbs: $CACHEDIR"
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BINDIR"; then
  echo "NOTE: $BINDIR is not on your PATH. Add: export PATH=\"$BINDIR:\$PATH\""
fi
echo ""
echo "Try: msxiv ~/Pictures/   or   msxiv -t ~/Pictures/"
