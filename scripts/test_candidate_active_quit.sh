#!/usr/bin/env bash
set -euo pipefail

if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${VIDEOTEXT_EPHEMERAL_WORK_ROOT:-${ROOT}/../work}"
TEST_BINARY="${WORK_ROOT}/videotext-candidate-active-quit-probe"

if [[ $# -ne 2 ]]; then
  echo "Использование: $0 <videotext.app> <real-media>" >&2
  exit 2
fi
[[ -d "$1" ]] || { echo "Candidate не найден: $1" >&2; exit 2; }
[[ -f "$2" ]] || { echo "Media не найден: $2" >&2; exit 2; }

mkdir -p "$WORK_ROOT"
swiftc -parse-as-library -O -framework AppKit -o "$TEST_BINARY" "$ROOT/Tests/CandidateActiveQuitProbe.swift"
"$TEST_BINARY" "$1" "$2"
