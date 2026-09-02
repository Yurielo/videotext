#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${ROOT}/../work"
TEST_BINARY="${WORK_ROOT}/videotext-long-topic-probe"
TEST_PROJECT="${WORK_ROOT}/videotext-long-topic-project"
SWIFT_SOURCES=()
mkdir -p "${WORK_ROOT}"

if [[ $# -ne 1 ]]; then
  echo "Использование: $0 <длинный-full.srt>" >&2
  exit 2
fi

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
  "${ROOT}/Tests/LongTopicProbe.swift"

"${TEST_BINARY}" "$1" "${TEST_PROJECT}"
