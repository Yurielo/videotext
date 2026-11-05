#!/usr/bin/env bash
set -euo pipefail

# Contain compiler/tool scratch; explicit application/project/evidence outputs persist.
if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_APP="${ROOT}/../work/videotext-build/videotext.app"
APP="${VIDEOTEXT_APP_PATH:-${DEFAULT_APP}}"
SEMINARTEXT_BUNDLE="${VIDEOTEXT_SEMINARTEXT_PREPARED:-}"
REGISTRY_ROOT="${VIDEOTEXT_REGISTRY_ROOT:-$ROOT/../four-product-architecture}"
REGISTRY_PYTHON="${VIDEOTEXT_REGISTRY_PYTHON:-$REGISTRY_ROOT/.venv/bin/python}"
CONTENTS="${APP}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"
SWIFT_SOURCES=()

while IFS= read -r source; do
  SWIFT_SOURCES+=("$source")
done < <(find "${ROOT}/Sources/videotext" -name '*.swift' | sort)

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

rm -rf "${APP}"
mkdir -p "${MACOS}" "${RESOURCES}"
cp "${ROOT}/Resources/Info.plist" "${CONTENTS}/Info.plist"
cp "${ROOT}/Resources/AppIcon.icns" "${RESOURCES}/AppIcon.icns"
mkdir -p "${RESOURCES}/Branding"
cp "${ROOT}/Resources/Branding/VideoTextLogo.png" "${RESOURCES}/Branding/VideoTextLogo.png"
mkdir -p "${RESOURCES}/SeminarText"
ditto --norsrc "$SEMINARTEXT_BUNDLE" "${RESOURCES}/SeminarText"
chmod +x "${RESOURCES}/SeminarText/seminartext"

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
