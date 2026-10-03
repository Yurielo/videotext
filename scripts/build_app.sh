#!/usr/bin/env bash
set -euo pipefail

# Contain compiler/tool scratch; explicit application/project/evidence outputs persist.
if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_APP="${ROOT}/../work/videotext-build/videotext.app"
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
cp "${ROOT}/Resources/AppIcon.icns" "${RESOURCES}/AppIcon.icns"
mkdir -p "${RESOURCES}/Branding"
cp "${ROOT}/Resources/Branding/VideoTextLogo.png" "${RESOURCES}/Branding/VideoTextLogo.png"

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
