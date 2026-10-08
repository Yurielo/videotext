#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 && !( $# -eq 1 && "$1" == "--self-test" ) && !( $# -eq 4 && "$3" == "--request-override" ) ]]; then
  echo "Usage: $0 fixture.json output-dir [--request-override request.json] OR --self-test" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${ROOT}/../work"
TEST_SOURCE="${ROOT}/Tests/TranslationCausalTraceProbe.swift"
SWIFT_SOURCES=()
mkdir -p "${WORK_ROOT}"
EVIDENCE_DIR="$(mktemp -d "${WORK_ROOT}/translation-causal-trace-build.XXXXXX")"
TEST_BINARY="${EVIDENCE_DIR}/videotext-translation-causal-trace-probe"
exec > >(tee "${EVIDENCE_DIR}/compile-run.log") 2>&1
trap 'status=$?; printf "exit_status=%s\n" "${status}" | tee "${EVIDENCE_DIR}/exit-status.txt"' EXIT
printf 'build_evidence=%s\n' "${EVIDENCE_DIR}"
date -u '+started_at=%Y-%m-%dT%H:%M:%SZ'
export TRACE_SOURCE_HEAD="$(git -C "${ROOT}" rev-parse HEAD)"
export TRACE_BUILD_INPUT_MANIFEST="${EVIDENCE_DIR}/inputs-sha256.before"
swiftc --version
while IFS= read -r source; do
  SWIFT_SOURCES+=("$source")
done < <(rg --files "${ROOT}/Sources/videotext" -g '*.swift' -g '!**/App/**' -g '!**/UI/**' | sort)
INPUT_SIGNATURE="$(shasum -a 256 "${SWIFT_SOURCES[@]}" "${TEST_SOURCE}")"
printf '%s\n' "${INPUT_SIGNATURE}" > "${TRACE_BUILD_INPUT_MANIFEST}"
swiftc -O -framework SwiftUI -framework AppKit -framework AVKit \
  -framework AVFoundation -framework UserNotifications \
  -o "${TEST_BINARY}" "${SWIFT_SOURCES[@]}" "${TEST_SOURCE}"
AFTER_SIGNATURE="$(shasum -a 256 "${SWIFT_SOURCES[@]}" "${TEST_SOURCE}")"
printf '%s\n' "${AFTER_SIGNATURE}" > "${EVIDENCE_DIR}/inputs-sha256.after"
if [[ "${INPUT_SIGNATURE}" != "${AFTER_SIGNATURE}" ]]; then
  echo "TRANSLATION_CAUSAL_TRACE_FAIL: compile inputs changed" >&2
  exit 1
fi
shasum -a 256 "${TEST_BINARY}" > "${EVIDENCE_DIR}/binary-sha256.txt"
"${TEST_BINARY}" "$@"
