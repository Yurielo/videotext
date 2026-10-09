#!/usr/bin/env bash
set -euo pipefail

if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${VIDEOTEXT_EPHEMERAL_WORK_ROOT:-${ROOT}/../work}"
TEST_BINARY="${WORK_ROOT}/videotext-simple-project-home-probe"
SWIFT_SOURCES=()

mkdir -p "${WORK_ROOT}"
SWIFT_SOURCES=(
  "${ROOT}/Sources/videotext/Core/Models.swift"
  "${ROOT}/Sources/videotext/Core/ProjectLayout.swift"
  "${ROOT}/Sources/videotext/Core/ArtifactModels.swift"
  "${ROOT}/Sources/videotext/Services/SimpleProjectHomeState.swift"
)

swiftc \
  -O \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVKit \
  -framework AVFoundation \
  -framework UserNotifications \
  -o "${TEST_BINARY}" \
  "${SWIFT_SOURCES[@]}" \
  "${ROOT}/Tests/SimpleProjectHomeProbe.swift"

"${TEST_BINARY}"

python3 - "${ROOT}/Sources/videotext/Services/SimpleProjectHomeState.swift" "${ROOT}/Sources/videotext/UI/ContentView.swift" <<'PY'
import pathlib
import sys

state = pathlib.Path(sys.argv[1]).read_text()
ui = pathlib.Path(sys.argv[2]).read_text()

required_state = {
    "source transcript TXT": "ProjectLayout(root: projectURL).transcriptURL",
    "topic TXT": "topicsTextURL(language: language, granularity: granularity)",
    "translated transcript TXT": "transcriptURL(language: target)",
    "user-facing result filter": "outputs.filter { $0.isGeneratedMedia && isNonemptyFile(at: $0.path) }",
}
missing = [name for name, snippet in required_state.items() if snippet not in state]
if missing:
    raise SystemExit("Missing Simple user-facing artifact contract: " + ", ".join(missing))

forbidden_state = ["firstPath(in: outputs", 'kinds: ["transcript", "full-srt"]', 'kinds: ["localized-transcript", "localized-subtitles"]']
present = [snippet for snippet in forbidden_state if snippet in state]
if present:
    raise SystemExit("Simple mode still has an internal artifact fallback: " + ", ".join(present))

required_ui = ["openSimpleResult(path)", "model.revealResult(ProjectOutput(", "output.isGeneratedMedia"]
missing = [snippet for snippet in required_ui if snippet not in ui]
if missing:
    raise SystemExit("Simple results UI contract missing: " + ", ".join(missing))

review_route = '''private func openSimpleReview(_ target: SimpleProjectHomeReviewTarget) {
        presentationMode = .advanced
        selectedResultsTab = target == .topics ? 1 : 2
    }'''
if review_route not in ui:
    raise SystemExit("Simple Human Review action must route pending source/translation review to Advanced Results")

if "WorkflowEngine" in state or "model.run(" in state:
    raise SystemExit("Simple presentation state must not trigger processing")
PY

echo "SIMPLE_USER_FACING_RESULTS_UI_CONTRACT_PASS"
