#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  printf 'PROJECT_RECOVERY_FAIL: Использование: %s <video> <проект> <модель-whisper>\n' "$0" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${ROOT}/../work"
TEST_BINARY="${WORK_ROOT}/videotext-project-recovery"
RECOVERY_TIMEOUT_SECONDS="${VIDEOTEXT_RECOVERY_TIMEOUT_SECONDS:-10800}"
SWIFT_SOURCES=()

if ! [[ "${RECOVERY_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'PROJECT_RECOVERY_FAIL: VIDEOTEXT_RECOVERY_TIMEOUT_SECONDS должен быть положительным целым числом.\n' >&2
  exit 2
fi

mkdir -p "${WORK_ROOT}"
while IFS= read -r source; do
  SWIFT_SOURCES+=("$source")
done < <(find "${ROOT}/Sources/videotext" -name '*.swift' ! -path '*/App/*' ! -path '*/UI/*' | sort)

if ! swiftc \
  -O \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVKit \
  -framework AVFoundation \
  -framework UserNotifications \
  -o "${TEST_BINARY}" \
  "${SWIFT_SOURCES[@]}" \
  "${ROOT}/Tests/ProjectRecoveryProbe.swift"; then
  printf 'PROJECT_RECOVERY_FAIL: не удалось собрать recovery probe.\n' >&2
  exit 1
fi

"${ROOT}/scripts/run_recovery_bounded.sh" \
  "${RECOVERY_TIMEOUT_SECONDS}" \
  "${TEST_BINARY}" "$1" "$2" "$3"
