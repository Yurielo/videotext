#!/usr/bin/env bash

set -euo pipefail

STATE_ROOT="${HOME}/Library/Application Support/videotext/audio/nara-wpe"
VENV="${STATE_ROOT}/venv"
PYTHON="/opt/homebrew/bin/python3.12"

if pgrep -x videotext >/dev/null || pgrep -x whisper-cli >/dev/null || pgrep -x ffmpeg >/dev/null || pgrep -x ffprobe >/dev/null; then
  echo "Остановите videotext, whisper-cli, ffmpeg и ffprobe перед установкой dereverb backend." >&2
  exit 3
fi

if [[ ! -x "${PYTHON}" ]]; then
  brew install python@3.12
fi

mkdir -p "${STATE_ROOT}"
"${PYTHON}" -m venv "${VENV}"
"${VENV}/bin/python" -m pip install --upgrade "pip==26.2"
"${VENV}/bin/python" -m pip install \
  "nara-wpe==0.0.11" \
  "numpy==2.5.2" \
  "Bottleneck==1.6.0" \
  "soundfile==0.14.0" \
  "scipy==1.18.1" \
  "click==8.5.0" \
  "tqdm==4.70.0"
"${VENV}/bin/python" -m pip check
"${VENV}/bin/python" -c 'import bottleneck, nara_wpe, numpy, scipy, soundfile; from nara_wpe.utils import istft, stft; from nara_wpe.wpe import wpe; print("NARA_WPE_IMPORT_PASS")'
"${VENV}/bin/python" -m pip freeze > "${STATE_ROOT}/versions.txt"

echo "NARA_WPE_SETUP_PASS: ${STATE_ROOT}"
