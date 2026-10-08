#!/bin/sh
# msxiv updater — pulls latest source (if git), rebuilds (release) and reinstalls.
# Usage:
#   ./update.sh                    # pull (if git) + rebuild + reinstall binary
#   ./update.sh --prefix=/tmp/test # custom prefix (binary -> $PREFIX/bin/msxiv)
#   ./update.sh --check            # only check: show git status / binary age, change nothing
#   ./update.sh --force-config     # also (over)write ~/.config/msxiv/config from config.example
#   PREFIX=/custom ./update.sh     # env override
set -eu

PREFIX="${PREFIX:-}"
CHECK_ONLY=0
FORCE_CONFIG=0

for arg in "$@"; do
  case "$arg" in
    --prefix) echo "usage: ./update.sh --prefix PATH (no space)" >&2; exit 1 ;;
    --prefix=*) PREFIX="${arg#--prefix=}" ;;
    --check) CHECK_ONLY=1 ;;
    --force-config) FORCE_CONFIG=1 ;;
    -h|--help)
      echo "Usage: ./update.sh [--prefix=PATH] [--check] [--force-config]"
      exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 1 ;;
  esac
done

if [ "${1:-}" = "--prefix" ]; then
  PREFIX="${2:-}"
  if [ -z "$PREFIX" ]; then echo "--prefix needs a path" >&2; exit 1; fi
fi

if [ -z "$PREFIX" ]; then
  if [ -d /opt/homebrew ]; then PREFIX=/opt/homebrew; else PREFIX=/usr/local; fi
fi
BINDIR="$PREFIX/bin"
CONFDIR="$HOME/.config/msxiv"

cd "$(dirname "$0")"

# --- 1. Pull latest source (only if this is a git checkout with a remote) ---
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git remote | grep -q .; then
    echo "Pulling latest source..."
    BEFORE="$(git rev-parse --short HEAD 2>/dev/null || echo none)"
    if git pull --ff-only 2>&1; then
      AFTER="$(git rev-parse --short HEAD 2>/dev/null || echo none)"
      if [ "$BEFORE" = "$AFTER" ]; then
        echo "Already up to date ($AFTER)."
      else
        echo "Updated: $BEFORE -> $AFTER"
      fi
    else
      echo "warning: git pull failed (diverged or offline?) — continuing with local source" >&2
    fi
  else
    echo "(No git remote configured — using local source.)"
  fi
else
  echo "(Not a git checkout — using local source.)"
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "--- check ---"
  echo "binary source: .build/release/msxiv"
  ls -lh .build/release/msxiv 2>/dev/null || echo "(not built yet — run ./update.sh to build)"
  echo "installed:    $BINDIR/msxiv"
  ls -lh "$BINDIR/msxiv" 2>/dev/null || echo "(not installed at this prefix)"
  exit 0
fi

# --- 2. Rebuild ---
command -v swift >/dev/null 2>&1 || { echo "error: swift not found (install Xcode CLT: xcode-select --install)" >&2; exit 1; }
command -v make >/dev/null 2>&1 || { echo "error: make not found" >&2; exit 1; }

echo "Rebuilding msxiv (release)..."
make

# --- 3. Reinstall binary ---
echo "Installing binary to $BINDIR/msxiv ..."
mkdir -p "$BINDIR"
install -m 755 .build/release/msxiv "$BINDIR/msxiv"

# --- 4. Config (never touch unless asked) ---
if [ "$FORCE_CONFIG" -eq 1 ]; then
  echo "Installing config to $CONFDIR/config ..."
  mkdir -p "$CONFDIR"
  install -m 644 config.example "$CONFDIR/config"
else
  echo "Config untouched (use --force-config to overwrite $CONFDIR/config)"
fi

# --- 5. Smoke test ---
"$BINDIR/msxiv" -h >/dev/null 2>&1 \
  && echo "Smoke test OK ($BINDIR/msxiv -h exits 0)" \
  || { echo "error: installed binary failed smoke test" >&2; exit 1; }

echo ""
echo "Updated."
echo "  binary: $BINDIR/msxiv"
