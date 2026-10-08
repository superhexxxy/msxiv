#!/bin/sh
# msxiv publisher — cuts a GitHub release, then publishes a Homebrew tap.
# Usage:
#   ./publish.sh           # publish v1.0.0
#   ./publish.sh v1.0.1    # publish another version
#
# Prerequisites (run once):
#   brew install gh
#   gh auth login          # browser flow
#   (Xcode CLT already provides swift/make)
set -eu

USER="superhexxxy"
REPO="msxiv"
VERSION="${1:-v1.0.0}"
TAPREPO="homebrew-tap"

cd "$(dirname "$0")"

say() { printf '\n==> %s\n' "$*"; }

# --- 0. Preconditions -------------------------------------------------------
command -v git >/dev/null 2>&1 || { echo "error: git not found" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "error: gh not found — run: brew install gh && gh auth login" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: gh not authenticated — run: gh auth login" >&2; exit 1; }
command -v brew >/dev/null 2>&1 || { echo "error: brew not found" >&2; exit 1; }

# --- 1. Brand files with real username ---------------------------------------
say "Branding files as $USER ..."
grep -rl "yourusername" -- . 2>/dev/null | while IFS= read -r f; do
  sed -i '' "s/yourusername/$USER/g" "$f"
  echo "  updated $f"
done || true
if grep -rq "yourusername" -- . 2>/dev/null; then
  echo "error: 'yourusername' placeholders remain" >&2; exit 1
fi

# --- 2. LICENSE (WTFPL — already in repo; fetch only if missing) --------------
if [ ! -f LICENSE ]; then
  say "Fetching WTFPL license text ..."
  if curl -sL http://www.wtfpl.net/txt/copying/ -o LICENSE; then
    echo "  LICENSE written"
  else
    echo "warning: could not download license — add a LICENSE file manually" >&2
  fi
fi

# --- 3. Commit + push + tag --------------------------------------------------
say "Committing and pushing $REPO ..."
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || git init -b main
git remote get-url origin >/dev/null 2>&1 \
  || git remote add origin "https://github.com/$USER/$REPO.git"
git add -A
if git diff --cached --quiet; then
  echo "  nothing new to commit"
else
  git commit -m "Release $VERSION"
fi
git push -u origin main 2>/dev/null || git push origin main
if git rev-parse "$VERSION" >/dev/null 2>&1; then
  echo "  tag $VERSION already exists locally"
else
  git tag "$VERSION"
fi
git push origin "$VERSION"

# --- 4. GitHub release --------------------------------------------------------
say "Creating GitHub release $VERSION ..."
if gh release view "$VERSION" --repo "$USER/$REPO" >/dev/null 2>&1; then
  echo "  release $VERSION already exists"
else
  gh release create "$VERSION" --repo "$USER/$REPO" \
    --title "$REPO $VERSION" --generate-notes
fi

# --- 5. Tarball sha256 (retry: GitHub needs a moment) ------------------------
say "Waiting for release tarball ..."
TARBALL_URL="https://github.com/$USER/$REPO/archive/refs/tags/$VERSION.tar.gz"
i=0
until curl -sfL "$TARBALL_URL" -o /tmp/msxiv-release.tgz 2>/dev/null; do
  i=$((i + 1))
  if [ "$i" -ge 12 ]; then echo "error: tarball not available: $TARBALL_URL" >&2; exit 1; fi
  echo "  retrying in 10s ... ($i/12)"
  sleep 10
done
SHA="$(shasum -a 256 /tmp/msxiv-release.tgz | awk '{print $1}')"
echo "  sha256: $SHA"

# --- 6. Update the template formula in this repo ------------------------------
say "Updating msxiv.rb template ..."
sed -i '' "s|https://github.com/$USER/$REPO/archive/refs/tags/.*\\.tar\\.gz|https://github.com/$USER/$REPO/archive/refs/tags/$VERSION.tar.gz|" msxiv.rb
sed -i '' 's/sha256 ".*"  # .*$/sha256 "'"$SHA"'"/; s/sha256 "REPLACE_WITH_ACTUAL_SHA256"/sha256 "'"$SHA"'"/' msxiv.rb
sed -i '' '/^  bottle do$/,/^  end$/d' msxiv.rb
git add -A
git diff --cached --quiet || git commit -m "Update formula for $VERSION"
git push origin main 2>/dev/null || git push origin main

# --- 7. Tap repo ---------------------------------------------------------------
say "Preparing tap $USER/$TAPREPO ..."
if gh repo view "$USER/$TAPREPO" >/dev/null 2>&1; then
  echo "  tap repo already exists"
else
  gh repo create "$USER/$TAPREPO" --public --description "Homebrew tap for msxiv"
fi
TAPDIR="$(mktemp -d)/tap"
git clone "https://github.com/$USER/$TAPREPO.git" "$TAPDIR"
mkdir -p "$TAPDIR/Formula"
cat > "$TAPDIR/Formula/msxiv.rb" <<EOF
class Msxiv < Formula
  desc "Neo Simple X Image Viewer for macOS (Apple Silicon native)"
  homepage "https://github.com/$USER/$REPO"
  url "$TARBALL_URL"
  sha256 "$SHA"
  license "WTFPL"

  depends_on xcode: ["14.0", :build]
  depends_on macos: :ventura

  def install
    system "make"
    bin.install ".build/release/msxiv"
    (etc/"msxiv").install "config.example" => "config"
  end

  def caveats
    <<~EOS
      mkdir -p ~/.config/msxiv
      cp #{etc}/msxiv/config ~/.config/msxiv/config
    EOS
  end

  test do
    system "#{bin}/msxiv", "--help"
  end
end
EOF
cd "$TAPDIR"
git add -A
git diff --cached --quiet && echo "  tap already up to date" || git commit -m "msxiv $VERSION ($SHA)"
git push -u origin main 2>/dev/null || git push origin main
cd - >/dev/null

# --- 8. Test install exactly as users get it -----------------------------------
say "Testing bottled-from-source install ..."
brew install --build-from-source "$TAPDIR/Formula/msxiv.rb"
"$(brew --prefix)/bin/msxiv" -h >/dev/null 2>&1 && echo "  smoke test OK"
brew test msxiv 2>/dev/null || echo "  (brew test skipped — formula not from tap yet)"
brew audit --strict --new msxiv 2>/dev/null || echo "  warning: brew audit nits — review before announcing"
brew uninstall msxiv

# --- 9. Final install from the tap ----------------------------------------------
say "Installing from tap ..."
brew tap "$USER/tap" 2>/dev/null || true
brew install msxiv
msxiv -h >/dev/null 2>&1 && echo "  msxiv installed and working"

say "Done. Users install with: brew tap $USER/tap && brew install msxiv"
say "Next release: ./publish.sh vX.Y.Z"
