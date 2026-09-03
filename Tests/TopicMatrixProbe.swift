import Foundation

@main
struct TopicMatrixProbe {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("videotext-topic-matrix-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try ProjectLayout(root: root).createDirectories()
        let service = TopicFileService()
        var expectedTitles: [String: String] = [:]

        for language in ArtifactLanguage.allCases {
            for granularity in TopicGranularity.allCases {
                let key = "\(language.rawValue)-\(granularity.rawValue)"
                let title = "Topic \(key)"
                expectedTitles[key] = title
                let file = TopicsFile(
                    schemaVersion: TopicAlgorithmIdentity.schemaVersion,
                    algorithmVersion: TopicAlgorithmIdentity.draftVersion,
                    adapter: TopicAlgorithmIdentity.draftAdapter,
                    createdAt: Date(),
                    sourceSRT: "\(language.rawValue).srt",
                    sourceSignature: "signature-\(language.rawValue)",
                    status: .draft,
                    granularity: granularity,
                    topics: [TopicSegment(
                        id: "topic-1",
                        title: title,
                        start: 0,
                        end: 10,
                        summary: key,
                        keywords: [language.rawValue, granularity.rawValue],
                        confidence: 0.5,
                        boundaryReason: "probe",
                        sourceCueStart: 1,
                        sourceCueEnd: 1,
                        cueIds: [1]
                    )]
                )
                try service.save(
                    file,
                    projectURL: root,
                    language: language,
                    granularity: granularity,
                    updateLegacyFiles: language == .ru && granularity == .normal
                )
            }
        }

        for language in ArtifactLanguage.allCases {
            for granularity in TopicGranularity.allCases {
                let loaded = try WorkflowEngine.loadTopics(
                    projectURL: root,
                    language: language,
                    granularity: granularity
                )
                let key = "\(language.rawValue)-\(granularity.rawValue)"
                try require(loaded.topics.first?.title == expectedTitles[key], "набор \(key) перезаписан")
                try require(
                    fm.fileExists(atPath: ProjectLayout(root: root).topicsTextURL(language: language, granularity: granularity).path),
                    "нет TXT-набора \(key)"
                )
            }
        }
        let legacy = try WorkflowEngine.loadTopics(projectURL: root)
        try require(legacy.granularity == .normal && legacy.topics.first?.title == "Topic ru-normal", "legacy-файл не указывает на выбранный набор")

        let layout = ProjectLayout(root: root)
        let localizedCues = [SubtitleCue(id: 1, start: 0, end: 2, text: "Локализованный источник тем.")]
        try SRTService().writePreservingIDs(localizedCues, to: layout.subtitlesURL(language: .ru))
        try "1\n00:00:00,000 --> 00:00:02,000\nЛокализованный источник тем.\n\n2\n00:00:02,000 --> 00:00:02,000\nСлужебная реплика\n".write(
            to: layout.fullSRTURL,
            atomically: true,
            encoding: .utf8
        )
        let localizedText = try String(contentsOf: layout.subtitlesURL(language: .ru), encoding: .utf8)
        let readyFile = TopicsFile(
            adapter: TopicAlgorithmIdentity.hybridAdapter,
            createdAt: Date(),
            sourceSRT: layout.subtitlesURL(language: .ru).path,
            sourceSignature: StableTopicHash.string(localizedText),
            status: .ready,
            granularity: .normal,
            topics: [TopicSegment(
                id: "topic-ready",
                title: "Готовая локализованная тема",
                start: 0,
                end: 2,
                summary: "Проверка языкового SRT.",
                keywords: ["локализация", "SRT"],
                confidence: 1,
                boundaryReason: "probe",
                sourceCueStart: 1,
                sourceCueEnd: 1,
                cueIds: [1]
            )]
        )
        try service.save(
            readyFile,
            projectURL: root,
            language: .ru,
            granularity: .normal,
            updateLegacyFiles: true
        )
        let readySummary = ProjectResultSummaryService().summarize(projectURL: root)
        try require(
            readySummary.artifact(.topics)?.availability == .ready,
            "сводка не использует языковой SRT для topic signature"
        )

        try SRTService().writePreservingIDs(
            [SubtitleCue(id: 1, start: 0, end: 2, text: "Изменённый источник тем.")],
            to: layout.subtitlesURL(language: .ru)
        )
        let staleSummary = ProjectResultSummaryService().summarize(projectURL: root)
        try require(staleSummary.artifact(.topics)?.availability == .partial, "изменённый языковой SRT не инвалидировал темы")
        print("TOPIC_MATRIX_PROBE_PASS")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
