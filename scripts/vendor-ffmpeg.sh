#!/bin/bash
# Fetch a STATIC ffmpeg into vendor/, for bundling inside MaestroBar.app.
#
# Audio recording needs ffmpeg; screen recording does not (that is
# `screencapture`). It used to come only from Homebrew, so anyone who installed
# by dragging the app out of the DMG got none — and the recorder then failed
# silently and produced a file with nothing in it.
#
# It must be STATIC. Homebrew's ffmpeg links 19 dylibs out of
# /opt/homebrew/Cellar, so copying that binary into the bundle would reproduce
# the exact failure this is meant to fix, on precisely the machines that have
# no Homebrew. The check at the bottom is the point of this script, not a
# formality: it is what stops a broken bundle being built and shipped.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="vendor/ffmpeg"
ARCH="$(uname -m)"

if [ -x "$DEST" ] && [ "${1:-}" != "--force" ]; then
  echo "==> $DEST already present (use --force to refetch)"
  exit 0
fi

case "$ARCH" in
  arm64)  URL="https://www.osxexperts.net/ffmpeg80arm.zip" ;;
  x86_64) URL="https://evermeet.cx/ffmpeg/getrelease/zip" ;;
  *) echo "Unknown architecture: $ARCH"; exit 1 ;;
esac

echo "==> Fetching a static ffmpeg for $ARCH"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -sSL --fail --max-time 600 -o "$TMP/ff.zip" "$URL" \
  || { echo "Download failed. Audio recording will fall back to Homebrew's ffmpeg."; exit 1; }
unzip -o -q "$TMP/ff.zip" -d "$TMP"

FOUND="$(find "$TMP" -type f -name ffmpeg -perm -u+x | head -1)"
[ -n "$FOUND" ] || { echo "No ffmpeg binary in the archive"; exit 1; }

mkdir -p vendor
cp "$FOUND" "$DEST"
chmod +x "$DEST"

# --- the checks that matter --------------------------------------------------
DEPS="$(otool -L "$DEST" | tail -n +2 | grep -v '/usr/lib/\|/System/Library/' || true)"
if [ -n "$DEPS" ]; then
  echo "REFUSING: this ffmpeg is not static. It would break on any machine"
  echo "without those libraries — the bug this exists to prevent:"
  echo "$DEPS"
  rm -f "$DEST"
  exit 1
fi
"$DEST" -hide_banner -version >/dev/null 2>&1 \
  || { echo "REFUSING: the downloaded ffmpeg does not run"; rm -f "$DEST"; exit 1; }
"$DEST" -hide_banner -devices 2>&1 | grep -q avfoundation \
  || { echo "REFUSING: no avfoundation input — it could not record audio"; rm -f "$DEST"; exit 1; }

echo "==> vendor/ffmpeg ready ($(du -h "$DEST" | cut -f1), static, avfoundation present)"
