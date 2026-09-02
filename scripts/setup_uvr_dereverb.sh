#!/usr/bin/env bash

set -euo pipefail

STATE_ROOT="${HOME}/Library/Application Support/videotext/audio/audio-separator"
VENV="${STATE_ROOT}/venv"
MODEL_DIR="${STATE_ROOT}/models"
PYTHON="/opt/homebrew/bin/python3.12"
MODELS=("UVR-De-Echo-Normal.pth" "UVR-De-Echo-Aggressive.pth")
MODEL_MD5S=("bcbc4bc5abcadd1d74200cf24006e2b5" "03c106e3aeb05a78ac55e72faa1095e8")

if pgrep -x videotext >/dev/null || pgrep -x whisper-cli >/dev/null || pgrep -x ffmpeg >/dev/null || pgrep -x ffprobe >/dev/null; then
  echo "Остановите videotext, whisper-cli, ffmpeg и ffprobe перед установкой UVR dereverb backend." >&2
  exit 3
fi

if [[ ! -x "${PYTHON}" ]]; then
  brew install python@3.12
fi

mkdir -p "${STATE_ROOT}" "${MODEL_DIR}"
"${PYTHON}" -m venv "${VENV}"
"${VENV}/bin/python" -m pip install --upgrade "pip==26.2"
"${VENV}/bin/python" -m pip install \
  "audio-separator[cpu]==0.44.5" \
  "audioread==3.1.0" \
  "librosa==0.10.2.post1"
"${VENV}/bin/python" -m pip check
for index in "${!MODELS[@]}"; do
  model="${MODELS[$index]}"
  "${VENV}/bin/audio-separator" \
    --model_file_dir "${MODEL_DIR}" \
    --model_filename "${model}" \
    --download_model_only

  actual_md5="$(md5 -q "${MODEL_DIR}/${model}")"
  if [[ "${actual_md5}" != "${MODEL_MD5S[$index]}" ]]; then
    echo "Неверная контрольная сумма ${model}: ${actual_md5}" >&2
    exit 4
  fi
done

"${VENV}/bin/audio-separator" --env_info
"${VENV}/bin/python" -m pip freeze > "${STATE_ROOT}/versions.txt"

echo "UVR_DEREVERB_SETUP_PASS: ${STATE_ROOT}"
echo "Удаление после теста: rm -rf '${STATE_ROOT}'"
