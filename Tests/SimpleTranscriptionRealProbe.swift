import Foundation

@main
struct SimpleTranscriptionRealProbe {
    @MainActor
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("SIMPLE_TRANSCRIPTION_REAL_PROBE_FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mediaPath = environment["VIDEOTEXT_SIMPLE_REAL_MEDIA"],
              let modelPath = environment["VIDEOTEXT_SIMPLE_REAL_MODEL"],
              let rootPath = environment["VIDEOTEXT_SIMPLE_REAL_ROOT"] else {
            throw ProbeFailure("Missing real Simple probe environment")
        }
        let originalMedia = URL(fileURLWithPath: mediaPath)
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let input = root.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let media = input.appendingPathComponent("Short-RU.mp4")
        try FileManager.default.copyItem(at: originalMedia, to: media)
        try require(SelectedTimingHash.file(media) == SelectedTimingHash.file(originalMedia),
                    "controlled Short-RU copy changed bytes")
        let bundled = try SeminarTextExecutableLocator().resolvedExecutable()
        let expectedBundled = Bundle.main.resourceURL?
            .appendingPathComponent("SeminarText/seminartext").standardizedFileURL
        try require(bundled.standardizedFileURL.path == expectedBundled?.path,
                    "Simple probe did not resolve its bundled SeminarText: resolved=\(bundled.path) expected=\(expectedBundled?.path ?? "nil")")

        let model = WorkflowViewModel()
        defer { try? model.log.text.write(to: root.appendingPathComponent("vm.log"), atomically: true, encoding: .utf8) }
        model.selectMedia(media)
        guard let project = model.projectURL else { throw ProbeFailure("selectMedia did not create a project") }
        let layout = ProjectLayout(root: project)
        let store = ProjectStore()
        try require(project.path.hasPrefix(root.path), "Simple project escaped evidence root")
        model.whisperLanguage = "ru"
        model.whisperModelPath = modelPath
        model.fillerAnalysisBeforeReview = false
        model.selectedOperations = [.topicTimecoding, .translateTranscript]
        try require(model.canStartSimpleTranscription, "new Short-RU project is not eligible for Simple transcription")
        try require(model.startSimpleTranscription(), "WorkflowViewModel.startSimpleTranscription did not start")
        try await waitUntil("Short-RU Source Human Review", seconds: 1800) { !model.isRunning }
        try require(model.humanReviewCheckpoint?.kind == .sourceTranscript
                    && model.humanReviewCheckpoint?.language == .ru,
                    "real Simple transcription did not stop at RU Source Human Review: \(model.alert?.message ?? model.status)")
        let pending = try store.load(from: project)
        try require(pending.humanReviewState?.pendingCheckpoint?.kind == .sourceTranscript,
                    "Source Human Review checkpoint was not persisted")
        let cues = try SRTService().load(from: layout.fullSRTURL)
        try require(!cues.isEmpty && cues.allSatisfy { $0.start >= 0 && $0.end > $0.start && $0.end <= 20 },
                    "real Short-RU SRT has empty or out-of-range executable cues")
        let sourceText = try String(contentsOf: layout.transcriptURL, encoding: .utf8)
        try require(!sourceText.contains("Вопросы и ответы")
                    && sourceText.localizedCaseInsensitiveContains("Элина")
                    && sourceText.localizedCaseInsensitiveContains("Клиентов"),
                    "Short-RU did not contain the selected conversation or retained the false phrase")
        try require(SelectedTimingHash.file(layout.whisperJSONURL) != "",
                    "core whisper.json is absent")

        let evidence = try JSONDecoder().decode(
            SeminarTextCoreTranscriptionEvidence.self,
            from: Data(contentsOf: layout.seminarTextCoreEvidenceURL)
        )
        let manifests = SeminarTextSelectedTimingRunner.findManifests(in: layout.seminarTextCoreDirectory)
        try require(manifests.count == 1, "Short-RU did not retain one selected SeminarText attempt")
        let package = manifests[0].deletingLastPathComponent()
        try require(evidence.selectedTimingManifestSHA256 == SelectedTimingHash.file(manifests[0])
                    && evidence.selectedWhisperJSONSHA256 == SelectedTimingHash.file(layout.whisperJSONURL),
                    "core evidence is not bound to the retained selected attempt")
        let selectedArtifacts = try verifyAttemptArtifacts(manifestURL: manifests[0], media: media)
        let reimported = try SeminarTextCoreWhisperEvidenceImporter().importSelectedWhisperJSON(
            packageRoot: package, expectedMediaURL: media, expectedLanguage: .ru
        )
        let coreWhisperBytes = try Data(contentsOf: layout.whisperJSONURL)
        try require(reimported == coreWhisperBytes,
                    "core whisper.json differs from retained selected-attempt raw tokens")
        let reverseRaw = try reverseRawIntervals(in: layout.whisperJSONURL)
        try require(!reverseRaw.isEmpty, "real Short-RU lacks the expected reverse raw token evidence")
        let ordinarySRTs = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: evidence.outputDirectory), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "srt" && $0.lastPathComponent.lowercased().hasPrefix("transcript") }
        try require(ordinarySRTs.count == 1 && evidence.sourceSRTSHA256 == SelectedTimingHash.file(ordinarySRTs[0]),
                    "core SRT is not from the retained selected attempt")
        try require(noDownstreamWork(pending, layout: layout), "Simple source-only run started topics or translation")
        let initialCoreEvidenceHash = SelectedTimingHash.file(layout.seminarTextCoreEvidenceURL)
        let initialJSONHash = SelectedTimingHash.file(layout.whisperJSONURL)
        let initialRunCount = coreRunCount(layout)

        try require(model.beginHumanReview(language: .ru), "Source Human Review could not be opened")
        guard let firstCue = model.reviewCues.first else { throw ProbeFailure("Source Human Review has no cue to edit") }
        let correctedFirstText = firstCue.text.trimmingCharacters(in: .whitespacesAndNewlines) + " Проверено вручную."
        try require(model.saveHumanReviewCue(firstCue, replacementText: correctedFirstText),
                    "Source Human Review could not save a cue edit")
        guard let savedCue = model.reviewCues.first else { throw ProbeFailure("edited Source cue disappeared") }
        try require(savedCue.id == firstCue.id && savedCue.start == firstCue.start
                    && savedCue.end == firstCue.end && savedCue.text == correctedFirstText,
                    "Source Human Review changed timing/ID or lost saved text")
        model.approveHumanReview()
        try await waitUntil("Short-RU Source approval continuation", seconds: 120) { !model.isRunning }
        let approved = try store.load(from: project)
        try require(model.humanReviewCheckpoint == nil
                    && approved.activeTranscriptRevision(for: .ru)?.reviewStatus == .approved,
                    "Source Human Review did not approve RU transcript: \(model.alert?.message ?? model.status)")
        try require(noDownstreamWork(approved, layout: layout), "Source approval started topics or translation")
        let approvedText = try String(contentsOf: layout.transcriptURL, encoding: .utf8)
        try require(approvedText.contains("Проверено вручную."),
                    "approved Source Human Review edit is missing from TXT")
        try require(initialRunCount == coreRunCount(layout)
                    && initialCoreEvidenceHash == SelectedTimingHash.file(layout.seminarTextCoreEvidenceURL)
                    && initialJSONHash == SelectedTimingHash.file(layout.whisperJSONURL),
                    "Source approval reran ASR or rewrote selected evidence")

        let reopened = WorkflowViewModel()
        reopened.openProject(project)
        let reopenedManifest = try store.load(from: project)
        let simpleState = SimpleProjectHomeStateService().make(
            projectURL: project, manifest: reopenedManifest, topicsDetail: nil, discoveredOutputs: reopened.outputs
        )
        try require(reopened.projectURL?.standardizedFileURL == project.standardizedFileURL
                    && !reopened.isRunning && reopened.humanReviewCheckpoint == nil
                    && simpleState.artifact(.transcription).readiness == .ready
                    && simpleState.artifact(.transcription).openOutputPath == layout.transcriptURL.path,
                    "reopen did not show the approved TXT as a ready Simple result")
        try require(initialRunCount == coreRunCount(layout)
                    && initialJSONHash == SelectedTimingHash.file(layout.whisperJSONURL),
                    "reopen reran ASR or changed selected evidence")
        try require(noDownstreamWork(reopenedManifest, layout: layout), "reopen started topics or translation")
        let reopenedText = try String(contentsOf: layout.transcriptURL, encoding: .utf8)
        try require(reopenedText.contains("Проверено вручную."),
                    "reopen lost the approved Source Human Review TXT edit")

        let result: [String: Any] = [
            "status": "PASS", "project": project.path,
            "sourceMediaSHA256": SelectedTimingHash.file(originalMedia),
            "modelSHA256": SelectedTimingHash.file(URL(fileURLWithPath: modelPath)),
            "bundledSeminarText": bundled.path,
            "bundledSeminarTextSHA256": SelectedTimingHash.file(bundled),
            "selectedManifestSHA256": SelectedTimingHash.file(manifests[0]),
            "whisperJSONSHA256": initialJSONHash,
            "sourceSRTSHA256": evidence.sourceSRTSHA256,
            "selectedArtifacts": selectedArtifacts,
            "cueCount": cues.count,
            "lastCueEnd": cues.last!.end,
            "reverseRawIntervals": reverseRaw,
            "transcriptTXT": layout.transcriptURL.path,
            "sourceReviewApproved": true,
            "sourceReviewCueEdited": true,
            "simpleResultReadyAfterReopen": true,
            "noAutomaticTopicsOrTranslation": true,
            "noASRAfterReviewOrReopen": true
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"), options: .atomic)
        print("SIMPLE_TRANSCRIPTION_REAL_PROBE_PASS cues=\(cues.count) reverseRaw=\(reverseRaw.count) project=\(project.path)")
    }

    private static func noDownstreamWork(_ manifest: ProjectManifest, layout: ProjectLayout) -> Bool {
        let operations = manifest.workflow?.operations ?? [:]
        return operations[WorkflowOperation.topicTimecoding.rawValue] == nil
            && operations[WorkflowOperation.translateTranscript.rawValue] == nil
            && !FileManager.default.fileExists(atPath: layout.topicsURL.path)
            && !FileManager.default.fileExists(atPath: layout.selectedTimingTranslationsURL(source: .ru, target: .en).path)
            && !manifest.outputs.contains(where: { $0.kind.contains("translation") || $0.kind.contains("topics") })
    }

    private static func coreRunCount(_ layout: ProjectLayout) -> Int {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: layout.seminarTextCoreDirectory, includingPropertiesForKeys: nil
        )) ?? []
        return children.filter { $0.lastPathComponent.hasPrefix("core-transcription-") }.count
    }

    private static func reverseRawIntervals(in url: URL) throws -> [[String: Any]] {
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let segments = root["transcription"] as? [[String: Any]] else {
            throw ProbeFailure("core whisper.json has no transcription")
        }
        var reversed: [[String: Any]] = []
        for segment in segments {
            for token in (segment["tokens"] as? [[String: Any]]) ?? [] {
                guard let offsets = token["offsets"] as? [String: Any],
                      let start = offsets["from"] as? NSNumber,
                      let end = offsets["to"] as? NSNumber,
                      start.doubleValue > end.doubleValue else { continue }
                reversed.append(["text": token["text"] as? String ?? "", "from": start, "to": end])
            }
        }
        return reversed
    }

    private static func verifyAttemptArtifacts(manifestURL: URL, media: URL) throws -> [[String: Any]] {
        guard let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
              let source = manifest["source"] as? [String: Any],
              source["media_sha256"] as? String == SelectedTimingHash.file(media),
              let parts = manifest["parts"] as? [[String: Any]], !parts.isEmpty else {
            throw ProbeFailure("selected manifest is not bound to Short-RU media")
        }
        var result: [[String: Any]] = []
        var selectedText = ""
        for part in parts {
            guard let attempt = part["selected_attempt"] as? String,
                  attempt == "initial" || attempt == "retry",
                  let artifacts = part["artifacts"] as? [String: Any] else {
                throw ProbeFailure("selected attempt identity is missing")
            }
            var record: [String: Any] = ["partID": part["id"] as? String ?? "", "selectedAttempt": attempt]
            for kind in ["txt", "srt", "json_full"] {
                guard let artifact = artifacts[kind] as? [String: Any],
                      let path = artifact["path"] as? String,
                      let sha = artifact["sha256"] as? String,
                      sha == SelectedTimingHash.file(manifestURL.deletingLastPathComponent().appendingPathComponent(path)) else {
                    throw ProbeFailure("\(kind) does not belong to selected attempt")
                }
                record["\(kind)SHA256"] = sha
                if kind == "txt" {
                    selectedText += try String(
                        contentsOf: manifestURL.deletingLastPathComponent().appendingPathComponent(path),
                        encoding: .utf8
                    )
                }
            }
            result.append(record)
        }
        try require(!selectedText.contains("Вопросы и ответы")
                    && selectedText.localizedCaseInsensitiveContains("Элина")
                    && selectedText.localizedCaseInsensitiveContains("Клиентов"),
                    "selected-attempt TXT lacks Short-RU conversation or contains the false phrase")
        return result
    }

    @MainActor
    private static func waitUntil(_ label: String, seconds: TimeInterval, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { throw ProbeFailure("Timed out: \(label)") }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw ProbeFailure(message) }
    }
}

private struct ProbeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
