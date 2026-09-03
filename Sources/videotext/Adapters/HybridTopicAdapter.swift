import Foundation

struct TopicParagraph: Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var cueIDs: [Int]
}

struct TopicPreparationResult {
    var paragraphs: [TopicParagraph]
    var excludedZeroDuration: Int
    var excludedServiceText: Int
    var mergedProgressiveCues: Int
}

struct TopicLabel: Codable, Equatable {
    var title: String
    var summary: String
    var keywords: [String]
    var confidence: Double
    var boundaryReason: String
}

struct TopicBoundaryCandidate: Codable, Equatable {
    var afterCueId: Int
    var semanticChange: Double
    var lexicalChange: Double
    var pauseSeconds: Double
    var score: Double
}

struct TopicBoundaryDecision: Codable, Equatable {
    var afterCueId: Int
    var keep: Bool
    var confidence: Double
    var reason: String
}

struct TopicBoundaryReview: Codable, Equatable {
    var decisions: [TopicBoundaryDecision]
}

struct TopicReviewItem: Codable, Equatable {
    var title: String
    var summary: String
    var keywords: [String]
    var startCueId: Int
    var endCueId: Int
    var confidence: Double
    var boundaryReason: String
}

struct TopicReviewResponse: Codable, Equatable {
    var topics: [TopicReviewItem]
}

struct TopicBoundaryReviewRequest {
    var id: String
    var granularity: TopicGranularity
    var cues: [SubtitleCue]
    var candidates: [TopicBoundaryCandidate]
    var focusAfterCueIds: [Int]
    var language: ArtifactLanguage = .ru

    var cacheText: String {
        let cueText = cues.map { "[\($0.id)]\($0.text)" }.joined(separator: "|")
        let candidateText = candidates.map { "\($0.afterCueId):\($0.score)" }.joined(separator: ",")
        return "\(HybridTopicAdapter.algorithmVersion)|\(granularity.rawValue)|\(focusAfterCueIds)|\(candidateText)|\(cueText)"
    }
}

struct TopicDescriptionBlock {
    var startCueId: Int
    var endCueId: Int
    var cues: [SubtitleCue]
}

struct TopicDescriptionRequest {
    var id: String
    var granularity: TopicGranularity
    var blocks: [TopicDescriptionBlock]
    var previousTitles: [String]
    var language: ArtifactLanguage = .ru
}

protocol TopicAIProvider {
    var embeddingModel: String { get }
    var primaryLanguageModel: String { get }
    var fallbackLanguageModel: String { get }
    func availableLanguageModels() async throws -> [String]
    func embeddings(for texts: [String]) async throws -> [[Double]]
    func reviewBoundaries(
        _ request: TopicBoundaryReviewRequest,
        model: String,
        correction: String?
    ) async throws -> TopicBoundaryReview
    func describeTopics(
        _ request: TopicDescriptionRequest,
        model: String,
        correction: String?
    ) async throws -> TopicReviewResponse
}

struct HybridTopicAdapter: TopicAdapter {
    static let algorithmVersion = TopicAlgorithmIdentity.hybridVersion
    let name = TopicAlgorithmIdentity.hybridAdapter
    private let provider: TopicAIProvider
    private let preprocessor = TopicTextPreprocessor()
    private let detector = TopicBoundaryDetector()
    private let validator = TopicValidator()

    init(provider: TopicAIProvider = OllamaTopicProvider()) {
        self.provider = provider
    }

    func buildTopics(
        from cues: [SubtitleCue],
        sourceSRT: URL,
        context: TopicBuildContext,
        onProgress: @escaping (Double) -> Void,
        onLog: @escaping (String) -> Void
    ) async throws -> TopicsFile {
        try Task.checkCancellation()
        let preparation = preprocessor.prepareWithReport(cues)
        let paragraphs = preparation.paragraphs
        guard !paragraphs.isEmpty else {
            throw WorkflowError.invalidTopics("после подготовки не осталось содержательных реплик.")
        }
        let meaningfulCueIDs = Set(paragraphs.flatMap(\.cueIDs))
        let analysisCues = cues
            .filter { meaningfulCueIDs.contains($0.id) }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        guard !analysisCues.isEmpty else {
            throw WorkflowError.invalidTopics("после подготовки не осталось исходных cue для анализа.")
        }
        let sourceSignature = StableTopicHash.string(try String(contentsOf: sourceSRT, encoding: .utf8))
        onLog("Подготовлено смысловых абзацев: \(paragraphs.count); содержательных cue: \(analysisCues.count).")
        if preparation.excludedZeroDuration > 0 {
            onLog("Исключено cue нулевой длительности: \(preparation.excludedZeroDuration).")
        }
        if preparation.excludedServiceText > 0 {
            onLog("Исключено служебных текстовых cue: \(preparation.excludedServiceText).")
        }
        if preparation.mergedProgressiveCues > 0 {
            onLog("Объединено прогрессивных повторов Whisper: \(preparation.mergedProgressiveCues). Исходные cueId сохранены.")
        }
        onProgress(0.05)

        let languageModels = try await provider.availableLanguageModels()
        guard !languageModels.isEmpty else {
            throw WorkflowError.topicServiceUnavailable("не найдены модели \(provider.primaryLanguageModel) и \(provider.fallbackLanguageModel).")
        }
        onLog("Embeddings: \(provider.embeddingModel); проверка тем: \(languageModels.joined(separator: ", ")).")
        let layout = ProjectLayout(root: context.projectURL)
        try FileManager.default.createDirectory(
            at: layout.topicCacheDirectory(language: context.language, granularity: context.granularity),
            withIntermediateDirectories: true
        )
        let embeddingCacheURL = layout.topicEmbeddingCacheURL(language: context.language)
        let labelCacheURL = layout.topicLabelCacheURL(language: context.language, granularity: context.granularity)
        var embeddingCache = TopicEmbeddingCache.load(
            from: embeddingCacheURL,
            model: provider.embeddingModel,
            sourceSignature: sourceSignature,
            granularity: context.granularity,
            algorithmVersion: Self.algorithmVersion
        )

        let keys = paragraphs.map { StableTopicHash.string($0.text) }
        let missingIndices = keys.indices.filter { embeddingCache.values[keys[$0]] == nil }
        let embeddingBatchSize = 32
        for batchStart in stride(from: 0, to: missingIndices.count, by: embeddingBatchSize) {
            try Task.checkCancellation()
            let indices = Array(missingIndices[batchStart..<min(batchStart + embeddingBatchSize, missingIndices.count)])
            let result = try await provider.embeddings(for: indices.map { paragraphs[$0].text })
            guard result.count == indices.count, result.allSatisfy({ !$0.isEmpty }) else {
                throw WorkflowError.invalidTopics("Ollama вернул неполный набор embeddings.")
            }
            for (index, vector) in zip(indices, result) { embeddingCache.values[keys[index]] = vector }
            try embeddingCache.save(to: embeddingCacheURL)
            let completed = batchStart + indices.count
            let fraction = missingIndices.isEmpty ? 1 : Double(completed) / Double(missingIndices.count)
            onProgress(0.05 + 0.27 * fraction)
        }
        if missingIndices.isEmpty {
            onLog("Embeddings восстановлены из кэша.")
            onProgress(0.32)
        }

        let vectors = try keys.map { key -> [Double] in
            guard let value = embeddingCache.values[key] else {
                throw WorkflowError.invalidTopics("в кэше отсутствует рассчитанный embedding.")
            }
            return value
        }
        let candidates = detector.candidates(
            paragraphs: paragraphs,
            embeddings: vectors,
            granularity: context.granularity
        )
        onLog("Семантических кандидатных границ: \(candidates.count) из \(max(paragraphs.count - 1, 0)) межабзацных переходов.")
        onProgress(0.35)

        var analysisCache = TopicAnalysisCache.load(
            from: labelCacheURL,
            sourceSignature: sourceSignature,
            granularity: context.granularity,
            algorithmVersion: Self.algorithmVersion
        )
        let windows = TopicBoundaryWindowBuilder().windows(
            candidates: candidates,
            paragraphs: paragraphs,
            cues: analysisCues,
            granularity: context.granularity
        ).map { window -> TopicBoundaryReviewRequest in
            var localized = window
            localized.language = context.language
            return localized
        }
        var decisions: [Int: TopicBoundaryDecision] = [:]
        var usedModels = Set<String>()
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            let cacheKey = StableTopicHash.string(window.cacheText)
            let cached = analysisCache.boundaryWindows[cacheKey]
            let result: CachedBoundaryReview
            if let cached,
               validator.boundaryReviewIssues(cached.review, request: window).isEmpty,
               languageModels.contains(cached.model) {
                result = cached
            } else {
                result = try await reviewBoundaries(window, models: languageModels)
                analysisCache.boundaryWindows[cacheKey] = result
                try analysisCache.save(to: labelCacheURL)
            }
            usedModels.insert(result.model)
            for decision in result.review.decisions { decisions[decision.afterCueId] = decision }
            onProgress(0.35 + 0.28 * Double(index + 1) / Double(max(windows.count, 1)))
        }
        if windows.isEmpty { onProgress(0.63) }

        let keptDecisions = decisions.values.filter(\.keep)
        let cueGroups = TopicCueGrouper().groups(
            cues: analysisCues,
            boundariesAfterCueIDs: Set(keptDecisions.map(\.afterCueId))
        )
        guard !cueGroups.isEmpty else { throw WorkflowError.invalidTopics("после проверки LLM не осталось смысловых разделов.") }
        onLog("LLM подтвердила границ: \(keptDecisions.count); итоговых диапазонов: \(cueGroups.count).")

        var topics: [TopicSegment] = []
        let descriptionBatchSize = 2
        for batchStart in stride(from: 0, to: cueGroups.count, by: descriptionBatchSize) {
            try Task.checkCancellation()
            let groups = Array(cueGroups[batchStart..<min(batchStart + descriptionBatchSize, cueGroups.count)])
            let request = TopicDescriptionRequest(
                id: "description-\(batchStart / descriptionBatchSize + 1)",
                granularity: context.granularity,
                blocks: groups.map {
                    TopicDescriptionBlock(startCueId: $0.first!.id, endCueId: $0.last!.id, cues: $0)
                },
                previousTitles: topics.map(\.title),
                language: context.language
            )
            let cacheKey = StableTopicHash.string(descriptionCacheText(request))
            let cached = analysisCache.descriptions[cacheKey]
            let result: CachedTopicReview
            if let cached,
               validator.topicReviewIssues(cached.review, request: request).isEmpty,
               languageModels.contains(cached.model) {
                result = cached
            } else {
                result = try await describeTopics(request, models: languageModels)
                analysisCache.descriptions[cacheKey] = result
                try analysisCache.save(to: labelCacheURL)
            }
            usedModels.insert(result.model)
            let items = Dictionary(uniqueKeysWithValues: result.review.topics.map { ($0.startCueId, $0) })
            for group in groups {
                guard let item = items[group.first!.id] else {
                    throw WorkflowError.invalidTopics("языковая модель пропустила диапазон cue \(group.first!.id)-\(group.last!.id).")
                }
                let precedingBoundary = (topics.last?.sourceCueEnd).flatMap { decisions[$0] }
                topics.append(makeTopic(
                    index: topics.count,
                    cues: group,
                    item: item,
                    reviewedBoundaryReason: precedingBoundary?.reason
                ))
            }
            let completed = batchStart + groups.count
            onProgress(0.63 + 0.32 * Double(completed) / Double(cueGroups.count))
        }

        let file = TopicsFile(
            schemaVersion: TopicAlgorithmIdentity.schemaVersion,
            algorithmVersion: Self.algorithmVersion,
            adapter: name,
            createdAt: Date(),
            sourceSRT: sourceSRT.path,
            sourceSignature: sourceSignature,
            status: .ready,
            granularity: context.granularity,
            embeddingModel: provider.embeddingModel,
            languageModel: usedModels.sorted().joined(separator: ", "),
            topics: topics
        )
        let issues = validator.validate(
            file,
            expectedCues: analysisCues,
            mediaDuration: context.mediaDuration
        )
        guard issues.isEmpty else { throw WorkflowError.invalidTopics(issues.joined(separator: " ")) }
        onProgress(1)
        return file
    }

    private func reviewBoundaries(
        _ request: TopicBoundaryReviewRequest,
        models: [String]
    ) async throws -> CachedBoundaryReview {
        var failures: [String] = []
        for model in models {
            var correction: String?
            for _ in 0..<2 {
                try Task.checkCancellation()
                do {
                    let review = try await provider.reviewBoundaries(request, model: model, correction: correction)
                    let issues = validator.boundaryReviewIssues(review, request: request)
                    if issues.isEmpty { return CachedBoundaryReview(model: model, review: review) }
                    correction = issues.joined(separator: " ")
                    failures.append("\(model): \(correction!)")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    correction = error.localizedDescription
                    failures.append("\(model): \(error.localizedDescription)")
                }
            }
        }
        throw WorkflowError.invalidTopics("LLM не проверила окно \(request.id): \(failures.joined(separator: " | "))")
    }

    private func describeTopics(
        _ request: TopicDescriptionRequest,
        models: [String]
    ) async throws -> CachedTopicReview {
        var failures: [String] = []
        for model in models {
            var correction: String?
            for _ in 0..<2 {
                try Task.checkCancellation()
                do {
                    let rawReview = try await provider.describeTopics(request, model: model, correction: correction)
                    let review = repairingShortTitles(in: rawReview, language: request.language)
                    let issues = validator.topicReviewIssues(review, request: request)
                    if issues.isEmpty { return CachedTopicReview(model: model, review: review) }
                    correction = issues.joined(separator: " ")
                    failures.append("\(model): \(correction!)")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    correction = error.localizedDescription
                    failures.append("\(model): \(error.localizedDescription)")
                }
            }
        }
        throw WorkflowError.invalidTopics("LLM не описала диапазоны \(request.id): \(failures.joined(separator: " | "))")
    }

    private func repairingShortTitles(
        in review: TopicReviewResponse,
        language: ArtifactLanguage
    ) -> TopicReviewResponse {
        let topics = review.topics.map { item -> TopicReviewItem in
            var repaired = item
            var words = repaired.title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            guard words.count < 3 else { return repaired }

            var normalizedTitleWords = Set(words.map { $0.lowercased() })
            for keyword in repaired.keywords {
                let keywordWords = keyword.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                for word in keywordWords where !normalizedTitleWords.contains(word.lowercased()) && words.count < 3 {
                    words.append(word)
                    normalizedTitleWords.insert(word.lowercased())
                }
                if words.count >= 3 { break }
            }
            let fallbackWords = language == .ru ? ["Обсуждение", "темы"] : ["Topic", "discussion"]
            for word in fallbackWords where words.count < 3 && !normalizedTitleWords.contains(word.lowercased()) {
                words.insert(word, at: 0)
                normalizedTitleWords.insert(word.lowercased())
            }
            repaired.title = words.joined(separator: " ")
            return repaired
        }
        return TopicReviewResponse(topics: topics)
    }

    private func makeTopic(
        index: Int,
        cues: [SubtitleCue],
        item: TopicReviewItem,
        reviewedBoundaryReason: String?
    ) -> TopicSegment {
        let cueIDs = cues.map(\.id)
        let start = cues.first?.start ?? 0
        let end = cues.last?.end ?? start
        return TopicSegment(
            id: "topic-\(index + 1)",
            title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
            start: start,
            end: end,
            summary: item.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            keywords: item.keywords,
            confidence: min(max(item.confidence, 0), 1),
            boundaryReason: reviewedBoundaryReason ?? item.boundaryReason,
            sourceCueStart: cueIDs.min(),
            sourceCueEnd: cueIDs.max(),
            cueIds: cueIDs
        )
    }

    private func descriptionCacheText(_ request: TopicDescriptionRequest) -> String {
        let blocks = request.blocks.map { block in
            "\(block.startCueId)-\(block.endCueId):" + block.cues.map { "[\($0.id)]\($0.text)" }.joined()
        }.joined(separator: "|")
        return "\(Self.algorithmVersion)|\(request.granularity.rawValue)|\(request.previousTitles.joined(separator: ";"))|\(blocks)"
    }
}

struct TopicTextPreprocessor {
    private struct PreparedCue {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
        var cueIDs: [Int]
    }

    func prepare(_ cues: [SubtitleCue]) -> [TopicParagraph] {
        prepareWithReport(cues).paragraphs
    }

    func prepareWithReport(_ cues: [SubtitleCue]) -> TopicPreparationResult {
        var excludedZeroDuration = 0
        var excludedServiceText = 0
        var mergedProgressiveCues = 0
        var meaningful: [SubtitleCue] = []
        for cue in cues.sorted(by: { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }) {
            if cue.end <= cue.start {
                excludedZeroDuration += 1
            } else if isServiceText(cue.text) {
                excludedServiceText += 1
            } else {
                meaningful.append(cue)
            }
        }
        var prepared: [PreparedCue] = []
        for cue in meaningful {
            let clean = cleanText(cue.text)
            guard !clean.isEmpty else { continue }
            if var previous = prepared.last, shouldCoalesce(previous, cue: cue, cleanText: clean) {
                mergedProgressiveCues += 1
                prepared.removeLast()
                let previousNormalized = normalized(previous.text)
                let currentNormalized = normalized(clean)
                if currentNormalized.count >= previousNormalized.count { previous.text = clean }
                previous.start = min(previous.start, cue.start)
                previous.end = max(previous.end, cue.end)
                previous.cueIDs.append(cue.id)
                prepared.append(previous)
            } else {
                prepared.append(PreparedCue(start: cue.start, end: cue.end, text: clean, cueIDs: [cue.id]))
            }
        }

        var paragraphs: [TopicParagraph] = []
        var current: TopicParagraph?
        for cue in prepared {
            if let value = current {
                let gap = cue.start - value.end
                let projectedDuration = cue.end - value.start
                if gap > 3.5 || projectedDuration > 45 {
                    paragraphs.append(value)
                    current = TopicParagraph(start: cue.start, end: cue.end, text: cue.text, cueIDs: cue.cueIDs)
                    continue
                }
                current?.end = cue.end
                current?.text += " " + cue.text
                current?.cueIDs.append(contentsOf: cue.cueIDs)
                if projectedDuration >= 20, endsSentence(cue.text), let completed = current {
                    paragraphs.append(completed)
                    current = nil
                }
            } else {
                current = TopicParagraph(start: cue.start, end: cue.end, text: cue.text, cueIDs: cue.cueIDs)
            }
        }
        if let current { paragraphs.append(current) }
        return TopicPreparationResult(
            paragraphs: paragraphs,
            excludedZeroDuration: excludedZeroDuration,
            excludedServiceText: excludedServiceText,
            mergedProgressiveCues: mergedProgressiveCues
        )
    }

    private func shouldCoalesce(_ previous: PreparedCue, cue: SubtitleCue, cleanText: String) -> Bool {
        let old = normalized(previous.text)
        let new = normalized(cleanText)
        guard !old.isEmpty, !new.isEmpty else { return false }
        let close = cue.start <= previous.end + 1.2
        let overlappingOrigin = abs(cue.start - previous.start) < 0.8 || cue.start < previous.end
        return close && (old == new || (overlappingOrigin && (old.contains(new) || new.contains(old))))
    }

    private func isServiceText(_ text: String) -> Bool {
        let value = normalized(text)
        let markers: Set<String> = [
            "blank audio", "music", "музыка", "тишина", "аплодисменты", "неразборчиво"
        ]
        return value.isEmpty || markers.contains(value)
    }

    private func cleanText(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return ".!?…:».".contains(last)
    }
}

struct TopicBoundaryDetector {
    func candidates(
        paragraphs: [TopicParagraph],
        embeddings: [[Double]],
        granularity: TopicGranularity
    ) -> [TopicBoundaryCandidate] {
        guard paragraphs.count > 1, paragraphs.count == embeddings.count else { return [] }
        let raw = (0..<(paragraphs.count - 1)).compactMap { index -> TopicBoundaryCandidate? in
            guard let afterCueID = paragraphs[index].cueIDs.last else { return nil }
            let semantic = 1 - cosine(embeddings[index], embeddings[index + 1])
            let lexical = 1 - TopicLexicon.jaccard(paragraphs[index].text, paragraphs[index + 1].text)
            let pause = max(0, paragraphs[index + 1].start - paragraphs[index].end)
            let completion = paragraphs[index].text.last.map { ".!?…:»".contains($0) } == true ? 0.08 : -0.12
            let score = semantic * 0.62 + lexical * 0.18 + min(pause / 8, 0.4) + completion
            return TopicBoundaryCandidate(
                afterCueId: afterCueID,
                semanticChange: semantic,
                lexicalChange: lexical,
                pauseSeconds: pause,
                score: score
            )
        }
        guard !raw.isEmpty else { return [] }

        let boundaryTimes = Dictionary(uniqueKeysWithValues: paragraphs.compactMap { paragraph in
            paragraph.cueIDs.last.map { ($0, paragraph.end) }
        })
        let minimumSpacing = granularity.durationRange.lowerBound
        let scoreFloor: Double
        switch granularity {
        case .detailed: scoreFloor = 0.30
        case .normal: scoreFloor = 0.34
        case .coarse: scoreFloor = 0.38
        }

        var selected: [TopicBoundaryCandidate] = []
        for candidate in raw.sorted(by: { $0.score > $1.score }) where candidate.score >= scoreFloor {
            guard let time = boundaryTimes[candidate.afterCueId] else { continue }
            let isFarEnough = selected.allSatisfy { existing in
                guard let existingTime = boundaryTimes[existing.afterCueId] else { return true }
                return abs(existingTime - time) >= minimumSpacing
            }
            if isFarEnough { selected.append(candidate) }
        }
        if selected.isEmpty, let strongest = raw.max(by: { $0.score < $1.score }) {
            selected.append(strongest)
        }

        let maximumGap = granularity.durationRange.upperBound * 1.15
        while let gap = firstOversizedGap(
            selected: selected,
            boundaryTimes: boundaryTimes,
            start: paragraphs.first!.start,
            end: paragraphs.last!.end,
            maximumGap: maximumGap
        ) {
            let margin = min(minimumSpacing * 0.4, gap.duration * 0.2)
            let midpoint = (gap.start + gap.end) / 2
            let selectedIDs = Set(selected.map(\.afterCueId))
            let filler = raw
                .filter { candidate in
                    guard !selectedIDs.contains(candidate.afterCueId),
                          let time = boundaryTimes[candidate.afterCueId] else { return false }
                    return time > gap.start + margin && time < gap.end - margin
                }
                .max(by: { lhs, rhs in
                    adjustedScore(lhs, midpoint: midpoint, boundaryTimes: boundaryTimes, maximumGap: maximumGap)
                        < adjustedScore(rhs, midpoint: midpoint, boundaryTimes: boundaryTimes, maximumGap: maximumGap)
                })
            guard let filler else { break }
            selected.append(filler)
        }

        return selected.sorted {
            (boundaryTimes[$0.afterCueId] ?? 0) < (boundaryTimes[$1.afterCueId] ?? 0)
        }
    }

    private func firstOversizedGap(
        selected: [TopicBoundaryCandidate],
        boundaryTimes: [Int: TimeInterval],
        start: TimeInterval,
        end: TimeInterval,
        maximumGap: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval, duration: TimeInterval)? {
        let times = selected.compactMap { boundaryTimes[$0.afterCueId] }.sorted()
        let anchors = [start] + times + [end]
        for pair in zip(anchors, anchors.dropFirst()) {
            let duration = pair.1 - pair.0
            if duration > maximumGap { return (pair.0, pair.1, duration) }
        }
        return nil
    }

    private func adjustedScore(
        _ candidate: TopicBoundaryCandidate,
        midpoint: TimeInterval,
        boundaryTimes: [Int: TimeInterval],
        maximumGap: TimeInterval
    ) -> Double {
        let time = boundaryTimes[candidate.afterCueId] ?? midpoint
        return candidate.score - abs(time - midpoint) / max(maximumGap, 1) * 0.08
    }

    func groups(
        paragraphs: [TopicParagraph],
        embeddings: [[Double]],
        granularity: TopicGranularity
    ) -> [[TopicParagraph]] {
        guard !paragraphs.isEmpty, paragraphs.count == embeddings.count else { return [] }
        guard paragraphs.count > 1 else { return [paragraphs] }
        let allowed = granularity.durationRange
        var ranges: [ClosedRange<Int>] = []
        var startIndex = 0

        while startIndex < paragraphs.count {
            let remainingDuration = paragraphs.last!.end - paragraphs[startIndex].start
            if remainingDuration <= allowed.upperBound * 1.15 {
                ranges.append(startIndex...(paragraphs.count - 1))
                break
            }

            var candidates: [(index: Int, score: Double)] = []
            var fallback = startIndex
            for index in startIndex..<(paragraphs.count - 1) {
                let duration = paragraphs[index].end - paragraphs[startIndex].start
                if duration <= allowed.upperBound { fallback = index }
                if duration >= allowed.lowerBound, duration <= allowed.upperBound {
                    candidates.append((index, boundaryScore(
                        left: paragraphs[index],
                        right: paragraphs[index + 1],
                        leftVector: embeddings[index],
                        rightVector: embeddings[index + 1],
                        duration: duration,
                        target: granularity.targetDuration
                    )))
                }
                if duration > allowed.upperBound { break }
            }
            let endIndex = candidates.max { $0.score < $1.score }?.index ?? max(startIndex, fallback)
            ranges.append(startIndex...endIndex)
            startIndex = endIndex + 1
        }

        if ranges.count > 1, let last = ranges.last {
            let duration = paragraphs[last.upperBound].end - paragraphs[last.lowerBound].start
            if duration < allowed.lowerBound * 0.45 {
                let trailing = ranges.removeLast()
                let previous = ranges.removeLast()
                ranges.append(previous.lowerBound...trailing.upperBound)
            }
        }
        return ranges.map { Array(paragraphs[$0]) }
    }

    private func boundaryScore(
        left: TopicParagraph,
        right: TopicParagraph,
        leftVector: [Double],
        rightVector: [Double],
        duration: TimeInterval,
        target: TimeInterval
    ) -> Double {
        let semanticChange = 1 - cosine(leftVector, rightVector)
        let lexicalChange = 1 - TopicLexicon.jaccard(left.text, right.text)
        let pauseBonus = min(max(right.start - left.end, 0) / 8, 0.4)
        let completionBonus = left.text.last.map { ".!?…:»".contains($0) } == true ? 0.08 : -0.12
        let targetPenalty = abs(duration - target) / max(target, 1) * 0.12
        return semanticChange * 0.62 + lexicalChange * 0.18 + pauseBonus + completionBonus - targetPenalty
    }

    private func cosine(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = 0.0
        var leftLength = 0.0
        var rightLength = 0.0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            leftLength += lhs[index] * lhs[index]
            rightLength += rhs[index] * rhs[index]
        }
        guard leftLength > 0, rightLength > 0 else { return 0 }
        return min(max(dot / (sqrt(leftLength) * sqrt(rightLength)), -1), 1)
    }
}

struct TopicBoundaryWindowBuilder {
    private let focusSize = 6

    func windows(
        candidates: [TopicBoundaryCandidate],
        paragraphs: [TopicParagraph],
        cues: [SubtitleCue],
        granularity: TopicGranularity
    ) -> [TopicBoundaryReviewRequest] {
        guard !candidates.isEmpty else { return [] }
        let paragraphIndex = Dictionary(uniqueKeysWithValues: paragraphs.enumerated().compactMap { index, paragraph in
            paragraph.cueIDs.last.map { ($0, index) }
        })
        return stride(from: 0, to: candidates.count, by: focusSize).map { start in
            let end = min(start + focusSize, candidates.count)
            let focus = Array(candidates[start..<end])
            let contextStart = max(0, start - 2)
            let contextEnd = min(candidates.count, end + 2)
            let contextCandidates = Array(candidates[contextStart..<contextEnd])
            var localParagraphIndices = Set<Int>()
            for candidate in contextCandidates {
                let boundaryIndex = paragraphIndex[candidate.afterCueId] ?? 0
                let localStart = max(0, boundaryIndex - 1)
                let localEnd = min(paragraphs.count - 1, boundaryIndex + 2)
                localParagraphIndices.formUnion(localStart...localEnd)
            }
            let cueIDs = Set(localParagraphIndices.flatMap { paragraphs[$0].cueIDs })
            let contextCues = cues.filter { cueIDs.contains($0.id) }
            return TopicBoundaryReviewRequest(
                id: "boundary-window-\(start / focusSize + 1)",
                granularity: granularity,
                cues: contextCues,
                candidates: contextCandidates,
                focusAfterCueIds: focus.map(\.afterCueId)
            )
        }
    }
}

struct TopicCueGrouper {
    func groups(cues: [SubtitleCue], boundariesAfterCueIDs: Set<Int>) -> [[SubtitleCue]] {
        guard !cues.isEmpty else { return [] }
        var result: [[SubtitleCue]] = []
        var current: [SubtitleCue] = []
        for cue in cues {
            current.append(cue)
            if boundariesAfterCueIDs.contains(cue.id), !current.isEmpty {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

enum TopicLexicon {
    private static let stopWords: Set<String> = [
        "the", "and", "that", "this", "with", "from", "have", "you", "are", "for", "was", "were",
        "как", "что", "это", "для", "или", "если", "они", "она", "оно", "его", "ее", "уже", "так", "вот",
        "то", "на", "мы", "вы", "по", "из", "не", "да", "же", "но", "и", "в", "а", "к", "у", "о", "об",
        "есть", "там", "все", "всё", "быть", "был", "была", "были", "будет", "мне", "меня", "тебя", "вам",
        "нас", "кто", "где", "когда", "тут", "тоже", "можно", "просто", "очень", "вообще", "теперь", "потом"
    ]

    static func meaningfulWords(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) && Int($0) == nil }
    }

    static func jaccard(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(meaningfulWords(in: lhs))
        let right = Set(meaningfulWords(in: rhs))
        guard !left.isEmpty || !right.isEmpty else { return 1 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    static func vector(_ paragraph: TopicParagraph) -> [Double] {
        var result = Array(repeating: 0.0, count: 96)
        for word in meaningfulWords(in: paragraph.text) {
            let hash = StableTopicHash.value(word)
            result[Int(hash % UInt64(result.count))] += 1
        }
        return result
    }
}

struct TopicValidator {
    func validate(
        _ file: TopicsFile,
        expectedCueIDs: Set<Int>,
        mediaDuration: TimeInterval?
    ) -> [String] {
        guard !file.topics.isEmpty else { return ["список тем пуст."] }
        var issues: [String] = []
        var previousEnd = -Double.infinity
        var titles = Set<String>()
        var previousTitles: [String] = []
        var assignedCueIDs: [Int] = []

        for (index, topic) in file.topics.enumerated() {
            if topic.start < 0 || topic.end <= topic.start { issues.append("тема \(index + 1) имеет некорректный диапазон.") }
            if topic.start < previousEnd - 0.001 { issues.append("тема \(index + 1) пересекается с предыдущей.") }
            if abs(topic.duration - (topic.end - topic.start)) > 0.01 { issues.append("у темы \(index + 1) неверно рассчитана длительность.") }
            if let mediaDuration, topic.end > mediaDuration + 1 { issues.append("тема \(index + 1) выходит за длительность видео.") }
            if topic.cueIds.isEmpty { issues.append("тема \(index + 1) не связана с SRT.") }
            if topic.sourceCueStart != topic.cueIds.min() || topic.sourceCueEnd != topic.cueIds.max() {
                issues.append("у темы \(index + 1) неверные границы исходных реплик.")
            }
            let normalizedTitle = Self.normalizedTitle(topic.title)
            if normalizedTitle.isEmpty { issues.append("у темы \(index + 1) пустое название.") }
            if titles.contains(normalizedTitle) { issues.append("название темы \(index + 1) дублируется.") }
            titles.insert(normalizedTitle)
            if file.status == .ready {
                let label = TopicLabel(
                    title: topic.title,
                    summary: topic.summary,
                    keywords: topic.keywords,
                    confidence: topic.confidence,
                    boundaryReason: topic.boundaryReason
                )
                issues.append(contentsOf: Self.labelIssues(label, previousTitles: previousTitles).map {
                    "тема \(index + 1): \($0)"
                })
            }
            previousTitles.append(topic.title)
            if !(0...1).contains(topic.confidence) { issues.append("у темы \(index + 1) неверная оценка уверенности.") }
            assignedCueIDs.append(contentsOf: topic.cueIds)
            previousEnd = topic.end
        }

        let assignedSet = Set(assignedCueIDs)
        if assignedSet != expectedCueIDs { issues.append("не все содержательные реплики SRT распределены по темам.") }
        if assignedSet.count != assignedCueIDs.count { issues.append("некоторые реплики SRT назначены нескольким темам.") }
        return issues
    }

    func validate(
        _ file: TopicsFile,
        expectedCues: [SubtitleCue],
        mediaDuration: TimeInterval?
    ) -> [String] {
        var issues = validate(file, expectedCueIDs: Set(expectedCues.map(\.id)), mediaDuration: mediaDuration)
        let cueMap = Dictionary(uniqueKeysWithValues: expectedCues.map { ($0.id, $0) })
        let orderedIDs = expectedCues.map(\.id)
        for (index, topic) in file.topics.enumerated() {
            guard let firstCue = cueMap[topic.sourceCueStart],
                  let lastCue = cueMap[topic.sourceCueEnd],
                  let firstIndex = orderedIDs.firstIndex(of: topic.sourceCueStart),
                  let lastIndex = orderedIDs.firstIndex(of: topic.sourceCueEnd),
                  firstIndex <= lastIndex else {
                issues.append("тема \(index + 1) ссылается на неизвестный cueId.")
                continue
            }
            let expectedIDs = Array(orderedIDs[firstIndex...lastIndex])
            if topic.cueIds != expectedIDs {
                issues.append("тема \(index + 1) содержит непоследовательный диапазон cueId.")
            }
            if abs(topic.start - firstCue.start) > 0.001 || abs(topic.end - lastCue.end) > 0.001 {
                issues.append("время темы \(index + 1) не совпадает с исходным SRT.")
            }
        }
        return issues
    }

    func boundaryReviewIssues(
        _ review: TopicBoundaryReview,
        request: TopicBoundaryReviewRequest
    ) -> [String] {
        var issues: [String] = []
        let expected = Set(request.focusAfterCueIds)
        let actual = review.decisions.map(\.afterCueId)
        if Set(actual) != expected {
            issues.append("ответ должен содержать только cueId \(request.focusAfterCueIds), получены \(actual).")
        }
        if Set(actual).count != actual.count { issues.append("ответ содержит повторяющиеся cueId границ.") }
        for decision in review.decisions {
            if !(0...1).contains(decision.confidence) { issues.append("у границы \(decision.afterCueId) неверная уверенность.") }
            if decision.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("у границы \(decision.afterCueId) отсутствует причина решения.")
            }
        }
        return issues
    }

    func topicReviewIssues(
        _ review: TopicReviewResponse,
        request: TopicDescriptionRequest
    ) -> [String] {
        var issues: [String] = []
        let expectedPairs = request.blocks.map { "\($0.startCueId):\($0.endCueId)" }
        let actualPairs = review.topics.map { "\($0.startCueId):\($0.endCueId)" }
        if Set(expectedPairs) != Set(actualPairs) || actualPairs.count != expectedPairs.count {
            issues.append("ответ должен сохранить диапазоны без изменения; ожидались \(expectedPairs), получены \(actualPairs).")
        }
        var previousTitles = request.previousTitles
        for item in review.topics.sorted(by: { $0.startCueId < $1.startCueId }) {
            let label = TopicLabel(
                title: item.title,
                summary: item.summary,
                keywords: item.keywords,
                confidence: item.confidence,
                boundaryReason: item.boundaryReason
            )
            issues.append(contentsOf: Self.labelIssues(label, previousTitles: previousTitles))
            if item.boundaryReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("для диапазона \(item.startCueId)-\(item.endCueId) не указана причина границы.")
            }
            previousTitles.append(item.title)
        }
        return issues
    }

    static func labelIssues(_ label: TopicLabel, previousTitles: [String]) -> [String] {
        var issues: [String] = []
        let words = label.title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if !(3...8).contains(words.count) { issues.append("название «\(label.title)» должно содержать от 3 до 8 слов.") }
        if TopicLexicon.meaningfulWords(in: label.title).count < 2 { issues.append("название не описывает содержание темы.") }
        if label.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("отсутствует краткое описание.") }
        if label.keywords.count < 2 || label.keywords.count > 8 { issues.append("нужно от 2 до 8 ключевых слов.") }
        if !(0...1).contains(label.confidence) { issues.append("уверенность должна быть от 0 до 1.") }
        let normalized = normalizedTitle(label.title)
        if previousTitles.map(normalizedTitle).contains(normalized) { issues.append("название повторяет предыдущую тему.") }
        return issues
    }

    private static func normalizedTitle(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private struct TopicEmbeddingCache: Codable {
    var model: String
    var sourceSignature: String
    var granularity: TopicGranularity
    var algorithmVersion: String
    var values: [String: [Double]]

    static func load(
        from url: URL,
        model: String,
        sourceSignature: String,
        granularity: TopicGranularity,
        algorithmVersion: String
    ) -> TopicEmbeddingCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(TopicEmbeddingCache.self, from: data),
              cache.model == model,
              cache.sourceSignature == sourceSignature,
              cache.algorithmVersion == algorithmVersion else {
            return TopicEmbeddingCache(
                model: model,
                sourceSignature: sourceSignature,
                granularity: granularity,
                algorithmVersion: algorithmVersion,
                values: [:]
            )
        }
        return cache
    }

    func save(to url: URL) throws { try TopicCacheWriter.write(self, to: url) }
}

private struct CachedBoundaryReview: Codable {
    var model: String
    var review: TopicBoundaryReview
}

private struct CachedTopicReview: Codable {
    var model: String
    var review: TopicReviewResponse
}

private struct TopicAnalysisCache: Codable {
    var sourceSignature: String
    var granularity: TopicGranularity
    var algorithmVersion: String
    var boundaryWindows: [String: CachedBoundaryReview]
    var descriptions: [String: CachedTopicReview]

    static func load(
        from url: URL,
        sourceSignature: String,
        granularity: TopicGranularity,
        algorithmVersion: String
    ) -> TopicAnalysisCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(TopicAnalysisCache.self, from: data),
              cache.sourceSignature == sourceSignature,
              cache.granularity == granularity,
              cache.algorithmVersion == algorithmVersion else {
            return TopicAnalysisCache(
                sourceSignature: sourceSignature,
                granularity: granularity,
                algorithmVersion: algorithmVersion,
                boundaryWindows: [:],
                descriptions: [:]
            )
        }
        return cache
    }

    func save(to url: URL) throws { try TopicCacheWriter.write(self, to: url) }
}

private enum TopicCacheWriter {
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

enum StableTopicHash {
    static func value(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    static func string(_ text: String) -> String { String(format: "%016llx", value(text)) }
}
