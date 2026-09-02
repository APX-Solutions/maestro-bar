#!/usr/bin/env bash
# transcribe.sh <file> [lang]     lang: mk | en   (default mk)
set -euo pipefail
FILE="$1"; LANG="${2:-mk}"
python3 - "$FILE" "$LANG" <<'PY'
import sys
from faster_whisper import WhisperModel
path, lang = sys.argv[1], sys.argv[2]
model = WhisperModel("small", device="cpu", compute_type="int8")
segments, info = model.transcribe(path, language=lang, vad_filter=True)
print(f"# detected={info.language} confidence={info.language_probability:.2f}", file=sys.stderr)
for s in segments:
    print(f"[{int(s.start//60):02d}:{int(s.start%60):02d}] {s.text.strip()}")
PY
