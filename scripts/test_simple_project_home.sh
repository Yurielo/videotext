#!/usr/bin/env bash
set -euo pipefail

if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${VIDEOTEXT_EPHEMERAL_WORK_ROOT:-${ROOT}/../work}"
TEST_BINARY="${WORK_ROOT}/videotext-simple-project-home-probe"
SWIFT_SOURCES=()

mkdir -p "${WORK_ROOT}"
SWIFT_SOURCES=(
  "${ROOT}/Sources/videotext/Core/Models.swift"
  "${ROOT}/Sources/videotext/Core/ProjectLayout.swift"
  "${ROOT}/Sources/videotext/Core/ArtifactModels.swift"
  "${ROOT}/Sources/videotext/Services/SimpleProjectHomeState.swift"
)

swiftc \
  -O \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVKit \
  -framework AVFoundation \
  -framework UserNotifications \
  -o "${TEST_BINARY}" \
  "${SWIFT_SOURCES[@]}" \
  "${ROOT}/Tests/SimpleProjectHomeProbe.swift"

"${TEST_BINARY}"
