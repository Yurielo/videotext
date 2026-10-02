#!/usr/bin/env bash
set -euo pipefail

# The supervisor owns all disposable scratch, including child tool TMPDIR.
if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

if [[ $# -ne 3 ]]; then
  printf 'Usage: %s <short-media> <whisper-model> <valid-vad-model>\n' "$0" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${VIDEOTEXT_EPHEMERAL_WORK_ROOT:-$ROOT/../work}"
BINARY="$WORK_ROOT/videotext-real-vad-fallback-probe"
SOURCES=()
mkdir -p "$WORK_ROOT"
while IFS= read -r source; do
  SOURCES+=("$source")
done < <(find "$ROOT/Sources/videotext" -name '*.swift' ! -path '*/App/*' ! -path '*/UI/*' | sort)

swiftc -O \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVKit \
  -framework AVFoundation \
  -framework UserNotifications \
  -o "$BINARY" \
  "${SOURCES[@]}" \
  "$ROOT/Tests/RealVADFallbackProbe.swift"

"$BINARY" "$1" "$2" "$3"
