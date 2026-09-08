#!/bin/bash
# First-time setup for Maestro Bar. One line, nothing to download by hand:
#
#   curl -fsSL https://raw.githubusercontent.com/APX-Solutions/maestro-bar/main/install.sh | bash -s -- YOUR_TOKEN
#
# Safe to re-run. Upgrades use update.sh instead, which keeps permissions.
set -uo pipefail

REPO="APX-Solutions/maestro-bar"
TOKEN="${1:-${MAESTRO_TOKEN:-}}"

say() { printf "  %s\n" "$1"; }
die() { printf "\n  STOP: %s\n\n" "$1" >&2; exit 1; }

printf "\n  Maestro Bar — setup\n  ===================\n\n"

# The token is the whole identity: it is what makes a recording *yours*. Refuse
# rather than install something that will fail silently on the first upload.
[ -n "$TOKEN" ] || die "no token given. The line you were sent ends with your token — paste the whole thing."
case "$TOKEN" in
  *[!A-Za-z0-9_-]*) die "that token has characters a token never contains — it was probably cut off. Ask for it again." ;;
esac
[ ${#TOKEN} -ge 20 ] || die "that token looks too short — it was probably cut off. Ask for it again."

# /Applications when we may, the user's own folder when we may not. Asking for
# an admin password is where a setup stops being one line.
DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; say "no admin rights — installing to $DEST"; }
APP="$DEST/MaestroBar.app"

mkdir -p "$HOME/.maestro"
printf %s "$TOKEN" > "$HOME/.maestro/token"
chmod 600 "$HOME/.maestro/token"
say "token saved"

tmp=$(mktemp -d) || die "could not create a temporary folder"
trap 'find /Volumes -maxdepth 1 -name "Maestro Bar*" 2>/dev/null | while read -r v; do hdiutil detach "$v" -force -quiet 2>/dev/null; done; rm -rf "$tmp"' EXIT

say "downloading the app…"
curl -fsSL -o "$tmp/MaestroBar.dmg" \
  "https://github.com/$REPO/releases/latest/download/MaestroBar.dmg" \
  || die "download failed. Check your connection and run the line again."

M=$(hdiutil attach "$tmp/MaestroBar.dmg" -nobrowse -mountrandom /tmp 2>/dev/null \
    | grep -o '/private/tmp/dmg\.[A-Za-z0-9]*' | tail -1)
[ -n "$M" ] && [ -d "$M/MaestroBar.app" ] || die "the download is not readable. Run the line again."

# Prove it can record before replacing anything. An app with no ffmpeg installs
# perfectly and then fails on the first recording with nothing to explain it.
[ -x "$M/MaestroBar.app/Contents/MacOS/ffmpeg" ] || {
  hdiutil detach "$M" -quiet 2>/dev/null
  die "that build is incomplete (no ffmpeg). Nothing was installed — tell Aleksandar."
}

osascript -e 'quit app "MaestroBar"' >/dev/null 2>&1
sleep 1
pkill -x MaestroBar 2>/dev/null

rm -rf "$APP" && cp -R "$M/MaestroBar.app" "$DEST/" || die "could not install to $DEST"
hdiutil detach "$M" -quiet 2>/dev/null

# The quarantine flag is the only reason dragging an app out of a dmg shows the
# scary blocked dialog; removing it is what "Open Anyway" does, three clicks in.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null
# Fresh install only: clear any screen-recording decision left by an older copy,
# so the prompt actually appears instead of macOS silently remembering a "no".
tccutil reset ScreenCapture com.carbonbox.maestrobar >/dev/null 2>&1

v=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null)
open "$APP" || die "installed, but could not start it — open Maestro Bar from $DEST"

cat <<EOF

  Installed ${v:-}. Look for the M in your menu bar, top right.

  Two things to finish:

    1. Click the M, press "Record screen + audio", and allow the permission
       macOS asks for.
    2. QUIT Maestro Bar and open it again.

  Step 2 is not optional. macOS only gives screen access to an app that starts
  AFTER you allow it, so without it your first recording comes out black.

  Later, to get the newest version:
    curl -fsSL https://raw.githubusercontent.com/$REPO/main/update.sh | bash

EOF
