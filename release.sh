#!/bin/bash
# Publish a new Maestro Bar build. Run from this folder:  ./release.sh
#
# Builds the dmg, tags the release v<BUILD>, and uploads it. After this, every
# Mac user's `update.sh` sees the new build and takes it.
#
# The tag is the plain build number on purpose: update.sh compares it to
# CFBundleVersion with a numeric test, and a semver tag ("v1.2.0") would make
# that comparison meaningless.
set -euo pipefail
cd "$(dirname "$0")"

command -v gh >/dev/null || { echo "Needs the GitHub CLI: brew install gh"; exit 1; }

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "STOP: uncommitted changes. A release must be a commit someone can go back to."
  git status --short
  exit 1
fi

BUILD=$(git rev-list --count HEAD)
SHA=$(git rev-parse --short HEAD)
TAG="v$BUILD"

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "STOP: $TAG already published. Commit something first — the build number is the commit count."
  exit 1
fi

./build.sh dmg
[ -f MaestroBar.dmg ] || { echo "STOP: no dmg was produced"; exit 1; }

# The check update.sh makes, made here too — so a broken build is caught before
# it reaches anyone rather than after.
M=$(hdiutil attach MaestroBar.dmg -nobrowse -mountrandom /tmp | grep -o '/private/tmp/dmg\.[A-Za-z0-9]*' | tail -1)
ok=0
[ -x "$M/MaestroBar.app/Contents/MacOS/ffmpeg" ] && ok=1
hdiutil detach "$M" -quiet
[ "$ok" = 1 ] || { echo "STOP: the dmg has no ffmpeg — not publishing it"; exit 1; }

gh release create "$TAG" MaestroBar.dmg \
  --title "Maestro Bar build $BUILD" \
  --notes "$(git log -1 --pretty=%s)

Commit $SHA. Update with:
    curl -fsSL https://raw.githubusercontent.com/APX-Solutions/maestro-bar/main/update.sh | bash"

echo
echo "Published $TAG. Everyone's update.sh will pick it up."
