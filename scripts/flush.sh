#!/usr/bin/env bash
# flush.sh — retry every transcript that failed to reach Maestro.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNSENT="$HOME/Recordings/unsent"
[ -d "$UNSENT" ] || exit 0
for t in "$UNSENT"/*.txt; do
  [ -e "$t" ] || continue
  echo "retrying $(basename "$t")"
  "$HERE/push.sh" "$t"
done
