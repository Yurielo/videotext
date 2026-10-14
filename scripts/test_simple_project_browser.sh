#!/usr/bin/env bash
set -euo pipefail

if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${VIDEOTEXT_EPHEMERAL_WORK_ROOT:-${ROOT}/../work}"
TEST_BINARY="${WORK_ROOT}/videotext-simple-project-browser-probe"

mkdir -p "${WORK_ROOT}"

swiftc \
  -O \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVKit \
  -framework AVFoundation \
  -framework UserNotifications \
  -o "${TEST_BINARY}" \
  "${ROOT}/Sources/videotext/Core/Models.swift" \
  "${ROOT}/Sources/videotext/Core/ProjectLayout.swift" \
  "${ROOT}/Sources/videotext/Core/ArtifactModels.swift" \
  "${ROOT}/Sources/videotext/Core/StableTopicHash.swift" \
  "${ROOT}/Sources/videotext/Services/SRTService.swift" \
  "${ROOT}/Sources/videotext/Services/ProjectHistoryStore.swift" \
  "${ROOT}/Sources/videotext/Services/ProjectStore.swift" \
  "${ROOT}/Sources/videotext/Services/ResultsDetector.swift" \
  "${ROOT}/Sources/videotext/Services/ProjectResultSummaryService.swift" \
  "${ROOT}/Sources/videotext/Services/SimpleProjectHomeState.swift" \
  "${ROOT}/Sources/videotext/Services/SimpleProjectBrowserState.swift" \
  "${ROOT}/Tests/SimpleProjectBrowserProbe.swift"

"${TEST_BINARY}"

if rg -U -q 'case \.openKnownProjects:[[:space:]]+if let url = openProjectDirectory' "${ROOT}/Sources/videotext/UI/ContentView.swift"; then
  echo "Open known projects still routes through Finder" >&2
  exit 1
fi

python3 - "${ROOT}/Sources/videotext/UI/ContentView.swift" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
required = {
    "Simple mode label removed": 'private var simplePresentationModePicker: some View {\n        Picker("", selection: $presentationMode)',
    "Advanced mode label preserved": 'private var advancedPresentationModePicker: some View {\n        Picker("Режим", selection: $presentationMode)',
    "internal browser": "case .openKnownProjects:\n            reloadSimpleProjectBrowser()\n            showProjectBrowser = true",
    "media picker": "case .createFromMedia:\n            if let url = openMediaFile() { model.selectMedia(url) }",
    "manual project picker": "case .locateProjectOnDisk:\n            if let url = openProjectDirectory()",
    "filtered selection": "return filteredSimpleProjectBrowserEntries.first { $0.id == selectedBrowserProjectPath }",
}
missing = [name for name, snippet in required.items() if snippet not in source]
if missing:
    raise SystemExit("Missing Simple navigation routing: " + ", ".join(missing))
PY

if rg -q 'WorkflowEngine|model\.run\(|translateApprovedTranscript|runDiagnostics' \
  "${ROOT}/Sources/videotext/Services/SimpleProjectBrowserState.swift"; then
  echo "Project Browser state service must not trigger processing" >&2
  exit 1
fi

echo "SIMPLE_PROJECT_BROWSER_UI_CONTRACT_PASS"
