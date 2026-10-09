import Foundation

@main
struct SimpleProjectHomeProbe {
    static func main() throws {
        try verifiesPresentationModes()
        try verifiesApprovedAndPendingStates()
        try verifiesLanguageLabelsAndExistingResults()
        print("SIMPLE_PROJECT_HOME_PROBE_PASS")
    }

    private static func verifiesPresentationModes() throws {
        guard ProjectPresentationMode.simple != .advanced,
              ProjectPresentationMode.simple.title == "Простой",
              ProjectPresentationMode.advanced.title == "Расширенный" else {
            throw ProbeFailure(message: "Режимы Simple/Advanced не различаются")
        }

        let state = SimpleProjectHomeStateService().make(
            projectURL: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            manifest: baseManifest(language: .ru),
            topicsDetail: nil,
            topicsAreViewable: false,
            discoveredOutputs: []
        )
        let mode = ProjectPresentationMode.advanced
        try expect(mode == .advanced && state.projectName == "project", "Переключение presentation mode не должно менять snapshot проекта")
    }

    private static func verifiesApprovedAndPendingStates() throws {
        let service = SimpleProjectHomeStateService()
        let source = sourceRevision(language: .ru, status: .approved)
        let topic = topicRevision(status: .approved)
        var manifest = baseManifest(language: .ru)
        manifest.transcriptRevisions = [source]
        manifest.humanReviewState = HumanReviewState(
            sourceReviewEnabled: true,
            translationReviewEnabled: false,
            fillerAnalysisBeforeReview: true,
            activeRevisionIDs: ["ru": source.id],
            draftRevisionIDs: [:],
            pendingCheckpoint: nil
        )
        manifest.topicRevisions = [topic]
        manifest.topicReviewState = TopicReviewState(
            enabled: true,
            activeRevisionIDs: [topic.variantKey: topic.id],
            pendingCheckpoint: nil
        )

        let ready = service.make(
            projectURL: URL(fileURLWithPath: "/tmp/Проект", isDirectory: true),
            manifest: manifest,
            topicsDetail: "тем: 7",
            topicsAreViewable: true,
            discoveredOutputs: [output(kind: "transcript"), output(kind: "topics")]
        )
        try expect(ready.artifact(.transcription).readiness == .ready, "Утверждённая source-ревизия не показана готовой")
        try expect(ready.artifact(.transcription).detail == "Русский", "Неверная подпись RU source")
        try expect(ready.artifact(.topics).readiness == .ready, "Утверждённые темы не показаны готовыми")
        try expect(ready.artifact(.topics).detail == "тем: 7", "Home не использует существующий summary тем")

        let unavailableTranscript = service.make(
            projectURL: URL(fileURLWithPath: "/tmp/Проект", isDirectory: true),
            manifest: manifest,
            topicsDetail: "тем: 7",
            topicsAreViewable: true,
            discoveredOutputs: [output(kind: "topics")]
        )
        try expect(unavailableTranscript.artifact(.transcription).readiness == .missing, "Одобренная ревизия без discovered output ошибочно показана готовой")

        manifest.humanReviewState?.pendingCheckpoint = HumanReviewCheckpoint(
            kind: .sourceTranscript,
            language: .ru,
            revisionID: source.id,
            pendingOperations: [],
            createdAt: Date()
        )
        let pendingSource = service.make(
            projectURL: URL(fileURLWithPath: "/tmp/Проект", isDirectory: true),
            manifest: manifest,
            topicsDetail: "тем: 7",
            topicsAreViewable: true,
            discoveredOutputs: []
        )
        try expect(pendingSource.artifact(.transcription).readiness == .needsReview, "Pending Source Review показан как готовый")
        try expect(pendingSource.artifact(.transcription).reviewTarget == .source, "Для Source Review не указан переход к проверке")

        manifest.humanReviewState?.pendingCheckpoint = nil
        manifest.topicReviewState?.pendingCheckpoint = TopicReviewCheckpoint(
            revisionIDs: [topic.variantKey: topic.id],
            pendingOperations: [],
            createdAt: Date()
        )
        let pendingTopics = service.make(
            projectURL: URL(fileURLWithPath: "/tmp/Проект", isDirectory: true),
            manifest: manifest,
            topicsDetail: "тем: 7",
            topicsAreViewable: true,
            discoveredOutputs: []
        )
        try expect(pendingTopics.artifact(.topics).readiness == .needsReview, "Pending Topic Review показан как готовый")
        try expect(pendingTopics.artifact(.topics).reviewTarget == .topics, "Для Topic Review не указан переход к проверке")
    }

    private static func verifiesLanguageLabelsAndExistingResults() throws {
        let service = SimpleProjectHomeStateService()
        let source = sourceRevision(language: .en, status: .approved)
        let translation = TranscriptRevision(
            id: "translation-ru",
            language: .ru,
            origin: .translated,
            parentRevisionID: source.id,
            transcriptArtifactID: "artifact-translation-ru",
            subtitleArtifactID: "artifact-subtitles-ru",
            contentHash: "translation",
            createdAt: Date(),
            reviewStatus: .approved
        )
        var manifest = baseManifest(language: .en)
        manifest.transcriptRevisions = [source, translation]
        manifest.humanReviewState = HumanReviewState(
            sourceReviewEnabled: true,
            translationReviewEnabled: true,
            fillerAnalysisBeforeReview: true,
            activeRevisionIDs: ["en": source.id, "ru": translation.id],
            draftRevisionIDs: [:],
            pendingCheckpoint: nil
        )
        let older = output(kind: "localized-transcript", path: "/tmp/transcript.ru.txt", date: 10)
        let newer = output(kind: "subtitled-video-ru", path: "/tmp/subtitled.ru.mp4", date: 20)
        let state = service.make(
            projectURL: URL(fileURLWithPath: "/tmp/English project", isDirectory: true),
            manifest: manifest,
            topicsDetail: "Не созданы",
            topicsAreViewable: false,
            discoveredOutputs: [older, newer]
        )
        try expect(state.artifact(.translation).readiness == .ready, "Утверждённый EN→RU перевод не показан готовым")
        try expect(state.artifact(.translation).detail == "Русский", "Неверная подпись EN→RU")
        try expect(state.recentResults.map(\.path) == [newer.path, older.path], "Последние результаты не взяты из existing discovery в порядке даты")

        manifest.humanReviewState?.pendingCheckpoint = HumanReviewCheckpoint(
            kind: .translatedTranscript,
            language: .ru,
            revisionID: translation.id,
            pendingOperations: [],
            createdAt: Date()
        )
        let pendingTranslation = service.make(
            projectURL: URL(fileURLWithPath: "/tmp/English project", isDirectory: true),
            manifest: manifest,
            topicsDetail: "Не созданы",
            topicsAreViewable: false,
            discoveredOutputs: [older]
        )
        try expect(pendingTranslation.artifact(.translation).readiness == .needsReview, "Pending Translation Review показан как готовый")
        try expect(pendingTranslation.artifact(.translation).openOutputPath == nil, "Pending перевод ошибочно доступен для открытия")
    }

    private static func baseManifest(language: ArtifactLanguage) -> ProjectManifest {
        ProjectManifest(
            appName: "videotext",
            appVersion: "0.6.8",
            build: "test",
            createdAt: Date(),
            updatedAt: Date(),
            sourceMediaPath: "/tmp/source.mp4",
            projectFolderPath: "/tmp/project",
            durationSeconds: 42,
            outputs: [],
            diagnostics: nil,
            languageProfile: LanguageProfile(
                detected: language == .ru ? .ru : .en,
                effective: language,
                confidence: 1,
                method: "test",
                model: nil,
                modelVersion: nil,
                sampleRanges: [],
                manuallyOverridden: false,
                detectedAt: Date()
            )
        )
    }

    private static func sourceRevision(language: ArtifactLanguage, status: TranscriptReviewStatus) -> TranscriptRevision {
        TranscriptRevision(
            id: "source-\(language.rawValue)",
            language: language,
            origin: .machineGenerated,
            parentRevisionID: nil,
            transcriptArtifactID: "artifact-source",
            subtitleArtifactID: "artifact-source-srt",
            contentHash: "source",
            createdAt: Date(),
            reviewStatus: status
        )
    }

    private static func topicRevision(status: TopicRevisionStatus) -> TopicRevision {
        TopicRevision(
            id: "topics-ru-normal",
            language: .ru,
            granularity: .normal,
            parentRevisionID: nil,
            jsonPath: "/tmp/topics.json",
            textPath: "/tmp/topics.txt",
            contentHash: "topics",
            status: status,
            createdAt: Date()
        )
    }

    private static func output(kind: String, path: String = "/tmp/result", date: TimeInterval = 0) -> ProjectOutput {
        ProjectOutput(id: path, kind: kind, path: path, createdAt: Date(timeIntervalSince1970: date))
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
