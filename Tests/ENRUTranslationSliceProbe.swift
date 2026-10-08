import Foundation

@main
struct ENRUTranslationSliceProbe {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("videotext-en-ru-slice-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try require(WorkflowOperation.translateTranscript.isEnabledForCurrentRelease, "EN→RU operation is disabled")
        try require(!WorkflowOperation.userSelectable.contains(.translateTranscript), "translation became automatic Core work")
        try require(!WorkflowOperation.createDubbing.isEnabledForCurrentRelease, "dubbing was enabled")
        try await verifyApprovedSourceFlow(root: root.appendingPathComponent("success"))
        try await verifyUnapprovedSourceIsRejected(root: root.appendingPathComponent("unapproved"))
        try await verifySourceFallbackFailsClosed(root: root.appendingPathComponent("source-fallback"))
        try await verifyWrongLanguageFailsClosed(root: root.appendingPathComponent("wrong-language"))
        try await verifyTranslationCancellationPreservesCore(root: root.appendingPathComponent("cancellation"))
        try await verifyImmediateCancellationPreservesCore(root: root.appendingPathComponent("immediate-cancellation"))
        try await verifyApprovedSourceMutationIsRejected(root: root.appendingPathComponent("source-mutation"))
        try verifyPersistedSourceMustMatchCoreEvidence(root: root.appendingPathComponent("stale-source-units"))
        try await verifyPoisonedCacheIsIgnored(root: root.appendingPathComponent("poisoned-cache"))
        try await verifyFailureIsolationAndRetry(root: root.appendingPathComponent("failure"))
        print("EN_RU_TRANSLATION_SLICE_PROBE_PASS")
    }

    private static func verifyApprovedSourceFlow(root: URL) async throws {
        let fixture = try makeFixture(root: root, approved: true)
        let translator = RecordingENRUTranslator()
        let slice = SelectedTimingVerticalSlice(translator: translator)
        let engine = WorkflowEngine(store: fixture.store, selectedTimingTranslation: slice)
        var log: [String] = []
        let sourceSRT = try Data(contentsOf: fixture.layout.fullSRTURL)
        let sourceTXT = try Data(contentsOf: fixture.layout.transcriptURL)
        let result = try await engine.run(settings: settings(fixture), onLog: { log.append($0) })

        try require(result.checkpoint?.kind == .translatedTranscript && result.checkpoint?.language == .ru,
                    "translation did not open required RU Human Review")
        try require(!log.contains(where: { $0.contains("Расшифровка bundled SeminarText") }), "translation reran ASR")
        try require(try Data(contentsOf: fixture.layout.fullSRTURL) == sourceSRT, "translation changed source SRT")
        try require(try Data(contentsOf: fixture.layout.transcriptURL) == sourceTXT, "translation changed source TXT")
        try require(FileManager.default.fileExists(atPath: fixture.layout.selectedTimingSourceUnitsURL.path),
                    "canonical selected timing was not connected to source units")
        let pending = try fixture.store.load(from: fixture.project)
        try require(pending.activeTranscriptRevision(for: .ru) == nil, "pending translation became active")
        try require(pending.workflow?.operations[WorkflowOperation.transcribe.rawValue] == nil,
                    "translation recorded an ASR operation")
        try require(pending.workflow?.operations[WorkflowOperation.translateTranscript.rawValue]?.status == .completed,
                    "translation operation did not complete before review")
        let machineTranslation = try requireValue(
            pending.transcriptRevisions?.last(where: { $0.language == .ru && $0.origin == .translated }),
            "pending translated revision is missing"
        )
        let translationDocument = try JSONDecoder().decode(
            TimedTranslationDocument.self,
            from: Data(contentsOf: fixture.layout.selectedTimingTranslationsURL(source: .en, target: .ru))
        )
        try require(translationDocument.source.units.map(\.id) == [1, 3]
                    && translationDocument.units.map(\.sourceUnitID) == [1, 3],
                    "translation renumbered non-contiguous source cue IDs")
        try require((pending.artifacts ?? []).filter { $0.language == .ru }.allSatisfy { $0.validationStatus == .needsReview },
                    "pending translation artifacts were marked ready")
        let pendingOutputs = ResultsDetector().discover(in: fixture.project)
        let pendingPaths = Set(pendingOutputs.map { canonicalPath(URL(fileURLWithPath: $0.path)) })
        try require(!pendingPaths.contains(canonicalPath(fixture.layout.transcriptURL(language: .ru)))
                    && !pendingPaths.contains(canonicalPath(fixture.layout.subtitlesURL(language: .ru))),
                    "pending RU translation appeared as a finished result")
        let pendingKinds = Set(pendingOutputs.map(\.kind))
        try require(pendingKinds.contains("topics") && pendingKinds.contains("fragment-video"),
                    "Core results disappeared while translation awaited review")
        try require(translator.requests.allSatisfy { $0.source == .en && $0.target == .ru },
                    "provider received a direction other than EN→RU")

        var coreLog: [String] = []
        var coreSettings = settings(fixture)
        coreSettings.selectedOperations = [.discoverResults]
        let coreResult = try await engine.run(settings: coreSettings, onLog: { coreLog.append($0) })
        try require(coreResult.checkpoint?.kind == .translatedTranscript,
                    "Core operation lost the pending Translation Human Review checkpoint")
        try require(!coreLog.contains(where: { $0.contains("Расшифровка bundled SeminarText") }),
                    "Core operation during pending translation reran ASR")
        try require(try Data(contentsOf: fixture.layout.fullSRTURL) == sourceSRT
                    && Data(contentsOf: fixture.layout.transcriptURL) == sourceTXT,
                    "Core operation during pending translation changed the source")

        _ = try HumanReviewService(store: fixture.store).approve(projectURL: fixture.project)
        let approved = try fixture.store.load(from: fixture.project)
        try require(approved.activeTranscriptRevision(for: .en)?.reviewStatus == .approved,
                    "source approval was lost")
        try require(approved.activeTranscriptRevision(for: .ru)?.reviewStatus == .approved,
                    "RU translation was not approved")
        let readyPaths = Set(ResultsDetector().discover(in: fixture.project).map {
            canonicalPath(URL(fileURLWithPath: $0.path))
        })
        try require(readyPaths.contains(canonicalPath(fixture.layout.transcriptURL(language: .ru)))
                    && readyPaths.contains(canonicalPath(fixture.layout.subtitlesURL(language: .ru))),
                    "approved RU TXT/SRT are not exposed")
        try require(!readyPaths.contains(canonicalPath(
            fixture.layout.transcriptRevisionURL(id: machineTranslation.id, language: .ru)
        )) && !readyPaths.contains(canonicalPath(
            fixture.layout.subtitleRevisionURL(id: machineTranslation.id, language: .ru)
        )), "superseded machine translation appeared as an approved result")

        let callsBeforeResume = translator.requests.count
        let resumed = try await engine.run(settings: settings(fixture), onLog: { log.append($0) })
        try require(resumed.checkpoint == nil, "approved translation reopened Human Review")
        try require(translator.requests.count == callsBeforeResume, "reopen/resume reran TranslateGemma")
        let reopened = try fixture.store.openProject(at: fixture.project).0
        try require(reopened.activeTranscriptRevision(for: .en)?.reviewStatus == .approved
                    && reopened.activeTranscriptRevision(for: .ru)?.reviewStatus == .approved,
                    "reopen lost approved EN/RU revisions")
    }

    private static func verifyUnapprovedSourceIsRejected(root: URL) async throws {
        let fixture = try makeFixture(root: root, approved: false)
        let translator = RecordingENRUTranslator()
        do {
            _ = try await WorkflowEngine(
                store: fixture.store,
                selectedTimingTranslation: SelectedTimingVerticalSlice(translator: translator)
            ).run(settings: settings(fixture), onLog: { _ in })
            throw ProbeFailure(message: "unapproved source was translated")
        } catch WorkflowError.processFailed(let message) {
            try require(message.contains("утверждённой английской"), "wrong unapproved-source failure")
        }
        try require(translator.requests.isEmpty, "provider ran before source approval")
    }

    private static func verifySourceFallbackFailsClosed(root: URL) async throws {
        let fixture = try makeFixture(root: root, approved: true)
        do {
            _ = try await WorkflowEngine(
                store: fixture.store,
                selectedTimingTranslation: SelectedTimingVerticalSlice(translator: SourceFallbackTranslator())
            ).run(settings: settings(fixture), onLog: { _ in })
            throw ProbeFailure(message: "source-text fallback unexpectedly succeeded")
        } catch WorkflowError.processFailed(let message) {
            try require(message.contains("исходный текст без перевода"),
                        "source-text fallback produced the wrong failure")
        }
        let manifest = try fixture.store.load(from: fixture.project)
        try require(manifest.activeTranscriptRevision(for: .ru) == nil,
                    "source-text fallback became an active RU revision")
        try require(!FileManager.default.fileExists(atPath: fixture.layout.subtitlesURL(language: .ru).path),
                    "source-text fallback published a RU SRT")
        try require(manifest.workflow?.status == .completed,
                    "source-text fallback invalidated the Core project")
    }

    private static func verifyWrongLanguageFailsClosed(root: URL) async throws {
        let mixedFixture = try makeFixture(root: root.appendingPathComponent("mixed"), approved: true)
        do {
            _ = try await WorkflowEngine(
                store: mixedFixture.store,
                selectedTimingTranslation: SelectedTimingVerticalSlice(translator: MostlyEnglishTranslator())
            ).run(settings: settings(mixedFixture), onLog: { _ in })
            throw ProbeFailure(message: "mostly English translation unexpectedly succeeded")
        } catch WorkflowError.processFailed(let message) {
            try require(message.contains("преимущественно не на русском языке"),
                        "mostly English output produced the wrong failure")
        }
        let manifest = try mixedFixture.store.load(from: mixedFixture.project)
        try require(manifest.activeTranscriptRevision(for: .ru) == nil,
                    "mostly English output became an active RU revision")
        try require(!FileManager.default.fileExists(atPath: mixedFixture.layout.subtitlesURL(language: .ru).path),
                    "mostly English output published a RU SRT")

        let uppercaseFixture = try makeFixture(root: root.appendingPathComponent("uppercase"), approved: true)
        let uppercaseCues = [
            SubtitleCue(id: 1, start: 0, end: 0.6, text: "LED SAVES ENERGY."),
            SubtitleCue(id: 3, start: 0.6, end: 1.2, text: "WARM LED LIGHT.")
        ]
        try SRTService().writePreservingIDs(uppercaseCues, to: uppercaseFixture.layout.fullSRTURL)
        try SRTService().writePreservingIDs(
            uppercaseCues,
            to: uppercaseFixture.layout.subtitleRevisionURL(id: "approved-en-source", language: .en)
        )
        do {
            _ = try await WorkflowEngine(
                store: uppercaseFixture.store,
                selectedTimingTranslation: SelectedTimingVerticalSlice(translator: DifferentEnglishTranslator())
            ).run(settings: settings(uppercaseFixture), onLog: { _ in })
            throw ProbeFailure(message: "uppercase English source accepted a different English response")
        } catch WorkflowError.processFailed(let message) {
            try require(message.contains("преимущественно не на русском языке"),
                        "uppercase-source wrong-language output produced the wrong failure")
        }
    }

    private static func verifyApprovedSourceMutationIsRejected(root: URL) async throws {
        let fixture = try makeFixture(root: root, approved: true)
        try Data("1\n00:00:00,000 --> 00:00:00,600\nChanged after approval.\n".utf8)
            .write(to: fixture.layout.fullSRTURL)
        let translator = RecordingENRUTranslator()
        do {
            _ = try await WorkflowEngine(
                store: fixture.store,
                selectedTimingTranslation: SelectedTimingVerticalSlice(translator: translator)
            ).run(settings: settings(fixture), onLog: { _ in })
            throw ProbeFailure(message: "modified approved source unexpectedly translated")
        } catch WorkflowError.processFailed(let message) {
            try require(message.contains("не совпадает с утверждённой английской ревизией"),
                        "modified approved source produced the wrong failure")
        }
        try require(translator.requests.isEmpty, "provider ran for source text not matching approved revision")
    }

    private static func verifyPersistedSourceMustMatchCoreEvidence(root: URL) throws {
        let fixture = try makeFixture(root: root, approved: true)
        let slice = SelectedTimingVerticalSlice(translator: RecordingENRUTranslator())
        var source = try slice.loadOrImportCoreSource(
            projectURL: fixture.project,
            mediaURL: fixture.media,
            language: .en
        )
        source.upstreamManifestSHA256 = "stale-independent-attempt"
        try slice.persistSource(source, to: fixture.project)
        do {
            _ = try slice.loadOrImportCoreSource(
                projectURL: fixture.project,
                mediaURL: fixture.media,
                language: .en
            )
            throw ProbeFailure(message: "stale source units were accepted")
        } catch WorkflowError.processFailed(let message) {
            try require(message.contains("не принадлежат canonical SeminarText attempt"),
                        "stale source units produced the wrong failure")
        }
    }

    private static func verifyPoisonedCacheIsIgnored(root: URL) async throws {
        let fixture = try makeFixture(root: root, approved: true)
        let firstProvider = RecordingENRUTranslator()
        let firstSlice = SelectedTimingVerticalSlice(translator: firstProvider)
        let selected = try firstSlice.loadOrImportCoreSource(
            projectURL: fixture.project,
            mediaURL: fixture.media,
            language: .en
        )
        let source = try firstSlice.sourceDocument(
            selected,
            reconciledWith: SRTService().load(from: fixture.layout.fullSRTURL)
        )
        _ = try await firstSlice.translate(
            sourceDocument: source,
            source: .en,
            target: .ru,
            cacheDirectory: fixture.layout.selectedTimingTranslationCacheDirectory
        )
        let cacheFiles = regularFiles(in: fixture.layout.selectedTimingTranslationCacheDirectory)
        try require(!cacheFiles.isEmpty, "translation cache was not created")
        let sourceByID = Dictionary(uniqueKeysWithValues: source.units.map { ($0.id, $0.text) })
        for url in cacheFiles where url.pathExtension == "json" {
            guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                  let unitID = object["unitID"] as? Int,
                  let sourceText = sourceByID[unitID] else { continue }
            object["text"] = "Translation: \(sourceText)"
            try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        }
        let retryProvider = RecordingENRUTranslator()
        let translated = try await SelectedTimingVerticalSlice(translator: retryProvider).translate(
            sourceDocument: source,
            source: .en,
            target: .ru,
            cacheDirectory: fixture.layout.selectedTimingTranslationCacheDirectory
        )
        try require(retryProvider.requests.count == source.units.count,
                    "poisoned cache bypassed TranslateGemma re-execution")
        try require(translated.units.allSatisfy { $0.text.contains("Проверенный русский перевод") },
                    "poisoned cache text survived validation")
    }

    private static func verifyFailureIsolationAndRetry(root: URL) async throws {
        let fixture = try makeFixture(root: root, approved: true)
        let coreRecord = ProjectOperationRecord(
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200),
            inputSignature: "preserve-core-signature",
            outputPaths: [fixture.layout.topicsURL.path],
            errorMessage: nil
        )
        try fixture.store.mutate(fixture.project) { manifest in
            manifest.workflow?.status = .ready
            manifest.workflow?.progress = 0.42
            manifest.workflow?.lastError = "preserve-core-state"
            manifest.workflow?.operations[WorkflowOperation.topicTimecoding.rawValue] = coreRecord
        }
        let coreRecordBefore = try operationData(coreRecord)
        let sourceSRT = try Data(contentsOf: fixture.layout.fullSRTURL)
        let sourceTXT = try Data(contentsOf: fixture.layout.transcriptURL)
        let topics = try Data(contentsOf: fixture.layout.topicsURL)
        let fragment = try Data(contentsOf: fixture.layout.fragmentVideoURL(kind: "existing"))
        do {
            _ = try await WorkflowEngine(
                store: fixture.store,
                selectedTimingTranslation: SelectedTimingVerticalSlice(translator: FailingENRUTranslator())
            ).run(settings: settings(fixture), onLog: { _ in })
            throw ProbeFailure(message: "controlled translation failure unexpectedly succeeded")
        } catch WorkflowError.processFailed(let message) {
            try require(message.contains("controlled TranslateGemma failure"), "wrong controlled failure")
        }
        let failed = try fixture.store.load(from: fixture.project)
        try require(failed.workflow?.status == .ready
                    && failed.workflow?.progress == 0.42
                    && failed.workflow?.lastError == "preserve-core-state",
                    "optional translation failure changed the Core workflow state")
        try require(failed.workflow?.operations[WorkflowOperation.translateTranscript.rawValue]?.status == .failed,
                    "translation-specific failure was not retained")
        try require(try operationData(
            failed.workflow?.operations[WorkflowOperation.topicTimecoding.rawValue]
        ) == coreRecordBefore, "translation failure changed a pre-existing Core operation record")
        try require(failed.activeTranscriptRevision(for: .en)?.reviewStatus == .approved,
                    "translation failure invalidated source approval")
        try require(try Data(contentsOf: fixture.layout.fullSRTURL) == sourceSRT
                    && Data(contentsOf: fixture.layout.transcriptURL) == sourceTXT,
                    "translation failure changed source artifacts")
        try require(try Data(contentsOf: fixture.layout.topicsURL) == topics
                    && Data(contentsOf: fixture.layout.fragmentVideoURL(kind: "existing")) == fragment,
                    "translation failure changed Core topics/fragments")
        try require(!FileManager.default.fileExists(atPath: fixture.layout.subtitlesURL(language: .ru).path),
                    "failed translation published RU SRT")
        let outputs = Set(ResultsDetector().discover(in: fixture.project).map(\.kind))
        try require(outputs.contains("topics") && outputs.contains("fragment-video"),
                    "translation failure hid Core results")

        let retryProvider = RecordingENRUTranslator()
        let retry = try await WorkflowEngine(
            store: fixture.store,
            selectedTimingTranslation: SelectedTimingVerticalSlice(translator: retryProvider)
        ).run(settings: settings(fixture), onLog: { _ in })
        try require(retry.checkpoint?.kind == .translatedTranscript && !retryProvider.requests.isEmpty,
                    "translation could not be retried after isolated failure")
    }

    private static func verifyTranslationCancellationPreservesCore(root: URL) async throws {
        let fixture = try makeFixture(root: root, approved: true)
        let coreRecord = ProjectOperationRecord(
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 300),
            finishedAt: Date(timeIntervalSince1970: 400),
            inputSignature: "cancel-preserve-core-signature",
            outputPaths: [fixture.layout.fragmentVideoURL(kind: "existing").path],
            errorMessage: nil
        )
        try fixture.store.mutate(fixture.project) { manifest in
            manifest.workflow?.status = .ready
            manifest.workflow?.progress = 0.73
            manifest.workflow?.lastError = "cancel-preserve-core-state"
            manifest.workflow?.operations[WorkflowOperation.cutTopic.rawValue] = coreRecord
        }
        let translator = CancellableENRUTranslator()
        let engine = WorkflowEngine(
            store: fixture.store,
            selectedTimingTranslation: SelectedTimingVerticalSlice(translator: translator)
        )
        let task = Task {
            try await engine.run(settings: settings(fixture), onLog: { _ in })
        }
        try require(translator.waitUntilStarted(), "translation cancellation probe did not reach provider")
        task.cancel()
        do {
            _ = try await task.value
            throw ProbeFailure(message: "cancelled translation unexpectedly succeeded")
        } catch is CancellationError {
            // Expected.
        }
        let cancelled = try fixture.store.load(from: fixture.project)
        try require(cancelled.workflow?.status == .ready
                    && cancelled.workflow?.progress == 0.73
                    && cancelled.workflow?.lastError == "cancel-preserve-core-state",
                    "translation cancellation changed the Core workflow state")
        try require(cancelled.workflow?.operations[WorkflowOperation.translateTranscript.rawValue]?.status == .stopped,
                    "translation cancellation did not retain a stopped translation record")
        try require(try operationData(
            cancelled.workflow?.operations[WorkflowOperation.cutTopic.rawValue]
        ) == operationData(coreRecord), "translation cancellation changed a pre-existing Core operation record")
        try require(cancelled.activeTranscriptRevision(for: .en)?.reviewStatus == .approved,
                    "translation cancellation invalidated source approval")
        try require(cancelled.activeTranscriptRevision(for: .ru) == nil,
                    "translation cancellation published a RU revision")
    }

    private static func verifyImmediateCancellationPreservesCore(root: URL) async throws {
        let fixture = try makeFixture(root: root, approved: true)
        try fixture.store.mutate(fixture.project) { manifest in
            manifest.workflow?.status = .ready
            manifest.workflow?.progress = 0.29
            manifest.workflow?.lastError = "immediate-cancel-core-state"
        }
        let task = Task {
            try await WorkflowEngine(
                store: fixture.store,
                selectedTimingTranslation: SelectedTimingVerticalSlice(translator: CancellableENRUTranslator())
            ).run(settings: settings(fixture), onLog: { _ in })
        }
        task.cancel()
        do {
            _ = try await task.value
            throw ProbeFailure(message: "immediately cancelled translation unexpectedly succeeded")
        } catch is CancellationError {
            // Expected.
        }
        let cancelled = try fixture.store.load(from: fixture.project)
        try require(cancelled.workflow?.status == .ready
                    && cancelled.workflow?.progress == 0.29
                    && cancelled.workflow?.lastError == "immediate-cancel-core-state",
                    "immediate translation cancellation changed the Core workflow state")
        try require(cancelled.workflow?.operations[WorkflowOperation.translateTranscript.rawValue]?.status == .stopped,
                    "immediate cancellation did not retain a stopped translation record")
        try require(cancelled.activeTranscriptRevision(for: .en)?.reviewStatus == .approved
                    && cancelled.activeTranscriptRevision(for: .ru) == nil,
                    "immediate translation cancellation changed transcript authority")
    }

    private static func settings(_ fixture: Fixture) -> WorkflowSettings {
        WorkflowSettings(
            mediaURL: fixture.media,
            projectURL: fixture.project,
            selectedOperations: [.translateTranscript],
            mode: .resumeProject,
            rangeStart: 0,
            rangeEnd: 1,
            fragmentName: "",
            burnFragmentSubtitles: false,
            subtitleStyle: .standard,
            selectedTopicID: nil,
            whisperModelPath: "/must-not-be-used/whisper.bin",
            whisperLanguage: "en",
            sourceHumanReviewEnabled: true,
            translationHumanReviewEnabled: true,
            fillerAnalysisBeforeReview: true
        )
    }

    private static func makeFixture(root: URL, approved: Bool) throws -> Fixture {
        let media = root.appendingPathComponent("led.mp4")
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("LED media fixture".utf8).write(to: media)
        let store = ProjectStore(history: ProjectHistoryStore(indexURL: root.appendingPathComponent("history.json")))
        var manifest = try store.ensureProject(at: project, mediaURL: media, mode: .newProject)
        let layout = ProjectLayout(root: project)
        let cues = [
            SubtitleCue(id: 1, start: 0, end: 0.6, text: "They save a lot of energy."),
            SubtitleCue(id: 3, start: 0.6, end: 1.2, text: "The LED supports warm light and mitochondria.")
        ]
        try SRTService().writePreservingIDs(cues, to: layout.fullSRTURL)
        try SRTService().writePreservingIDs(cues, to: layout.subtitlesURL(language: .en))
        let transcript = cues.map(\.text).joined(separator: "\n\n") + "\n"
        try transcript.write(to: layout.transcriptURL, atomically: true, encoding: .utf8)
        try transcript.write(to: layout.transcriptURL(language: .en), atomically: true, encoding: .utf8)
        try makeCorePackage(layout: layout, media: media)
        try Data("topics".utf8).write(to: layout.topicsURL)
        let fragment = layout.fragmentVideoURL(kind: "existing")
        try FileManager.default.createDirectory(at: fragment.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fragment".utf8).write(to: fragment)

        let sourceID = "approved-en-source"
        let revision = TranscriptRevision(
            id: sourceID,
            language: .en,
            origin: .userEdited,
            parentRevisionID: "machine-en-source",
            transcriptArtifactID: "source-en-txt",
            subtitleArtifactID: "source-en-srt",
            contentHash: StableTopicHash.string(try String(contentsOf: layout.fullSRTURL, encoding: .utf8)),
            createdAt: Date(),
            reviewStatus: approved ? .approved : .pending
        )
        try Data(contentsOf: layout.fullSRTURL).write(to: layout.subtitleRevisionURL(id: sourceID, language: .en))
        try Data(contentsOf: layout.transcriptURL).write(to: layout.transcriptRevisionURL(id: sourceID, language: .en))
        manifest.languageProfile = LanguageProfile(
            detected: .en,
            effective: .en,
            confidence: 1,
            method: "fixture",
            model: nil,
            modelVersion: nil,
            sampleRanges: [],
            manuallyOverridden: false,
            detectedAt: Date()
        )
        manifest.transcriptRevisions = [revision]
        var review = HumanReviewState.newProjectDefault
        review.sourceReviewEnabled = true
        review.translationReviewEnabled = true
        review.activeRevisionIDs[ArtifactLanguage.en.rawValue] = sourceID
        manifest.humanReviewState = review
        manifest.workflow?.status = .completed
        try store.save(manifest, to: project)
        return Fixture(media: media, project: project, layout: layout, store: store)
    }

    private static func makeCorePackage(layout: ProjectLayout, media: URL) throws {
        let package = layout.seminarTextCoreDirectory
            .appendingPathComponent("core-transcription-fixture/run/structured_timing", isDirectory: true)
        let parts = package.appendingPathComponent("parts", isDirectory: true)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        let jsonURL = parts.appendingPathComponent("part_0000.json")
        let txtURL = parts.appendingPathComponent("part_0000.txt")
        let srtURL = parts.appendingPathComponent("part_0000.srt")
        let tokens: [[String: Any]] = [
            token(" They", 0, 100), token(" save", 100, 180), token(" a", 180, 220),
            token(" lot", 220, 300), token(" of", 300, 360), token(" energy", 360, 560), token(".", 560, 600),
            token(" The", 600, 680), token(" LED", 680, 760), token(" supports", 760, 850),
            token(" warm", 850, 920), token(" light", 920, 980), token(" and", 980, 1030),
            token(" mitochondria", 1030, 1160), token(".", 1160, 1200), token("[_EOT_]", 1200, 1200)
        ]
        let json: [String: Any] = ["transcription": [[
            "offsets": ["from": 0, "to": 1200],
            "no_speech_prob": 0.01,
            "tokens": tokens
        ]]]
        try JSONSerialization.data(withJSONObject: json).write(to: jsonURL)
        let text = " They save a lot of energy. The LED supports warm light and mitochondria."
        try Data(text.utf8).write(to: txtURL)
        try Data("1\n00:00:00,000 --> 00:00:01,200\n\(text)\n".utf8).write(to: srtURL)
        func artifact(_ url: URL) -> [String: String] {
            ["path": "parts/\(url.lastPathComponent)", "sha256": SelectedTimingHash.file(url)]
        }
        let selectedManifest: [String: Any] = [
            "schema_version": 1,
            "artifact_type": "seminartext.selected_whisper_timing",
            "source": ["media_sha256": SelectedTimingHash.file(media)],
            "transcription": ["language": "en"],
            "parts": [[
                "id": "part_0000",
                "order": 0,
                "absolute_offset_seconds": 0.0,
                "absolute_range": ["start_seconds": 0.0, "end_seconds": 1.2],
                "selected_timing_absolute_range": ["start_seconds": 0.0, "end_seconds": 1.2],
                "selected_attempt": "initial",
                "artifacts": ["txt": artifact(txtURL), "srt": artifact(srtURL), "json_full": artifact(jsonURL)]
            ]]
        ]
        let manifestURL = package.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: selectedManifest).write(to: manifestURL)
        let evidence = SeminarTextCoreTranscriptionEvidence(
            schemaVersion: 1,
            runtimeIdentity: "fixture",
            sourceSRTSHA256: SelectedTimingHash.file(srtURL),
            selectedTimingManifestSHA256: SelectedTimingHash.file(manifestURL),
            selectedWhisperJSONSHA256: SelectedTimingHash.file(jsonURL),
            outputDirectory: package.deletingLastPathComponent().path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(evidence).write(to: layout.seminarTextCoreEvidenceURL, options: .atomic)
    }

    private static func token(_ text: String, _ from: Int, _ to: Int) -> [String: Any] {
        ["text": text, "offsets": ["from": from, "to": to], "p": 0.95]
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw ProbeFailure(message: message) }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw ProbeFailure(message: message) }
        return value
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func operationData(_ operation: ProjectOperationRecord?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(operation)
    }

    private static func regularFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url
        }
    }
}

private struct Fixture {
    let media: URL
    let project: URL
    let layout: ProjectLayout
    let store: ProjectStore
}

private final class RecordingENRUTranslator: SimpleTextTranslationProvider {
    struct Request { let text: String; let source: ArtifactLanguage; let target: ArtifactLanguage }
    private(set) var requests: [Request] = []

    func identity() async throws -> TranslationModelIdentity {
        TranslationModelIdentity(model: "translategemma:4b", digest: "fixture-digest", protocolVersion: "translategemma-simple-text-v1")
    }

    func translate(text: String, source: ArtifactLanguage, target: ArtifactLanguage) async throws -> String {
        requests.append(Request(text: text, source: source, target: target))
        return "Проверенный русский перевод \(requests.count)."
    }
}

private struct FailingENRUTranslator: SimpleTextTranslationProvider {
    func identity() async throws -> TranslationModelIdentity {
        TranslationModelIdentity(model: "translategemma:4b", digest: "fixture-digest", protocolVersion: "translategemma-simple-text-v1")
    }

    func translate(text: String, source: ArtifactLanguage, target: ArtifactLanguage) async throws -> String {
        throw WorkflowError.processFailed("controlled TranslateGemma failure")
    }
}

private struct SourceFallbackTranslator: SimpleTextTranslationProvider {
    func identity() async throws -> TranslationModelIdentity {
        TranslationModelIdentity(model: "translategemma:4b", digest: "fixture-digest", protocolVersion: "translategemma-simple-text-v1")
    }

    func translate(text: String, source: ArtifactLanguage, target: ArtifactLanguage) async throws -> String {
        text
    }
}

private struct MostlyEnglishTranslator: SimpleTextTranslationProvider {
    func identity() async throws -> TranslationModelIdentity {
        TranslationModelIdentity(model: "translategemma:4b", digest: "fixture-digest", protocolVersion: "translategemma-simple-text-v1")
    }

    func translate(text: String, source: ArtifactLanguage, target: ArtifactLanguage) async throws -> String {
        "Перевод: It conserves energy and supports warm light."
    }
}

private struct DifferentEnglishTranslator: SimpleTextTranslationProvider {
    func identity() async throws -> TranslationModelIdentity {
        TranslationModelIdentity(model: "translategemma:4b", digest: "fixture-digest", protocolVersion: "translategemma-simple-text-v1")
    }

    func translate(text: String, source: ArtifactLanguage, target: ArtifactLanguage) async throws -> String {
        "This is different English output."
    }
}

private final class CancellableENRUTranslator: SimpleTextTranslationProvider {
    private let started = DispatchSemaphore(value: 0)

    func identity() async throws -> TranslationModelIdentity {
        TranslationModelIdentity(model: "translategemma:4b", digest: "fixture-digest", protocolVersion: "translategemma-simple-text-v1")
    }

    func translate(text: String, source: ArtifactLanguage, target: ArtifactLanguage) async throws -> String {
        started.signal()
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return "Проверенный русский перевод."
    }

    func waitUntilStarted() -> Bool {
        started.wait(timeout: .now() + 5) == .success
    }
}

private struct ProbeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
