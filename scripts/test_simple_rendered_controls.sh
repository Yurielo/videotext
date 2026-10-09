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
done < <(find "${ROOT}/Sources/videotext" -name '*.swift' ! -path '*/App/*' | sort)

# NotificationService requires bundle identity even in a rendered UI probe.
TEST_APP="${VIDEOTEXT_UI_PROBE_APP:-${WORK_ROOT}/simple-rendered-controls-probe.app}"
TEST_BINARY="${TEST_APP}/Contents/MacOS/simple-rendered-controls-probe"
mkdir -p "$(dirname "${TEST_BINARY}")"
cp "${ROOT}/Resources/Info.plist" "${TEST_APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable simple-rendered-controls-probe' "${TEST_APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.codex.videotext.simple-rendered-probe' "${TEST_APP}/Contents/Info.plist"
swiftc -O -framework SwiftUI -framework AppKit -framework AVKit \
  -framework AVFoundation -framework UserNotifications \
  -o "${TEST_BINARY}" \
  "${SWIFT_SOURCES[@]}" "${ROOT}/Tests/SimpleRenderedControlsProbe.swift"
"${TEST_BINARY}" "$@"
