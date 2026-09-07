#!/usr/bin/env bash
# send.sh <recording-file> [client]
#
# Send a recording to Maestro as-is. The media IS the report: Maestro reads it
# (video included, when the screen was captured), decides whether it is a bug, a
# feature request or thinking aloud, and raises the card. Nothing is transcribed
# here and nothing is typed by anyone.
#
# This replaces push.sh for the recordings path. push.sh transcribes locally and
# posts text to /meetings/ingest — which throws away the screen, and whisper on a
# laptop handles Macedonian far worse than the model does.
#
# Nothing is ever lost: if any step fails the file stays where it is and its path
# is queued in ~/Recordings/unsent-media for flush-media.sh to retry.
set -uo pipefail

FILE="${1:?usage: send.sh <file> [client]}"
CLIENT="${2:-}"
API="${MAESTRO_API:-https://maestro-agent.duckdns.org}"
UNSENT="$HOME/Recordings/unsent-media"
BASE="$(basename "$FILE")"

note() { osascript -e "display notification \"$1\" with title \"Maestro\"" >/dev/null 2>&1; }
park() { mkdir -p "$UNSENT"; printf '%s\n' "$FILE" >> "$UNSENT/queue"; note "$1"; exit 1; }

[ -s "$FILE" ] || { note "Nothing recorded"; exit 1; }

# The app substitutes only {file} and {client}, so the kind comes from the
# extension. The recorder writes video for screen capture and audio otherwise.
case "${FILE##*.}" in
  mov|mp4|webm) KIND="screen" ;;
  *)            KIND="audio"  ;;
esac

# The token, from a file first and the keychain second.
#
# The keychain is the nicer place to keep it, but it challenges the app whenever
# the app's code identity changes — a re-sign, a rebuild, a reinstall — and the
# dialog it raises cannot always be typed into. A recording is not worth losing
# to that. ~/.maestro/token is mode 600 and readable by nobody else.
TOKEN=""
[ -r "$HOME/.maestro/token" ] && TOKEN="$(tr -d "[:space:]" < "$HOME/.maestro/token")"
[ -n "$TOKEN" ] || TOKEN="$(security find-generic-password -s maestro-token -w 2>/dev/null)"
[ -n "${TOKEN:-}" ] || park "No token — put one in ~/.maestro/token; recording kept"

auth=(-H "Authorization: Bearer $TOKEN")

# 1. ask where to put it. The upload goes straight to S3: routing a screen
#    recording through the API would put half a gigabyte through a box that
#    serves live clients on 900MB of RAM.
SIGNED="$(curl -sS --max-time 30 "${auth[@]}" -H 'Content-Type: application/json' \
  -X POST "$API/recordings/upload-url" \
  -d "$(python3 -c 'import json,sys;print(json.dumps({"filename":sys.argv[1],"kind":sys.argv[2]}))' "$BASE" "$KIND")" 2>/dev/null)"

read -r KEY URL CTYPE <<<"$(python3 - <<PY 2>/dev/null
import json
d = json.loads('''$SIGNED''' or "{}")
print(d.get("key",""), d.get("url",""), d.get("content_type",""))
PY
)"
[ -n "${KEY:-}" ] && [ -n "${URL:-}" ] || park "Maestro would not sign the upload — recording kept"

# 2. upload. --fail so a 4xx from S3 is an error rather than a saved error page.
note "Uploading $BASE"
curl -sS --fail --max-time 900 -X PUT "$URL" \
  -H "Content-Type: ${CTYPE:-application/octet-stream}" \
  --upload-file "$FILE" >/dev/null 2>&1 \
  || park "Upload failed — recording kept"

# 3. tell Maestro to read it. Long timeout on purpose: it downloads the media,
#    hands it to the model and waits for a verdict.
# The page the reporter pasted before recording, left beside the media by the
# app. Read here rather than passed as an argument so it survives a parked
# recording that is retried later, possibly after a restart.
PAGE_URL=""
[ -f "$FILE.url" ] && PAGE_URL="$(tr -d '\r\n' < "$FILE.url" 2>/dev/null || true)"

OUT="$(curl -sS --max-time 900 "${auth[@]}" -H 'Content-Type: application/json' \
  -X POST "$API/recordings/ingest" \
  -d "$(python3 -c 'import json,sys;print(json.dumps({"key":sys.argv[1],"kind":sys.argv[2],"page_url":sys.argv[3]}))' "$KEY" "$KIND" "$PAGE_URL")" 2>/dev/null)"

# Read, so the note has done its job. Left behind it would attach the wrong
# page to nothing in particular.
rm -f "$FILE.url"

python3 - <<PY
import json, subprocess
d = json.loads('''$OUT''' or "{}")
cat, routed = d.get("category"), d.get("routed")
if not d.get("ok"):
    msg = "Maestro could not read it — recording kept"
elif routed == "triage":
    msg = f"{cat}: {d.get('title') or ''}"[:120] + " — card raised"
elif routed == "meeting":
    msg = f"Brainstorm — {d.get('tasks', 0)} task(s) proposed"
else:
    # Read, but deliberately not turned into a card. Say why: "other" and a
    # low-confidence verdict are normal answers, not failures.
    msg = f"Read, no card: {d.get('reason') or cat or 'nothing actionable'}"[:150]
subprocess.run(["osascript", "-e", f'display notification "{msg}" with title "Maestro"'],
               capture_output=True)
PY

python3 -c "import json,sys;sys.exit(0 if json.loads('''$OUT''' or '{}').get('ok') else 1)" \
  || park "Maestro could not read it — recording kept"
rm -f "$UNSENT/queue" 2>/dev/null || true
