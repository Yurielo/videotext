#!/usr/bin/env bash

set -euo pipefail

# The supervisor owns all disposable scratch, including child tool TMPDIR.
if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${VIDEOTEXT_EPHEMERAL_WORK_ROOT:-${ROOT}/../work}"
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
