#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${ROOT}/../work"
TEST_APP="${WORK_ROOT}/videotext-icon-probe.app"

VIDEOTEXT_APP_PATH="${TEST_APP}" "${ROOT}/scripts/build_app.sh" >/dev/null

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "${TEST_APP}/Contents/Info.plist")" == "AppIcon" ]]
[[ -s "${TEST_APP}/Contents/Resources/AppIcon.icns" ]]
[[ -s "${TEST_APP}/Contents/Resources/Branding/VideoTextLogo.png" ]]
codesign --verify --deep --strict "${TEST_APP}"
sips -g pixelWidth -g pixelHeight -g hasAlpha \
  "${TEST_APP}/Contents/Resources/Branding/VideoTextLogo.png" | \
  grep -Eq 'pixelWidth: 1024|pixelHeight: 1024|hasAlpha: yes'

printf 'APP_ICON_PROBE_PASS\n'
