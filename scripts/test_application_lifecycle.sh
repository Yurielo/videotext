#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${ROOT}/../work"
TEST_BINARY="${WORK_ROOT}/videotext-application-lifecycle-probe"

mkdir -p "${WORK_ROOT}"
swiftc \
  -framework AppKit \
  -o "${TEST_BINARY}" \
  "${ROOT}/Sources/videotext/Core/ApplicationTerminationHandling.swift" \
  "${ROOT}/Sources/videotext/App/ApplicationLifecycle.swift" \
  "${ROOT}/Tests/ApplicationLifecycleProbe.swift"

"${TEST_BINARY}"
