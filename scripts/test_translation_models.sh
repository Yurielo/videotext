#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${ROOT}/../work"
TEST_BINARY="${WORK_ROOT}/videotext-translation-model-benchmark"
REPORT="${WORK_ROOT}/translation-model-benchmark.json"
TEST_STATE="${WORK_ROOT}/translation-model-benchmark-state"
OLLAMA="/Applications/Ollama.app/Contents/Resources/ollama"
SWIFT_SOURCES=()

rm -rf "${TEST_STATE}"
mkdir -p "${WORK_ROOT}" "${TEST_STATE}"
export VIDEOTEXT_HISTORY_PATH="${TEST_STATE}/history.json"
export VIDEOTEXT_ETA_HISTORY_PATH="${TEST_STATE}/eta-history.json"

if [[ ! -x "${OLLAMA}" ]]; then
  OLLAMA="$(command -v ollama)"
fi

cleanup() {
  "${OLLAMA}" stop translategemma:4b >/dev/null 2>&1 || true
}
trap cleanup EXIT

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
  "${ROOT}/Tests/TranslationModelBenchmark.swift"

"${TEST_BINARY}" "${REPORT}"
