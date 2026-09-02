#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_APP="${TMPDIR:-/private/tmp}/videotext-build/videotext.app"
APP="${VIDEOTEXT_APP_PATH:-${DEFAULT_APP}}"
CONTENTS="${APP}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"
SWIFT_SOURCES=()

while IFS= read -r source; do
  SWIFT_SOURCES+=("$source")
done < <(find "${ROOT}/Sources/videotext" -name '*.swift' | sort)

rm -rf "${APP}"
mkdir -p "${MACOS}" "${RESOURCES}"
cp "${ROOT}/Resources/Info.plist" "${CONTENTS}/Info.plist"

swiftc \
  -O \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVKit \
  -framework AVFoundation \
  -framework UserNotifications \
  -o "${MACOS}/videotext" \
  "${SWIFT_SOURCES[@]}"

chmod +x "${MACOS}/videotext"
plutil -lint "${CONTENTS}/Info.plist"
if command -v SetFile >/dev/null 2>&1; then
  SetFile -a e "${APP}"
  sleep 1
fi
xattr -cr "${APP}"
xattr -d com.apple.FinderInfo "${APP}" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "${APP}" 2>/dev/null || true
codesign --force --deep --sign - "${APP}"
codesign --verify --deep --strict "${APP}"

echo "${APP}"
