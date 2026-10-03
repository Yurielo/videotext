#!/usr/bin/env bash
set -euo pipefail

# The supervisor owns all disposable scratch, including child tool TMPDIR.
if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="${ROOT}/scripts/run_recovery_bounded.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/videotext-watchdog-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

"${RUNNER}" 5 /bin/sh -c 'printf "PROJECT_RECOVERY_PASS\n"' > "${WORK}/pass.out" 2>&1
grep -q 'PROJECT_RECOVERY_PASS' "${WORK}/pass.out"

set +e
"${RUNNER}" 1 /bin/sleep 10 > "${WORK}/timeout.out" 2>&1
STATUS=$?
set -e
if [[ ${STATUS} -ne 124 ]]; then
  printf 'RECOVERY WATCHDOG PROBE FAIL: ожидался код 124, получен %s.\n' "${STATUS}" >&2
  exit 1
fi
grep -q 'PROJECT_RECOVERY_FAIL: превышен общий лимит восстановления 1 секунд.' "${WORK}/timeout.out"

printf 'RECOVERY WATCHDOG PROBE PASS\n'
