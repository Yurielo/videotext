import Foundation
import Darwin

@main
struct SimpleTranscriptionProbe {
    @MainActor
    static func main() async {
        do {
            guard let path = ProcessInfo.processInfo.environment["VIDEOTEXT_EPHEMERAL_WORK_ROOT"],
                  ProcessInfo.processInfo.environment["VIDEOTEXT_TMP_RUNNER"] == "1" else {
                throw ProbeFailure(message: "Run through scripts/test_simple_transcription.sh")
            }
            let root = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("fixtures-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = ProjectStore(history: ProjectHistoryStore(indexURL: root.appendingPathComponent("history.json")))
            try testExpansion()
            try testEligibility(root: root, store: store)
            try testLanguageContract(root: root, store: store)
            for language in ArtifactLanguage.allCases {
                try testReviewLifecycle(root: root, store: store, language: language)
            }
            for preference in [false, true] {
                try await testActualRequestTermination(root: root, store: store, preference: preference, cancel: false)
                try await testActualRequestTermination(root: root, store: store, preference: preference, cancel: true)
            }
            try await testActualRequestTermination(root: root, store: store, preference: false,
                                                  cancel: false, persistedPreference: true)
            try await testActualRequestTermination(root: root, store: store, preference: false,
                                                  cancel: true, applicationTermination: true)
            print("SIMPLE_TRANSCRIPTION_PROBE_PASS")
            print("GAP: completed ASR -> automatic review/accept and native Quit -> reopen, including notification wait, require actual Candidate evidence")
        } catch {
            fputs("SIMPLE_TRANSCRIPTION_PROBE_FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func testExpansion() throws {
        let engine = WorkflowEngine()
        for filler in [false, true] {
            var expected: [WorkflowOperation] = [
                .diagnostics, .createManifest, .detectLanguage, .transcribe, .assessTranscriptionQuality
            ]
            if filler { expected.append(.detectFillerWords) }
            expected += [.validateTimeline, .discoverResults]
            let expanded = engine.expanded([.validateTimeline], includeFillerAnalysisBeforeReview: filler)
            try require(expanded == expected, "Source-only expansion changed (filler=\(filler))")
            let checkpointOperation: WorkflowOperation = filler ? .detectFillerWords : .assessTranscriptionQuality
            let index = try value(expanded.firstIndex(of: checkpointOperation), "Missing review boundary")
            try require(Array(expanded.dropFirst(index + 1)) == [.validateTimeline, .discoverResults],
                        "Source review continuation contains non-source work")
        }
        print("PASS source-only expansion; filler off/on")
    }

    @MainActor
    private static func testEligibility(root: URL, store: ProjectStore) throws {
        let fixture = try makeFixture(root: root, store: store, name: "eligibility", language: nil)
        let model = WorkflowViewModel()
        try reject(model, "no project/media")
        model.projectURL = fixture.project
        try reject(model, "no media")
        model.mediaURL = fixture.media
        model.selectedOperations = [.topicTimecoding, .translateTranscript, .burnSubtitles]
        model.sourceHumanReviewEnabled = false
        model.translationHumanReviewEnabled = true
        let before = try Data(contentsOf: ProjectLayout(root: fixture.project).manifestURL)
        for language in ["ru", "en", "auto"] {
            model.whisperLanguage = language
            try require(model.canStartSimpleTranscription, "Empty project rejected for \(language)")
        }
        try require(try Data(contentsOf: ProjectLayout(root: fixture.project).manifestURL) == before,
                    "Eligibility mutated project")
        try require(model.selectedOperations == [.topicTimecoding, .translateTranscript, .burnSubtitles]
                    && !model.sourceHumanReviewEnabled && model.translationHumanReviewEnabled,
                    "Eligibility mutated Advanced settings")

        model.isRunning = true
        try reject(model, "busy/double start")
        model.isStopping = true
        try reject(model, "stopping active run")
        model.isRunning = false
        model.isStopping = false
        let checkpoint = HumanReviewCheckpoint(kind: .sourceTranscript, language: .ru,
                                              revisionID: "pending", pendingOperations: [], createdAt: Date())
        model.humanReviewCheckpoint = checkpoint
        try reject(model, "in-memory Source checkpoint")
        var translation = checkpoint
        translation.kind = .translatedTranscript
        translation.language = .en
        model.humanReviewCheckpoint = translation
        try reject(model, "in-memory other-language checkpoint")
        model.humanReviewCheckpoint = nil
        model.topicReviewCheckpoint = TopicReviewCheckpoint(revisionIDs: [:], pendingOperations: [], createdAt: Date())
        try reject(model, "in-memory Topics checkpoint")
        model.topicReviewCheckpoint = nil

        for persisted in [checkpoint, translation] {
            try store.mutate(fixture.project) { manifest in
                manifest.humanReviewState?.pendingCheckpoint = persisted
            }
            try reject(model, "persisted checkpoint with stale empty VM state")
        }
        try store.mutate(fixture.project) { manifest in
            manifest.humanReviewState?.pendingCheckpoint = nil
            manifest.topicReviewState?.pendingCheckpoint = TopicReviewCheckpoint(
                revisionIDs: [:], pendingOperations: [], createdAt: Date()
            )
        }
        try reject(model, "persisted Topics checkpoint")
        try store.mutate(fixture.project) { manifest in
            manifest.topicReviewState?.pendingCheckpoint = nil
        }
        for status: ProjectStatus in [.failed, .stopped] {
            try store.mutate(fixture.project) { manifest in
                manifest.workflow?.status = status
            }
            try require(model.canStartSimpleTranscription, "Retry blocked after \(status)")
        }
        try Data("invalid manifest".utf8).write(to: ProjectLayout(root: fixture.project).manifestURL)
        try reject(model, "corrupt manifest")
        print("PASS eligibility, rejection, pending languages, retry and corrupt manifest")
    }

    @MainActor
    private static func testActualRequestTermination(
        root: URL, store: ProjectStore, preference: Bool, cancel: Bool,
        persistedPreference: Bool? = nil, applicationTermination: Bool = false
    ) async throws {
        let savedPreference = persistedPreference ?? preference
        let action = applicationTermination ? "quit-cancellation" : (cancel ? "cancel" : "error")
        let label = "actual-\(action)-review-\(preference)-persisted-\(savedPreference)"
        let fixture = try makeFixture(root: root, store: store, name: label, language: nil)
        let layout = ProjectLayout(root: fixture.project)
        try store.mutate(fixture.project) { manifest in
            manifest.humanReviewState?.sourceReviewEnabled = savedPreference
        }
        let model = WorkflowViewModel()
        model.openProject(fixture.project)
        model.sourceHumanReviewEnabled = preference
        model.selectedOperations = [.topicTimecoding, .translateTranscript, .burnSubtitles]
        model.whisperLanguage = "en"
        // A second guard against inference even if a future engine moves language detection earlier.
        model.whisperModelPath = root.appendingPathComponent("intentionally-absent-whisper-model.bin").path
        let advancedOperations = model.selectedOperations
        let before = try store.load(from: fixture.project)
        try require(model.sourceHumanReviewEnabled == preference && model.canStartSimpleTranscription,
                    "Actual-request fixture is not eligible")
        try require(model.startSimpleTranscription() && model.isRunning, "Actual VM request did not start")
        do {
            try require(!model.startSimpleTranscription(), "Actual double-click scheduled a second run")
            // Observe an actual engine write, not a simulated HumanReviewService transition.
            try await waitUntil("engine persisted per-run Source Review", seconds: 30) {
                let manifest = try store.load(from: fixture.project)
                return manifest.workflow?.status == .running
                    && manifest.humanReviewState?.sourceReviewEnabled == true
            }
            if cancel {
                if applicationTermination {
                    // This is the app delegate's cancellation phase, not a simulated stop.
                    // Do not call prepareForApplicationTermination: it also unloads shared Ollama models.
                    model.cancelForApplicationTermination()
                } else {
                    model.stop()
                    try require(model.isStopping, "Actual stop did not enter stopping state")
                }
            } else {
                // Diagnostics is the first async boundary. Losing this owned input then fails
                // createManifest before language detection or any ASR/model invocation.
                try FileManager.default.removeItem(at: fixture.media)
            }
            try await waitUntil("actual VM termination", seconds: 30) { !model.isRunning }
            let after = try store.load(from: fixture.project)
            try require(after.workflow?.status == (cancel ? .stopped : .failed),
                        "Actual \(label) reported an incorrect terminal state")
            try require(after.humanReviewState?.sourceReviewEnabled == preference,
                        "Actual \(label) leaked per-run review into persisted Advanced preference")
            try require(model.sourceHumanReviewEnabled == preference
                        && model.selectedOperations == advancedOperations && model.whisperLanguage == "en"
                        && !model.isStopping && model.humanReviewCheckpoint == nil,
                        "Actual termination mutated Advanced settings or left busy/review state")
            try require(model.alert?.title == (cancel ? "Обработка остановлена" : "Ошибка обработки"),
                        "Actual termination presented false success or wrong error/cancel state")
            let operationKeys = Set(after.workflow?.operations.keys.map { $0 } ?? [])
            let earlyOnly = Set([WorkflowOperation.diagnostics.rawValue, WorkflowOperation.createManifest.rawValue])
            try require(operationKeys.isSubset(of: earlyOnly), "Unexpected operations before controlled failure")
            if !cancel {
                try require(after.workflow?.operations[WorkflowOperation.createManifest.rawValue]?.status == .failed,
                            "Missing-input failure did not occur at createManifest")
            }
            try require(after.transcriptRevisions == before.transcriptRevisions
                        && after.topicRevisions == before.topicRevisions
                        && after.humanReviewState?.pendingCheckpoint == nil
                        && !FileManager.default.fileExists(atPath: layout.whisperJSONURL.path)
                        && !FileManager.default.fileExists(atPath: layout.fullSRTURL.path),
                        "Controlled termination produced ASR/review/downstream artifacts")
            try assertNoOwnedChildGroups()
            if !cancel {
                // Recreate exactly this scratch input so openProject can verify its fingerprint.
                let originalDate = try value(before.sourceFingerprint?.modificationTime, "Missing fixture fingerprint")
                try Data("deterministic fixture; not real media".utf8).write(to: fixture.media)
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: originalDate)], ofItemAtPath: fixture.media.path
                )
            }
            let reopened = WorkflowViewModel()
            reopened.openProject(fixture.project)
            try require(reopened.projectURL?.standardizedFileURL == fixture.project.standardizedFileURL
                        && reopened.mediaURL != nil && reopened.alert == nil,
                        "Actual termination fixture failed to reopen")
            try require(reopened.sourceHumanReviewEnabled == preference && !reopened.isRunning
                        && reopened.humanReviewCheckpoint == nil,
                        "Reopen changed persisted Advanced preference or auto-started review/ASR")
            print("PASS \(label): actual request, witnessed run-local write, terminal restore, reopen; no ASR")
        } catch {
            model.cancelForApplicationTermination()
            try? await waitUntil("failed probe cleanup", seconds: 10) { !model.isRunning }
            throw error
        }
    }

    @MainActor
    private static func waitUntil(
        _ label: String, seconds: TimeInterval, condition: () throws -> Bool
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
                try require(group > 0, "Invalid owned child group")
                let result = kill(-group, 0)
                try require(result == -1 && errno == ESRCH, "Probe left an active owned child group: \(group)")
            }
        }
    }

    @MainActor
    private static func testLanguageContract(root: URL, store: ProjectStore) throws {
        let preferences: [(input: String, normalized: String)] = [
            ("ru", "ru"), ("en", "en"), ("auto", "auto"),
            (" EN \n", "en"), (" \n", "auto")
        ]
        for language in ArtifactLanguage.allCases {
            let fixture = try makeFixture(root: root, store: store,
                                          name: "language-\(language.rawValue)", language: nil)
            let model = WorkflowViewModel()
            // selectMedia creates an owned scratch project and sets the actual private mode to .newProject.
            model.selectMedia(fixture.media)
            let project = try value(model.projectURL, "selectMedia failed for language fixture")
            try require(project.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
                        "Language fixture escaped owned scratch")
            let layout = ProjectLayout(root: project)
            try assertLanguagePreferences(model, preferences: preferences, locked: nil, label: "fresh newProject")
            try store.mutate(project) { manifest in
                manifest.languageProfile = LanguageProfile(
                    detected: language == .ru ? .ru : .en, effective: language, confidence: 1,
                    method: "fixture", model: nil, modelVersion: nil, sampleRanges: [],
                    manuallyOverridden: false, detectedAt: Date()
                )
                manifest.workflow?.status = .stopped
            }
            let cues = [SubtitleCue(id: 1, start: 0, end: 2, text: "Cached \(language.rawValue) source.")]
            try SRTService().writePreservingIDs(cues, to: layout.fullSRTURL)

            // A cancelled first run retains .newProject in the VM but can still reuse source SRT.
            // The final contract locks on persisted effective language, not mode or detection-file presence.
            for detection in [nil, Data(), Data("{}".utf8)] as [Data?] {
                if let detection {
                    try detection.write(to: layout.languageDetectionURL)
                } else if FileManager.default.fileExists(atPath: layout.languageDetectionURL.path) {
                    try FileManager.default.removeItem(at: layout.languageDetectionURL)
                }
                let before = try Data(contentsOf: layout.manifestURL)
                try assertLanguagePreferences(model, preferences: preferences, locked: language,
                                              label: "same-session newProject cached source")
                try require(try Data(contentsOf: layout.manifestURL) == before,
                            "Same-session language lookup mutated manifest")
            }

            for status: ProjectStatus in [.ready, .stopped, .failed] {
                try store.mutate(project) { manifest in manifest.workflow?.status = status }
                // openProject selects .retryFailedOperations for failed, .resumeProject otherwise.
                model.openProject(project)
                try require(model.mediaURL?.standardizedFileURL == fixture.media.standardizedFileURL
                            && !model.isRunning && model.humanReviewCheckpoint == nil,
                            "Language reopen started processing or lost media")
                let before = try Data(contentsOf: layout.manifestURL)
                try assertLanguagePreferences(model, preferences: preferences, locked: language,
                                              label: "reopen \(status.rawValue)")
                try require(try Data(contentsOf: layout.manifestURL) == before,
                            "Resumed language lookup mutated manifest")
            }
            try store.mutate(project) { manifest in manifest.languageProfile = nil }
            model.openProject(project)
            try assertLanguagePreferences(model, preferences: preferences, locked: nil,
                                          label: "resume without effective profile")
        }
        print("PASS language contract: stored RU/EN vs RU/EN/Auto; newProject/resume/retry; Advanced preferences unchanged")
    }

    @MainActor
    private static func assertLanguagePreferences(
        _ model: WorkflowViewModel,
        preferences: [(input: String, normalized: String)],
        locked: ArtifactLanguage?,
        label: String
    ) throws {
        for preference in preferences {
            model.whisperLanguage = preference.input
            try require(model.simpleTranscriptionLockedLanguage == locked,
                        "Wrong lock for \(label), preference=\(preference.input)")
            try require(model.simpleTranscriptionLanguage == (locked?.rawValue ?? preference.normalized),
                        "Launch/presentation language disagrees with persisted source for \(label)")
            try require(model.whisperLanguage == preference.input && !model.isRunning,
                        "Language getter mutated Advanced preference or started processing for \(label)")
        }
    }

    @MainActor
    private static func reject(_ model: WorkflowViewModel, _ label: String) throws {
        try require(!model.canStartSimpleTranscription, "Unexpected eligibility: \(label)")
        // Only rejected entry points are invoked: no successful Task or ASR can be scheduled.
        try require(!model.startSimpleTranscription(), "Unexpected start: \(label)")
    }

    @MainActor
    private static func testReviewLifecycle(root: URL, store: ProjectStore, language: ArtifactLanguage) throws {
        let fixture = try makeFixture(root: root, store: store, name: "review-\(language.rawValue)", language: language)
        let layout = ProjectLayout(root: fixture.project)
        let service = HumanReviewService(store: store)
        let other = language.translationTarget
        let untouchedURL = layout.subtitlesURL(language: other)
        let untouched = try Data(contentsOf: untouchedURL)
        let untouchedText = try Data(contentsOf: layout.transcriptURL(language: other))
        let originalManifest = try store.load(from: fixture.project)
        let otherRevision = originalManifest.activeTranscriptRevision(for: other)
        let sourceID = "source-\(language.rawValue)"
        let baselineSubtitleURL = layout.subtitleRevisionURL(id: sourceID, language: language)
        let baselineSubtitle = try Data(contentsOf: baselineSubtitleURL)
        // Simulate the required run-local override while persisted Advanced review is disabled.
        try require(originalManifest.humanReviewState?.sourceReviewEnabled == false,
                    "Fixture must start with Advanced Source Review disabled")
        let checkpoint = try value(service.transitionAfterGeneration(
            projectURL: fixture.project, kind: .sourceTranscript, language: language,
            revisionID: sourceID, pendingOperations: [.validateTimeline, .discoverResults],
            sourceReviewEnabled: true, translationReviewEnabled: false
        ), "Mandatory Source review missing")
        try require(checkpoint.language == language && checkpoint.revisionID == sourceID,
                    "Review bound to wrong language/revision")
        // Helper-level preservation coverage only; actual entry/termination is tested separately.
        let beforeRestore = try store.load(from: fixture.project)
        let helperModel = WorkflowViewModel()
        try helperModel.restoreSourceHumanReviewPreference(false, projectURL: fixture.project)
        let afterRestore = try store.load(from: fixture.project)
        var expectedReviewState = beforeRestore.humanReviewState
        expectedReviewState?.sourceReviewEnabled = false
        try require(afterRestore.humanReviewState == expectedReviewState
                    && afterRestore.transcriptRevisions == beforeRestore.transcriptRevisions
                    && afterRestore.workflow?.status == beforeRestore.workflow?.status,
                    "Preference restore modified checkpoint/revisions/workflow")
        let pendingBefore = try store.load(from: fixture.project).humanReviewState?.pendingCheckpoint
        let pendingModel = WorkflowViewModel()
        pendingModel.openProject(fixture.project)
        try require(pendingModel.beginHumanReview(language: language)
                    && !pendingModel.sourceHumanReviewEnabled,
                    "Opening existing pending Source Review flipped Advanced preference")
        try reject(pendingModel, "pending Source reopen")
        try require(!pendingModel.isRunning && pendingModel.humanReviewCheckpoint == pendingBefore,
                    "Pending reopen lost exact persisted checkpoint or started processing")

        let replacement = "Edited source \(language.rawValue) cue one."
        let originalCues = try SRTService().load(from: layout.fullSRTURL)
        let draft = try service.saveDraftCue(projectURL: fixture.project, language: language,
                                             cueID: 1, replacementText: replacement)
        try sameTiming(originalCues, draft)
        try require(draft[0].text == replacement && draft[1].text == originalCues[1].text,
                    "Draft changed wrong cue/body")
        let saved = try store.load(from: fixture.project)
        try require(saved.humanReviewState?.draftRevisionIDs[language.rawValue] != nil,
                    "Draft revision not persisted")
        let reopenedDraft = WorkflowViewModel()
        reopenedDraft.openProject(fixture.project)
        try require(!reopenedDraft.isRunning && reopenedDraft.humanReviewCheckpoint == pendingBefore,
                    "Draft close/reopen accepted review or started processing")
        try require(try SRTService().load(from: layout.fullSRTURL).first?.text == replacement,
                    "Draft text lost on reopen")

        var tampered = draft
        tampered[0].start = 0.25
        try SRTService().writePreservingIDs(tampered, to: layout.fullSRTURL)
        do {
            _ = try service.approve(projectURL: fixture.project)
            throw ProbeFailure(message: "Timing mutation was accepted")
        } catch WorkflowError.invalidSRT {
            // The source entry must retain the existing strict timing validation.
        }
        try require(try store.load(from: fixture.project).humanReviewState?.pendingCheckpoint == pendingBefore,
                    "Failed approval consumed checkpoint")
        try SRTService().writePreservingIDs(draft, to: layout.fullSRTURL)
        let approval = try service.approve(projectURL: fixture.project)
        try require(approval.pendingOperations == [.validateTimeline, .discoverResults],
                    "Accept queued Topics/Translation or lost source validation")
        try sameTiming(originalCues, approval.cues)
        let approved = try store.load(from: fixture.project)
        try require(approved.humanReviewState?.pendingCheckpoint == nil
                    && approved.activeTranscriptRevision(for: language)?.id == approval.revision.id
                    && approval.revision.reviewStatus == .approved, "Wrong approved source revision")
        let otherSubtitleAfter = try Data(contentsOf: untouchedURL)
        let otherTextAfter = try Data(contentsOf: layout.transcriptURL(language: other))
        try require(approved.activeTranscriptRevision(for: other) == otherRevision
                    && otherSubtitleAfter == untouched && otherTextAfter == untouchedText,
                    "Source review modified other-language revision/body")
        try require(try Data(contentsOf: baselineSubtitleURL) == baselineSubtitle,
                    "Source review rewrote immutable machine baseline")
        try require((approved.transcriptRevisions ?? []).filter { $0.language == other }.count == 1,
                    "Source review generated a translation")
        try require((approved.topicRevisions ?? []).isEmpty
                    && approved.topicReviewState?.pendingCheckpoint == nil,
                    "Source review created Topics/review")
        try require(try String(contentsOf: layout.transcriptURL, encoding: .utf8)
            == draft.map(\.text).joined(separator: "\n\n") + "\n", "Published TXT is not exact edited source")
        let state = SimpleProjectHomeStateService().make(projectURL: fixture.project, manifest: approved,
                                                        topicsDetail: nil, discoveredOutputs: [])
        try require(state.artifact(.transcription).openOutputPath == layout.transcriptURL.path,
                    "Source Open does not point to readable TXT")
        try require(state.artifact(.topics).reviewTarget == nil, "Simple exposes Topics correction")
        let manifestBeforeReopen = try store.load(from: fixture.project)
        let reopened = WorkflowViewModel()
        reopened.openProject(fixture.project)
        try reject(reopened, "approved source reopen")
        let afterReopen = try store.load(from: fixture.project)
        try require(!reopened.isRunning && reopened.humanReviewCheckpoint == nil
                    && afterReopen.transcriptRevisions == manifestBeforeReopen.transcriptRevisions,
                    "Approved reopen started processing, reopened review or changed revisions")
        print("PASS \(language.rawValue) review/draft/timing/accept/TXT/reopen and other-language isolation")
    }

    private static func sameTiming(_ before: [SubtitleCue], _ after: [SubtitleCue]) throws {
        try require(before.count == after.count && zip(before, after).allSatisfy { original, edited in
            original.id == edited.id && original.start == edited.start && original.end == edited.end
        }, "Cue count/order/IDs/timing changed")
    }

    private struct Fixture {
        var project: URL
        var media: URL
    }

    private static func makeFixture(root: URL, store: ProjectStore, name: String,
                                    language: ArtifactLanguage?) throws -> Fixture {
        let project = root.appendingPathComponent(name, isDirectory: true)
        let media = root.appendingPathComponent("\(name).mp4")
        try Data("deterministic fixture; not real media".utf8).write(to: media)
        var manifest = try store.ensureProject(at: project, mediaURL: media, mode: .newProject)
        guard let language else { return Fixture(project: project, media: media) }
        let layout = ProjectLayout(root: project)
        manifest.languageProfile = LanguageProfile(
            detected: language == .ru ? .ru : .en, effective: language, confidence: 1,
            method: "fixture", model: nil, modelVersion: nil, sampleRanges: [],
            manuallyOverridden: false, detectedAt: Date()
        )
        manifest.durationSeconds = 4
        manifest.humanReviewState = .newProjectDefault
        manifest.humanReviewState?.sourceReviewEnabled = false
        manifest.transcriptRevisions = []
        for current in ArtifactLanguage.allCases {
            let source = current == language
            let id = source ? "source-\(current.rawValue)" : "existing-other-\(current.rawValue)"
            let cues = [SubtitleCue(id: 1, start: 0, end: 2, text: "\(current.rawValue) first cue."),
                        SubtitleCue(id: 2, start: 2, end: 4, text: "\(current.rawValue) second cue.")]
            let text = cues.map(\.text).joined(separator: "\n\n") + "\n"
            try SRTService().writePreservingIDs(cues, to: layout.subtitlesURL(language: current))
            try SRTService().writePreservingIDs(cues, to: layout.subtitleRevisionURL(id: id, language: current))
            try text.write(to: layout.transcriptURL(language: current), atomically: true, encoding: .utf8)
            try text.write(to: layout.transcriptRevisionURL(id: id, language: current), atomically: true, encoding: .utf8)
            if source {
                try SRTService().writePreservingIDs(cues, to: layout.fullSRTURL)
                try text.write(to: layout.transcriptURL, atomically: true, encoding: .utf8)
            } else {
                manifest.humanReviewState?.activeRevisionIDs[current.rawValue] = id
            }
            manifest.transcriptRevisions?.append(TranscriptRevision(
                id: id, language: current, origin: source ? .machineGenerated : .translated,
                parentRevisionID: nil, transcriptArtifactID: "\(id)-txt", subtitleArtifactID: "\(id)-srt",
                contentHash: StableTopicHash.string(text), createdAt: Date(),
                reviewStatus: source ? nil : .approved
            ))
        }
        try store.save(manifest, to: project)
        return Fixture(project: project, media: media)
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw ProbeFailure(message: message) }
    }

    private static func value<T>(_ optional: T?, _ message: String) throws -> T {
        guard let optional else { throw ProbeFailure(message: message) }
        return optional
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
