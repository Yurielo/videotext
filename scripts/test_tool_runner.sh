#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${ROOT}/../work"
TEST_BINARY="${WORK_ROOT}/videotext-tool-runner-probe"
SWIFT_SOURCES=()

if [[ $# -ne 1 ]]; then
  echo "Использование: $0 <короткое-видео>" >&2
  exit 2
fi

mkdir -p "${WORK_ROOT}"
while IFS= read -r source; do
  SWIFT_SOURCES+=("$source")
done < <(find "${ROOT}/Sources/videotext" -name '*.swift' ! -path '*/App/*' ! -path '*/UI/*' | sort)

swiftc \
  -O \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVKit \
  -framework AVFoundation \
  -framework UserNotifications \
  -o "${TEST_BINARY}" \
  "${SWIFT_SOURCES[@]}" \
  "${ROOT}/Tests/ToolRunnerProbe.swift"

"${TEST_BINARY}" "$1"
