#!/bin/bash
# Maestro Bar — one command install on a Mac.
#
#   ./install.sh
#
# Idempotent: run it again after a change and it rebuilds in place. It never
# overwrites a config you have edited, and it never asks for a password it
# does not need.
set -uo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"

BIN="$HOME/.maestro/bin"
CFG="$HOME/.config/maestro/bar.json"
API_DEFAULT="https://maestro-agent.duckdns.org"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '   ✓ %s\n' "$*"; }
warn() { printf '   ! %s\n' "$*"; }

# --- 1. prerequisites --------------------------------------------------------
say "Checking what is already here"

if [ "$(uname)" != "Darwin" ]; then
  echo "This installs a macOS menu bar app. You are not on a Mac."
  exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
  warn "Xcode command line tools are missing. Installing them opens a dialog."
  echo "     Run:  xcode-select --install"
  echo "     Then run this script again."
  exit 1
fi
ok "Xcode command line tools"

# ffmpeg is needed for audio (screen capture is `screencapture` and needs
# nothing). The app carries its own copy, so this is no longer a prerequisite —
# the build fetches a static one and bundles it. Homebrew's is used only if
# it is already there.
if command -v ffmpeg >/dev/null 2>&1; then
  ok "ffmpeg (already installed)"
else
  say "Fetching a static ffmpeg to bundle with the app (needed to record audio)"
  ./scripts/vendor-ffmpeg.sh \
    || warn "Could not fetch ffmpeg. Screen recording still works; audio will not."
fi

# --- 2. build ----------------------------------------------------------------
say "Building"
./build.sh install || { echo "Build failed. Send the output above to whoever gave you this."; exit 1; }

# --- 3. scripts --------------------------------------------------------------
say "Installing the recording scripts to ~/.maestro/bin"
mkdir -p "$BIN" "$HOME/Recordings"
cp scripts/*.sh "$BIN/"
chmod +x "$BIN"/*.sh
ok "$(ls "$BIN" | tr '\n' ' ')"

# --- 4. config ---------------------------------------------------------------
say "Configuration"
mkdir -p "$(dirname "$CFG")"
if [ -f "$CFG" ]; then
  ok "$CFG already exists, leaving it alone"
else
  printf '   API base URL [%s]: ' "$API_DEFAULT"
  read -r API
  API="${API:-$API_DEFAULT}"
  python3 - "$HERE/maestro-bar.json" "$CFG" "$API" <<'PY'
import json, sys
src, dst, api = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open(src))
cfg["api"] = api
json.dump(cfg, open(dst, "w"), indent=2, ensure_ascii=False)
PY
  ok "wrote $CFG"
fi

# --- 5. the token ------------------------------------------------------------
say "API token"
if security find-generic-password -s maestro-token >/dev/null 2>&1; then
  ok "already in your keychain"
else
  echo "   Whoever runs Maestro gives you a machine token. It goes in your"
  echo "   login keychain, not in any file. Paste it at the prompt below."
  echo "   (Skip with ctrl-C; recording and capture work without it, the"
  echo "    review queue does not.)"
  security add-generic-password -a "$USER" -s maestro-token -w \
    && ok "stored" || warn "not stored, run this later:  security add-generic-password -a \"\$USER\" -s maestro-token -w"
fi

# --- 6. transcription, optional ---------------------------------------------
say "Transcription (optional)"
if python3 -c "import faster_whisper" >/dev/null 2>&1; then
  ok "faster-whisper is installed"
else
  printf '   Install faster-whisper so recordings become text? It downloads a\n'
  printf '   speech model of a few hundred MB the first time. [y/N]: '
  read -r yn
  case "$yn" in
    [Yy]*) pip3 install --user faster-whisper && ok "installed" || warn "install failed" ;;
    *) warn "skipped; recordings will be saved as audio and not transcribed" ;;
  esac
fi

# --- 7. start at login -------------------------------------------------------
say "Start at login"
printf '   Start Maestro Bar automatically when you log in? [Y/n]: '
read -r yn
case "$yn" in
  [Nn]*) warn "skipped" ;;
  *) ./build.sh login >/dev/null 2>&1 && ok "login item installed" || warn "could not install the login item" ;;
esac

# --- done --------------------------------------------------------------------
cat <<DONE

Done. Maestro Bar is running — look for the M in the menu bar.

  ⌘M                 show and hide the strip on the edge of the screen
  ⌃⌥R  /  ⌃⌥S        record audio  /  record screen

Two permission prompts will appear the first time you record. macOS asks for
Microphone when you record audio, and Screen Recording when you record the
screen. Screen Recording needs the app restarted after you grant it; the
microphone does not.

Everything the menu and the strip show comes from:
  $CFG
Edit it, then use "Reload config" in the menu. No rebuild.
DONE
