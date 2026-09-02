#!/usr/bin/env bash
# Lists audio inputs. Use the number for AUDIO_DEV if ":0" is the wrong mic.
FFMPEG=ffmpeg
for p in "/Applications/MaestroBar.app/Contents/MacOS/ffmpeg" \
         "$HOME/Applications/MaestroBar.app/Contents/MacOS/ffmpeg"; do
  [ -x "$p" ] && { FFMPEG="$p"; break; }
done
"$FFMPEG" -f avfoundation -list_devices true -i "" 2>&1 | sed -n '/audio devices/,$p'
