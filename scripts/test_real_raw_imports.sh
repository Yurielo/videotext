#!/usr/bin/env bash
set -euo pipefail

if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${VIDEOTEXT_EPHEMERAL_WORK_ROOT:?owned_tmp.py must supply scratch}"
RU_PACKAGE="${1:?Usage: $0 <ru-package> <ru-media> <en-package> <en-media> <result-json>}"
RU_MEDIA="${2:?Usage: $0 <ru-package> <ru-media> <en-package> <en-media> <result-json>}"
EN_PACKAGE="${3:?Usage: $0 <ru-package> <ru-media> <en-package> <en-media> <result-json>}"
EN_MEDIA="${4:?Usage: $0 <ru-package> <ru-media> <en-package> <en-media> <result-json>}"
RESULT_JSON="${5:?Usage: $0 <ru-package> <ru-media> <en-package> <en-media> <result-json>}"
mkdir -p "${WORK_ROOT}"
SWIFT_SOURCES=()
while IFS= read -r source; do
  SWIFT_SOURCES+=("${source}")
done < <(find "${ROOT}/Sources/videotext" -name '*.swift' ! -path '*/App/*' ! -path '*/UI/*' | sort)
TEST_BINARY="${WORK_ROOT}/videotext-real-raw-import-probe"
swiftc -framework SwiftUI -framework AppKit -framework AVKit -framework AVFoundation -framework UserNotifications \
  -o "${TEST_BINARY}" "${SWIFT_SOURCES[@]}" "${ROOT}/Tests/RealRawImportProbe.swift"
"${TEST_BINARY}" "${RU_PACKAGE}" "${RU_MEDIA}" "${EN_PACKAGE}" "${EN_MEDIA}" "${RESULT_JSON}"
