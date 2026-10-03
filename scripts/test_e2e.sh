#!/usr/bin/env bash
set -euo pipefail

# The supervisor owns all disposable scratch, including child tool TMPDIR.
if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${VIDEOTEXT_EPHEMERAL_WORK_ROOT:-${ROOT}/../work}"
TEST_APP="${WORK_ROOT}/videotext-e2e.app"
TEST_BINARY="${TEST_APP}/Contents/MacOS/videotext-e2e"
SWIFT_SOURCES=()

if [[ $# -ne 2 ]]; then
  echo "Использование: $0 <короткое-видео> <модель-whisper>" >&2
  exit 2
fi

VIDEO_PATH="$1"
MODEL_PATH="$2"
mkdir -p "${WORK_ROOT}"
SOURCE_PATH="$(mktemp -d "${WORK_ROOT}/videotext-e2e-source.XXXXXX")"
cleanup_source() {
  rm -rf -- "${SOURCE_PATH}"
}
trap cleanup_source EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export VIDEOTEXT_HISTORY_PATH="${SOURCE_PATH}/history.json"
export QA_E2E_EVIDENCE_DIR="${QA_E2E_EVIDENCE_DIR:-${SOURCE_PATH}/evidence}"
EXTENSION="${VIDEO_PATH##*.}"
TEST_VIDEO="${SOURCE_PATH}/Короткое видео Юрий's test.${EXTENSION}"
cp "${VIDEO_PATH}" "${TEST_VIDEO}"

rm -rf "${TEST_APP}"
mkdir -p "$(dirname "${TEST_BINARY}")"
cp "${ROOT}/Resources/Info.plist" "${TEST_APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable videotext-e2e' "${TEST_APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.codex.videotext.e2e' "${TEST_APP}/Contents/Info.plist"

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
  "${ROOT}/Tests/EndToEnd.swift"

"${TEST_BINARY}" "${TEST_VIDEO}" "${MODEL_PATH}"
