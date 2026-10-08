import Foundation

@main
struct TranslationAdapterProbe {
    static func main() async throws {
        let source = [
            SubtitleCue(id: 7, start: 1.25, end: 3.75, text: "В версии 2 есть десять функций."),
            SubtitleCue(id: 9, start: 4, end: 6, text: "Проверяем порядок строк.")
        ]
        let provider = ScriptedTranslationProvider(responses: [
            [7: "", 9: "We check the line order."],
            [7: "Version 2 has ten functions.", 9: "We check the line order."]
        ])
        let result = try await TranslationAdapter(provider: provider).translate(
            cues: source,
            source: .ru,
            target: .en,
            onProgress: { _ in },
            onLog: { _ in }
        )
        let providerCallCount = await provider.callCount
        try require(providerCallCount == 2, "невалидный cue не был повторен ровно один раз, либо соседний cue пересчитан")
        try require(result.issues.isEmpty, "валидный повтор оставил ReviewTask")
        try require(result.cues.map(\.id) == [7, 9], "перевод изменил cue ID")
        try require(result.cues.map(\.start) == source.map(\.start), "перевод изменил таймкоды")
        try require(result.cues[0].text == "Version 2 has ten functions.", "не сохранён EN-перевод")

        let reverse = try await TranslationAdapter(provider: ScriptedTranslationProvider(responses: [[
            7: "В версии 2 есть десять функций.",
            9: "Проверяем порядок строк."
        ]])).translate(
            cues: result.cues,
            source: .en,
            target: .ru,
            onProgress: { _ in },
            onLog: { _ in }
        )
        try require(reverse.issues.isEmpty && reverse.cues[1].text.contains("Проверяем"), "не работает EN → RU")

        let bad = try await TranslationAdapter(provider: ScriptedTranslationProvider(responses: [
            [7: "Version 3 has ten functions.", 9: "We check the line order."],
            [7: "Version 3 has ten functions.", 9: "We check the line order."]
        ])).translate(
            cues: source,
            source: .ru,
            target: .en,
            onProgress: { _ in },
            onLog: { _ in }
        )
        try require(!bad.issues.isEmpty, "изменение числа не помечено для проверки")

        let changedTerm = try await TranslationAdapter(provider: ScriptedTranslationProvider(responses: [
            [1: "Модуль видеотекст готов."],
            [1: "Модуль видеотекст готов."]
        ])).translate(
            cues: [SubtitleCue(id: 1, start: 0, end: 2, text: "The videotext module is ready.")],
            source: .en,
            target: .ru,
            onProgress: { _ in },
            onLog: { _ in }
        )
        try require(
            changedTerm.issues.contains { $0.reasonCodes.contains(where: { $0.contains("protected-term-changed") }) },
            "изменение защищенного технического термина не помечено для проверки"
        )

        try verifyTranslatedReviewDoesNotChangeSource()
        try verifyDisabledTranslationReviewDoesNotApproveFallback()
        try verifyDisabledTranslationReviewApprovesValidResult()
        print("TRANSLATION_ADAPTER_PROBE_PASS")
    }

    private static func verifyTranslatedReviewDoesNotChangeSource() throws {
        let fm = FileManager.default
        let root = (URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? fm.temporaryDirectory.path, isDirectory: true)).appendingPathComponent("videotext-translation-review-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let sourceMedia = root.appendingPathComponent("source.mp4")
        let project = root.appendingPathComponent("project", isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("media".utf8).write(to: sourceMedia)
        let store = ProjectStore(history: ProjectHistoryStore(indexURL: root.appendingPathComponent("history.json")))
        var manifest = try store.ensureProject(at: project, mediaURL: sourceMedia, mode: .newProject)
        manifest.languageProfile = LanguageProfile(
            detected: .ru,
            effective: .ru,
            confidence: 1,
            method: "probe",
            model: nil,
            modelVersion: nil,
            sampleRanges: [],
            manuallyOverridden: false,
            detectedAt: Date()
        )
        let layout = ProjectLayout(root: project)
        let sourceCues = [SubtitleCue(id: 7, start: 1, end: 2, text: "Исходный текст")]
        let translatedCues = [SubtitleCue(id: 7, start: 1, end: 2, text: "Bad translation")]
        try SRTService().writePreservingIDs(sourceCues, to: layout.fullSRTURL)
        try SRTService().writePreservingIDs(sourceCues, to: layout.subtitlesURL(language: .ru))
        try SRTService().writePreservingIDs(translatedCues, to: layout.subtitlesURL(language: .en))
        try "Исходный текст\n".write(to: layout.transcriptURL(language: .ru), atomically: true, encoding: .utf8)
        try "Bad translation\n".write(to: layout.transcriptURL(language: .en), atomically: true, encoding: .utf8)
        let revision = TranscriptRevision(
            id: "translation-probe",
            language: .en,
            origin: .translated,
            parentRevisionID: "source-probe",
            transcriptArtifactID: "translation-txt",
            subtitleArtifactID: "translation-srt",
            contentHash: nil,
            createdAt: Date()
        )
        manifest.transcriptRevisions = [revision]
        manifest.reviewTasks = [ReviewTask(
            id: "translation-task",
            transcriptRevisionID: revision.id,
            status: .needsReview,
            language: .en,
            start: 1,
            end: 2,
            cueIDs: [7],
            reasonCodes: ["translation-invalid"],
            confidence: nil,
            originalText: "Исходный текст",
            suggestedText: "Good translation",
            createdAt: Date(),
            resolvedAt: nil,
            dependentArtifactIDs: []
        )]
        try store.save(manifest, to: project)
        _ = try ReviewTaskService(store: store).resolve(
            projectURL: project,
            taskID: "translation-task",
            replacementText: "Good translation"
        )
        let unchanged = try SRTService().load(from: layout.fullSRTURL)
        let edited = try SRTService().load(from: layout.subtitlesURL(language: .en))
        try require(unchanged.first?.text == "Исходный текст", "правка перевода изменила full.srt")
        try require(edited.first?.text == "Good translation", "правка не попала в EN SRT")
    }

    private static func verifyDisabledTranslationReviewDoesNotApproveFallback() throws {
        let fixture = try translationReviewFixture(hasUnresolvedTask: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        do {
            _ = try HumanReviewService(store: fixture.store).transitionAfterGeneration(
                projectURL: fixture.project,
                kind: .translatedTranscript,
                language: .en,
                revisionID: fixture.revision.id,
                pendingOperations: [],
                sourceReviewEnabled: false,
                translationReviewEnabled: false
            )
            throw ProbeFailure(message: "неполученный перевод был автоматически утвержден")
        } catch WorkflowError.processFailed(let message) {
            try require(message.contains("не может быть автоматически утверждён"), "неправильная ошибка для неполученного перевода")
        }

        let manifest = try fixture.store.load(from: fixture.project)
        let translated = try SRTService().load(from: fixture.layout.subtitlesURL(language: .en))
        try require(
            manifest.activeTranscriptRevision(for: .en) == nil
                && manifest.transcriptRevisions?.first?.reviewStatus != .approved,
            "fallback-перевод стал активной утвержденной ревизией"
        )
        try require(
            manifest.reviewTasks?.contains(where: { $0.status == .needsReview }) == true
                && (manifest.artifacts ?? []).allSatisfy { $0.validationStatus == .needsReview },
            "fallback-перевод потерял статус needsReview"
        )
        try require(
            translated.first?.text == fixture.sourceText,
            "probe не сохранил контролируемый source-text fallback"
        )
    }

    private static func verifyDisabledTranslationReviewApprovesValidResult() throws {
        let fixture = try translationReviewFixture(hasUnresolvedTask: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let checkpoint = try HumanReviewService(store: fixture.store).transitionAfterGeneration(
            projectURL: fixture.project,
            kind: .translatedTranscript,
            language: .en,
            revisionID: fixture.revision.id,
            pendingOperations: [],
            sourceReviewEnabled: false,
            translationReviewEnabled: false
        )
        let manifest = try fixture.store.load(from: fixture.project)
        try require(checkpoint == nil, "валидный перевод ошибочно потребовал Human Review")
        try require(
            manifest.activeTranscriptRevision(for: .en)?.id == fixture.revision.id
                && manifest.transcriptRevisions?.first?.reviewStatus == .approved
                && (manifest.artifacts ?? []).allSatisfy { $0.validationStatus == .ready },
            "валидный перевод не стал готовым при выключенном optional review"
        )
    }

    private static func translationReviewFixture(hasUnresolvedTask: Bool) throws -> (
        root: URL,
        project: URL,
        layout: ProjectLayout,
        store: ProjectStore,
        revision: TranscriptRevision,
        sourceText: String
    ) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("videotext-translation-approval-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let media = root.appendingPathComponent("source.mp4")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("media".utf8).write(to: media)
        let store = ProjectStore(history: ProjectHistoryStore(indexURL: root.appendingPathComponent("history.json")))
        var manifest = try store.ensureProject(at: project, mediaURL: media, mode: .newProject)
        let layout = ProjectLayout(root: project)
        let sourceText = "The untranslated fallback must not be approved."
        let cue = SubtitleCue(id: 7, start: 1, end: 2, text: sourceText)
        try SRTService().writePreservingIDs([cue], to: layout.subtitlesURL(language: .en))
        try sourceText.write(to: layout.transcriptURL(language: .en), atomically: true, encoding: .utf8)
        let revision = TranscriptRevision(
            id: "translation-approval-probe",
            language: .en,
            origin: .translated,
            parentRevisionID: "source-probe",
            transcriptArtifactID: "translation-txt",
            subtitleArtifactID: "translation-srt",
            contentHash: nil,
            createdAt: Date(),
            reviewStatus: hasUnresolvedTask ? .pending : nil
        )
        manifest.transcriptRevisions = [revision]
        manifest.artifacts = [
            ProjectArtifactRecord(
                id: revision.transcriptArtifactID,
                kind: .transcript,
                path: layout.transcriptURL(language: .en).path,
                language: .en,
                origin: .translated,
                granularity: nil,
                sourceArtifactID: nil,
                sourceRevision: revision.id,
                dependencyIDs: [],
                contentHash: nil,
                createdAt: Date(),
                generator: "probe",
                generatorVersion: "1",
                model: "probe",
                validationStatus: .needsReview,
                qualityStatus: .needsReview,
                reviewTaskCount: hasUnresolvedTask ? 1 : 0
            ),
            ProjectArtifactRecord(
                id: revision.subtitleArtifactID,
                kind: .subtitles,
                path: layout.subtitlesURL(language: .en).path,
                language: .en,
                origin: .translated,
                granularity: nil,
                sourceArtifactID: revision.transcriptArtifactID,
                sourceRevision: revision.id,
                dependencyIDs: [revision.transcriptArtifactID],
                contentHash: nil,
                createdAt: Date(),
                generator: "probe",
                generatorVersion: "1",
                model: "probe",
                validationStatus: .needsReview,
                qualityStatus: .needsReview,
                reviewTaskCount: hasUnresolvedTask ? 1 : 0
            )
        ]
        if hasUnresolvedTask {
            manifest.reviewTasks = [ReviewTask(
                id: "fallback-task",
                transcriptRevisionID: revision.id,
                status: .needsReview,
                language: .en,
                start: cue.start,
                end: cue.end,
                cueIDs: [cue.id],
                reasonCodes: ["translation-invalid"],
                confidence: nil,
                originalText: sourceText,
                suggestedText: sourceText,
                createdAt: Date(),
                resolvedAt: nil,
                dependentArtifactIDs: [revision.transcriptArtifactID, revision.subtitleArtifactID]
            )]
        } else {
            manifest.reviewTasks = []
        }
        try store.save(manifest, to: project)
        return (root, project, layout, store, revision, sourceText)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private actor ScriptedTranslationProvider: TranslationAIProvider {
    private var responses: [[Int: String]]
    private(set) var callCount = 0

    init(responses: [[Int: String]]) {
        self.responses = responses
    }

    func preferredModel() async throws -> String { "probe-model" }

    func translate(
        cues: [TranslationRequestCue],
        source: ArtifactLanguage,
        target: ArtifactLanguage,
        model: String,
        correction: String?
    ) async throws -> [Int: String] {
        let index = min(callCount, max(responses.count - 1, 0))
        callCount += 1
        let owned = Set(cues.map(\.id))
        return responses[index].filter { owned.contains($0.key) }
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
