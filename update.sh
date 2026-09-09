#!/bin/bash
# Upgrade Maestro Bar to the latest release. One command, safe to re-run:
#
#   curl -fsSL https://raw.githubusercontent.com/APX-Solutions/maestro-bar/main/update.sh | bash
#
# Downloads the newest published build, checks it is real, swaps the app and
# restarts it. Says "already up to date" and stops if there is nothing to do.
set -uo pipefail

REPO="APX-Solutions/maestro-bar"
APP="/Applications/MaestroBar.app"
[ -d "$APP" ] || APP="$HOME/Applications/MaestroBar.app"   # non-admin install

say() { printf "  %s\n" "$1"; }
die() { printf "\n  STOP: %s\n\n" "$1" >&2; exit 1; }

printf "\n  Maestro Bar — update\n  ====================\n\n"

[ -d "$APP" ] || die "Maestro Bar is not installed. Use the install link you were sent first."

have=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist" 2>/dev/null || echo 0)
say "installed: build $have"

# The newest release, asked of GitHub rather than guessed. A public repo needs
# no token, which is the whole point: everyone runs the identical command.
latest=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
         | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)
[ -n "$latest" ] || die "could not reach GitHub. Check your connection and try again."
say "available: build $latest"

# Numeric compare, so a rerun after a successful update does nothing rather than
# reinstalling the same build and asking for permissions again.
if [ "$have" -ge "$latest" ] 2>/dev/null; then
  printf "\n  Already up to date. Nothing to do.\n\n"
  exit 0
fi

tmp=$(mktemp -d) || die "could not create a temporary folder"
trap 'find /Volumes -maxdepth 1 -name "Maestro Bar*" 2>/dev/null | while read -r v; do hdiutil detach "$v" -force -quiet 2>/dev/null; done; rm -rf "$tmp"' EXIT

say "downloading…"
curl -fsSL -o "$tmp/MaestroBar.dmg" \
  "https://github.com/$REPO/releases/latest/download/MaestroBar.dmg" \
  || die "download failed. Try again in a minute."

M=$(hdiutil attach "$tmp/MaestroBar.dmg" -nobrowse -mountrandom /tmp 2>/dev/null \
    | grep -o '/private/tmp/dmg\.[A-Za-z0-9]*' | tail -1)
[ -n "$M" ] && [ -d "$M/MaestroBar.app" ] || die "the download is not readable. Try again."

# Prove the thing we are about to install actually works before deleting the
# thing that does. An app without its ffmpeg cannot record, and finding that out
# after the swap leaves someone with nothing.
[ -x "$M/MaestroBar.app/Contents/MacOS/ffmpeg" ] || {
  hdiutil detach "$M" -quiet 2>/dev/null
  die "that build is incomplete (no ffmpeg). Nothing was changed — tell Aleksandar."
}

osascript -e 'quit app "MaestroBar"' >/dev/null 2>&1
sleep 2
pkill -x MaestroBar 2>/dev/null
sleep 1

rm -rf "$APP" && cp -R "$M/MaestroBar.app" "$(dirname "$APP")/" || die "could not replace the app"
hdiutil detach "$M" -quiet 2>/dev/null

xattr -dr com.apple.quarantine "$APP" 2>/dev/null

# Clear the screen-recording decision, even though this is an upgrade.
#
# The instinct is to preserve it, and that was the first version of this script.
# It is wrong while the app is ad-hoc signed: macOS identifies it by cdhash,
# every build has a different one, and the old entry therefore authorises an app
# that no longer exists. What the person sees is the worst of both — System
# Settings showing Maestro Bar already switched ON, and the app asking for
# permission anyway, with the toggle doing nothing because it is already on.
#
# Resetting turns that dead end into one honest prompt. It costs an allow and a
# restart per update, which is the real price of ad-hoc signing; a Developer ID
# certificate is what removes it, not this line.
tccutil reset ScreenCapture com.carbonbox.maestrobar >/dev/null 2>&1

now=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null)
open "$APP" || die "updated, but could not start it — open Maestro Bar from Applications"

cat <<EOF

  Updated to ${now:-the latest build}. Maestro Bar is running again.

  Screen recording will ask permission once more. That is expected on every
  update — macOS sees each new build as a different app — so:

    1. Press Ctrl+Alt+S, and allow the permission macOS asks for.
    2. QUIT Maestro Bar and open it again.

  Audio recording (Ctrl+Alt+R) needs none of that and works right now.

EOF
