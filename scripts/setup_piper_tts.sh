#!/usr/bin/env bash

set -euo pipefail

STATE_ROOT="${HOME}/Library/Application Support/videotext/tts/piper"
VENV="${STATE_ROOT}/venv"
PYTHON="/opt/homebrew/bin/python3.12"

if pgrep -x videotext >/dev/null || pgrep -x whisper-cli >/dev/null || pgrep -x ffmpeg >/dev/null; then
  echo "Остановите videotext, whisper-cli и ffmpeg перед установкой TTS." >&2
  exit 3
fi

if [[ ! -x "${PYTHON}" ]]; then
  brew install python@3.12
fi

mkdir -p "${STATE_ROOT}"
"${PYTHON}" -m venv "${VENV}"
"${VENV}/bin/python" -m pip install --upgrade pip
"${VENV}/bin/python" -m pip install "piper-tts==1.7.0"

"${VENV}/bin/python" -m piper --help >/dev/null
echo "PIPER_TTS_SETUP_PASS: ${STATE_ROOT}"
