#!/usr/bin/env bash
# push.sh <recording-file> [client]
#
# Transcribe a recording and push the transcript into Maestro, where the
# meeting agent analyses it like any other meeting. Nothing is ever lost: if
# the push fails the transcript stays on disk in ~/Recordings/unsent and
# flush.sh retries it later.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FILE="${1:?usage: push.sh <file> [client]}"
CLIENT="${2:-}"
API="${MAESTRO_API:-https://maestro-agent.duckdns.org}"
BASE="$(basename "${FILE%.*}")"
TXT="${FILE%.*}.txt"
UNSENT="$HOME/Recordings/unsent"

note() { osascript -e "display notification \"$1\" with title \"Maestro\"" >/dev/null 2>&1; }

# 1. transcribe, unless it was already done
if [ ! -s "$TXT" ]; then
  note "Transcribing $BASE"
  "$HERE/transcribe.sh" "$FILE" > "$TXT" 2>/dev/null
fi
if [ ! -s "$TXT" ]; then
  note "Transcript came out empty, keeping the audio"
  exit 1
fi

# 2. build the request body. python does the JSON so quoting and newlines in
#    the transcript cannot break it.
BODY="$(python3 - "$TXT" "$BASE" "$CLIENT" <<'PY'
import hashlib, json, os, sys, datetime
txt, base, client = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(txt, encoding="utf-8", errors="replace").read()
# Stable id: the same file pushed twice updates one row instead of making two.
ext = "local:" + hashlib.sha1(f"{base}:{os.path.getsize(txt)}".encode()).hexdigest()[:16]
started = datetime.datetime.fromtimestamp(os.path.getmtime(txt), datetime.timezone.utc)
print(json.dumps({
    "external_id": ext,
    "title": (client + " — " if client else "") + base,
    "transcript": text,
    "attendees": [],
    "started_at": started.isoformat(),
    "source": "local-recording",
}))
PY
)"

TOKEN="$(security find-generic-password -s maestro-token -w 2>/dev/null)"
if [ -z "${TOKEN:-}" ]; then
  mkdir -p "$UNSENT"; cp "$TXT" "$UNSENT/"
  note "No token in the keychain, transcript saved to unsent"
  exit 1
fi

# 3. push
CODE="$(printf '%s' "$BODY" | curl -sS -o /tmp/maestro-push.out -w '%{http_code}' \
  -X POST "$API/meetings/ingest" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --data-binary @- 2>/dev/null)"

if [ "${CODE:-0}" -ge 200 ] && [ "${CODE:-0}" -lt 300 ]; then
  TASKS="$(python3 -c 'import json,sys;print(json.load(open("/tmp/maestro-push.out")).get("tasks",""))' 2>/dev/null || echo "")"
  note "In Maestro: $BASE${TASKS:+ ($TASKS tasks)}"
  rm -f "$UNSENT/$(basename "$TXT")" 2>/dev/null
else
  mkdir -p "$UNSENT"; cp "$TXT" "$UNSENT/"
  note "Push failed (${CODE:-no response}), saved to unsent"
fi
