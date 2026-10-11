import Foundation
import Darwin

struct ProbeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
final class RecordingTopicAdapter: TopicAdapter {
    let name = TopicAlgorithmIdentity.hybridAdapter
    private(set) var calls = 0
    private(set) var granularities: [TopicGranularity] = []
    var delayNanoseconds: UInt64 = 0
    var ignoresCancellation = false

    func buildTopics(
        from cues: [SubtitleCue],
        sourceSRT: URL,
        context: TopicBuildContext,
        onProgress: @escaping (Double) -> Void,
        onLog: @escaping (String) -> Void
    ) async throws -> TopicsFile {
        calls += 1
        granularities.append(context.granularity)
        onProgress(0.25)
        if delayNanoseconds > 0 {
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch is CancellationError where ignoresCancellation {
                // Deliberately return a completed result after cancellation so
                // the engine's post-adapter persistence boundary is exercised.
            }
        }
        if !ignoresCancellation { try Task.checkCancellation() }
        onProgress(1)
        let text = try String(contentsOf: sourceSRT, encoding: .utf8)
        return TopicsFile(
            adapter: name,
            createdAt: Date(),
            sourceSRT: sourceSRT.path,
            sourceSignature: StableTopicHash.string(text),
            status: .ready,
            granularity: context.granularity,
            embeddingModel: "fixture-embedding",
            languageModel: "fixture-language",
            topics: [TopicSegment(
                id: "topic-1",
                title: "Готовая тема проекта",
                start: cues.first?.start ?? 0,
                end: cues.last?.end ?? 0,
                summary: "Тема из принятой расшифровки.",
                keywords: ["тема", "проект"],
                confidence: 0.95,
                boundaryReason: "Fixture boundary.",
                cueIds: cues.map(\.id)
            )]
        )
    }
}

@main
struct SimpleTopicsProbe {
    @MainActor
    static func main() async {
        do {
            guard let path = ProcessInfo.processInfo.environment["VIDEOTEXT_EPHEMERAL_WORK_ROOT"],
                  ProcessInfo.processInfo.environment["VIDEOTEXT_TMP_RUNNER"] == "1" else {
                throw ProbeFailure(message: "Run through scripts/test_simple_topics.sh")
            }
            let root = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("simple-topics-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let history = ProjectHistoryStore(indexURL: root.appendingPathComponent("history.json"))
            let store = ProjectStore(history: history)

            try await verifySimpleLifecycle(root: root, store: store, history: history)
            try await verifyCancelResume(root: root, store: store, history: history)
            try verifyMissingApprovalRefuses(root: root, store: store, history: history)
            try await verifyReuseGuard(root: root, store: store)
            try await verifyApprovedRevisionRaceGuards(root: root, store: store, history: history)
            try await verifyMalformedReusedTopicsRejected(root: root, store: store, history: history)
            try await verifyAdvancedReviewUnchanged(root: root, store: store)
            try assertNoOwnedChildGroups()
            print("SIMPLE_TOPICS_PROBE_PASS")
        } catch {
            fputs("SIMPLE_TOPICS_PROBE_FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func verifySimpleLifecycle(
        root: URL,
        store: ProjectStore,
        history: ProjectHistoryStore
    ) async throws {
        let fixture = try makeAcceptedFixture(root: root, store: store, name: "simple")
        let adapter = RecordingTopicAdapter()
        let engine = WorkflowEngine(store: store, hybridTopicAdapter: adapter)
        let model = WorkflowViewModel(engine: engine, store: store, historyStore: history)
        model.openProject(fixture.project)
        model.topicGranularity = .coarse

        let request = try value(model.simpleTopicsWorkflowRequest, "Accepted source did not expose Simple topics")
        try require(request.operations == [.topicTimecoding], "Simple request contains non-topic selected operations")
        try require(request.language == .ru && request.granularity == .coarse,
                    "Simple request lost the source language or explicit canonical granularity")
        try require(model.canCreateTopicsFromAcceptedTranscript, "Simple topics eligibility disagrees with its request")
        try require(model.startSimpleTopicsFromAcceptedTranscript(), "Simple topics request did not start")
        try require(model.isRunning, "Simple topics request did not enter running state")
        try await waitUntil("Simple topics completion") { !model.isRunning }

        let layout = ProjectLayout(root: fixture.project)
        let manifest = try store.load(from: fixture.project)
        let key = "ru.coarse"
        let activeID = try value(manifest.topicReviewState?.activeRevisionIDs[key], "Simple topics were not approved")
        let active = try value(manifest.topicRevisions?.first(where: { $0.id == activeID }), "Active topic revision is missing")
        try require(active.status == .approved, "Simple topics did not become ready")
        try require(manifest.topicReviewState?.enabled == true,
                    "Simple run changed the persisted Advanced topic-review preference")
        try require(manifest.humanReviewState?.fillerAnalysisBeforeReview == true,
                    "Simple run changed the persisted Advanced filler preference")
        try require(manifest.topicReviewState?.pendingCheckpoint == nil && model.topicReviewCheckpoint == nil,
                    "Simple run exposed topic correction instead of a ready result")
        try require(adapter.calls == 1 && adapter.granularities == [.coarse],
                    "Simple run generated the wrong number of topic variants")
        try require(nonempty(layout.topicsURL(language: .ru, granularity: .coarse))
                    && nonempty(layout.topicsTextURL(language: .ru, granularity: .coarse)),
                    "Simple run did not save its selected canonical topic variant")
        try require(!nonempty(layout.topicsURL(language: .ru, granularity: .normal))
                    && !nonempty(layout.topicsURL(language: .ru, granularity: .detailed)),
                    "Simple run created unselected topic variants")
        try require(manifest.workflow?.operations[WorkflowOperation.transcribe.rawValue]?.status == .skipped,
                    "Simple topics did not reuse the accepted transcription")
        try require(manifest.workflow?.operations[WorkflowOperation.translateTranscript.rawValue] == nil,
                    "Simple topics scheduled translation")
        try require(!model.log.text.contains("Запуск: Расшифровать всё видео")
                    && !model.log.text.contains("Расшифровка bundled SeminarText"),
                    "Simple topics launched ASR")
        try require(model.progress.overallFraction == 1 && model.progress.remaining == 0,
                    "Simple topics did not publish completed progress")

        let reopened = WorkflowViewModel(store: store, historyStore: history)
        reopened.openProject(fixture.project)
        try require(!reopened.isRunning && !reopened.canCreateTopicsFromAcceptedTranscript,
                    "Reopen offered to regenerate ready topics")
        try require(reopened.topics.count == 1 && reopened.topicGranularity == .coarse,
                    "Reopen did not restore the selected ready topics")
        let callsBeforeResume = adapter.calls
        var resume = settings(for: fixture, granularity: .coarse)
        resume.topicHumanReviewEnabled = false
        let policy = WorkflowExecutionPolicy(
            requireReusableTranscription: true,
            preserveReviewPreferences: true,
            approvedTranscript: ApprovedTranscriptReuseRequirement(
                language: .ru,
                revisionID: "accepted-simple"
            )
        )
        _ = try await engine.run(settings: resume, policy: policy, onLog: { _ in })
        try require(adapter.calls == callsBeforeResume, "Ready topics were regenerated on resume")
        print("PASS accepted source -> one selected topic variant -> ready/open/reopen; no ASR or translation")
    }

    @MainActor
    private static func verifyCancelResume(
        root: URL,
        store: ProjectStore,
        history: ProjectHistoryStore
    ) async throws {
        let fixture = try makeAcceptedFixture(root: root, store: store, name: "cancel-resume")
        let adapter = RecordingTopicAdapter()
        adapter.delayNanoseconds = 30_000_000_000
        adapter.ignoresCancellation = true
        let engine = WorkflowEngine(store: store, hybridTopicAdapter: adapter)
        let model = WorkflowViewModel(engine: engine, store: store, historyStore: history)
        model.openProject(fixture.project)
        model.topicGranularity = .normal
        try require(model.startSimpleTopicsFromAcceptedTranscript(), "Cancelable Simple topics did not start")
        try await waitUntil("Simple topic adapter start") {
            adapter.calls == 1 && model.progress.operation == .topicTimecoding
        }
        model.stop()
        try require(model.isStopping, "Simple topic stop did not enter stopping state")
        try await waitUntil("Simple topic cancellation") { !model.isRunning }

        let cancelled = try store.load(from: fixture.project)
        try require(cancelled.workflow?.status == .stopped,
                    "Simple topic cancellation did not persist workflow .stopped")
        try require(cancelled.workflow?.operations[WorkflowOperation.topicTimecoding.rawValue]?.status == .stopped,
                    "Simple topic cancellation did not stop the active topic operation")
        try require(cancelled.topicReviewState?.activeRevisionIDs["ru.normal"] == nil,
                    "Cancelled Simple topics published a ready revision")
        let layout = ProjectLayout(root: fixture.project)
        try require(!nonempty(layout.topicsURL(language: .ru, granularity: .normal))
                    && !nonempty(layout.topicsTextURL(language: .ru, granularity: .normal)),
                    "Non-cooperative adapter persisted topics after cancellation")
        try require(cancelled.topicReviewState?.enabled == true
                    && cancelled.humanReviewState?.fillerAnalysisBeforeReview == true,
                    "Cancellation changed Advanced review preferences")
        try require(model.canCreateTopicsFromAcceptedTranscript,
                    "Cancelled Simple topics could not be resumed")

        adapter.delayNanoseconds = 0
        adapter.ignoresCancellation = false
        try require(model.startSimpleTopicsFromAcceptedTranscript(), "Simple topic resume did not start")
        try await waitUntil("Simple topic resume completion") { !model.isRunning }
        let resumed = try store.load(from: fixture.project)
        let activeID = try value(resumed.topicReviewState?.activeRevisionIDs["ru.normal"],
                                 "Resumed Simple topics did not publish a ready revision")
        try require(resumed.topicRevisions?.first(where: { $0.id == activeID })?.status == .approved,
                    "Resumed Simple topics were not approved")
        try require(adapter.calls == 2, "Cancel/resume used the topic adapter an unexpected number of times")
        try require(!model.canCreateTopicsFromAcceptedTranscript,
                    "Completed resume still offers topic regeneration")
        print("PASS Simple topic stop -> workflow stopped -> resume -> ready")
    }

    @MainActor
    private static func verifyMissingApprovalRefuses(
        root: URL,
        store: ProjectStore,
        history: ProjectHistoryStore
    ) throws {
        let fixture = try makeAcceptedFixture(root: root, store: store, name: "unapproved")
        try store.mutate(fixture.project) { manifest in
            manifest.humanReviewState?.activeRevisionIDs = [:]
            manifest.transcriptRevisions?[0].reviewStatus = .pending
        }
        let model = WorkflowViewModel(store: store, historyStore: history)
        model.openProject(fixture.project)
        let before = try Data(contentsOf: ProjectLayout(root: fixture.project).manifestURL)
        try require(!model.canCreateTopicsFromAcceptedTranscript,
                    "Unapproved source exposed Simple topic creation")
        try require(!model.startSimpleTopicsFromAcceptedTranscript() && !model.isRunning,
                    "Unapproved source started a workflow")
        let after = try Data(contentsOf: ProjectLayout(root: fixture.project).manifestURL)
        try require(after == before,
                    "Rejected Simple request mutated the project")
        print("PASS missing approval -> refusal without workflow mutation")
    }

    private static func verifyReuseGuard(root: URL, store: ProjectStore) async throws {
        let fixture = try makeAcceptedFixture(root: root, store: store, name: "reuse-guard")
        let layout = ProjectLayout(root: fixture.project)
        try Data("{\"transcription\":[]}".utf8).write(to: layout.whisperJSONURL, options: .atomic)
        let adapter = RecordingTopicAdapter()
        let engine = WorkflowEngine(store: store, hybridTopicAdapter: adapter)
        var guarded = settings(for: fixture, granularity: .normal)
        guarded.topicHumanReviewEnabled = false
        let policy = WorkflowExecutionPolicy(
            requireReusableTranscription: true,
            preserveReviewPreferences: true,
            approvedTranscript: ApprovedTranscriptReuseRequirement(
                language: .ru,
                revisionID: "accepted-reuse-guard"
            )
        )
        var logs: [String] = []
        do {
            _ = try await engine.run(settings: guarded, policy: policy, onLog: { logs.append($0) })
            throw ProbeFailure(message: "Unsafe transcription reuse unexpectedly succeeded")
        } catch let error as WorkflowError {
            try require(error.localizedDescription.contains("Повторный Whisper не запускался"),
                        "Unsafe reuse returned the wrong failure: \(error.localizedDescription)")
        }
        try require(adapter.calls == 0 && !logs.contains(where: { $0.contains("Запуск: Расшифровать всё видео") }),
                    "Reuse guard allowed ASR or topic generation")
        try require(!FileManager.default.fileExists(atPath: layout.seminarTextCoreDirectory.path),
                    "Reuse guard created SeminarText output")
        print("PASS unusable evidence -> fail closed before ASR")
    }

    @MainActor
    private static func verifyApprovedRevisionRaceGuards(
        root: URL,
        store: ProjectStore,
        history: ProjectHistoryStore
    ) async throws {
        for mutation in ["divergent-srt", "revoked-approval"] {
            let fixture = try makeAcceptedFixture(root: root, store: store, name: mutation)
            let adapter = RecordingTopicAdapter()
            let engine = WorkflowEngine(store: store, hybridTopicAdapter: adapter)
            let model = WorkflowViewModel(engine: engine, store: store, historyStore: history)
            model.openProject(fixture.project)
            let request = try value(model.simpleTopicsWorkflowRequest,
                                    "Race fixture was not eligible before \(mutation)")
            let policy = WorkflowExecutionPolicy(
                requireReusableTranscription: true,
                preserveReviewPreferences: true,
                approvedTranscript: ApprovedTranscriptReuseRequirement(
                    language: request.language,
                    revisionID: request.approvedRevisionID
                )
            )
            if mutation == "divergent-srt" {
                let changed = [
                    SubtitleCue(id: 1, start: 0, end: 2, text: "Другой валидный принятый текст."),
                    SubtitleCue(id: 2, start: 2, end: 4, text: "Он не совпадает с immutable revision.")
                ]
                let layout = ProjectLayout(root: fixture.project)
                try SRTService().writePreservingIDs(changed, to: layout.fullSRTURL)
                try SRTService().writePreservingIDs(changed, to: layout.subtitlesURL(language: .ru))
            } else {
                try store.mutate(fixture.project) { manifest in
                    manifest.humanReviewState?.activeRevisionIDs.removeValue(forKey: "ru")
                    manifest.transcriptRevisions?[0].reviewStatus = .pending
                }
            }
            do {
                _ = try await engine.run(
                    settings: settings(for: fixture, granularity: request.granularity),
                    policy: policy,
                    onLog: { _ in }
                )
                throw ProbeFailure(message: "Runtime accepted \(mutation) after Simple preflight")
            } catch let error as WorkflowError {
                try require(error.localizedDescription.contains("принятая расшифровка изменилась"),
                            "Runtime returned the wrong \(mutation) failure: \(error.localizedDescription)")
            }
            try require(adapter.calls == 0,
                        "Runtime started topics after \(mutation)")
            let layout = ProjectLayout(root: fixture.project)
            try require(!nonempty(layout.topicsURL(language: .ru, granularity: request.granularity)),
                        "Runtime persisted topics after \(mutation)")
        }
        print("PASS valid-but-divergent SRT and revoked approval fail before topic generation")
    }

    @MainActor
    private static func verifyMalformedReusedTopicsRejected(
        root: URL,
        store: ProjectStore,
        history: ProjectHistoryStore
    ) async throws {
        let fixture = try makeAcceptedFixture(root: root, store: store, name: "malformed-topics")
        let layout = ProjectLayout(root: fixture.project)
        let sourceText = try String(contentsOf: layout.subtitlesURL(language: .ru), encoding: .utf8)
        let malformed = TopicsFile(
            adapter: TopicAlgorithmIdentity.hybridAdapter,
            createdAt: Date(),
            sourceSRT: layout.subtitlesURL(language: .ru).path,
            sourceSignature: StableTopicHash.string(sourceText),
            status: .ready,
            granularity: .normal,
            embeddingModel: "fixture-embedding",
            languageModel: "fixture-language",
            topics: [TopicSegment(
                id: "topic-1",
                title: "Невалидная тема",
                start: 0,
                end: 4,
                summary: "Содержит неизвестные cue identifiers.",
                keywords: ["invalid"],
                confidence: 0.9,
                boundaryReason: "Invalid fixture.",
                sourceCueStart: 999,
                sourceCueEnd: 999,
                cueIds: [999]
            )]
        )
        try TopicFileService().save(
            malformed,
            projectURL: fixture.project,
            language: .ru,
            granularity: .normal,
            updateLegacyFiles: true
        )
        let adapter = RecordingTopicAdapter()
        let engine = WorkflowEngine(store: store, hybridTopicAdapter: adapter)
        let model = WorkflowViewModel(engine: engine, store: store, historyStore: history)
        model.openProject(fixture.project)
        let request = try value(model.simpleTopicsWorkflowRequest,
                                "Malformed unapproved topics unexpectedly hid the Simple create action")
        let policy = WorkflowExecutionPolicy(
            requireReusableTranscription: true,
            preserveReviewPreferences: true,
            approvedTranscript: ApprovedTranscriptReuseRequirement(
                language: request.language,
                revisionID: request.approvedRevisionID
            )
        )
        var simpleSettings = settings(for: fixture, granularity: .normal)
        simpleSettings.topicHumanReviewEnabled = false
        do {
            _ = try await engine.run(
                settings: simpleSettings,
                policy: policy,
                onLog: { _ in }
            )
            throw ProbeFailure(message: "Malformed reused topics were auto-approved")
        } catch let error as WorkflowError {
            try require(error.localizedDescription.contains("cue")
                        || error.localizedDescription.contains("реплик"),
                        "Malformed topics returned the wrong validation failure: \(error.localizedDescription)")
        }
        let manifest = try store.load(from: fixture.project)
        try require(adapter.calls == 0, "Malformed current topics were recomputed instead of strictly rejected")
        try require(manifest.topicReviewState?.activeRevisionIDs["ru.normal"] == nil,
                    "Malformed topics acquired an active approved revision")
        try require(manifest.topicReviewState?.pendingCheckpoint == nil,
                    "Malformed topics created a review checkpoint in Simple")
        print("PASS malformed current topics fail strict validation before auto-approval")
    }

    private static func verifyAdvancedReviewUnchanged(root: URL, store: ProjectStore) async throws {
        let fixture = try makeAcceptedFixture(root: root, store: store, name: "advanced")
        let adapter = RecordingTopicAdapter()
        let engine = WorkflowEngine(store: store, hybridTopicAdapter: adapter)
        var advanced = settings(for: fixture, granularity: .detailed)
        advanced.topicHumanReviewEnabled = true
        let result = try await engine.run(settings: advanced, onLog: { _ in })
        let manifest = try store.load(from: fixture.project)
        try require(result.topicReviewCheckpoint != nil && manifest.topicReviewState?.pendingCheckpoint != nil,
                    "Advanced topic run lost its review checkpoint")
        try require(manifest.topicReviewState?.enabled == true,
                    "Advanced topic-review preference changed")
        try require(adapter.calls == 1 && adapter.granularities == [.detailed],
                    "Advanced run did not retain its selected topic variant")
        print("PASS Advanced topic review remains enabled and pending")
    }

    private static func settings(
        for fixture: (project: URL, media: URL),
        granularity: TopicGranularity
    ) -> WorkflowSettings {
        WorkflowSettings(
            mediaURL: fixture.media,
            projectURL: fixture.project,
            selectedOperations: [.topicTimecoding],
            mode: .resumeProject,
            rangeStart: 0,
            rangeEnd: 1,
            fragmentName: "",
            burnFragmentSubtitles: false,
            subtitleStyle: .standard,
            selectedTopicID: nil,
            whisperModelPath: "/intentionally/not/used/whisper-model.bin",
            whisperLanguage: "ru",
            topicGranularity: granularity,
            artifactLanguage: .ru,
            sourceHumanReviewEnabled: true,
            translationHumanReviewEnabled: false,
            fillerAnalysisBeforeReview: false,
            topicHumanReviewEnabled: true
        )
    }

    private static func makeAcceptedFixture(
        root: URL,
        store: ProjectStore,
        name: String
    ) throws -> (project: URL, media: URL) {
        let media = root.appendingPathComponent("\(name).wav")
        try writeSilentWAV(to: media, seconds: 5)
        let project = root.appendingPathComponent("\(name)-project", isDirectory: true)
        _ = try store.ensureProject(at: project, mediaURL: media, mode: .resumeProject)
        let layout = ProjectLayout(root: project)
        let cues = [
            SubtitleCue(id: 1, start: 0, end: 2, text: "Первая содержательная реплика о проекте."),
            SubtitleCue(id: 2, start: 2, end: 4, text: "Вторая содержательная реплика завершает тему.")
        ]
        try SRTService().writePreservingIDs(cues, to: layout.fullSRTURL)
        try SRTService().writePreservingIDs(cues, to: layout.subtitlesURL(language: .ru))
        let transcript = cues.map(\.text).joined(separator: "\n\n") + "\n"
        try transcript.write(to: layout.transcriptURL, atomically: true, encoding: .utf8)
        try transcript.write(to: layout.transcriptURL(language: .ru), atomically: true, encoding: .utf8)

        let revisionID = "accepted-\(name)"
        try SRTService().writePreservingIDs(cues, to: layout.subtitleRevisionURL(id: revisionID, language: .ru))
        try transcript.write(
            to: layout.transcriptRevisionURL(id: revisionID, language: .ru),
            atomically: true,
            encoding: .utf8
        )
        let srtText = try String(contentsOf: layout.fullSRTURL, encoding: .utf8)
        let revision = TranscriptRevision(
            id: revisionID,
            language: .ru,
            origin: .userEdited,
            parentRevisionID: nil,
            transcriptArtifactID: "artifact-\(revisionID)-txt",
            subtitleArtifactID: "artifact-\(revisionID)-srt",
            contentHash: StableTopicHash.string(srtText),
            createdAt: Date(),
            reviewStatus: .approved
        )
        let whisper: [String: Any] = [
            "result": ["language": "ru"],
            "transcription": [[
                "tokens": [["text": " реплика", "offsets": ["from": 0, "to": 500]]]
            ]]
        ]
        try JSONSerialization.data(withJSONObject: whisper, options: [.sortedKeys])
            .write(to: layout.whisperJSONURL, options: .atomic)
        try Data("{\"fixture\":true}".utf8).write(to: layout.languageDetectionURL, options: .atomic)
        try Data("{\"fixture\":true}".utf8).write(to: layout.transcriptionQualityURL, options: .atomic)
        try Data("[]".utf8).write(to: layout.reviewTasksURL, options: .atomic)
        try "<html>fixture</html>".write(to: layout.transcriptReviewHTMLURL, atomically: true, encoding: .utf8)
        try "Временная шкала корректна.\n".write(to: layout.timelineValidationURL, atomically: true, encoding: .utf8)

        try store.mutate(project) { manifest in
            manifest.durationSeconds = 5
            manifest.languageProfile = LanguageProfile(
                detected: .ru,
                effective: .ru,
                confidence: 1,
                method: "fixture",
                model: nil,
                modelVersion: nil,
                sampleRanges: [],
                manuallyOverridden: false,
                detectedAt: Date()
            )
            manifest.transcriptRevisions = [revision]
            manifest.humanReviewState = HumanReviewState(
                sourceReviewEnabled: true,
                translationReviewEnabled: false,
                fillerAnalysisBeforeReview: true,
                activeRevisionIDs: ["ru": revisionID],
                draftRevisionIDs: [:],
                pendingCheckpoint: nil
            )
            manifest.topicRevisions = []
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
    private static func waitUntil(
        _ label: String,
        seconds: TimeInterval = 30,
        condition: () throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !(try condition()) {
            guard Date() < deadline else { throw ProbeFailure(message: "Timed out: \(label)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func assertNoOwnedChildGroups() throws {
        let namespace = OwnedTemporaryWorkspace.namespace
        guard FileManager.default.fileExists(atPath: namespace.path) else { return }
        for directory in try FileManager.default.contentsOfDirectory(at: namespace, includingPropertiesForKeys: nil) {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("owner.json")),
                  let receipt = try? JSONDecoder().decode(OwnedTemporaryWorkspace.Receipt.self, from: data),
                  receipt.pid == getpid() else { continue }
            try require(!receipt.launchPending, "Probe left an owned pending child launch")
            if let group = receipt.childGroup {
                let result = kill(-group, 0)
                try require(result == -1 && errno == ESRCH, "Probe left an active owned child group: \(group)")
            }
        }
    }

    private static func nonempty(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }

    private static func value<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw ProbeFailure(message: message) }
        return value
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}
