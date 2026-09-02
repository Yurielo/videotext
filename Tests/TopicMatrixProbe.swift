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
