#!/bin/bash
# Copy ui/ into the Windows checkout beside this one. The page is written once,
# here; the Windows app carries a copy because the two repos are separate.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${1:-../MaestroBarWin/ui}"
mkdir -p "$DEST"
rsync -a --delete --exclude .DS_Store ui/ "$DEST/"
echo "==> ui/ copied to $DEST (do not edit it there; edit MaestroBar/ui and run this again)"
