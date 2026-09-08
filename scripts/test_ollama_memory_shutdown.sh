#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${ROOT}/../work"
TEST_BINARY="${WORK_ROOT}/videotext-ollama-memory-manager-probe"

mkdir -p "${WORK_ROOT}"
swiftc \
  -O \
  -o "${TEST_BINARY}" \
  "${ROOT}/Sources/videotext/Services/OllamaMemoryManager.swift" \
  "${ROOT}/Tests/OllamaMemoryManagerProbe.swift"

"${TEST_BINARY}"
