#!/usr/bin/env bash
# flush-media.sh
#
# Retry recordings that send.sh could not deliver — no token yet, no network,
# S3 refused. The media is still on disk; only the delivery failed, and a
# recording nobody can replay is a conversation lost.
#
# The queue is a list of paths, not a copy of the files: a screen recording is
# large and duplicating it to retry it later would fill the disk.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE="$HOME/Recordings/unsent-media/queue"
[ -s "$QUEUE" ] || { echo "nothing waiting"; exit 0; }

# Read the whole queue first and truncate it, so a failure re-queues cleanly
# through send.sh instead of being retried forever inside this loop.
PENDING="$(sort -u "$QUEUE")"
: > "$QUEUE"

echo "$PENDING" | while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [ ! -s "$f" ]; then
    echo "gone, dropping: $f"
    continue
  fi
  echo "sending: $(basename "$f")"
  "$HERE/send.sh" "$f" || true   # send.sh re-queues its own failures
done
