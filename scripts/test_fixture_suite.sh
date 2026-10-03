#!/usr/bin/env bash
set -euo pipefail
if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${TMPDIR}/fixture-suite"
mkdir -p "$WORK"
export VIDEOTEXT_HISTORY_PATH="$WORK/history.json"
export VIDEOTEXT_ETA_HISTORY_PATH="$WORK/eta-history.json"
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(find "$ROOT/Sources/videotext" -name '*.swift' ! -path '*/App/*' ! -path '*/UI/*' | sort)
# Reuse one testable core module: no app packaging or heavyweight models.
swiftc -O -whole-module-optimization -emit-library -emit-module -enable-testing \
  -module-name VideoTextFixtureCore -emit-module-path "$WORK/VideoTextFixtureCore.swiftmodule" \
  -framework SwiftUI -framework AppKit -framework AVKit -framework AVFoundation -framework UserNotifications \
  -o "$WORK/libVideoTextFixtureCore.dylib" "${SOURCES[@]}"
PROBES=(WhisperVAD TranscriptionQuality ProjectSchema HumanReview TopicAnalysis TopicMatrix ETA FillerWord QuoteRange ReviewTask SpeedAdjustment TranslationAdapter TopicPicker ProcessShutdown OllamaMemoryManager FragmentProcessing FillerMute Blur Watermark LanguageDetection)
for name in "${PROBES[@]}"; do
  printf 'RUN_FIXTURE %s\n' "$name"
  { printf '@testable import VideoTextFixtureCore\n'; cat "$ROOT/Tests/${name}Probe.swift"; } > "$WORK/${name}.swift"
  swiftc -O -parse-as-library -I "$WORK" -L "$WORK" -lVideoTextFixtureCore \
    -Xlinker -rpath -Xlinker "$WORK" -o "$WORK/$name" "$WORK/${name}.swift"
  case "$name" in
    TranscriptionQuality) "$WORK/$name" "$ROOT/Tests/Fixtures/Baseline/zero_duration_service_cue.srt" ;;
    ProjectSchema) "$WORK/$name" "$ROOT/Tests/Fixtures/Baseline/legacy_manifest_v3.json" ;;
    *) "$WORK/$name" ;;
  esac
done
"$ROOT/scripts/test_baseline_guard.sh"
"$ROOT/scripts/test_application_lifecycle.sh"
"$ROOT/scripts/test_recovery_watchdog.sh"
printf 'FIXTURE_SUITE_PASS probes=%s additional_shell_probes=3 heavy_models=0 app_builds=0\n' "${#PROBES[@]}"
