#!/usr/bin/env bash
set -euo pipefail

if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${TMPDIR}/en-ru-translation-led"
TEST_BINARY="${WORK}/probe"

: "${VIDEOTEXT_LED_SOURCE:?Set VIDEOTEXT_LED_SOURCE to the accepted LED media.}"
: "${VIDEOTEXT_LED_APPROVED_EN_PROJECT:?Set VIDEOTEXT_LED_APPROVED_EN_PROJECT to an approved EN project template.}"

mkdir -p "$WORK"
export VIDEOTEXT_HISTORY_PATH="$WORK/history.json"
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(
  find "$ROOT/Sources/videotext" -name '*.swift' ! -path '*/App/*' ! -path '*/UI/*' | sort
)

swiftc -O -whole-module-optimization \
  -framework SwiftUI -framework AppKit -framework AVKit -framework AVFoundation -framework UserNotifications \
  -o "$TEST_BINARY" "${SOURCES[@]}" "$ROOT/Tests/ENRUTranslationLEDProbe.swift"

"$TEST_BINARY"
