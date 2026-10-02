import Foundation

enum TopicProbeError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

final class FakeTopicAIProvider: TopicAIProvider {
    let embeddingModel = "fake-embedding"
    let primaryLanguageModel = "fake-primary"
    let fallbackLanguageModel = "fake-fallback"
    var embeddingCalls = 0
    var boundaryCalls = 0
    var descriptionCalls = 0
    var responseDelay: UInt64 = 0
    var failPrimary = false
    var shortTitles = false
    var duplicateTitles = false
    var permanentlyInvalidDescriptions = false
    var keepAllBoundaries = false
    var descriptionModels: [String] = []

    func availableLanguageModels() async throws -> [String] {
        [primaryLanguageModel, fallbackLanguageModel]
    }

    func embeddings(for texts: [String]) async throws -> [[Double]] {
        embeddingCalls += 1
        return texts.map { text in
            text.contains("звёзд") ? [1, 0, 0] : [0, 1, 0]
        }
    }

    func reviewBoundaries(
        _ request: TopicBoundaryReviewRequest,
        model: String,
        correction: String?
    ) async throws -> TopicBoundaryReview {
        boundaryCalls += 1
        if responseDelay > 0 { try await Task.sleep(nanoseconds: responseDelay) }
        if failPrimary, model == primaryLanguageModel {
            return TopicBoundaryReview(decisions: [])
        }
        return TopicBoundaryReview(decisions: request.focusAfterCueIds.map { cueID in
            TopicBoundaryDecision(
                afterCueId: cueID,
                keep: keepAllBoundaries || cueID == 12,
                confidence: cueID == 12 ? 0.96 : 0.88,
                reason: cueID == 12 ? "Начинается самостоятельная тема приготовления супа." : "Продолжается прежняя тема."
            )
        })
    }

    func describeTopics(
        _ request: TopicDescriptionRequest,
        model: String,
        correction: String?
    ) async throws -> TopicReviewResponse {
        descriptionCalls += 1
        descriptionModels.append(model)
        if responseDelay > 0 { try await Task.sleep(nanoseconds: responseDelay) }
        if failPrimary, model == primaryLanguageModel {
            return TopicReviewResponse(topics: [])
        }
        return TopicReviewResponse(topics: request.blocks.map { block in
            let astronomy = block.cues.contains { $0.text.contains("звёзд") }
            return TopicReviewItem(
                title: duplicateTitles
                    ? "Обсуждение нового раздела семинара"
                    : (shortTitles
                        ? (astronomy ? "Наблюдение звёзд" : "Приготовление супа")
                        : (astronomy ? "Наблюдение далёких звёзд телескопом" : "Приготовление овощного супа дома")),
                summary: astronomy
                    ? "Астрономы обсуждают наблюдение звёзд и настройку телескопа."
                    : "Обсуждается приготовление овощного супа и выбор ингредиентов.",
                keywords: permanentlyInvalidDescriptions
                    ? []
                    : (astronomy ? ["звёзды", "телескоп", "астрономия"] : ["суп", "овощи", "рецепт"]),
                startCueId: block.startCueId,
                endCueId: block.endCueId,
                confidence: astronomy ? 0.94 : 0.91,
                boundaryReason: astronomy ? "Начинается раздел наблюдения звёзд." : "Разговор переходит к приготовлению супа."
            )
        })
    }

    var aiCalls: Int {
        boundaryCalls + descriptionCalls
    }
}

@main
struct TopicAnalysisProbe {
    static func main() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("videotext-topic-probe-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try validatePreprocessing()
            try await validateShortTitleRepair(parent: root)
            try await validateDuplicateTitleRepair(parent: root)
            try await validateInvalidDescriptionsFail(parent: root)
            try await validateAllGranularitiesComplete(parent: root)
            let cues = syntheticCues()
            let sourceSRT = root.appendingPathComponent("source.srt")
            try SRTService().write(cues, to: sourceSRT)
            let provider = FakeTopicAIProvider()
            let adapter = HybridTopicAdapter(provider: provider)
            let context = TopicBuildContext(projectURL: root, mediaDuration: 720, granularity: .normal)
            var progress: [Double] = []
            let file = try await adapter.buildTopics(
                from: cues,
                sourceSRT: sourceSRT,
                context: context,
                onProgress: { progress.append($0) },
                onLog: { print($0) }
            )
            try require(file.status == .ready, "гибридный результат не получил статус ready")
            try require(file.topics.count == 2, "ожидалось две смысловые темы, получено \(file.topics.count)")
            try require(file.topics[0].title.contains("звёзд"), "первая тема названа неверно")
            try require(file.topics[1].title.contains("супа"), "вторая тема названа неверно")
            try require(Set(file.topics.flatMap(\.cueIds)) == Set(cues.map(\.id)), "часть SRT потеряна")
            try require(progress.last == 1, "прогресс тематического анализа не достиг 100%")
            try validateAlgorithmCompatibility(file: file, sourceSRT: sourceSRT)

            let embeddingCalls = provider.embeddingCalls
            let aiCalls = provider.aiCalls
            _ = try await adapter.buildTopics(
                from: cues,
                sourceSRT: sourceSRT,
                context: context,
                onProgress: { _ in },
                onLog: { _ in }
            )
            try require(provider.embeddingCalls == embeddingCalls, "embeddings не восстановлены из кэша")
            try require(provider.aiCalls == aiCalls, "решения LLM не восстановлены из кэша")

            try validateStrictFailure(file: file, cues: cues)
            try await validateCancellationResume(cues: cues, sourceSRT: sourceSRT, parent: root)
            try validateBrokenModelJSON()
            try validateUnknownCueAndTemporalJSON(cues: cues)
            try await validateFallback(cues: cues, sourceSRT: sourceSRT, parent: root)
            try validateTopicEditing(file: file, cues: cues, parent: root)
            print("TOPIC PROBE PASS: подготовка, границы, JSON, кэш, остановка и редактор проверены")
        } catch {
            fputs("TOPIC PROBE FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func syntheticCues() -> [SubtitleCue] {
        (0..<24).map { index in
            let start = Double(index) * 30
            let astronomy = index < 12
            let text = astronomy
                ? "Исследователи обсуждают наблюдение далёких звёзд и настройку телескопа."
                : "Повар объясняет приготовление овощного супа и выбор свежих ингредиентов."
            return SubtitleCue(id: index + 1, start: start, end: start + 28, text: text)
        }
    }

    private static func validatePreprocessing() throws {
        let cues = [
            SubtitleCue(id: 1, start: 0, end: 2, text: "Мы обсуждаем"),
            SubtitleCue(id: 2, start: 0.2, end: 3, text: "Мы обсуждаем новый проект"),
            SubtitleCue(id: 3, start: 3.1, end: 5, text: "Следующая законченная мысль."),
            SubtitleCue(id: 4, start: 5, end: 5, text: "Служебная реплика")
        ]
        let paragraphs = TopicTextPreprocessor().prepare(cues)
        try require(Set(paragraphs.flatMap(\.cueIDs)) == Set([1, 2, 3]), "не сохранена связь после удаления прогрессивного повтора")
        try require(paragraphs.map(\.text).joined(separator: " ").contains("новый проект"), "потеряна полная прогрессивная реплика")
    }

    private static func validateShortTitleRepair(parent: URL) async throws {
        let provider = FakeTopicAIProvider()
        provider.shortTitles = true
        let cues = syntheticCues()
        let root = parent.appendingPathComponent("short-title-repair", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceSRT = root.appendingPathComponent("source.srt")
        try SRTService().write(cues, to: sourceSRT)
        let file = try await HybridTopicAdapter(provider: provider).buildTopics(
            from: cues,
            sourceSRT: sourceSRT,
            context: TopicBuildContext(projectURL: root, mediaDuration: 720, granularity: .normal),
            onProgress: { _ in },
            onLog: { _ in }
        )
        try require(file.topics.allSatisfy {
            (3...8).contains($0.title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count)
        }, "короткое название LLM не исправлено детерминированно")
        try require(file.topics[0].title.contains("звёзд"), "исправление потеряло смысл первого названия")
        try require(file.topics[1].title.contains("суп"), "исправление потеряло смысл второго названия")
    }

    private static func validateDuplicateTitleRepair(parent: URL) async throws {
        let provider = FakeTopicAIProvider()
        provider.duplicateTitles = true
        let cues = syntheticCues()
        let root = parent.appendingPathComponent("duplicate-title-repair", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceSRT = root.appendingPathComponent("source.srt")
        try SRTService().write(cues, to: sourceSRT)
        let file = try await HybridTopicAdapter(provider: provider).buildTopics(
            from: cues,
            sourceSRT: sourceSRT,
            context: TopicBuildContext(projectURL: root, mediaDuration: 720, granularity: .normal),
            onProgress: { _ in },
            onLog: { _ in }
        )
        try require(file.topics.count == 2, "ремонт названий изменил количество тем")
        try require(file.topics[0].title != file.topics[1].title, "повторное название не исправлено детерминированно")
        try require(file.topics[1].title.contains("суп"), "исправленное название потеряло различимый термин")
    }

    private static func validateInvalidDescriptionsFail(parent: URL) async throws {
        let provider = FakeTopicAIProvider()
        provider.duplicateTitles = true
        provider.permanentlyInvalidDescriptions = true
        provider.keepAllBoundaries = true
        let cues = (0..<13).map { index in
            SubtitleCue(
                id: index + 1,
                start: Double(index) * 600,
                end: Double(index) * 600 + 590,
                text: index.isMultiple(of: 2)
                    ? "Исследование далёких звёзд оптическим телескопом."
                    : "Приготовление овощного супа по домашнему рецепту."
            )
        }
        let root = parent.appendingPathComponent("bounded-coarse-fallback", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceSRT = root.appendingPathComponent("source.srt")
        try SRTService().write(cues, to: sourceSRT)
        let adapter = HybridTopicAdapter(provider: provider)
        do {
            _ = try await adapter.buildTopics(
                from: cues,
                sourceSRT: sourceSRT,
                context: TopicBuildContext(projectURL: root, mediaDuration: 7_790, granularity: .coarse),
                onProgress: { _ in },
                onLog: { _ in }
            )
            throw TopicProbeError.failed("невалидные описания были выданы как готовый тематический результат")
        } catch is WorkflowError {}
        try require(provider.descriptionCalls == 4, "невалидные описания вызвали неверное число запросов: \(provider.descriptionCalls)")
        try require(
            provider.descriptionModels == [
                provider.primaryLanguageModel, provider.primaryLanguageModel,
                provider.fallbackLanguageModel, provider.fallbackLanguageModel
            ],
            "порядок ограниченного fallback между моделями нарушен"
        )
    }

    private static func validateAllGranularitiesComplete(parent: URL) async throws {
        let cues = syntheticCues()
        for granularity in TopicGranularity.allCases {
            let root = parent.appendingPathComponent("granularity-\(granularity.rawValue)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let sourceSRT = root.appendingPathComponent("source.srt")
            try SRTService().write(cues, to: sourceSRT)
            let file = try await HybridTopicAdapter(provider: FakeTopicAIProvider()).buildTopics(
                from: cues,
                sourceSRT: sourceSRT,
                context: TopicBuildContext(projectURL: root, mediaDuration: 720, granularity: granularity),
                onProgress: { _ in },
                onLog: { _ in }
            )
            try require(file.status == .ready, "набор \(granularity.rawValue) не завершился")
            try require(!file.topics.isEmpty, "набор \(granularity.rawValue) не содержит тем")
        }
    }

    private static func validateStrictFailure(file: TopicsFile, cues: [SubtitleCue]) throws {
        var invalid = file
        invalid.topics[1].start = invalid.topics[0].end - 1
        invalid.topics[1].duration = invalid.topics[1].end - invalid.topics[1].start
        let issues = TopicValidator().validate(invalid, expectedCueIDs: Set(cues.map(\.id)), mediaDuration: 720)
        try require(issues.contains(where: { $0.contains("пересекается") }), "валидатор пропустил пересечение тем")
        var wrongTime = file
        wrongTime.topics[0].start += 0.5
        let timeIssues = TopicValidator().validate(wrongTime, expectedCues: cues, mediaDuration: 720)
        try require(timeIssues.contains(where: { $0.contains("не совпадает с исходным SRT") }), "валидатор принял время, придуманное не из SRT")
    }

    private static func validateAlgorithmCompatibility(file: TopicsFile, sourceSRT: URL) throws {
        let signature = StableTopicHash.string(try String(contentsOf: sourceSRT, encoding: .utf8))
        try require(
            TopicAlgorithmIdentity.isCurrent(file, granularity: .normal, sourceSignature: signature),
            "актуальный гибридный результат не распознан"
        )
        var legacy = file
        legacy.schemaVersion = 1
        legacy.algorithmVersion = "legacy"
        legacy.adapter = "KeywordTopicAdapter"
        legacy.status = .draft
        legacy.sourceSignature = ""
        try require(!TopicAlgorithmIdentity.recognizes(legacy), "устаревший KeywordTopicAdapter признан актуальным")
        var legacyDraft = file
        legacyDraft.status = .draft
        try require(!TopicAlgorithmIdentity.recognizes(legacyDraft), "черновой topics.json признан актуальным")
        try require(
            !TopicAlgorithmIdentity.isCurrent(legacy, granularity: .normal, sourceSignature: signature),
            "устаревший topics.json разрешил пропуск пересчёта"
        )
        try require(
            !TopicAlgorithmIdentity.isCurrent(file, granularity: .normal, sourceSignature: "other-srt"),
            "таймкодинг от другого SRT признан актуальным"
        )
    }

    private static func validateCancellationResume(cues: [SubtitleCue], sourceSRT: URL, parent: URL) async throws {
        let root = parent.appendingPathComponent("cancel-resume", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let provider = FakeTopicAIProvider()
        provider.responseDelay = 3_000_000_000
        let adapter = HybridTopicAdapter(provider: provider)
        let context = TopicBuildContext(projectURL: root, mediaDuration: 720, granularity: .normal)
        let task = Task {
            try await adapter.buildTopics(
                from: cues,
                sourceSRT: sourceSRT,
                context: context,
                onProgress: { _ in },
                onLog: { _ in }
            )
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        do {
            _ = try await task.value
            throw TopicProbeError.failed("тематический анализ не остановился")
        } catch is CancellationError {}
        let callsAfterStop = provider.embeddingCalls
        provider.responseDelay = 0
        let resumed = try await adapter.buildTopics(
            from: cues,
            sourceSRT: sourceSRT,
            context: context,
            onProgress: { _ in },
            onLog: { _ in }
        )
        try require(resumed.topics.count == 2, "анализ не продолжился после остановки")
        try require(provider.embeddingCalls == callsAfterStop, "после остановки заново рассчитаны готовые embeddings")
    }

    private static func validateBrokenModelJSON() throws {
        do {
            _ = try TopicLabelDecoder.decode("```json\n{broken}\n```")
            throw TopicProbeError.failed("повреждённый JSON модели ошибочно принят")
        } catch is WorkflowError {}
    }

    private static func validateUnknownCueAndTemporalJSON(cues: [SubtitleCue]) throws {
        let request = TopicBoundaryReviewRequest(
            id: "unknown-cue",
            granularity: .normal,
            cues: cues,
            candidates: [],
            focusAfterCueIds: [12]
        )
        let review = TopicBoundaryReview(decisions: [
            TopicBoundaryDecision(afterCueId: 999, keep: true, confidence: 0.8, reason: "Несуществующая граница")
        ])
        let issues = TopicValidator().boundaryReviewIssues(review, request: request)
        try require(!issues.isEmpty, "валидатор принял неизвестный cueId")

        let temporal = """
        {"topics":[{"title":"Тестовая смысловая тема видео","summary":"Описание.","keywords":["тест","видео"],"startCueId":1,"endCueId":2,"confidence":0.9,"boundaryReason":"Новая тема.","start":0}]}
        """
        do {
            _ = try TopicJSONDecoder.decode(temporal, as: TopicReviewResponse.self)
            throw TopicProbeError.failed("декодер принял временной код от LLM")
        } catch is WorkflowError {}
    }

    private static func validateFallback(cues: [SubtitleCue], sourceSRT: URL, parent: URL) async throws {
        let root = parent.appendingPathComponent("fallback", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let provider = FakeTopicAIProvider()
        provider.failPrimary = true
        let file = try await HybridTopicAdapter(provider: provider).buildTopics(
            from: cues,
            sourceSRT: sourceSRT,
            context: TopicBuildContext(projectURL: root, mediaDuration: 720, granularity: .normal),
            onProgress: { _ in },
            onLog: { _ in }
        )
        try require(file.languageModel?.contains("fake-fallback") == true, "после ошибок основной модели не использована резервная")
    }

    private static func validateTopicEditing(file: TopicsFile, cues: [SubtitleCue], parent: URL) throws {
        let media = parent.appendingPathComponent("source.mp4")
        try Data("test-media".utf8).write(to: media, options: .atomic)
        let project = parent.appendingPathComponent("editing-project", isDirectory: true)
        var manifest = try ProjectStore().ensureProject(at: project, mediaURL: media, mode: .newProject)
        manifest.durationSeconds = 720
        try ProjectStore().save(manifest, to: project)
        let layout = ProjectLayout(root: project)
        try SRTService().write(cues, to: layout.fullSRTURL)
        try TopicFileService().save(file, projectURL: project)

        let movedBoundary = try TopicFileService().update(
            projectURL: project,
            id: file.topics[1].id,
            title: file.topics[1].title,
            start: cues[10].start,
            end: file.topics[1].end
        )
        try require(movedBoundary.topics[0].sourceCueEnd == cues[9].id, "редактор не перенёс границу предыдущей темы")
        try require(movedBoundary.topics[1].sourceCueStart == cues[10].id, "редактор не привязал начало к cueId")
        try require(movedBoundary.topics[1].start == cues[10].start, "редактор сохранил время не из SRT")
        try require(movedBoundary.topics.flatMap(\.cueIds) == cues.map(\.id), "изменение границы потеряло или переставило cueId")

        let split = try TopicFileService().split(projectURL: project, id: file.topics[0].id)
        try require(split.topics.count == 3, "редактор не разделил тему")
        let merged = try TopicFileService().mergeWithNext(projectURL: project, id: split.topics[0].id)
        try require(merged.topics.count == 2, "редактор не объединил темы")
        let removed = try TopicFileService().removeBoundary(projectURL: project, id: merged.topics[1].id)
        try require(removed.topics.count == 1, "редактор не удалил границу темы")
        let topic = removed.topics[0]
        let updated = try TopicFileService().update(
            projectURL: project,
            id: topic.id,
            title: "Полный обзор астрономии и кулинарии",
            start: topic.start,
            end: topic.end
        )
        try require(updated.topics[0].title.contains("Полный обзор"), "редактор не сохранил название")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TopicProbeError.failed(message) }
    }
}
