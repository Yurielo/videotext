#!/usr/bin/env bash
set -euo pipefail

if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_PROJECT="${1:?Usage: $0 <approved-ru-project>}"
SOURCE_MEDIA="${2:?Usage: $0 <approved-ru-project> <source-media>}"
WORK_ROOT="${VIDEOTEXT_EPHEMERAL_WORK_ROOT:-${ROOT}/../work}"
TEST_BINARY="${WORK_ROOT}/videotext-ru-en-real-probe"
REAL_ROOT="${WORK_ROOT}/ru-en-real-$(date +%Y%m%d%H%M%S)"
mkdir -p "${WORK_ROOT}"

SWIFT_SOURCES=()
while IFS= read -r source; do
  SWIFT_SOURCES+=("${source}")
done < <(find "${ROOT}/Sources/videotext" -name '*.swift' ! -path '*/App/*' ! -path '*/UI/*' | sort)

swiftc -O \
  -framework SwiftUI -framework AppKit -framework AVKit -framework AVFoundation -framework UserNotifications \
  -o "${TEST_BINARY}" "${SWIFT_SOURCES[@]}" "${ROOT}/Tests/RUENTranslationRealProbe.swift"

VIDEOTEXT_RU_APPROVED_PROJECT="${SOURCE_PROJECT}" \
VIDEOTEXT_RU_SOURCE="${SOURCE_MEDIA}" \
VIDEOTEXT_RU_EN_REAL_ROOT="${REAL_ROOT}" \
"${TEST_BINARY}"
printf 'RU_EN_REAL_ROOT=%s\n' "${REAL_ROOT}"
