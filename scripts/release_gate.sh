#!/bin/bash

set -euo pipefail

# Contain compiler/tool scratch; explicit application/project/evidence outputs persist.
if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="$ROOT/../work"
OUTPUT_ROOT="$ROOT/../outputs"
FINAL_LINK="$OUTPUT_ROOT/videotext.app"
PROMOTE=false
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

usage() {
  printf 'Использование: %s <ru-видео> <модель-whisper> <en-видео> <en-проект> [--promote]\n' "$0"
}

if [[ $# -lt 4 || $# -gt 5 ]]; then
  usage >&2
  exit 2
fi

VIDEO_PATH="$1"
MODEL_PATH="$2"
EN_VIDEO_PATH="$3"
EN_PROJECT_PATH="$4"
if [[ $# -eq 5 ]]; then
  [[ "$5" == "--promote" ]] || { usage >&2; exit 2; }
  PROMOTE=true
fi

[[ -f "$VIDEO_PATH" ]] || { printf 'Не найдено RU-видео: %s\n' "$VIDEO_PATH" >&2; exit 2; }
[[ -f "$MODEL_PATH" ]] || { printf 'Не найдена модель Whisper: %s\n' "$MODEL_PATH" >&2; exit 2; }
[[ -f "$EN_VIDEO_PATH" ]] || { printf 'Не найдено EN-видео: %s\n' "$EN_VIDEO_PATH" >&2; exit 2; }
[[ -d "$EN_PROJECT_PATH" ]] || { printf 'Не найден EN-проект: %s\n' "$EN_PROJECT_PATH" >&2; exit 2; }
[[ -f "$EN_PROJECT_PATH/Support files/manifest.json" ]] || {
  printf 'В EN-проекте нет manifest.json: %s\n' "$EN_PROJECT_PATH" >&2
  exit 2
}
[[ -f "$EN_PROJECT_PATH/Texts/full.srt" ]] || {
  printf 'В EN-проекте нет full.srt: %s\n' "$EN_PROJECT_PATH" >&2
  exit 2
}

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
RUN_DIR="$WORK_ROOT/release-gate/$STAMP"
CANDIDATE_ROOT="${VIDEOTEXT_CANDIDATE_ROOT:-/private/tmp/videotext-release-candidate-$STAMP}"
CANDIDATE="$CANDIDATE_ROOT/videotext.app"
EVIDENCE="$RUN_DIR/evidence.env"
mkdir -p "$RUN_DIR" "$CANDIDATE_ROOT" "$OUTPUT_ROOT"

record() {
  printf '%s=%q\n' "$1" "$2" >> "$EVIDENCE"
}

fail() {
  record status FAIL
  record failure "$1"
  printf 'RELEASE GATE FAIL: %s\nEvidence: %s\n' "$1" "$EVIDENCE" >&2
  exit 1
}

active_tools() {
  ps -axo pid=,comm= | awk '$2 ~ /(^|\/)(videotext|whisper-cli|ffmpeg|ffprobe)$/ {print}'
}

require_no_active_tools() {
  local active
  active="$(active_tools)"
  [[ -z "$active" ]] || fail "активны процессы: $active"
}

release_files() {
  find "$ROOT/Sources" "$ROOT/Resources" -type f -print
  printf '%s\n' \
    "$ROOT/scripts/build_app.sh" \
    "$ROOT/scripts/test_e2e.sh" \
    "$ROOT/scripts/owned_tmp.py" \
    "$ROOT/scripts/test_project_schema.sh" \
    "$ROOT/scripts/test_human_review.sh" \
    "$ROOT/scripts/test_topics.sh" \
    "$ROOT/scripts/test_topic_matrix.sh" \
    "$ROOT/scripts/test_ollama_topics.sh" \
    "$ROOT/scripts/test_translation.sh" \
    "$ROOT/scripts/test_translation_models.sh" \
    "$ROOT/scripts/test_ollama_memory_shutdown.sh" \
    "$ROOT/scripts/test_no_retired_translation_models.sh" \
    "$ROOT/scripts/test_translation_ownership.sh" \
    "$ROOT/scripts/test_translation_semantic_review.sh" \
    "$ROOT/scripts/test_selected_timing_vertical_slice.sh" \
    "$ROOT/scripts/test_owned_tmp.sh" \
    "$ROOT/scripts/test_process_shutdown.sh" \
    "$ROOT/scripts/test_application_lifecycle.sh" \
    "$ROOT/scripts/test_tool_runner.sh" \
    "$ROOT/scripts/test_whisper_vad.sh" \
    "$ROOT/scripts/test_transcription_quality.sh" \
    "$ROOT/scripts/check_baseline.sh" \
    "$ROOT/scripts/test_baseline_guard.sh" \
    "$ROOT/scripts/release_gate.sh" \
    "$ROOT/Tests/EndToEnd.swift" \
    "$ROOT/Tests/ProjectSchemaProbe.swift" \
    "$ROOT/Tests/HumanReviewProbe.swift" \
    "$ROOT/Tests/TopicAnalysisProbe.swift" \
    "$ROOT/Tests/TopicMatrixProbe.swift" \
    "$ROOT/Tests/OllamaTopicProbe.swift" \
    "$ROOT/Tests/TranslationAdapterProbe.swift" \
    "$ROOT/Tests/TranslationModelBenchmark.swift" \
    "$ROOT/Tests/OllamaMemoryManagerProbe.swift" \
    "$ROOT/Tests/TranslationOwnershipProbe.swift" \
    "$ROOT/Tests/TranslationSemanticReviewProbe.swift" \
    "$ROOT/Tests/SelectedTimingVerticalSliceProbe.swift" \
    "$ROOT/Tests/OwnedTMPProbe.swift" \
    "$ROOT/Tests/ProcessShutdownProbe.swift" \
    "$ROOT/Tests/ApplicationLifecycleProbe.swift" \
    "$ROOT/Tests/test_owned_tmp.py" \
    "$ROOT/Tests/ToolRunnerProbe.swift" \
    "$ROOT/Tests/WhisperVADProbe.swift" \
    "$ROOT/Tests/TranscriptionQualityProbe.swift"
}

release_inputs_hash() {
  release_files | LC_ALL=C sort | while IFS= read -r path; do
    [[ -f "$path" ]] || exit 1
    printf '%s  %s\n' "$(shasum -a 256 "$path" | awk '{print $1}')" "${path#"$ROOT"/}"
  done | shasum -a 256 | awk '{print $1}'
}

bundle_hash() {
  local app="$1"
  (
    cd "$app"
    find . -type f -print | LC_ALL=C sort | while IFS= read -r path; do
      printf '%s  %s\n' "$(shasum -a 256 "$path" | awk '{print $1}')" "$path"
    done
  ) | shasum -a 256 | awk '{print $1}'
}

directory_hash() {
  local directory="$1"
  (
    cd "$directory"
    find . -type f -print | LC_ALL=C sort | while IFS= read -r path; do
      printf '%s  %s\n' "$(shasum -a 256 "$path" | awk '{print $1}')" "$path"
    done
  ) | shasum -a 256 | awk '{print $1}'
}

assert_snapshot() {
  local current candidate_current
  current="$(release_inputs_hash)" || fail "не удалось вычислить hash release inputs"
  [[ "$current" == "$SOURCE_HASH" ]] || fail "release inputs изменились после начала gate"
  # Before the candidate build there is no bundle to compare yet.
  [[ -n "${CANDIDATE_HASH:-}" ]] || return 0
  candidate_current="$(bundle_hash "$CANDIDATE")"
  [[ "$candidate_current" == "$CANDIDATE_HASH" ]] || fail "release candidate изменился после сборки"
}

stop_smoke_app() {
  local pid
  for pid in ${SMOKE_PIDS:-}; do
    kill "$pid" 2>/dev/null || true
  done
}

trap stop_smoke_app EXIT

: > "$EVIDENCE"
record status RUNNING
record started_at "$STAMP"
[[ -z "$(git -C "$ROOT" status --porcelain=v1)" ]] || fail "рабочее дерево содержит незакоммиченные изменения"
SOURCE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)" || fail "не удалось определить commit release candidate"
SOURCE_VERSION="$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' "$ROOT/Sources/videotext/Core/Models.swift" | head -1)"
SOURCE_BUILD="$(sed -n 's/.*static let build = "\([^"]*\)".*/\1/p' "$ROOT/Sources/videotext/Core/Models.swift" | head -1)"
[[ -n "$SOURCE_VERSION" && -n "$SOURCE_BUILD" ]] || fail "не удалось прочитать BuildInfo"
record source_commit "$SOURCE_COMMIT"
record source_tree_clean true
record source_version "$SOURCE_VERSION"
record source_build "$SOURCE_BUILD"
if ! BASELINE_RESULT="$("$ROOT/scripts/check_baseline.sh" 2>&1)"; then
  fail "$BASELINE_RESULT"
fi
record baseline_status "$BASELINE_RESULT"
record video_path "$VIDEO_PATH"
VIDEO_SHA256="$(shasum -a 256 "$VIDEO_PATH" | awk '{print $1}')"
record video_sha256 "$VIDEO_SHA256"
record whisper_model_path "$MODEL_PATH"
record whisper_model_sha256 "$(shasum -a 256 "$MODEL_PATH" | awk '{print $1}')"
EN_VIDEO_SHA256="$(shasum -a 256 "$EN_VIDEO_PATH" | awk '{print $1}')"
EN_PROJECT_SHA256="$(directory_hash "$EN_PROJECT_PATH")"
record en_video_path "$EN_VIDEO_PATH"
record en_video_sha256 "$EN_VIDEO_SHA256"
record en_project_path "$EN_PROJECT_PATH"
record en_project_sha256 "$EN_PROJECT_SHA256"
record en_project_manifest_sha256 "$(shasum -a 256 "$EN_PROJECT_PATH/Support files/manifest.json" | awk '{print $1}')"
record en_project_full_srt_sha256 "$(shasum -a 256 "$EN_PROJECT_PATH/Texts/full.srt" | awk '{print $1}')"
for tool in ffmpeg ffprobe whisper-cli; do
  command -v "$tool" >/dev/null 2>&1 || fail "не найден обязательный инструмент $tool"
done
record ffmpeg_version "$(ffmpeg -version 2>/dev/null | sed -n '1p')"
record ffprobe_version "$(ffprobe -version 2>/dev/null | sed -n '1p')"
record whisper_version "$(whisper-cli --version 2>&1 | sed -n '1p')"

# The selected-timing route consumes the canonical SeminarText capability. A
# release gate must never accidentally exercise an older similarly named CLI.
SEMINARTEXT_EXECUTABLE="${VIDEOTEXT_SEMINARTEXT_EXECUTABLE:-}"
[[ -n "$SEMINARTEXT_EXECUTABLE" ]] || fail "задайте VIDEOTEXT_SEMINARTEXT_EXECUTABLE для canonical SeminarText selected timing"
[[ -x "$SEMINARTEXT_EXECUTABLE" ]] || fail "SeminarText не исполняемый: $SEMINARTEXT_EXECUTABLE"
SEMINARTEXT_HELP="$("$SEMINARTEXT_EXECUTABLE" transcribe --help 2>&1)" || fail "не удалось проверить SeminarText: $SEMINARTEXT_EXECUTABLE"
printf '%s\n' "$SEMINARTEXT_HELP" | /usr/bin/grep -Fq -- '--language' || fail "SeminarText не поддерживает --language: $SEMINARTEXT_EXECUTABLE"
printf '%s\n' "$SEMINARTEXT_HELP" | /usr/bin/grep -Fq -- '--structured-timing' || fail "SeminarText не поддерживает --structured-timing: $SEMINARTEXT_EXECUTABLE"
record seminartext_executable "$SEMINARTEXT_EXECUTABLE"
record seminartext_sha256 "$(shasum -a 256 "$SEMINARTEXT_EXECUTABLE" | awk '{print $1}')"
record seminartext_runtime_identity "$("$SEMINARTEXT_EXECUTABLE" runtime-identity 2>&1)"

require_no_active_tools
SOURCE_HASH="$(release_inputs_hash)" || fail "не удалось вычислить hash release inputs"
record release_inputs_sha256 "$SOURCE_HASH"

for focused in \
  test_project_schema.sh \
  test_human_review.sh \
  test_topics.sh \
  test_topic_matrix.sh \
  test_ollama_topics.sh \
  test_translation.sh \
  test_translation_ownership.sh \
  test_selected_timing_vertical_slice.sh \
  test_no_retired_translation_models.sh \
  test_owned_tmp.sh \
  test_process_shutdown.sh \
  test_application_lifecycle.sh \
  test_whisper_vad.sh \
  test_transcription_quality.sh; do
  log="$RUN_DIR/$focused.log"
  if ! "$ROOT/scripts/$focused" > "$log" 2>&1; then
    record "${focused%.sh}_exit_status" 1
    record "${focused%.sh}_log" "$log"
    fail "focused-проверка $focused завершилась ошибкой"
  fi
  record "${focused%.sh}_exit_status" 0
  record "${focused%.sh}_log" "$log"
done
log="$RUN_DIR/test_translation_semantic_review.sh.log"
if ! "$ROOT/scripts/test_translation_semantic_review.sh" --check-alarms > "$log" 2>&1; then
  record test_translation_semantic_review_exit_status 1
  record test_translation_semantic_review_log "$log"
  fail "focused-проверка test_translation_semantic_review.sh завершилась ошибкой"
fi
record test_translation_semantic_review_exit_status 0
record test_translation_semantic_review_log "$log"
log="$RUN_DIR/test_tool_runner.sh.log"
if ! "$ROOT/scripts/test_tool_runner.sh" "$VIDEO_PATH" > "$log" 2>&1; then
  record test_tool_runner_exit_status 1
  record test_tool_runner_log "$log"
  fail "focused-проверка test_tool_runner.sh завершилась ошибкой"
fi
record test_tool_runner_exit_status 0
record test_tool_runner_log "$log"
assert_snapshot

for run in 1 2; do
  log="$RUN_DIR/e2e-$run.log"
  e2e_evidence="$RUN_DIR/e2e-$run-evidence"
  mkdir -p "$e2e_evidence"
  if ! QA_E2E_EVIDENCE_DIR="$e2e_evidence" "$ROOT/scripts/test_e2e.sh" \
    "$VIDEO_PATH" "$MODEL_PATH" "$EN_VIDEO_PATH" "$EN_PROJECT_PATH" > "$log" 2>&1; then
    record "e2e_${run}_command" "$ROOT/scripts/test_e2e.sh $VIDEO_PATH $MODEL_PATH $EN_VIDEO_PATH $EN_PROJECT_PATH"
    record "e2e_${run}_exit_status" 1
    record "e2e_${run}_log" "$log"
    fail "E2E #$run завершился с ненулевым кодом"
  fi
  /usr/bin/grep -Fq 'E2E PASS' "$log" || fail "E2E #$run не содержит E2E PASS"
  [[ "$(/usr/bin/grep -Fc 'REAL_TRANSLATION_PASS ru->en:' "$log")" -eq 1 ]] || \
    fail "E2E #$run не доказал единственный RU->EN production-проход"
  [[ "$(/usr/bin/grep -Fc 'REAL_TRANSLATION_PASS en->ru:' "$log")" -eq 1 ]] || \
    fail "E2E #$run не доказал единственный EN->RU production-проход"
  [[ "$(shasum -a 256 "$VIDEO_PATH" | awk '{print $1}')" == "$VIDEO_SHA256" ]] || \
    fail "E2E #$run изменил RU-видео"
  [[ "$(shasum -a 256 "$EN_VIDEO_PATH" | awk '{print $1}')" == "$EN_VIDEO_SHA256" ]] || \
    fail "E2E #$run изменил EN-видео"
  [[ "$(directory_hash "$EN_PROJECT_PATH")" == "$EN_PROJECT_SHA256" ]] || \
    fail "E2E #$run изменил исходный EN-проект"
  record "e2e_${run}_command" "$ROOT/scripts/test_e2e.sh $VIDEO_PATH $MODEL_PATH $EN_VIDEO_PATH $EN_PROJECT_PATH"
  record "e2e_${run}_exit_status" 0
  record "e2e_${run}_status" PASS
  record "e2e_${run}_log" "$log"
  record "e2e_${run}_evidence" "$e2e_evidence"
  assert_snapshot
  require_no_active_tools
done

if ! VIDEOTEXT_APP_PATH="$CANDIDATE" "$ROOT/scripts/build_app.sh" > "$RUN_DIR/build.log" 2>&1; then
  record build_command "VIDEOTEXT_APP_PATH=$CANDIDATE $ROOT/scripts/build_app.sh"
  record build_exit_status 1
  record build_log "$RUN_DIR/build.log"
  fail "сборка candidate завершилась ошибкой"
fi
record build_command "VIDEOTEXT_APP_PATH=$CANDIDATE $ROOT/scripts/build_app.sh"
record build_exit_status 0
record build_log "$RUN_DIR/build.log"
[[ -d "$CANDIDATE" ]] || fail "candidate не создан"
record codesign_before_command "codesign --verify --deep --strict $CANDIDATE"
if ! codesign --verify --deep --strict "$CANDIDATE" > "$RUN_DIR/codesign-before.log" 2>&1; then
  record codesign_before_exit_status 1
  record codesign_before_log "$RUN_DIR/codesign-before.log"
  fail "candidate не прошел codesign"
fi
record codesign_before_exit_status 0
record codesign_before_log "$RUN_DIR/codesign-before.log"
CANDIDATE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CANDIDATE/Contents/Info.plist")"
CANDIDATE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$CANDIDATE/Contents/Info.plist")"
record candidate_version "$CANDIDATE_VERSION"
record candidate_build "$CANDIDATE_BUILD"
[[ "$CANDIDATE_VERSION" == "$SOURCE_VERSION" ]] || \
  fail "версия candidate $CANDIDATE_VERSION не совпадает с BuildInfo $SOURCE_VERSION"
[[ "$CANDIDATE_BUILD" == "$SOURCE_BUILD" ]] || \
  fail "build candidate $CANDIDATE_BUILD не совпадает с BuildInfo $SOURCE_BUILD"
CANDIDATE_HASH="$(bundle_hash "$CANDIDATE")"
record candidate_path "$CANDIDATE"
record candidate_sha256 "$CANDIDATE_HASH"
assert_snapshot

record smoke_command "open -n $CANDIDATE"
if ! open -n "$CANDIDATE" > "$RUN_DIR/smoke-open.log" 2>&1; then
  record smoke_open_exit_status 1
  record smoke_log "$RUN_DIR/smoke-open.log"
  fail "candidate не запускается"
fi
record smoke_open_exit_status 0
record smoke_log "$RUN_DIR/smoke-open.log"
sleep 5
SMOKE_PIDS="$(pgrep -x videotext 2>/dev/null || true)"
[[ -n "$SMOKE_PIDS" ]] || fail "после smoke-запуска не найден процесс videotext"
for pid in $SMOKE_PIDS; do
  kill -0 "$pid" 2>/dev/null || fail "smoke-процесс videotext завершился преждевременно"
done
stop_smoke_app
SMOKE_PIDS=""

for _ in 1 2 3 4 5; do
  pgrep -x videotext >/dev/null || break
  sleep 1
done
require_no_active_tools
record smoke_metadata_cleanup_command "xattr -cr $CANDIDATE"
if ! xattr -cr "$CANDIDATE" > "$RUN_DIR/smoke-metadata-cleanup.log" 2>&1; then
  record smoke_metadata_cleanup_exit_status 1
  record smoke_metadata_cleanup_log "$RUN_DIR/smoke-metadata-cleanup.log"
  fail "не удалось удалить служебные xattr после smoke-запуска"
fi
record smoke_metadata_cleanup_exit_status 0
record smoke_metadata_cleanup_log "$RUN_DIR/smoke-metadata-cleanup.log"
assert_snapshot
record codesign_after_command "codesign --verify --deep --strict $CANDIDATE"
if ! codesign --verify --deep --strict "$CANDIDATE" > "$RUN_DIR/codesign-after.log" 2>&1; then
  record codesign_after_exit_status 1
  record codesign_after_log "$RUN_DIR/codesign-after.log"
  fail "подпись candidate повреждена после smoke-запуска"
fi
record codesign_after_exit_status 0
record codesign_after_log "$RUN_DIR/codesign-after.log"
assert_snapshot

record candidate_architecture "$(file "$CANDIDATE/Contents/MacOS/videotext")"
record smoke_status PASS

if [[ "$PROMOTE" == true ]]; then
  require_no_active_tools
  if [[ -L "$FINAL_LINK" ]]; then
    FINAL_APP="$(readlink "$FINAL_LINK")"
  else
    FINAL_APP="$FINAL_LINK"
  fi
  FINAL_PARENT="$(dirname "$FINAL_APP")"
  STAGED_APP="$FINAL_PARENT/.videotext-release-$STAMP.app"
  BACKUP_DIR="$WORK_ROOT/release-gate/backups"
  BACKUP_APP="$BACKUP_DIR/videotext-before-$STAMP.app"
  mkdir -p "$FINAL_PARENT" "$BACKUP_DIR"

  ditto --norsrc "$CANDIDATE" "$STAGED_APP" || fail "не удалось подготовить promotion copy"
  record promotion_copy_command "ditto --norsrc $CANDIDATE $STAGED_APP"
  record promotion_copy_exit_status 0
  if command -v SetFile >/dev/null 2>&1; then
    SetFile -a e "$STAGED_APP"
    sleep 1
  fi
  xattr -cr "$STAGED_APP"
  codesign --force --deep --sign - "$STAGED_APP" > "$RUN_DIR/codesign-promote.log" 2>&1 || \
    fail "не удалось переподписать promotion copy"
  codesign --verify --deep --strict "$STAGED_APP" >> "$RUN_DIR/codesign-promote.log" 2>&1 || \
    fail "promotion copy не прошла codesign"
  [[ "$(bundle_hash "$STAGED_APP")" == "$CANDIDATE_HASH" ]] || \
    fail "hash promotion copy не совпадает с candidate"

  require_no_active_tools
  if [[ -e "$FINAL_APP" ]]; then
    mv "$FINAL_APP" "$BACKUP_APP" || fail "не удалось сохранить предыдущую стабильную сборку"
  fi
  if ! mv "$STAGED_APP" "$FINAL_APP"; then
    [[ -e "$BACKUP_APP" ]] && mv "$BACKUP_APP" "$FINAL_APP"
    fail "не удалось продвинуть candidate"
  fi
  sleep 5
  if ! codesign --verify --deep --strict "$FINAL_APP" > "$RUN_DIR/codesign-final.log" 2>&1; then
    mv "$FINAL_APP" "$RUN_DIR/failed-promoted.app"
    [[ -e "$BACKUP_APP" ]] && mv "$BACKUP_APP" "$FINAL_APP"
    fail "финальная сборка не прошла codesign; предыдущая версия восстановлена"
  fi
  if [[ "$(bundle_hash "$FINAL_APP")" != "$CANDIDATE_HASH" ]]; then
    mv "$FINAL_APP" "$RUN_DIR/failed-promoted.app"
    [[ -e "$BACKUP_APP" ]] && mv "$BACKUP_APP" "$FINAL_APP"
    fail "hash финальной сборки не совпадает с candidate; предыдущая версия восстановлена"
  fi
  record final_path "$FINAL_APP"
  record final_sha256 "$CANDIDATE_HASH"
  record promotion_command "mv $STAGED_APP $FINAL_APP"
  record promotion_exit_status 0
  record promoted true
else
  record promoted false
fi

record completed_at "$(date -u '+%Y%m%dT%H%M%SZ')"
record status PASS

required_evidence=(
  source_commit source_tree_clean source_version source_build
  release_inputs_sha256 candidate_sha256
  candidate_version candidate_build
  build_command build_exit_status build_log
  e2e_1_command e2e_1_exit_status e2e_1_log
  e2e_2_command e2e_2_exit_status e2e_2_log
  smoke_command smoke_open_exit_status smoke_log
  smoke_metadata_cleanup_command smoke_metadata_cleanup_exit_status smoke_metadata_cleanup_log
  codesign_before_command codesign_before_exit_status codesign_before_log
  codesign_after_command codesign_after_exit_status codesign_after_log
)
if [[ "$PROMOTE" == true ]]; then
  required_evidence+=(
    promotion_copy_command promotion_copy_exit_status
    promotion_command promotion_exit_status final_path final_sha256
  )
fi
for key in "${required_evidence[@]}"; do
  /usr/bin/grep -q "^${key}=" "$EVIDENCE" || fail "evidence не содержит $key"
done
printf 'RELEASE GATE PASS\nCandidate: %s\nEvidence: %s\n' "$CANDIDATE" "$EVIDENCE"
if [[ "$PROMOTE" == false ]]; then
  printf 'Стабильная сборка не заменена. Для продвижения повторите с --promote.\n'
fi
