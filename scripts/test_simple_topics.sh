#!/usr/bin/env bash
set -euo pipefail

if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${VIDEOTEXT_EPHEMERAL_WORK_ROOT:?owned_tmp.py must supply scratch}"
mkdir -p "${WORK_ROOT}"
export VIDEOTEXT_HISTORY_PATH="${WORK_ROOT}/history.json"
export VIDEOTEXT_ETA_HISTORY_PATH="${WORK_ROOT}/eta-history.json"
SWIFT_SOURCES=()
while IFS= read -r source; do
  SWIFT_SOURCES+=("$source")
done < <(find "${ROOT}/Sources/videotext" -name '*.swift' ! -path '*/App/*' ! -path '*/UI/*' | sort)

TEST_APP="${WORK_ROOT}/simple-topics-probe.app"
TEST_BINARY="${TEST_APP}/Contents/MacOS/simple-topics-probe"
mkdir -p "$(dirname "${TEST_BINARY}")"
cp "${ROOT}/Resources/Info.plist" "${TEST_APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable simple-topics-probe' "${TEST_APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.codex.videotext.simple-topics-probe' "${TEST_APP}/Contents/Info.plist"
swiftc -O -framework SwiftUI -framework AppKit -framework AVKit \
  -framework AVFoundation -framework UserNotifications \
  -o "${TEST_BINARY}" \
  "${SWIFT_SOURCES[@]}" "${ROOT}/Tests/SimpleTopicsProbe.swift"
"${TEST_BINARY}" "$@"
