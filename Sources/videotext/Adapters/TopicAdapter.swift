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
