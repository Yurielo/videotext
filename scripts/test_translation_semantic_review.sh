#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 && !( $# -eq 1 && "$1" == "--check-alarms" ) ]]; then
  echo "Usage: $0 <approved-review-fixture.json> <output.json> OR --check-alarms" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${ROOT}/../work"
TEST_BINARY="${WORK_ROOT}/videotext-translation-semantic-review-probe"
SWIFT_SOURCES=()
mkdir -p "${WORK_ROOT}"
while IFS= read -r source; do
  SWIFT_SOURCES+=("$source")
done < <(find "${ROOT}/Sources/videotext" -name '*.swift' ! -path '*/App/*' ! -path '*/UI/*' | sort)

swiftc -O -framework SwiftUI -framework AppKit -framework AVKit \
  -framework AVFoundation -framework UserNotifications \
  -o "${TEST_BINARY}" "${SWIFT_SOURCES[@]}" "${ROOT}/Tests/TranslationSemanticReviewProbe.swift"

"${TEST_BINARY}" "$@"
