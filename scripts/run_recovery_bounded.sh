#!/usr/bin/env bash
set -uo pipefail

# The supervisor owns all disposable scratch, including child tool TMPDIR.
if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

if [[ $# -lt 2 || ! "$1" =~ ^[1-9][0-9]*$ ]]; then
  printf 'PROJECT_RECOVERY_FAIL: watchdog ожидает <секунды> <команда> [аргументы].\n' >&2
  exit 2
fi

TIMEOUT_SECONDS="$1"
shift
MARKER="$(mktemp "${TMPDIR:-/tmp}/videotext-recovery-timeout.XXXXXX")"
COMMAND_PID=""
WATCHDOG_PID=""

terminate_command() {
  if [[ -n "${COMMAND_PID}" ]] && kill -0 "${COMMAND_PID}" 2>/dev/null; then
    pkill -TERM -P "${COMMAND_PID}" 2>/dev/null || true
    kill -TERM "${COMMAND_PID}" 2>/dev/null || true
  fi
}

cleanup() {
  if [[ -n "${WATCHDOG_PID}" ]]; then
    kill "${WATCHDOG_PID}" 2>/dev/null || true
  fi
  terminate_command
  rm -f "${MARKER}"
}
trap cleanup EXIT INT TERM

"$@" &
COMMAND_PID=$!
(
  remaining="${TIMEOUT_SECONDS}"
  while (( remaining > 0 )); do
    if ! kill -0 "${COMMAND_PID}" 2>/dev/null; then
      exit 0
    fi
    sleep 1
    remaining=$((remaining - 1))
  done
  if kill -0 "${COMMAND_PID}" 2>/dev/null; then
    printf 'PROJECT_RECOVERY_FAIL: превышен общий лимит восстановления %s секунд.\n' "${TIMEOUT_SECONDS}" >&2
    printf 'timeout\n' > "${MARKER}"
    pkill -TERM -P "${COMMAND_PID}" 2>/dev/null || true
    kill -TERM "${COMMAND_PID}" 2>/dev/null || true
    sleep 2
    pkill -KILL -P "${COMMAND_PID}" 2>/dev/null || true
    kill -KILL "${COMMAND_PID}" 2>/dev/null || true
  fi
) &
WATCHDOG_PID=$!

wait "${COMMAND_PID}"
STATUS=$?
kill "${WATCHDOG_PID}" 2>/dev/null || true
wait "${WATCHDOG_PID}" 2>/dev/null || true
WATCHDOG_PID=""
COMMAND_PID=""

if [[ -s "${MARKER}" ]]; then
  exit 124
fi
if (( STATUS != 0 )); then
  printf 'PROJECT_RECOVERY_FAIL: recovery probe завершился с кодом %s.\n' "${STATUS}" >&2
fi
exit "${STATUS}"
