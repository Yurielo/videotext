#!/usr/bin/env bash
set -euo pipefail

# The supervisor owns all disposable scratch, including child tool TMPDIR.
if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/private/tmp}/videotext-baseline-guard.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
APP="$TEMP/videotext.app"
mkdir -p "$APP/Contents"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
SOURCE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

VIDEOTEXT_INSTALLED_APP="$APP" "$ROOT/scripts/check_baseline.sh" > "$TEMP/pass.log"
grep -q '^BASELINE_OK:' "$TEMP/pass.log"

/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 9999.0.0' "$APP/Contents/Info.plist"
if VIDEOTEXT_INSTALLED_APP="$APP" "$ROOT/scripts/check_baseline.sh" > "$TEMP/fail.log" 2>&1; then
  printf 'Expected newer installed version to block promotion\n' >&2
  exit 1
fi
grep -q '^BASELINE_DIVERGENCE: installed 9999.0.0/' "$TEMP/fail.log"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 9999.1.1' "$APP/Contents/Info.plist"
if VIDEOTEXT_INSTALLED_APP="$APP" "$ROOT/scripts/check_baseline.sh" > "$TEMP/fail.log" 2>&1; then
  printf 'Expected newer installed build to block promotion\n' >&2
  exit 1
fi
grep -q "^BASELINE_DIVERGENCE: installed $SOURCE_VERSION/9999.1.1" "$TEMP/fail.log"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier wrong.bundle' "$APP/Contents/Info.plist"
if VIDEOTEXT_INSTALLED_APP="$APP" "$ROOT/scripts/check_baseline.sh" > "$TEMP/fail.log" 2>&1; then
  printf 'Expected different bundle ID to block promotion\n' >&2
  exit 1
fi
grep -q '^BASELINE_DIVERGENCE: installed app bundle ID differs:' "$TEMP/fail.log"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.0.0' "$APP/Contents/Info.plist"
VIDEOTEXT_INSTALLED_APP="$APP" "$ROOT/scripts/check_baseline.sh" > "$TEMP/pass.log"
grep -q '^BASELINE_OK:' "$TEMP/pass.log"

printf 'BASELINE_GUARD_PASS\n'
