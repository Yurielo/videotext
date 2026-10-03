#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${ROOT}/../work"
TEST_BINARY="${WORK_ROOT}/videotext-translation-ownership-probe"
TEST_SOURCE="${ROOT}/Tests/TranslationOwnershipProbe.swift"
SWIFT_SOURCES=()

mkdir -p "${WORK_ROOT}"
EVIDENCE_DIR="$(mktemp -d "${WORK_ROOT}/translation-ownership-evidence.XXXXXX")"
exec > >(tee "${EVIDENCE_DIR}/run.log") 2>&1
trap 'status=$?; printf "exit_status=%s\n" "${status}" | tee "${EVIDENCE_DIR}/exit-status.txt"' EXIT
printf 'evidence_directory=%s\ncommand=bash scripts/test_translation_ownership.sh\n' "${EVIDENCE_DIR}"
date -u '+started_at=%Y-%m-%dT%H:%M:%SZ'
while IFS= read -r source; do
  SWIFT_SOURCES+=("$source")
done < <(rg --files "${ROOT}/Sources/videotext" -g '*.swift' -g '!**/App/**' -g '!**/UI/**' | sort)

INPUT_SIGNATURE="$(shasum -a 256 "${SWIFT_SOURCES[@]}" "${TEST_SOURCE}")"
printf '%s\n' "${INPUT_SIGNATURE}" > "${EVIDENCE_DIR}/inputs-sha256.before"
shasum -a 256 "${SWIFT_SOURCES[@]}" > "${EVIDENCE_DIR}/sources-sha256.before"
printf 'compiled_source_manifest_sha256=%s\n' "$(shasum -a 256 "${EVIDENCE_DIR}/sources-sha256.before")"
swiftc \
  -O \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVKit \
  -framework AVFoundation \
  -framework UserNotifications \
  -o "${TEST_BINARY}" \
  "${SWIFT_SOURCES[@]}" \
  "${TEST_SOURCE}"

FINAL_SIGNATURE="$(shasum -a 256 "${SWIFT_SOURCES[@]}" "${TEST_SOURCE}")"
printf '%s\n' "${FINAL_SIGNATURE}" > "${EVIDENCE_DIR}/inputs-sha256.after"
shasum -a 256 "${SWIFT_SOURCES[@]}" > "${EVIDENCE_DIR}/sources-sha256.after"
if [[ "${INPUT_SIGNATURE}" != "${FINAL_SIGNATURE}" ]]; then
  echo "TRANSLATION_OWNERSHIP_PROBE_FAIL: inputs changed during compilation" >&2
  exit 1
fi
printf 'compile_inputs_unchanged=true\n'

"${TEST_BINARY}"
