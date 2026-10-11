#!/usr/bin/env bash
set -euo pipefail

if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_MEDIA="${1:?Usage: $0 <Short-RU.mp4> <whisper-model> <new-evidence-root>}"
WHISPER_MODEL="${2:?Usage: $0 <Short-RU.mp4> <whisper-model> <new-evidence-root>}"
EVIDENCE_ROOT="${3:?Usage: $0 <Short-RU.mp4> <whisper-model> <new-evidence-root>}"
WORK_ROOT="${VIDEOTEXT_EPHEMERAL_WORK_ROOT:?owned_tmp.py must supply scratch}"
[[ -f "${SOURCE_MEDIA}" && -r "${SOURCE_MEDIA}" ]] || { echo "Missing source media" >&2; exit 2; }
[[ -f "${WHISPER_MODEL}" && -r "${WHISPER_MODEL}" ]] || { echo "Missing Whisper model" >&2; exit 2; }
[[ -x "${ROOT}/Resources/SeminarText/seminartext" ]] || { echo "Missing bundled SeminarText" >&2; exit 2; }
[[ ! -e "${EVIDENCE_ROOT}" ]] || { echo "Evidence root must be new: ${EVIDENCE_ROOT}" >&2; exit 2; }
mkdir -p "${EVIDENCE_ROOT}" "${WORK_ROOT}"
export VIDEOTEXT_HISTORY_PATH="${WORK_ROOT}/history.json"
export VIDEOTEXT_ETA_HISTORY_PATH="${WORK_ROOT}/eta-history.json"

SWIFT_SOURCES=()
while IFS= read -r source; do
  SWIFT_SOURCES+=("${source}")
done < <(find "${ROOT}/Sources/videotext" -name '*.swift' ! -path '*/App/*' ! -path '*/UI/*' | sort)

TEST_APP="${WORK_ROOT}/simple-transcription-real-probe.app"
TEST_BINARY="${TEST_APP}/Contents/MacOS/simple-transcription-real-probe"
mkdir -p "$(dirname "${TEST_BINARY}")" "${TEST_APP}/Contents/Resources"
cp "${ROOT}/Resources/Info.plist" "${TEST_APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable simple-transcription-real-probe' "${TEST_APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.codex.videotext.simple-transcription-real-probe' "${TEST_APP}/Contents/Info.plist"
ditto --norsrc "${ROOT}/Resources/SeminarText" "${TEST_APP}/Contents/Resources/SeminarText"
swiftc -O -framework SwiftUI -framework AppKit -framework AVKit \
  -framework AVFoundation -framework UserNotifications \
  -o "${TEST_BINARY}" "${SWIFT_SOURCES[@]}" "${ROOT}/Tests/SimpleTranscriptionRealProbe.swift"

VIDEOTEXT_SIMPLE_REAL_MEDIA="${SOURCE_MEDIA}" \
VIDEOTEXT_SIMPLE_REAL_MODEL="${WHISPER_MODEL}" \
VIDEOTEXT_SIMPLE_REAL_ROOT="${EVIDENCE_ROOT}" \
"${TEST_BINARY}" 2>&1 | tee "${EVIDENCE_ROOT}/probe.log"
printf 'SIMPLE_TRANSCRIPTION_REAL_ROOT=%s\n' "${EVIDENCE_ROOT}"
