#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 && $# -ne 6 ]]; then
  echo "Usage: $0 <media> <prepared-wav> <model> <duration-seconds> <output-project> [context-file]" >&2
  exit 64
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${ROOT}/../work"
BINARY="${WORK_ROOT}/videotext-issue-6-long-russian-probe"
SOURCES=()

mkdir -p "${WORK_ROOT}"
while IFS= read -r source; do
  SOURCES+=("$source")
done < <(find "${ROOT}/Sources/videotext" -name '*.swift' ! -path '*/App/*' ! -path '*/UI/*' | sort)

swiftc \
  -O \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVKit \
  -framework AVFoundation \
  -framework UserNotifications \
  -o "${BINARY}" \
  "${SOURCES[@]}" \
  "${ROOT}/Tests/Issue6LongRussianProbe.swift"

"${BINARY}" "$@"
