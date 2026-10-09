import Foundation

@main
struct RUENTranslationSliceProbe {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("videotext-ru-en-slice-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try require(WorkflowOperation.translateTranscript.isEnabledForCurrentRelease, "RU→EN operation is disabled")
        try require(!WorkflowOperation.userSelectable.contains(.translateTranscript), "translation became automatic Core work")
        try require(!WorkflowOperation.createDubbing.isEnabledForCurrentRelease, "dubbing was enabled")
        try require(ArtifactLanguage.ru.translationTarget == .en && ArtifactLanguage.en.translationTarget == .ru,
                    "translation directions are not limited to the accepted RU↔EN pair")

        try await verifyTargetLanguagePromptContract()
        try await verifyApprovedSourceFlow(root: root.appendingPathComponent("success"))
        try await verifyRejectedResponseRetriesAndPersistsEvidence(root: root.appendingPathComponent("retry-success"))
        try await verifySourceFallbackFailsClosed(root: root.appendingPathComponent("source-fallback"))
        try await verifyWrongLanguageFailsClosed(root: root.appendingPathComponent("wrong-language"))
        try await verifyFailureIsolation(root: root.appendingPathComponent("failure-isolation"))
        print("RU_EN_TRANSLATION_SLICE_PROBE_PASS")
    }

    private static func verifyTargetLanguagePromptContract() async throws {
        let recorder = PromptRequestRecorder()
        let translator = OllamaSimpleTextTranslateGemma(transport: { request in
            await recorder.record(request)
            return try JSONSerialization.data(withJSONObject: [
                "done": true,
                "message": ["content": "Translated output."]
            ])
        })

        _ = try await translator.translate(
            text: " А, что еще важно хотел добавить",
            source: .ru,
            target: .en
        )
        _ = try await translator.translate(
            text: " And I also wanted to add",
            source: .en,
            target: .ru
        )

        let prompts = await recorder.prompts()
        try require(prompts.count == 2, "prompt contract probe did not capture both translation directions")
        let ruToEn = prompts[0]
        let enToRu = prompts[1]
        let semanticInstruction = "Return only the translated passage. Preserve meaning, negation, numbers, names, terminology and natural repetitions. Do not add context or complete unstated meaning."

        try require(ruToEn.contains(semanticInstruction)
                    && ruToEn.contains("The output must be in English. Do not return Russian text.")
                    && ruToEn.hasSuffix("\n\n А, что еще важно хотел добавить"),
                    "RU→EN prompt lost its semantic contract, target-language contract, or leading whitespace")
        try require(enToRu.contains(semanticInstruction)
                    && enToRu.contains("The output must be in Russian. Do not return English text.")
                    && enToRu.hasSuffix("\n\n And I also wanted to add"),
                    "EN→RU prompt lost its semantic contract, target-language contract, or source text")
    }

    private static func verifyApprovedSourceFlow(root: URL) async throws {
        let fixture = try makeFixture(root: root)
        let translator = RecordingRUENTranslator()
        let engine = WorkflowEngine(
            store: fixture.store,
            selectedTimingTranslation: SelectedTimingVerticalSlice(translator: translator)
        )
        let sourceSRT = try Data(contentsOf: fixture.layout.fullSRTURL)
        let sourceTXT = try Data(contentsOf: fixture.layout.transcriptURL)
        var log: [String] = []
        let result = try await engine.run(settings: settings(fixture), onLog: { log.append($0) })

        try require(result.checkpoint?.kind == .translatedTranscript && result.checkpoint?.language == .en,
                    "RU→EN translation did not open required English Translation Human Review")
        try require(!log.contains(where: { $0.contains("Расшифровка bundled SeminarText") }),
                    "RU→EN translation reran ASR")
        try require(translator.requests.allSatisfy { $0.source == .ru && $0.target == .en },
                    "provider received a direction other than RU→EN")
        try require(try Data(contentsOf: fixture.layout.fullSRTURL) == sourceSRT
                    && Data(contentsOf: fixture.layout.transcriptURL) == sourceTXT,
                    "RU→EN translation changed approved Russian source artifacts")

        let pending = try fixture.store.load(from: fixture.project)
        try require(pending.activeTranscriptRevision(for: .en) == nil,
                    "pending EN translation became active before Human Review")
        try require(pending.workflow?.operations[WorkflowOperation.transcribe.rawValue] == nil,
                    "RU→EN translation recorded an ASR operation")
        try require((pending.artifacts ?? []).filter { $0.language == .en }.allSatisfy { $0.validationStatus == .needsReview },
                    "pending EN translation artifacts were marked ready")
        try require(SubtitleSourceResolver.availableSelections(manifest: pending, projectURL: fixture.project) == [.source],
                    "pending EN translation was selectable as subtitles")

        let document = try JSONDecoder().decode(
            TimedTranslationDocument.self,
            from: Data(contentsOf: fixture.layout.selectedTimingTranslationsURL(source: .ru, target: .en))
        )
        try require(document.sourceLanguage == .ru && document.targetLanguage == .en,
                    "timed translation provenance recorded the wrong direction")
        try require(zip(document.source.units, document.units).allSatisfy {
            $0.id == $1.sourceUnitID && $0.textSHA256 == $1.sourceTextSHA256 && $0.start == $1.start && $0.end == $1.end
        }, "RU→EN translation lost source ordering, ownership, or timing")

        _ = try HumanReviewService(store: fixture.store).approve(projectURL: fixture.project)
        let approved = try fixture.store.load(from: fixture.project)
        try require(approved.activeTranscriptRevision(for: .ru)?.reviewStatus == .approved,
                    "RU source approval was lost")
        try require(approved.activeTranscriptRevision(for: .en)?.reviewStatus == .approved,
                    "EN translation was not approved")
        try require(FileManager.default.fileExists(atPath: fixture.layout.transcriptURL(language: .en).path)
                    && FileManager.default.fileExists(atPath: fixture.layout.subtitlesURL(language: .en).path),
                    "approved EN TXT/SRT are missing")
        try require(SubtitleSourceResolver.availableSelections(manifest: approved, projectURL: fixture.project)
                    == [.source, .approvedTranslation(.en)],
                    "approved EN translation was not selectable as Перевод (EN)")
        let selected = try SubtitleSourceResolver.resolve(.approvedTranslation(.en), manifest: approved, projectURL: fixture.project)
        try require(selected.language == .en && selected.isTranslation && selected.srtURL == fixture.layout.subtitlesURL(language: .en),
                    "approved EN subtitles resolved to the wrong source")

        let callsBeforeResume = translator.requests.count
        let resumed = try await engine.run(settings: settings(fixture), onLog: { log.append($0) })
        try require(resumed.checkpoint == nil && translator.requests.count == callsBeforeResume,
                    "reopen/resume reran approved RU→EN translation")
        let reopened = try fixture.store.openProject(at: fixture.project).0
        try require(reopened.activeTranscriptRevision(for: .ru)?.reviewStatus == .approved
                    && reopened.activeTranscriptRevision(for: .en)?.reviewStatus == .approved,
                    "reopen lost approved RU/EN revisions")
    }

    private static func verifySourceFallbackFailsClosed(root: URL) async throws {
        let fixture = try makeFixture(root: root)
        do {
            _ = try await WorkflowEngine(
                store: fixture.store,
                selectedTimingTranslation: SelectedTimingVerticalSlice(translator: SourceFallbackTranslator())
            ).run(settings: settings(fixture), onLog: { _ in })
            throw ProbeFailure(message: "Russian source fallback unexpectedly succeeded")
        } catch WorkflowError.processFailed(let message) {
            try require(message.contains("исходный текст без перевода"), "source fallback produced the wrong failure")
        }
        let manifest = try fixture.store.load(from: fixture.project)
        try require(manifest.activeTranscriptRevision(for: .en) == nil,
                    "source fallback became an active EN revision")
        try require(!FileManager.default.fileExists(atPath: fixture.layout.subtitlesURL(language: .en).path),
                    "source fallback published EN subtitles")
        let rejected = rejectedResponses(at: fixture.layout, source: .ru, target: .en)
        try require(rejected.count == 2,
                    "source fallback retained \(rejected.count) rejected attempts instead of two")
        try require(cachedTexts(at: fixture.layout).isEmpty,
                    "source fallback was cached as a valid translation")
        try require(manifest.workflow?.status == .completed, "source fallback invalidated the Core project")
    }

    private static func verifyRejectedResponseRetriesAndPersistsEvidence(root: URL) async throws {
        let fixture = try makeFixture(root: root)
        let translator = RejectThenTranslateRUENTranslator()
        let result = try await WorkflowEngine(
            store: fixture.store,
            selectedTimingTranslation: SelectedTimingVerticalSlice(translator: translator)
        ).run(settings: settings(fixture), onLog: { _ in })

        try require(result.checkpoint?.kind == .translatedTranscript && result.checkpoint?.language == .en,
                    "valid retry did not reach English Translation Human Review")
        try require(translator.calls == 3,
                    "translation did not make exactly one bounded retry before translating both units")
        let rejected = rejectedResponses(at: fixture.layout, source: .ru, target: .en)
        try require(rejected.count == 1, "valid retry retained the wrong number of rejected responses")
        guard let evidence = rejected.first else { throw ProbeFailure(message: "missing rejected response evidence") }
        try require(evidence.unitID == 1
                    && evidence.sourceLanguage == .ru
                    && evidence.targetLanguage == .en
                    && evidence.sourceTextSHA256 == SelectedTimingHash.string(" Юрий не отменил встречу в 7 часов.")
                    && evidence.model == "translategemma:4b"
                    && evidence.modelDigest == "fixture-digest"
                    && evidence.protocolVersion == "translategemma-simple-text-v1"
                    && evidence.attempt == 1
                    && evidence.rawResponse == "Русский ответ без перевода."
                    && evidence.latinLetterCount == 0
                    && evidence.cyrillicLetterCount > 0
                    && evidence.validationFailureReason.contains("преимущественно не на английском языке")
                    && !evidence.requestSHA256.isEmpty,
                    "rejected response evidence is incomplete or altered")
        let cache = cachedTexts(at: fixture.layout)
        try require(cache.count == 2, "accepted retry did not populate the normal cache")
        try require(!cache.contains("Русский ответ без перевода."),
                    "rejected response was cached as a valid translation")
    }

    private static func verifyWrongLanguageFailsClosed(root: URL) async throws {
        let fixture = try makeFixture(root: root)
        do {
            _ = try await WorkflowEngine(
                store: fixture.store,
                selectedTimingTranslation: SelectedTimingVerticalSlice(translator: RussianOutputTranslator())
            ).run(settings: settings(fixture), onLog: { _ in })
            throw ProbeFailure(message: "Russian output unexpectedly passed as English translation")
        } catch WorkflowError.processFailed(let message) {
            try require(message.contains("преимущественно не на английском языке"),
                        "wrong-language output produced the wrong failure")
        }
        let manifest = try fixture.store.load(from: fixture.project)
        try require(manifest.activeTranscriptRevision(for: .en) == nil,
                    "wrong-language output became an active EN revision")
        let rejected = rejectedResponses(at: fixture.layout, source: .ru, target: .en)
        try require(rejected.count == SelectedTimingVerticalSlice.maximumTranslationAttempts,
                    "retry exhaustion did not retain every rejected response")
        try require(rejected.map(\.attempt) == [1, 2]
                    && rejected.allSatisfy { $0.rawResponse == "Русский ответ без перевода." },
                    "retry evidence did not retain the exact rejected responses")
        try require(cachedTexts(at: fixture.layout).isEmpty,
                    "retry exhaustion cached rejected text as a valid translation")
        try Data("existing topics".utf8).write(to: fixture.layout.topicsURL)
        try require(FileManager.default.fileExists(atPath: fixture.layout.topicsURL.path),
                    "Core project is not usable after translation retry exhaustion")
    }

    private static func verifyFailureIsolation(root: URL) async throws {
        let fixture = try makeFixture(root: root)
        let preservedTopic = fixture.layout.topicsURL
        try Data("existing topics".utf8).write(to: preservedTopic)
        let sourceSRT = try Data(contentsOf: fixture.layout.fullSRTURL)
        do {
            _ = try await WorkflowEngine(
                store: fixture.store,
                selectedTimingTranslation: SelectedTimingVerticalSlice(translator: FailingRUENTranslator())
            ).run(settings: settings(fixture), onLog: { _ in })
            throw ProbeFailure(message: "controlled RU→EN failure unexpectedly succeeded")
        } catch WorkflowError.processFailed(let message) {
            try require(message.contains("controlled TranslateGemma failure"), "wrong controlled failure")
        }
        let failed = try fixture.store.load(from: fixture.project)
        try require(failed.workflow?.status == .completed,
                    "optional RU→EN failure changed completed Core workflow")
        try require(failed.workflow?.operations[WorkflowOperation.translateTranscript.rawValue]?.status == .failed,
                    "translation failure was not retained separately")
        try require(failed.activeTranscriptRevision(for: .ru)?.reviewStatus == .approved
                    && failed.activeTranscriptRevision(for: .en) == nil,
                    "translation failure changed source transcript authority")
        try require(try Data(contentsOf: fixture.layout.fullSRTURL) == sourceSRT
                    && Data(contentsOf: preservedTopic) == Data("existing topics".utf8),
                    "translation failure changed existing Core artifacts")
    }

    private static func settings(_ fixture: Fixture) -> WorkflowSettings {
        WorkflowSettings(
            mediaURL: fixture.media,
            projectURL: fixture.project,
            selectedOperations: [.translateTranscript],
            mode: .resumeProject,
            rangeStart: 0,
            rangeEnd: 2,
            fragmentName: "",
            burnFragmentSubtitles: false,
            subtitleStyle: .standard,
            selectedTopicID: nil,
            whisperModelPath: "/must-not-be-used/whisper.bin",
            whisperLanguage: "ru",
            sourceHumanReviewEnabled: true,
            translationHumanReviewEnabled: true,
            fillerAnalysisBeforeReview: true
        )
    }

    private static func makeFixture(root: URL) throws -> Fixture {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = root.appendingPathComponent("russian-source.mp4")
        let project = root.appendingPathComponent("project", isDirectory: true)
        try Data("controlled Russian media".utf8).write(to: media)
        let store = ProjectStore(history: ProjectHistoryStore(indexURL: root.appendingPathComponent("history.json")))
        var manifest = try store.ensureProject(at: project, mediaURL: media, mode: .newProject)
        let layout = ProjectLayout(root: project)
        let cues = [
            SubtitleCue(id: 1, start: 0, end: 0.8, text: "Юрий не отменил встречу в 7 часов."),
            SubtitleCue(id: 3, start: 0.8, end: 1.6, text: "В отчёте указано 12 участников.")
        ]
        try SRTService().writePreservingIDs(cues, to: layout.fullSRTURL)
        try SRTService().writePreservingIDs(cues, to: layout.subtitlesURL(language: .ru))
        let transcript = cues.map(\.text).joined(separator: "\n\n") + "\n"
        try transcript.write(to: layout.transcriptURL, atomically: true, encoding: .utf8)
        try transcript.write(to: layout.transcriptURL(language: .ru), atomically: true, encoding: .utf8)
        try makeCorePackage(layout: layout, media: media)

        let sourceID = "approved-ru-source"
        let sourceSRT = try Data(contentsOf: layout.fullSRTURL)
        try sourceSRT.write(to: layout.subtitleRevisionURL(id: sourceID, language: .ru))
        try Data(contentsOf: layout.transcriptURL).write(to: layout.transcriptRevisionURL(id: sourceID, language: .ru))
        manifest.languageProfile = LanguageProfile(
            detected: .ru, effective: .ru, confidence: 1, method: "fixture", model: nil, modelVersion: nil,
            sampleRanges: [], manuallyOverridden: false, detectedAt: Date()
        )
        manifest.transcriptRevisions = [TranscriptRevision(
            id: sourceID, language: .ru, origin: .userEdited, parentRevisionID: "machine-ru-source",
            transcriptArtifactID: "source-ru-txt", subtitleArtifactID: "source-ru-srt",
            contentHash: StableTopicHash.string(try String(contentsOf: layout.fullSRTURL, encoding: .utf8)),
            createdAt: Date(), reviewStatus: .approved
        )]
        var review = HumanReviewState.newProjectDefault
        review.sourceReviewEnabled = true
        review.translationReviewEnabled = true
        review.activeRevisionIDs[ArtifactLanguage.ru.rawValue] = sourceID
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
        let text = " Юрий не отменил встречу в 7 часов. В отчёте указано 12 участников."
        let tokens: [[String: Any]] = [
            token(" Юрий", 0, 100), token(" не", 100, 180), token(" отменил", 180, 300), token(" встречу", 300, 420),
            token(" в", 420, 470), token(" 7", 470, 520), token(" часов", 520, 760), token(".", 760, 800),
            token(" В", 800, 860), token(" отчёте", 860, 980), token(" указано", 980, 1100), token(" 12", 1100, 1160),
            token(" участников", 1160, 1560), token(".", 1560, 1600), token("[_EOT_]", 1600, 1600)
        ]
        let json: [String: Any] = ["transcription": [[
            "offsets": ["from": 0, "to": 1600], "no_speech_prob": 0.01, "tokens": tokens
        ]]]
        try JSONSerialization.data(withJSONObject: json).write(to: jsonURL)
        try Data(text.utf8).write(to: txtURL)
        try Data("1\n00:00:00,000 --> 00:00:01,600\n\(text)\n".utf8).write(to: srtURL)
        func artifact(_ url: URL) -> [String: String] {
            ["path": "parts/\(url.lastPathComponent)", "sha256": SelectedTimingHash.file(url)]
        }
        let selectedManifest: [String: Any] = [
            "schema_version": 1,
            "artifact_type": "seminartext.selected_whisper_timing",
            "source": ["media_sha256": SelectedTimingHash.file(media)],
            "transcription": ["language": "ru"],
            "parts": [[
                "id": "part_0000", "order": 0, "absolute_offset_seconds": 0.0,
                "absolute_range": ["start_seconds": 0.0, "end_seconds": 1.6],
                "selected_timing_absolute_range": ["start_seconds": 0.0, "end_seconds": 1.6],
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

    private static func rejectedResponses(
        at layout: ProjectLayout,
        source: ArtifactLanguage,
        target: ArtifactLanguage
    ) -> [SelectedTimingRejectedResponseEvidence] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try? decoder.decode(
            SelectedTimingRejectedResponseEvidenceDocument.self,
            from: Data(contentsOf: layout.selectedTimingTranslationRejectedResponsesURL(source: source, target: target))
        )
        return document?.responses ?? []
    }

    private static func cachedTexts(at layout: ProjectLayout) -> [String] {
        guard let runDirectories = try? FileManager.default.contentsOfDirectory(
            at: layout.selectedTimingTranslationCacheDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return runDirectories.flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        }.compactMap { url in
            guard let root = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { return nil }
            return root["text"] as? String
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw ProbeFailure(message: message) }
    }

    private struct Fixture {
        let media: URL
        let project: URL
        let layout: ProjectLayout
        let store: ProjectStore
    }
}

private protocol RUENTranslator: SimpleTextTranslationProvider {}

private actor PromptRequestRecorder {
    private var captured: [URLRequest] = []

    func record(_ request: URLRequest) {
        captured.append(request)
    }

    func prompts() -> [String] {
        captured.compactMap { request in
            guard let body = request.httpBody,
                  let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let messages = root["messages"] as? [[String: Any]],
                  let content = messages.first?["content"] as? String else {
                return nil
            }
            return content
        }
    }
}

private final class RecordingRUENTranslator: RUENTranslator {
    struct Request { let source: ArtifactLanguage; let target: ArtifactLanguage }
    private(set) var requests: [Request] = []

    func identity() async throws -> TranslationModelIdentity {
        TranslationModelIdentity(model: "translategemma:4b", digest: "fixture-digest", protocolVersion: "translategemma-simple-text-v1")
    }

    func translate(text: String, source: ArtifactLanguage, target: ArtifactLanguage) async throws -> String {
        requests.append(Request(source: source, target: target))
        return requests.count == 1 ? "Yuri did not cancel the meeting at 7 o'clock." : "The report lists 12 participants."
    }
}

private struct SourceFallbackTranslator: RUENTranslator {
    func identity() async throws -> TranslationModelIdentity {
        TranslationModelIdentity(model: "translategemma:4b", digest: "fixture-digest", protocolVersion: "translategemma-simple-text-v1")
    }
    func translate(text: String, source: ArtifactLanguage, target: ArtifactLanguage) async throws -> String { text }
}

private struct RussianOutputTranslator: RUENTranslator {
    func identity() async throws -> TranslationModelIdentity {
        TranslationModelIdentity(model: "translategemma:4b", digest: "fixture-digest", protocolVersion: "translategemma-simple-text-v1")
    }
    func translate(text: String, source: ArtifactLanguage, target: ArtifactLanguage) async throws -> String { "Русский ответ без перевода." }
}

private final class RejectThenTranslateRUENTranslator: RUENTranslator {
    private(set) var calls = 0

    func identity() async throws -> TranslationModelIdentity {
        TranslationModelIdentity(model: "translategemma:4b", digest: "fixture-digest", protocolVersion: "translategemma-simple-text-v1")
    }

    func translate(text: String, source: ArtifactLanguage, target: ArtifactLanguage) async throws -> String {
        calls += 1
        if calls == 1 { return "Русский ответ без перевода." }
        return calls == 2 ? "Yuri did not cancel the meeting at 7 o'clock." : "The report lists 12 participants."
    }
}

private struct FailingRUENTranslator: RUENTranslator {
    func identity() async throws -> TranslationModelIdentity {
        TranslationModelIdentity(model: "translategemma:4b", digest: "fixture-digest", protocolVersion: "translategemma-simple-text-v1")
    }
    func translate(text: String, source: ArtifactLanguage, target: ArtifactLanguage) async throws -> String {
        throw WorkflowError.processFailed("controlled TranslateGemma failure")
    }
}

private struct ProbeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
