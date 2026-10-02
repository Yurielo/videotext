#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Historical evidence is intentionally retained in docs. Active production,
# test and release paths must never select or invoke the retired model family.
if rg -n -i 'q[w]en' "$ROOT/Sources" "$ROOT/Tests" "$ROOT/scripts"; then
  printf 'RETIRED_MODEL_RUNTIME_CHECK_FAIL: active code still references the retired model family.\n' >&2
  exit 1
fi

printf 'RETIRED_MODEL_RUNTIME_CHECK_PASS\n'
