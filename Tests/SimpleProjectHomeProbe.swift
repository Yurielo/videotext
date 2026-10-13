import Foundation

@main
struct SimpleProjectHomeProbe {
    static func main() throws {
        try verifiesPresentationModes()
        try verifiesSimpleNavigationContract()
        try verifiesApprovedAndPendingStates()
        try verifiesUserFacingResultResolution()
        try verifiesPersistedFragmentsRemainInRecentResults()
        try verifiesReadableTextDoesNotFallBackToSupportFiles()
        try verifiesSelectedTopicVariantUsesItsOwnTXT()
        try verifiesApprovedCorrectionTargetsInBothDirections()
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
        try expect(ready.artifact(.transcription).reviewTarget == .source, "Approved Source должен оставаться доступным для исправления")
        try expect(ready.artifact(.transcription).detail == "Русский", "Неверная подпись RU source")
        try expect(ready.artifact(.topics).readiness == .ready, "Утверждённые темы не показаны готовыми")
        try expect(ready.artifact(.topics).reviewTarget == nil, "Approved Topics correction должен оставаться Advanced-only")
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
        try expect(unavailableTranscript.artifact(.transcription).reviewTarget == nil, "Недоступный Source TXT не должен показывать approved correction")

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
        try expect(state.artifact(.translation).reviewTarget == .translation, "Approved Translation должен оставаться доступным для исправления")
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
        try expect(pendingTranslation.artifact(.translation).reviewTarget == .translation, "Pending Translation потерял correction target")
        try expect(pendingTranslation.artifact(.translation).openOutputPath == nil, "Pending перевод ошибочно доступен для открытия")
    }

    private static func verifiesPersistedFragmentsRemainInRecentResults() throws {
        let service = SimpleProjectHomeStateService()
        let projectURL = try makeProject("persisted-fragments")
        defer { removeProject(projectURL) }
        let layout = ProjectLayout(root: projectURL)
        let topicVideo = layout.fragmentVideoURL(kind: "topic-approved")
        let topicSubtitled = layout.fragmentSubtitledVideoURL(kind: "topic-approved")
        let rangeVideo = layout.fragmentVideoURL(kind: "range")
        let sourceSubtitled = layout.subtitledVideoURL
        let translatedSubtitled = layout.subtitledVideoURL(language: .en)
        for url in [topicVideo, topicSubtitled, rangeVideo, sourceSubtitled, translatedSubtitled] {
            try writeText("media", to: url)
        }

        let topicFragment = FragmentRecord(
            id: "topic-approved", name: "Введение", start: 0, end: 20,
            createdAt: Date(timeIntervalSince1970: 40), videoPath: topicVideo.path,
            subtitlePath: layout.fragmentSRTURL(kind: "topic-approved").path,
            subtitledVideoPath: topicSubtitled.path, ffprobeReportPath: nil,
            style: .standard, language: .ru, topicGranularity: .normal, topicID: "topic-1"
        )
        let rangeFragment = FragmentRecord(
            id: "range", name: "Диапазон", start: 20, end: 30,
            createdAt: Date(timeIntervalSince1970: 30), videoPath: rangeVideo.path,
            subtitlePath: layout.fragmentSRTURL(kind: "range").path,
            subtitledVideoPath: nil, ffprobeReportPath: nil, style: .standard
        )
        var manifest = baseManifest(language: .ru)
        let approvedTopic = TopicSegment(
            id: "topic-1", title: "Переименованная тема", start: 0, end: 20,
            summary: "", keywords: [], sourceCueStart: 0, sourceCueEnd: 0, cueIds: []
        )
        let approvedFile = TopicsFile(
            adapter: "probe", createdAt: Date(timeIntervalSince1970: 1), sourceSRT: "full.srt",
            topics: [approvedTopic]
        )
        let approvedID = "approved-topic-fragments"
        let approvedURL = layout.topicRevisionJSONURL(id: approvedID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let approvedData = try encoder.encode(approvedFile)
        try FileManager.default.createDirectory(at: approvedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try approvedData.write(to: approvedURL, options: .atomic)
        let approvedRevision = TopicRevision(
            id: approvedID, language: .ru, granularity: .normal, parentRevisionID: nil,
            jsonPath: approvedURL.path, textPath: layout.topicRevisionTextURL(id: approvedID).path,
            contentHash: "approved-fixture",
            status: .approved, createdAt: Date(timeIntervalSince1970: 1)
        )
        manifest.topicRevisions = [approvedRevision]
        manifest.topicReviewState = TopicReviewState(
            enabled: true, activeRevisionIDs: [approvedRevision.variantKey: approvedID], pendingCheckpoint: nil
        )
        manifest.fragments = [topicFragment, rangeFragment]
        let outputs = [
            output(kind: "fragment-video", path: topicVideo.path, date: 40),
            output(kind: "fragment-subtitled-video-ru", path: topicSubtitled.path, date: 40),
            output(kind: "fragment-video", path: rangeVideo.path, date: 30),
            output(kind: "subtitled-video", path: sourceSubtitled.path, date: 20),
            output(kind: "subtitled-video-en", path: translatedSubtitled.path, date: 10),
            output(kind: "fragment-video", path: projectURL.appendingPathComponent("cancelled.mp4").path, date: 50)
        ]

        let immediate = service.make(projectURL: projectURL, manifest: manifest, topicsDetail: nil, discoveredOutputs: outputs)
        let topicEntries = immediate.recentResults.filter { $0.path == topicSubtitled.path || $0.path == topicVideo.path }
        try expect(topicEntries.count == 1, "Один topic fragment не должен дублироваться source/subtitled файлами")
        try expect(topicEntries.first?.path == topicSubtitled.path, "Recent results должен открывать завершённый topic fragment")
        try expect(topicEntries.first?.title == "Введение · 00:00:00.000–00:00:20.000", "Topic fragment должен сохранить title, записанный при создании, а не новое active название")
        try expect(immediate.recentResults.first(where: { $0.path == rangeVideo.path })?.title == "Фрагмент · 00:00:20.000–00:00:30.000", "Range fragment не получил различимый label из stored range")
        try expect(immediate.recentResults.contains(where: { $0.path == rangeVideo.path }), "Фрагмент по времени исчез из recent results")
        try expect(immediate.recentResults.contains(where: { $0.path == sourceSubtitled.path }), "Source subtitled video исчез из recent results")
        try expect(immediate.recentResults.contains(where: { $0.path == translatedSubtitled.path }), "Translated subtitled video исчез из recent results")
        try expect(!immediate.recentResults.contains(where: { $0.path.hasSuffix("cancelled.mp4") }), "Отменённый или несуществующий fragment показан готовым")

        // Reopen must derive the same user-facing fragment from persisted manifest
        // state even when a fresh result scan does not return a fragment output.
        let reopened = service.make(
            projectURL: projectURL,
            manifest: manifest,
            topicsDetail: nil,
            discoveredOutputs: [
                output(kind: "subtitled-video-en", path: translatedSubtitled.path, date: 10),
                output(kind: "subtitled-video", path: sourceSubtitled.path, date: 20)
            ]
        )
        try expect(reopened.recentResults.contains(where: { $0.path == topicSubtitled.path }), "Persisted topic fragment исчез после reopen")
        try expect(reopened.recentResults.filter { $0.path == topicSubtitled.path }.count == 1, "Topic fragment продублировался после reopen")
        try expect(reopened.recentResults.contains(where: { $0.path == rangeVideo.path }), "Range fragment исчез после reopen")
        try expect(reopened.recentResults.first(where: { $0.path == topicSubtitled.path })?.title == "Введение · 00:00:00.000–00:00:20.000", "Topic label изменился после reopen или Topic Review edit")

        // Distinct persisted artifacts with an otherwise identical label receive
        // only a stable creation-time suffix; their Open paths stay independent.
        let duplicateVideo = layout.fragmentVideoURL(kind: "same-range")
        try writeText("second media", to: duplicateVideo)
        var sameRange = rangeFragment
        sameRange.id = "same-range"
        sameRange.videoPath = duplicateVideo.path
        sameRange.createdAt = Date(timeIntervalSince1970: 31)
        manifest.fragments = [rangeFragment, sameRange]
        let sameLabelState = service.make(projectURL: projectURL, manifest: manifest, topicsDetail: nil, discoveredOutputs: [])
        let sameRangeResults = sameLabelState.recentResults.filter { $0.path == rangeVideo.path || $0.path == duplicateVideo.path }
        try expect(sameRangeResults.count == 2 && Set(sameRangeResults.map(\.title)).count == 2,
                   "Different FragmentRecord с одинаковым диапазоном должны иметь различимые labels")
        try expect(Set(sameRangeResults.map(\.path)) == Set([rangeVideo.path, duplicateVideo.path]),
                   "Distinct fragment labels изменили Open mapping")
        let reopenedSameLabelState = service.make(
            projectURL: projectURL,
            manifest: manifest,
            topicsDetail: nil,
            discoveredOutputs: []
        )
        let reopenedSameRangeResults = reopenedSameLabelState.recentResults.filter {
            $0.path == rangeVideo.path || $0.path == duplicateVideo.path
        }
        try expect(reopenedSameRangeResults.count == 2
            && Set(reopenedSameRangeResults.map(\.title)) == Set(sameRangeResults.map(\.title)),
                   "Creation-time suffix для одинаковых fragment labels изменился после reopen")
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

    private static func verifiesApprovedCorrectionTargetsInBothDirections() throws {
        for language in ArtifactLanguage.allCases {
            let project = try makeProject("approved-correction-\(language.rawValue)")
            defer { removeProject(project) }
            let layout = ProjectLayout(root: project)
            let source = sourceRevision(language: language, status: .approved)
            let target = language.translationTarget
            let translated = TranscriptRevision(
                id: "approved-translation-\(target.rawValue)", language: target, origin: .userEdited,
                parentRevisionID: source.id, transcriptArtifactID: "translated-txt",
                subtitleArtifactID: "translated-srt", contentHash: "translated",
                createdAt: Date(), reviewStatus: .approved
            )
            var manifest = baseManifest(language: language)
            manifest.transcriptRevisions = [source, translated]
            manifest.humanReviewState = HumanReviewState(
                sourceReviewEnabled: true, translationReviewEnabled: true,
                activeRevisionIDs: [language.rawValue: source.id, target.rawValue: translated.id],
                draftRevisionIDs: [:], pendingCheckpoint: nil
            )
            try writeText("Approved source", to: layout.transcriptURL)
            try writeText("Approved translation", to: layout.transcriptURL(language: target))
            let state = SimpleProjectHomeStateService().make(
                projectURL: project, manifest: manifest, topicsDetail: nil, discoveredOutputs: []
            )
            try expect(state.artifact(.transcription).reviewTarget == .source, "\(language.rawValue) approved Source не имеет correction target")
            try expect(state.artifact(.translation).reviewTarget == .translation, "\(target.rawValue) approved Translation не имеет correction target")
            try expect(state.artifact(.translation).language == target, "Correction target потерял язык перевода")
            try expect(state.artifact(.topics).reviewTarget == nil, "Topics correction появился в Simple")
        }
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
