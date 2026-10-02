#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACCEPTED_BASELINE="c4d851c9b39b2aeb696a12aa357d1ae0df350cd3"
INSTALLED_APP="${VIDEOTEXT_INSTALLED_APP:-$HOME/Applications/videotext.app}"

diverged() {
  printf 'BASELINE_DIVERGENCE: %s\n' "$1" >&2
  exit 1
}

is_newer() {
  local left_version="$1" right_version="$2" index left_part right_part
  local -a left_parts right_parts
  [[ "$left_version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || diverged "invalid installed version: $left_version"
  [[ "$right_version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || diverged "invalid source version: $right_version"
  IFS=. read -r -a left_parts <<< "$left_version"
  IFS=. read -r -a right_parts <<< "$right_version"
  for ((index = 0; index < ${#left_parts[@]} || index < ${#right_parts[@]}; index++)); do
    left_part="${left_parts[index]:-0}"
    right_part="${right_parts[index]:-0}"
    left_part=$((10#$left_part))
    right_part=$((10#$right_part))
    ((left_part > right_part)) && return 0
    ((left_part < right_part)) && return 1
  done
  return 1
}

git -C "$ROOT" cat-file -e "${ACCEPTED_BASELINE}^{commit}" 2>/dev/null || \
  diverged "accepted 0.6.8 baseline commit is unavailable; fetch full Git history"
git -C "$ROOT" merge-base --is-ancestor "$ACCEPTED_BASELINE" HEAD || \
  diverged "HEAD omits accepted 0.6.8 production baseline $ACCEPTED_BASELINE"

SOURCE_VERSION="$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' "$ROOT/Sources/videotext/Core/Models.swift" | head -1)"
SOURCE_BUILD="$(sed -n 's/.*static let build = "\([^"]*\)".*/\1/p' "$ROOT/Sources/videotext/Core/Models.swift" | head -1)"
[[ -n "$SOURCE_VERSION" && -n "$SOURCE_BUILD" ]] || diverged "source BuildInfo is missing"

if [[ "$(uname -s)" == "Darwin" ]]; then
  SOURCE_PLIST="$ROOT/Resources/Info.plist"
  PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_PLIST")"
  PLIST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_PLIST")"
  [[ "$PLIST_VERSION" == "$SOURCE_VERSION" && "$PLIST_BUILD" == "$SOURCE_BUILD" ]] || \
    diverged "source Info.plist and BuildInfo version/build differ"

  if [[ -e "$INSTALLED_APP" ]]; then
    INSTALLED_PLIST="$INSTALLED_APP/Contents/Info.plist"
    [[ -f "$INSTALLED_PLIST" ]] || diverged "installed app has no Info.plist: $INSTALLED_APP"
    SOURCE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_PLIST")"
    INSTALLED_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED_PLIST")"
    [[ "$SOURCE_ID" == "$INSTALLED_ID" ]] || diverged "installed app bundle ID differs: $INSTALLED_ID"
    INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED_PLIST")"
    INSTALLED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED_PLIST")"
    if is_newer "$INSTALLED_VERSION" "$SOURCE_VERSION" || \
       { [[ "$INSTALLED_VERSION" == "$SOURCE_VERSION" ]] && is_newer "$INSTALLED_BUILD" "$SOURCE_BUILD"; }; then
      diverged "installed $INSTALLED_VERSION/$INSTALLED_BUILD is newer than source $SOURCE_VERSION/$SOURCE_BUILD; reconcile the development baseline before promotion"
    fi
  fi
fi

printf 'BASELINE_OK: %s/%s includes %s\n' "$SOURCE_VERSION" "$SOURCE_BUILD" "$ACCEPTED_BASELINE"
