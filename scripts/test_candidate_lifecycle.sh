#!/usr/bin/env bash
set -euo pipefail

if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${VIDEOTEXT_EPHEMERAL_WORK_ROOT:-${ROOT}/../work}"
TEST_BINARY="${WORK_ROOT}/videotext-candidate-lifecycle-probe"

if [[ $# -ne 1 ]]; then
  echo "Использование: $0 <videotext.app>" >&2
  exit 2
fi

CANDIDATE="$1"
[[ -d "$CANDIDATE" ]] || { echo "Candidate не найден: $CANDIDATE" >&2; exit 1; }

mkdir -p "$WORK_ROOT"
swiftc -parse-as-library -O -framework AppKit -o "$TEST_BINARY" "$ROOT/Tests/CandidateLifecycleProbe.swift"
"$TEST_BINARY" "$CANDIDATE"
