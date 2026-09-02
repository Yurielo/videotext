import Foundation

struct TopicBuildContext {
    var projectURL: URL
    var mediaDuration: TimeInterval?
    var granularity: TopicGranularity
    var language: ArtifactLanguage = .ru
}

protocol TopicAdapter {
    var name: String { get }

    func buildTopics(
        from cues: [SubtitleCue],
        sourceSRT: URL,
        context: TopicBuildContext,
        onProgress: @escaping (Double) -> Void,
        onLog: @escaping (String) -> Void
    ) async throws -> TopicsFile
}

struct DraftTopicAdapter: TopicAdapter {
    static let algorithmVersion = TopicAlgorithmIdentity.draftVersion
    let name = TopicAlgorithmIdentity.draftAdapter

    func buildTopics(
        from cues: [SubtitleCue],
        sourceSRT: URL,
        context: TopicBuildContext,
        onProgress: @escaping (Double) -> Void,
        onLog: @escaping (String) -> Void
    ) async throws -> TopicsFile {
        let paragraphs = TopicTextPreprocessor().prepare(cues)
        guard !paragraphs.isEmpty else {
            throw WorkflowError.invalidTopics("после подготовки не осталось содержательных реплик.")
        }
        onProgress(0.2)

        let vectors = paragraphs.map(TopicLexicon.vector)
        let groups = TopicBoundaryDetector().groups(
            paragraphs: paragraphs,
            embeddings: vectors,
            granularity: context.granularity
        )
        let topics = groups.enumerated().map { index, group in
            draftTopic(index: index, paragraphs: group)
        }
        let file = TopicsFile(
            schemaVersion: TopicAlgorithmIdentity.schemaVersion,
            algorithmVersion: Self.algorithmVersion,
            adapter: name,
            createdAt: Date(),
            sourceSRT: sourceSRT.path,
            sourceSignature: StableTopicHash.string(try String(contentsOf: sourceSRT, encoding: .utf8)),
            status: .draft,
            granularity: context.granularity,
            topics: topics
        )
        let issues = TopicValidator().validate(
            file,
            expectedCueIDs: Set(paragraphs.flatMap(\.cueIDs)),
            mediaDuration: context.mediaDuration
        )
        guard issues.isEmpty else { throw WorkflowError.invalidTopics(issues.joined(separator: " ")) }
        onLog("Создан явно обозначенный черновой таймкодинг без Ollama.")
        onProgress(1)
        return file
    }

    private func draftTopic(index: Int, paragraphs: [TopicParagraph]) -> TopicSegment {
        let text = paragraphs.map(\.text).joined(separator: " ")
        let words = TopicLexicon.meaningfulWords(in: text)
        let counts = Dictionary(grouping: words, by: { $0 }).mapValues(\.count)
        var keywords = counts.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(5).map(\.key)
        while keywords.count < 3 { keywords.append("раздел-\(index + 1)") }
        let cueIDs = paragraphs.flatMap(\.cueIDs)
        let start = paragraphs.first?.start ?? 0
        let end = paragraphs.last?.end ?? start
        let summary = String(text.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines)
        return TopicSegment(
            id: "topic-\(index + 1)",
            title: keywords.prefix(4).joined(separator: " ").capitalized,
            start: start,
            end: end,
            summary: summary,
            keywords: Array(keywords.prefix(5)),
            confidence: 0.25,
            boundaryReason: "Черновое деление по лексике и продолжительности без проверки LLM.",
            sourceCueStart: cueIDs.min(),
            sourceCueEnd: cueIDs.max(),
            cueIds: cueIDs
        )
    }
}
