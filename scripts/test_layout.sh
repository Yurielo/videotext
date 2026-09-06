#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${ROOT}/../work"
TEST_APP="${WORK_ROOT}/videotext-layout-probe.app"
TEST_BINARY="${TEST_APP}/Contents/MacOS/videotext-layout-probe"
TEST_STATE="${WORK_ROOT}/layout-probe-state"
OUTPUT_IMAGE="${1:-${WORK_ROOT}/videotext-layout-980x680.png}"
SWIFT_SOURCES=()

rm -rf "${TEST_APP}" "${TEST_STATE}"
mkdir -p "$(dirname "${TEST_BINARY}")" "$(dirname "${OUTPUT_IMAGE}")" "${TEST_STATE}"
mkdir -p "${TEST_APP}/Contents/Resources"
export VIDEOTEXT_HISTORY_PATH="${TEST_STATE}/history.json"
export VIDEOTEXT_ETA_HISTORY_PATH="${TEST_STATE}/eta-history.json"
cp "${ROOT}/Resources/Info.plist" "${TEST_APP}/Contents/Info.plist"
cp "${ROOT}/Resources/AppIcon.icns" "${TEST_APP}/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable videotext-layout-probe' "${TEST_APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.codex.videotext.layout-probe' "${TEST_APP}/Contents/Info.plist"
while IFS= read -r source; do
  SWIFT_SOURCES+=("$source")
done < <(find "${ROOT}/Sources/videotext" -name '*.swift' ! -path '*/App/*' | sort)

swiftc \
  -O \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVKit \
  -framework AVFoundation \
  -framework UserNotifications \
  -o "${TEST_BINARY}" \
  "${SWIFT_SOURCES[@]}" \
  "${ROOT}/Tests/LayoutProbe.swift"

"${TEST_BINARY}" "${OUTPUT_IMAGE}"
