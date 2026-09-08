#!/bin/bash
# Builds MaestroBar.app. Run from this folder:  ./build.sh
# Optional:  ./build.sh install   (also copies to /Applications and launches)
#            ./build.sh login     (also installs a login item)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MaestroBar"
BUNDLE_ID="com.carbonbox.maestrobar"
APP="$APP_NAME.app"

# The version, from git rather than by hand.
#
# Every build called itself 1.0 (1), so nothing could tell an old app from a new
# one — which is the whole reason an update check was impossible. The commit
# count is monotonic, needs no discipline to maintain, and is what an update
# compares. The short string carries the sha so a screenshot of About tells you
# exactly which build someone is running.
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)
SHA=$(git rev-parse --short HEAD 2>/dev/null || echo dev)
DIRTY=""
git diff --quiet 2>/dev/null || DIRTY="+"
VERSION="1.$BUILD ($SHA$DIRTY)"
echo "==> Version $VERSION"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode command line tools are missing. Run: xcode-select --install"
  exit 1
fi

echo "==> Compiling"
swift build -c release

BIN=".build/release/$APP_NAME"
[ -f "$BIN" ] || { echo "Build produced no binary"; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# The app carries its own scripts and its own default config, so someone who
# was handed the .app needs nothing else on disk.
mkdir -p "$APP/Contents/Resources/scripts"
cp scripts/*.sh "$APP/Contents/Resources/scripts/" 2>/dev/null || true
chmod +x "$APP/Contents/Resources/scripts/"*.sh 2>/dev/null || true
cp maestro-bar.json "$APP/Contents/Resources/maestro-bar.json"

# --- ffmpeg, inside the bundle ----------------------------------------------
# Audio needs it; screen capture does not. Shipping it here is what makes audio
# work for someone who installed by dragging the app out of the DMG and has
# never had Homebrew — previously they got no ffmpeg, and the recorder failed
# silently and wrote an empty file.
#
# It goes in Contents/MacOS so it is signed as part of the app and inherits the
# bundle's identity. Copying it in AFTER signing is what invalidates the
# signature, which takes the Keychain ACLs and the TCC grants with it.
if [ ! -x vendor/ffmpeg ]; then
  echo "==> No vendor/ffmpeg — fetching one"
  ./scripts/vendor-ffmpeg.sh || echo "note: continuing without a bundled ffmpeg"
fi
if [ -x vendor/ffmpeg ]; then
  # Never bundle a dynamically linked build. Homebrew's links 19 dylibs out of
  # the Cellar, and a bundle carrying that would fail exactly where it must not.
  BADDEPS="$(otool -L vendor/ffmpeg | tail -n +2 | grep -v '/usr/lib/\|/System/Library/' || true)"
  if [ -n "$BADDEPS" ]; then
    echo "==> vendor/ffmpeg is not static; NOT bundling it (audio will need Homebrew)"
  else
    cp vendor/ffmpeg "$APP/Contents/MacOS/ffmpeg"
    chmod +x "$APP/Contents/MacOS/ffmpeg"
    # Signed before the app: a nested executable needs its own signature, and
    # signing the bundle does not reach inside for it.
    codesign --force --sign - "$APP/Contents/MacOS/ffmpeg" >/dev/null 2>&1 || \
      echo "note: could not sign the bundled ffmpeg"
    echo "==> Bundled ffmpeg ($(du -h vendor/ffmpeg | cut -f1))"
  fi
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>Maestro Bar</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Maestro Bar records meetings and brainstorms you start yourself.</string>
</dict>
</plist>
PLIST

# Ad hoc signature with a fixed identifier keeps the privacy permissions
# attached to the same app across rebuilds more often than an unsigned binary.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 || \
  echo "note: could not sign; the app still runs, permissions may re-prompt"

echo "==> Built $(pwd)/$APP"

case "${1:-}" in
  install)
    rm -rf "/Applications/$APP"
    cp -R "$APP" /Applications/
    open "/Applications/$APP"
    echo "==> Installed to /Applications and launched"
    ;;
  login)
    PLIST_PATH="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    TARGET="/Applications/$APP"
    [ -d "$TARGET" ] || TARGET="$(pwd)/$APP"
    cat > "$PLIST_PATH" <<LA
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$BUNDLE_ID</string>
  <key>ProgramArguments</key>
  <array><string>$TARGET/Contents/MacOS/$APP_NAME</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
LA
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    launchctl load "$PLIST_PATH"
    echo "==> Login item installed: $PLIST_PATH"
    ;;
  dmg)
    # A disk image is what people expect to be handed: mount, drag, done.
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f "$APP_NAME.dmg"
    hdiutil create -volname "Maestro Bar" -srcfolder "$STAGE" \
      -ov -format UDZO "$APP_NAME.dmg" >/dev/null
    rm -rf "$STAGE"
    echo "==> $(pwd)/$APP_NAME.dmg  — send this file"
    ;;
  *)
    echo "    open $APP        to run it"
    echo "    ./build.sh install   to put it in /Applications"
    echo "    ./build.sh login     to start it at login"
    echo "    ./build.sh dmg       to make a disk image to send to someone"
    ;;
esac
