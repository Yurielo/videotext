#!/usr/bin/env bash
set -euo pipefail

# The supervisor owns all disposable scratch, including child tool TMPDIR.
if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${VIDEOTEXT_EPHEMERAL_WORK_ROOT:-${ROOT}/../work}"
TEST_BINARY="${WORK_ROOT}/videotext-ollama-memory-manager-probe"

mkdir -p "${WORK_ROOT}"
swiftc \
  -O \
  -o "${TEST_BINARY}" \
  "${ROOT}/Sources/videotext/Services/OllamaMemoryManager.swift" \
  "${ROOT}/Tests/OllamaMemoryManagerProbe.swift"

"${TEST_BINARY}"
