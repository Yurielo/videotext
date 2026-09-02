#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${ROOT}/../work"
BINARY="${WORK_ROOT}/videotext-topic-picker-probe"

mkdir -p "${WORK_ROOT}"
swiftc \
  -O \
  -framework AppKit \
  -o "${BINARY}" \
  "${ROOT}/Sources/videotext/Core/Models.swift" \
  "${ROOT}/Sources/videotext/Core/ArtifactModels.swift" \
  "${ROOT}/Sources/videotext/Services/ProgressTracker.swift" \
  "${ROOT}/Sources/videotext/Services/TimecodeParser.swift" \
  "${ROOT}/Tests/TopicPickerProbe.swift"

"${BINARY}"
