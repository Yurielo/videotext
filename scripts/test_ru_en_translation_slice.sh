#!/usr/bin/env bash
set -euo pipefail

if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${VIDEOTEXT_EPHEMERAL_WORK_ROOT:-${ROOT}/../work}"
TEST_BINARY="${WORK_ROOT}/videotext-ru-en-translation-slice-probe"
mkdir -p "${WORK_ROOT}"

SWIFT_SOURCES=()
while IFS= read -r source; do
  SWIFT_SOURCES+=("${source}")
done < <(find "${ROOT}/Sources/videotext" -name '*.swift' ! -path '*/App/*' ! -path '*/UI/*' | sort)

swiftc \
  -framework SwiftUI -framework AppKit -framework AVKit -framework AVFoundation -framework UserNotifications \
  -o "${TEST_BINARY}" "${SWIFT_SOURCES[@]}" "${ROOT}/Tests/RUENTranslationSliceProbe.swift"
"${TEST_BINARY}"
