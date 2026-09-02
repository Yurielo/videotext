#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${ROOT}/../work"
APP="${WORK_ROOT}/videotext-notification-probe.app"
MACOS="${APP}/Contents/MacOS"
RESULT="${WORK_ROOT}/videotext-notification-probe.log"

if [[ $# -ne 1 ]]; then
  echo "Использование: $0 <папка-проекта>" >&2
  exit 2
fi

rm -rf "${APP}"
mkdir -p "${MACOS}"
cp "${ROOT}/Tests/NotificationProbe-Info.plist" "${APP}/Contents/Info.plist"

swiftc \
  -O \
  -framework AppKit \
  -framework UserNotifications \
  -o "${MACOS}/videotext-notification-probe" \
  "${ROOT}/Sources/videotext/Core/Models.swift" \
  "${ROOT}/Sources/videotext/Services/ProgressTracker.swift" \
  "${ROOT}/Sources/videotext/Services/NotificationService.swift" \
  "${ROOT}/Tests/NotificationProbe.swift"

xattr -cr "${APP}"
xattr -d com.apple.FinderInfo "${APP}" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "${APP}" 2>/dev/null || true
codesign --force --deep --sign - "${APP}"
: >"${RESULT}"
"${MACOS}/videotext-notification-probe" "$1" >"${RESULT}" 2>&1 &
PROBE_PID=$!

for _ in $(seq 1 100); do
  if ! kill -0 "${PROBE_PID}" 2>/dev/null; then
    set +e
    wait "${PROBE_PID}"
    STATUS=$?
    set -e
    cat "${RESULT}"
    exit "${STATUS}"
  fi
  sleep 0.1
done

kill "${PROBE_PID}" 2>/dev/null || true
wait "${PROBE_PID}" 2>/dev/null || true
cat "${RESULT}"
echo "NOTIFICATION_TEST_TIMEOUT=permission-not-confirmed" >&2
exit 4
