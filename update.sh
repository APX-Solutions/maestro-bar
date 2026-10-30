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

# Who macOS thinks the installed app is, read before it is replaced.
was=$(codesign -d -r- "$APP" 2>&1 | grep '^designated')

osascript -e 'quit app "MaestroBar"' >/dev/null 2>&1
sleep 2
pkill -x MaestroBar 2>/dev/null
sleep 1

rm -rf "$APP" && cp -R "$M/MaestroBar.app" "$(dirname "$APP")/" || die "could not replace the app"
hdiutil detach "$M" -quiet 2>/dev/null

xattr -dr com.apple.quarantine "$APP" 2>/dev/null

# Keep the permissions when the app is still the same app to macOS, clear them
# when it is not.
#
# macOS ties each grant to the app's designated requirement. Builds signed with
# the Maestro Bar certificate all share one, so their grants carry over. An
# ad-hoc build's requirement is the hash of its code, which every build changes:
# the old entry then authorises an app that no longer exists, and what the
# person sees is the worst of both — System Settings showing Maestro Bar already
# switched ON, and the app asking anyway, with the toggle doing nothing because
# it is already on. Resetting turns that dead end into one honest prompt.
moved=0
if [ "$was" != "$(codesign -d -r- "$APP" 2>&1 | grep '^designated')" ]; then
  moved=1
  tccutil reset ScreenCapture com.carbonbox.maestrobar >/dev/null 2>&1
  tccutil reset Microphone com.carbonbox.maestrobar >/dev/null 2>&1
fi

now=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null)
open "$APP" || die "updated, but could not start it — open Maestro Bar from Applications"

if [ "$moved" = 0 ]; then
  printf "\n  Updated to %s. Maestro Bar is running again, permissions kept.\n\n" "${now:-the latest build}"
  exit 0
fi

cat <<EOF

  Updated to ${now:-the latest build}. Maestro Bar is running again.

  This build is signed differently from the one it replaced, so macOS asks for
  permission one more time:

    1. Allow screen recording when macOS asks (or press Ctrl+Alt+S).
    2. Allow the microphone the first time you record audio.

  Maestro Bar restarts itself once screen recording is allowed.

EOF
