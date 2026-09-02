#!/usr/bin/env bash
# Toggle recorder.  rec.sh [audio|screen] [tag]
# Press once to start, run again to stop.
set -uo pipefail
INBOX="$HOME/Recordings"
PIDFILE="/tmp/maestro-rec.pid"
MODE="${1:-audio}"
TAG="${2:-internal}"
mkdir -p "$INBOX"

notify(){ osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true; }

# The app ships its own static ffmpeg, so prefer that over whatever is on PATH:
# this script has to work on a machine that has never had Homebrew, which is
# most of the people who install by dragging the app out of the DMG. Bare
# `ffmpeg` used to fail there with nothing but an empty file to show for it.
ffmpeg_bin() {
  for p in "/Applications/MaestroBar.app/Contents/MacOS/ffmpeg" \
           "$HOME/Applications/MaestroBar.app/Contents/MacOS/ffmpeg" \
           "$HOME/Desktop/MaestroBar/MaestroBar.app/Contents/MacOS/ffmpeg"; do
    [ -x "$p" ] && { echo "$p"; return; }
  done
  command -v ffmpeg 2>/dev/null || echo ffmpeg
}
FFMPEG="$(ffmpeg_bin)"

if [ -f "$PIDFILE" ]; then
  PID="$(cat "$PIDFILE")"
  kill -INT "$PID" 2>/dev/null || true
  sleep 1
  kill -0 "$PID" 2>/dev/null && kill -TERM "$PID" 2>/dev/null
  rm -f "$PIDFILE"
  LAST="$(ls -t "$INBOX" | head -1)"
  notify "Stopped" "$LAST"
  echo "stopped -> $INBOX/$LAST"
  exit 0
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
case "$MODE" in
  audio)
    OUT="$INBOX/${STAMP}--${TAG}.wav"
    "$FFMPEG" -nostdin -loglevel error -f avfoundation \
           -i ":${AUDIO_DEV:-0}" -ac 1 -ar 16000 "$OUT" &
    ;;
  screen)
    OUT="$INBOX/${STAMP}--${TAG}.mov"
    screencapture -v -g -k "$OUT" &
    ;;
  *) echo "usage: rec.sh [audio|screen] [tag]"; exit 1 ;;
esac
echo $! > "$PIDFILE"
notify "Recording" "$MODE / $TAG"
echo "recording -> $OUT   (run again to stop)"
