#!/bin/bash
# Double-click this file. macOS opens it in Terminal and runs the installer.
cd "$(dirname "$0")" || exit 1
./install.sh
echo
echo "You can close this window."
