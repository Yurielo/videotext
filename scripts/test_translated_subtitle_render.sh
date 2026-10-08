#!/usr/bin/env bash
set -euo pipefail

if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_PROJECT="${1:?Usage: $0 <approved-en-ru-project>}"
WORK_ROOT="${VIDEOTEXT_EPHEMERAL_WORK_ROOT:-${ROOT}/../work}"
TEST_BINARY="${WORK_ROOT}/videotext-translated-subtitle-render-probe"
CONTROLLED_ROOT="${WORK_ROOT}/translated-subtitle-render-$(date +%Y%m%d%H%M%S)"
CONTROLLED_PROJECT="${CONTROLLED_ROOT}/project"

test -d "${SOURCE_PROJECT}"
mkdir -p "${WORK_ROOT}" "${CONTROLLED_ROOT}"
ditto "${SOURCE_PROJECT}" "${CONTROLLED_PROJECT}"

SWIFT_SOURCES=()
while IFS= read -r source; do
  SWIFT_SOURCES+=("${source}")
done < <(find "${ROOT}/Sources/videotext" -name '*.swift' ! -path '*/App/*' ! -path '*/UI/*' | sort)
swiftc -O -framework SwiftUI -framework AppKit -framework AVKit -framework AVFoundation -framework UserNotifications \
  -o "${TEST_BINARY}" "${SWIFT_SOURCES[@]}" "${ROOT}/Tests/TranslatedSubtitleRenderProbe.swift"
"${TEST_BINARY}" "${CONTROLLED_PROJECT}"
