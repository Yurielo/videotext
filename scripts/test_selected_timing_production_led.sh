#!/usr/bin/env bash
set -euo pipefail

if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${VIDEOTEXT_EPHEMERAL_WORK_ROOT:-${ROOT}/../work}"
TEST_BINARY="${WORK_ROOT}/videotext-selected-timing-production-led-probe"

: "${VIDEOTEXT_LED_SOURCE:?Set VIDEOTEXT_LED_SOURCE to the accepted LED media.}"
: "${VIDEOTEXT_SEMINARTEXT_EXECUTABLE:?Set VIDEOTEXT_SEMINARTEXT_EXECUTABLE to canonical SeminarText.}"
: "${VIDEOTEXT_LED_PROJECT_ROOT:?Set VIDEOTEXT_LED_PROJECT_ROOT to an empty owned project directory.}"

mkdir -p "${WORK_ROOT}"
SWIFT_SOURCES=()
while IFS= read -r source; do
  SWIFT_SOURCES+=("${source}")
done < <(find "${ROOT}/Sources/videotext" -name '*.swift' ! -path '*/App/*' ! -path '*/UI/*' | sort)

swiftc \
  -framework SwiftUI -framework AppKit -framework AVKit -framework AVFoundation -framework UserNotifications \
  -o "${TEST_BINARY}" "${SWIFT_SOURCES[@]}" "${ROOT}/Tests/SelectedTimingProductionLEDProbe.swift"
"${TEST_BINARY}"
