import Foundation

@main
struct SimpleProjectHomeProbe {
    static func main() throws {
        try verifiesPresentationModes()
        try verifiesSimpleNavigationContract()
        try verifiesApprovedAndPendingStates()
        try verifiesUserFacingResultResolution()
        try verifiesReadableTextDoesNotFallBackToSupportFiles()
        try verifiesSelectedTopicVariantUsesItsOwnTXT()
        print("SIMPLE_PROJECT_HOME_PROBE_PASS")
    }

    private static func verifiesSimpleNavigationContract() throws {
        try expect(!SimpleProjectNavigationAction.openKnownProjects.usesSystemPicker, "Открытие известных проектов не должно вызывать Finder")
        try expect(SimpleProjectNavigationAction.createFromMedia.usesSystemPicker, "Новый проект должен сохранять выбор медиа")
        try expect(SimpleProjectNavigationAction.locateProjectOnDisk.usesSystemPicker, "Ручной поиск проекта должен сохранять выбор папки")
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
            discoveredOutputs: []
        )
        let mode = ProjectPresentationMode.advanced
        try expect(mode == .advanced && state.projectName == "project", "Переключение presentation mode не должно менять snapshot проекта")
    }

    private static func verifiesApprovedAndPendingStates() throws {
        let service = SimpleProjectHomeStateService()
        let projectURL = try makeProject("approved")
        defer { removeProject(projectURL) }
        let layout = ProjectLayout(root: projectURL)
        try writeText("Исходная расшифровка", to: layout.transcriptURL)
        try writeText("Темы", to: layout.topicsTextURL(language: .ru, granularity: .normal))
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
            projectURL: projectURL,
            manifest: manifest,
            topicsDetail: "тем: 7",
            discoveredOutputs: [
                output(kind: "transcript", path: layout.transcriptURL.path),
                output(kind: "topics-text", path: layout.topicsTextURL(language: .ru, granularity: .normal).path)
            ]
        )
        try expect(ready.artifact(.transcription).readiness == .ready, "Утверждённая source-ревизия не показана готовой")
        try expect(ready.artifact(.transcription).detail == "Русский", "Неверная подпись RU source")
        try expect(ready.artifact(.topics).readiness == .ready, "Утверждённые темы не показаны готовыми")
        try expect(ready.artifact(.topics).detail == "тем: 7", "Home не использует существующий summary тем")
        try expect(
            ready.artifact(.topics).openOutputPath == layout.topicsTextURL(language: .ru, granularity: .normal).path,
            "Темы должны открывать выбранный topics TXT, а не JSON"
        )

        try FileManager.default.removeItem(at: layout.transcriptURL)
        let unavailableTranscript = service.make(
            projectURL: projectURL,
            manifest: manifest,
            topicsDetail: "тем: 7",
            discoveredOutputs: [output(kind: "full-srt", path: layout.fullSRTURL.path)]
        )
        try expect(unavailableTranscript.artifact(.transcription).readiness == .missing, "SRT не должен подменять недоступный transcript.txt")

        manifest.humanReviewState?.pendingCheckpoint = HumanReviewCheckpoint(
            kind: .sourceTranscript,
            language: .ru,
            revisionID: source.id,
            pendingOperations: [],
            createdAt: Date()
        )
        let pendingSource = service.make(
            projectURL: projectURL,
            manifest: manifest,
            topicsDetail: "тем: 7",
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
            projectURL: projectURL,
            manifest: manifest,
            topicsDetail: "тем: 7",
            discoveredOutputs: []
        )
        try expect(pendingTopics.artifact(.topics).readiness == .needsReview, "Pending Topic Review показан как готовый")
        try expect(pendingTopics.artifact(.topics).reviewTarget == nil, "Simple mode не должен открывать Topic Review без выбора checkpoint-варианта")

        var failedManifest = baseManifest(language: .ru)
        failedManifest.workflow = ProjectWorkflowState(
            status: .failed,
            progress: 0.4,
            mode: .resumeProject,
            operations: [
                WorkflowOperation.translateTranscript.rawValue: ProjectOperationRecord(
                    status: .failed,
                    startedAt: Date(),
                    finishedAt: Date(),
                    inputSignature: nil,
                    outputPaths: [],
                    errorMessage: "test"
                )
            ],
            lastError: "test"
        )
        let failed = service.make(
            projectURL: projectURL,
            manifest: failedManifest,
            topicsDetail: nil,
            discoveredOutputs: []
        )
        try expect(failed.artifact(.translation).readiness == .failed, "Failed перевод должен быть показан как ошибка")
    }

    private static func verifiesUserFacingResultResolution() throws {
        let service = SimpleProjectHomeStateService()
        let projectURL = try makeProject("user-facing")
        defer { removeProject(projectURL) }
        let layout = ProjectLayout(root: projectURL)
        try writeText("Source transcript", to: layout.transcriptURL)
        try writeText("Translated transcript", to: layout.transcriptURL(language: .ru))
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
        let transcript = output(kind: "transcript", path: layout.transcriptURL.path, date: 30)
        let translatedText = output(kind: "localized-transcript", path: layout.transcriptURL(language: .ru).path, date: 10)
        let mediaURL = projectURL.appendingPathComponent("Video/subtitled.ru.mp4")
        try writeText("media", to: mediaURL)
        let newer = output(kind: "subtitled-video-ru", path: mediaURL.path, date: 20)
        let internalJSON = output(kind: "project-file", path: "/tmp/whisper.json", date: 40)
        let supportSRT = output(kind: "full-srt", path: layout.fullSRTURL.path, date: 50)
        let state = service.make(
            projectURL: projectURL,
            manifest: manifest,
            topicsDetail: "Не созданы",
            discoveredOutputs: [transcript, translatedText, newer, internalJSON, supportSRT]
        )
        try expect(state.artifact(.translation).readiness == .ready, "Утверждённый EN→RU перевод не показан готовым")
        try expect(state.artifact(.translation).detail == "Русский", "Неверная подпись EN→RU")
        try expect(state.artifact(.translation).displayTitle == "Перевод RU", "Перевод должен явно показывать целевой язык")
        try expect(state.artifact(.transcription).openOutputPath == layout.transcriptURL.path, "Расшифровка должна открывать transcript.txt")
        try expect(state.artifact(.translation).openOutputPath == layout.transcriptURL(language: .ru).path, "Перевод должен открывать approved translated TXT")
        try expect(
            Set(state.recentResults.map(\.path)) == Set([transcript.path, newer.path, translatedText.path]),
            "Recent results должны содержать только читаемые тексты и медиа"
        )
        try expect(!state.recentResults.contains(where: { $0.path == internalJSON.path || $0.path == supportSRT.path }), "Internal JSON/SRT не должны попадать в Simple recent results")

        manifest.humanReviewState?.pendingCheckpoint = HumanReviewCheckpoint(
            kind: .translatedTranscript,
            language: .ru,
            revisionID: translation.id,
            pendingOperations: [],
            createdAt: Date()
        )
        let pendingTranslation = service.make(
            projectURL: projectURL,
            manifest: manifest,
            topicsDetail: "Не созданы",
            discoveredOutputs: [translatedText]
        )
        try expect(pendingTranslation.artifact(.translation).readiness == .needsReview, "Pending Translation Review показан как готовый")
        try expect(pendingTranslation.artifact(.translation).openOutputPath == nil, "Pending перевод ошибочно доступен для открытия")
    }

    private static func verifiesReadableTextDoesNotFallBackToSupportFiles() throws {
        let service = SimpleProjectHomeStateService()
        let projectURL = try makeProject("strict")
        defer { removeProject(projectURL) }
        let layout = ProjectLayout(root: projectURL)
        let source = sourceRevision(language: .ru, status: .approved)
        let translation = TranscriptRevision(
            id: "translation-en",
            language: .en,
            origin: .translated,
            parentRevisionID: source.id,
            transcriptArtifactID: "artifact-translation-en",
            subtitleArtifactID: "artifact-subtitles-en",
            contentHash: "translation",
            createdAt: Date(),
            reviewStatus: .approved
        )
        let topic = topicRevision(status: .approved)
        var manifest = baseManifest(language: .ru)
        manifest.transcriptRevisions = [source, translation]
        manifest.humanReviewState = HumanReviewState(
            sourceReviewEnabled: true,
            translationReviewEnabled: true,
            fillerAnalysisBeforeReview: true,
            activeRevisionIDs: ["ru": source.id, "en": translation.id],
            draftRevisionIDs: [:],
            pendingCheckpoint: nil
        )
        manifest.topicRevisions = [topic]
        manifest.topicReviewState = TopicReviewState(
            enabled: true,
            activeRevisionIDs: [topic.variantKey: topic.id],
            pendingCheckpoint: nil
        )

        let strict = service.make(
            projectURL: projectURL,
            manifest: manifest,
            topicsDetail: "тем: 3",
            discoveredOutputs: [
                output(kind: "full-srt", path: layout.fullSRTURL.path),
                output(kind: "localized-subtitles", path: layout.subtitlesURL(language: .en).path),
                output(kind: "topics", path: layout.topicsURL.path)
            ]
        )
        try expect(strict.artifact(.transcription).readiness == .missing, "SRT не может быть fallback для transcript TXT")
        try expect(strict.artifact(.topics).readiness == .missing, "topics.json не может быть fallback для topics TXT")
        try expect(strict.artifact(.translation).readiness == .missing, "translated SRT не может быть fallback для translated TXT")
        try expect(strict.recentResults.isEmpty, "Support-only outputs не могут стать Simple recent results")
    }

    private static func verifiesSelectedTopicVariantUsesItsOwnTXT() throws {
        let service = SimpleProjectHomeStateService()
        let projectURL = try makeProject("topic-variant")
        defer { removeProject(projectURL) }
        let layout = ProjectLayout(root: projectURL)
        let source = sourceRevision(language: .en, status: .approved)
        let translatedCoarse = TopicRevision(
            id: "topics-ru-coarse",
            language: .ru,
            granularity: .coarse,
            parentRevisionID: nil,
            jsonPath: layout.topicsURL(language: .ru, granularity: .coarse).path,
            textPath: layout.topicsTextURL(language: .ru, granularity: .coarse).path,
            contentHash: "topics-ru-coarse",
            status: .approved,
            createdAt: Date()
        )
        try writeText("Темы на русском", to: layout.topicsTextURL(language: .ru, granularity: .coarse))
        var manifest = baseManifest(language: .en)
        manifest.transcriptRevisions = [source]
        manifest.humanReviewState = HumanReviewState(
            sourceReviewEnabled: true,
            translationReviewEnabled: false,
            fillerAnalysisBeforeReview: true,
            activeRevisionIDs: ["en": source.id],
            draftRevisionIDs: [:],
            pendingCheckpoint: nil
        )
        manifest.topicRevisions = [translatedCoarse]
        manifest.topicReviewState = TopicReviewState(
            enabled: true,
            activeRevisionIDs: [translatedCoarse.variantKey: translatedCoarse.id],
            pendingCheckpoint: nil
        )

        let state = service.make(
            projectURL: projectURL,
            manifest: manifest,
            topicsDetail: "тем: 2",
            discoveredOutputs: [],
            topicLanguage: .ru,
            topicGranularity: .coarse
        )
        let topics = state.artifact(.topics)
        try expect(topics.readiness == .ready, "Selected translated/coarse topics variant не показан готовым")
        try expect(topics.openOutputPath == layout.topicsTextURL(language: .ru, granularity: .coarse).path, "Selected topic variant должен открыть свой TXT")
        try expect(topics.displayTitle == "Темы RU · Крупный", "Simple mode должен явно называть выбранный variant тем")
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

    private static func makeProject(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("videotext-simple-home-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func removeProject(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
