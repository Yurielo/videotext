#!/usr/bin/env bash
set -euo pipefail

# The supervisor owns all disposable scratch, including child tool TMPDIR.
if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${VIDEOTEXT_EPHEMERAL_WORK_ROOT:-${ROOT}/../work}"
SEMINARTEXT_BUNDLE="${VIDEOTEXT_SEMINARTEXT_PREPARED:-}"
REGISTRY_ROOT="${VIDEOTEXT_REGISTRY_ROOT:-$ROOT/../four-product-architecture}"
REGISTRY_PYTHON="${VIDEOTEXT_REGISTRY_PYTHON:-$REGISTRY_ROOT/.venv/bin/python}"
TEST_APP="${WORK_ROOT}/videotext-e2e.app"
TEST_BINARY="${TEST_APP}/Contents/MacOS/videotext-e2e"
SWIFT_SOURCES=()

PROFILE=""
if [[ "${1:-}" == "--profile" ]]; then
  [[ $# -ge 2 ]] || { echo "После --profile требуется core или translation" >&2; exit 2; }
  PROFILE="$2"
  shift 2
fi
if [[ -z "$PROFILE" ]]; then
  if [[ $# -eq 2 ]]; then PROFILE="core"; elif [[ $# -eq 4 ]]; then PROFILE="translation"; fi
fi
if [[ "$PROFILE" == "core" && $# -ne 2 ]] || [[ "$PROFILE" == "translation" && $# -ne 4 ]] || [[ "$PROFILE" != "core" && "$PROFILE" != "translation" ]]; then
  echo "Использование: $0 --profile core <ru-видео> <модель-whisper>" >&2
  echo "       или: $0 --profile translation <ru-видео> <модель-whisper> <en-видео> <en-проект>" >&2
  exit 2
fi

VIDEO_PATH="$1"
MODEL_PATH="$2"
EN_VIDEO_PATH="${3:-}"
EN_PROJECT_PATH="${4:-}"
mkdir -p "${WORK_ROOT}"
SOURCE_PATH="$(mktemp -d "${WORK_ROOT}/videotext-e2e-source.XXXXXX")"
RU_SOURCE_PATH="${SOURCE_PATH}/ru"
EN_SOURCE_PATH="${SOURCE_PATH}/en"
cleanup_source() {
  rm -rf -- "${SOURCE_PATH}"
}
trap cleanup_source EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export VIDEOTEXT_HISTORY_PATH="${SOURCE_PATH}/history.json"
export QA_E2E_EVIDENCE_DIR="${QA_E2E_EVIDENCE_DIR:-${SOURCE_PATH}/evidence}"
export VIDEOTEXT_E2E_PROFILE="$PROFILE"
EXTENSION="${VIDEO_PATH##*.}"
mkdir -p "${RU_SOURCE_PATH}"
TEST_VIDEO="${RU_SOURCE_PATH}/Короткое видео Юрий's test.${EXTENSION}"
cp -p "${VIDEO_PATH}" "${TEST_VIDEO}"
TEST_ARGUMENTS=("${TEST_VIDEO}" "${MODEL_PATH}")
if [[ -n "${EN_VIDEO_PATH}" ]]; then
  [[ -f "${EN_VIDEO_PATH}" ]] || { echo "Не найдено английское видео: ${EN_VIDEO_PATH}" >&2; exit 2; }
  [[ -d "${EN_PROJECT_PATH}" ]] || { echo "Не найден английский проект: ${EN_PROJECT_PATH}" >&2; exit 2; }
  EN_EXTENSION="${EN_VIDEO_PATH##*.}"
  mkdir -p "${EN_SOURCE_PATH}"
  TEST_EN_VIDEO="${EN_SOURCE_PATH}/English source.${EN_EXTENSION}"
  TEST_EN_PROJECT="${EN_SOURCE_PATH}/English source project"
  cp -p "${EN_VIDEO_PATH}" "${TEST_EN_VIDEO}"
  ditto --norsrc "${EN_PROJECT_PATH}" "${TEST_EN_PROJECT}"
  TEST_ARGUMENTS+=("${TEST_EN_VIDEO}" "${TEST_EN_PROJECT}")
fi

rm -rf "${TEST_APP}"
mkdir -p "$(dirname "${TEST_BINARY}")"
cp "${ROOT}/Resources/Info.plist" "${TEST_APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable videotext-e2e' "${TEST_APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.codex.videotext.e2e' "${TEST_APP}/Contents/Info.plist"
[[ -n "$SEMINARTEXT_BUNDLE" && -d "$SEMINARTEXT_BUNDLE" ]] || {
  echo "Missing prepared registered SeminarText bundle; run registry_integration.py prepare." >&2; exit 2;
}
[[ -f "$SEMINARTEXT_BUNDLE/FOUR_PRODUCT_REGISTRY_DEPENDENCY.json" && -x "$SEMINARTEXT_BUNDLE/seminartext" ]] || {
  echo "Prepared SeminarText bundle is incomplete." >&2; exit 2;
}
[[ -x "$REGISTRY_PYTHON" ]] || { echo "Missing supported central registry Python: $REGISTRY_PYTHON" >&2; exit 2; }
"$REGISTRY_PYTHON" "$ROOT/scripts/registry_integration.py" verify \
  --registry-root "$REGISTRY_ROOT" --bundle "$SEMINARTEXT_BUNDLE" >/dev/null || {
  echo "Prepared SeminarText bundle is not the current registered activation." >&2; exit 2;
}
mkdir -p "${TEST_APP}/Contents/Resources/SeminarText"
ditto --norsrc "$SEMINARTEXT_BUNDLE" "${TEST_APP}/Contents/Resources/SeminarText"
chmod +x "${TEST_APP}/Contents/Resources/SeminarText/seminartext"

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

"${TEST_BINARY}" "${TEST_ARGUMENTS[@]}"
