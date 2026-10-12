import Foundation
import Darwin

struct SimpleSourceSubtitlesProbeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
struct SimpleSourceSubtitlesProbe {
    @MainActor
    static func main() async {
        do {
            guard let path = ProcessInfo.processInfo.environment["VIDEOTEXT_EPHEMERAL_WORK_ROOT"],
                  ProcessInfo.processInfo.environment["VIDEOTEXT_TMP_RUNNER"] == "1" else {
                throw SimpleSourceSubtitlesProbeFailure(message: "Run through scripts/test_simple_source_subtitles.sh")
            }
            let root = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("simple-source-subtitles-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            try await verifyHealthyRequestStartsOnlyBurn(root: root)
            try verifyMissingOrStaleReuseRefusesBeforeLaunch(root: root)
            print("SIMPLE_SOURCE_SUBTITLES_PROBE_PASS")
        } catch {
            fputs("SIMPLE_SOURCE_SUBTITLES_PROBE_FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func verifyHealthyRequestStartsOnlyBurn(root: URL) async throws {
        let fixture = try makeAcceptedFixture(root: root, name: "healthy")
        let history = ProjectHistoryStore(indexURL: root.appendingPathComponent("healthy-history.json"))
        let store = ProjectStore(history: history)
        let controller = ProcessController()
        let model = WorkflowViewModel(
            engine: WorkflowEngine(store: store, controller: controller),
            store: store,
            historyStore: history
        )
        model.openProject(fixture.project)
        model.selectedOperations = [.transcribe, .topicTimecoding]
        model.subtitleSource = .approvedTranslation(.en)
        model.subtitleStyle = SubtitleStyleSettings(
            textColorHex: "#FFFFFF", outlineColorHex: "#000000", fontName: "Helvetica", fontSize: 26,
            outlineWidth: 3, position: .bottom, backgroundOpacity: 0.3
        )
        let advancedOperations = model.selectedOperations
        let advancedSource = model.subtitleSource
        let advancedStyle = model.subtitleStyle

        let request = try requireValue(
            model.simpleSourceSubtitleWorkflowRequest,
            "Accepted canonical source did not expose the Simple source-subtitle request"
        )
        try require(request.operations == [.burnSubtitles], "Simple request scheduled operations besides burnSubtitles")
        try require(request.subtitleSource == .source && request.subtitleStyle == .standard,
                    "Simple request did not fix source SRT and standard subtitle style")
        try require(request.language == .ru, "Simple request lost the approved source language")
        try require(model.canCreateSourceSubtitledVideoFromAcceptedTranscript,
                    "Simple subtitle eligibility disagrees with its request")
        try require(model.startSimpleSourceSubtitledVideoFromAcceptedTranscript(),
                    "Healthy source subtitle request did not enter the workflow")
        try require(model.isRunning && !model.isStopping,
                    "Healthy source subtitle request did not enter running state")
        try require(model.selectedOperations == advancedOperations
                    && model.subtitleSource == advancedSource
                    && model.subtitleStyle == advancedStyle,
                    "Simple source-subtitle start rewrote Advanced presentation selections")
        model.stop()
        try await waitUntil("immediate source-subtitle cancellation") { !model.isRunning }
        try require(model.status == "Остановлено", "Immediate source-subtitle cancellation did not use normal lifecycle")
        try require(controller.launchedExecutables.isEmpty,
                    "Immediate Simple request launched an external tool: \(controller.launchedExecutables)")
        let operations = (try store.load(from: fixture.project)).workflow?.operations ?? [:]
        try require(operations[WorkflowOperation.transcribe.rawValue] == nil
                    && operations[WorkflowOperation.topicTimecoding.rawValue] == nil,
                    "Simple source subtitle start scheduled ASR or topics")
        print("PASS accepted source -> fixed burnSubtitles request; cancellation launches neither ASR nor topics")
    }

    @MainActor
    private static func verifyMissingOrStaleReuseRefusesBeforeLaunch(root: URL) throws {
        for condition in ["missing-evidence", "stale-srt"] {
            let fixture = try makeAcceptedFixture(root: root, name: condition)
            let history = ProjectHistoryStore(indexURL: root.appendingPathComponent("\(condition)-history.json"))
            let store = ProjectStore(history: history)
            let controller = ProcessController()
            let model = WorkflowViewModel(
                engine: WorkflowEngine(store: store, controller: controller),
                store: store,
                historyStore: history
            )
            model.openProject(fixture.project)
            let layout = ProjectLayout(root: fixture.project)
            if condition == "missing-evidence" {
                try FileManager.default.removeItem(at: layout.whisperJSONURL)
            } else {
                let changed = [
                    SubtitleCue(id: 1, start: 0, end: 2, text: "Stale local source subtitle."),
                    SubtitleCue(id: 2, start: 2, end: 4, text: "It must not replace the accepted revision.")
                ]
                try SRTService().writePreservingIDs(changed, to: layout.fullSRTURL)
                try SRTService().writePreservingIDs(changed, to: layout.subtitlesURL(language: .ru))
            }
            let before = try Data(contentsOf: layout.manifestURL)
            try require(!model.canCreateSourceSubtitledVideoFromAcceptedTranscript
                        && model.simpleSourceSubtitleWorkflowRequest == nil,
                        "\(condition) unexpectedly exposed source subtitle rendering")
            try require(!model.startSimpleSourceSubtitledVideoFromAcceptedTranscript() && !model.isRunning,
                        "\(condition) unexpectedly entered a workflow")
            let after = try Data(contentsOf: layout.manifestURL)
            try require(after == before, "\(condition) mutated the manifest before refusing")
            try require(controller.launchedExecutables.isEmpty,
                        "\(condition) launched an external process: \(controller.launchedExecutables)")
            let operations = (try store.load(from: fixture.project)).workflow?.operations ?? [:]
            try require(operations[WorkflowOperation.transcribe.rawValue] == nil
                        && operations[WorkflowOperation.topicTimecoding.rawValue] == nil,
                        "\(condition) started ASR or topics")
        }
        print("PASS missing or stale approved-source requirements fail closed before process launch")
    }

    private static func makeAcceptedFixture(root: URL, name: String) throws -> (project: URL, media: URL) {
        let media = root.appendingPathComponent("\(name).wav")
        try writeSilentWAV(to: media, seconds: 5)
        let project = root.appendingPathComponent("\(name)-project", isDirectory: true)
        let store = ProjectStore()
        _ = try store.ensureProject(at: project, mediaURL: media, mode: .resumeProject)
        let layout = ProjectLayout(root: project)
        let cues = [
            SubtitleCue(id: 1, start: 0, end: 2, text: "Approved source subtitle one."),
            SubtitleCue(id: 2, start: 2, end: 4, text: "Approved source subtitle two.")
        ]
        try SRTService().writePreservingIDs(cues, to: layout.fullSRTURL)
        try SRTService().writePreservingIDs(cues, to: layout.subtitlesURL(language: .ru))
        let revisionID = "approved-\(name)"
        try SRTService().writePreservingIDs(cues, to: layout.subtitleRevisionURL(id: revisionID, language: .ru))
        let transcript = cues.map(\.text).joined(separator: "\n\n") + "\n"
        try transcript.write(to: layout.transcriptURL, atomically: true, encoding: .utf8)
        try transcript.write(to: layout.transcriptURL(language: .ru), atomically: true, encoding: .utf8)
        try transcript.write(to: layout.transcriptRevisionURL(id: revisionID, language: .ru), atomically: true, encoding: .utf8)
        let srtText = try String(contentsOf: layout.fullSRTURL, encoding: .utf8)
        let revision = TranscriptRevision(
            id: revisionID,
            language: .ru,
            origin: .userEdited,
            parentRevisionID: nil,
            transcriptArtifactID: "\(revisionID)-txt",
            subtitleArtifactID: "\(revisionID)-srt",
            contentHash: StableTopicHash.string(srtText),
            createdAt: Date(),
            reviewStatus: .approved
        )
        let whisper: [String: Any] = [
            "result": ["language": "ru"],
            "transcription": [["tokens": [["text": " subtitle", "offsets": ["from": 0, "to": 500]]]]]
        ]
        try JSONSerialization.data(withJSONObject: whisper, options: [.sortedKeys])
            .write(to: layout.whisperJSONURL, options: .atomic)
        try store.mutate(project) { manifest in
            manifest.durationSeconds = 5
            manifest.languageProfile = LanguageProfile(
                detected: .ru, effective: .ru, confidence: 1, method: "fixture",
                model: nil, modelVersion: nil, sampleRanges: [], manuallyOverridden: false, detectedAt: Date()
            )
            manifest.transcriptRevisions = [revision]
            manifest.humanReviewState = HumanReviewState(
                sourceReviewEnabled: true, translationReviewEnabled: false, fillerAnalysisBeforeReview: true,
                activeRevisionIDs: ["ru": revisionID], draftRevisionIDs: [:], pendingCheckpoint: nil
            )
            manifest.topicReviewState = .newProjectDefault
            manifest.workflow?.status = .completed
        }
        return (project, media)
    }

    private static func writeSilentWAV(to url: URL, seconds: Int) throws {
        let sampleRate = 8_000
        let sampleCount = sampleRate * seconds
        let dataSize = sampleCount * 2
        var data = Data()
        func append(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func append(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8)); append(UInt32(36 + dataSize)); data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(dataSize)); data.append(Data(repeating: 0, count: dataSize))
        try data.write(to: url, options: .atomic)
    }

    @MainActor
    private static func waitUntil(_ label: String, condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !(try condition()) {
            guard Date() < deadline else { throw SimpleSourceSubtitlesProbeFailure(message: "Timed out: \(label)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw SimpleSourceSubtitlesProbeFailure(message: message) }
        return value
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SimpleSourceSubtitlesProbeFailure(message: message) }
    }
}
