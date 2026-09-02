import Foundation

@main
struct SpeedAdjustmentProbe {
    static func main() throws {
        let service = SRTService()
        let source = [
            SubtitleCue(id: 7, start: 2, end: 5, text: "Первая реплика"),
            SubtitleCue(id: 9, start: 8, end: 12, text: "Second cue")
        ]
        let faster = try service.cues(source, adjustedForSpeed: 2)
        try require(faster.map(\.id) == [7, 9], "идентификаторы cue изменились")
        try require(faster[0].start == 1 && faster[0].end == 2.5, "шкала 2x рассчитана неверно")
        let slower = try service.cues(source, adjustedForSpeed: 0.5)
        try require(slower[1].start == 16 && slower[1].end == 24, "шкала 0.5x рассчитана неверно")

        let topics = TopicsFile(
            adapter: TopicAlgorithmIdentity.hybridAdapter,
            createdAt: Date(),
            sourceSRT: "/source.srt",
            sourceSignature: "source",
            topics: [TopicSegment(id: "topic-1", title: "Тема", start: 10, end: 30, keywords: [], cueIds: [1])]
        )
        let adjustedTopics = try service.topics(
            topics,
            adjustedForSpeed: 2,
            sourceRange: ClosedRangeRecord(start: 20, end: 40)
        )
        try require(adjustedTopics.topics[0].start == 0 && adjustedTopics.topics[0].end == 5, "тема фрагмента не обрезана и не перебазирована")

        let review = ReviewTask(
            id: "review-1",
            transcriptRevisionID: "revision",
            status: .needsReview,
            language: .ru,
            start: 18,
            end: 24,
            cueIDs: [1],
            reasonCodes: ["confidence"],
            confidence: 0.2,
            originalText: "Текст",
            suggestedText: nil,
            createdAt: Date(),
            resolvedAt: nil,
            dependentArtifactIDs: []
        )
        let adjustedReview = try service.reviewTasks(
            [review],
            language: .ru,
            adjustedForSpeed: 2,
            sourceRange: ClosedRangeRecord(start: 20, end: 40)
        )
        try require(adjustedReview[0].start == 0 && adjustedReview[0].end == 2, "review task фрагмента пересчитан неверно")

        do {
            _ = try service.cues(source, adjustedForSpeed: 2.1)
            throw ProbeFailure(message: "недопустимый коэффициент принят")
        } catch let error as WorkflowError {
            guard case .processFailed = error else { throw error }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("videotext-speed-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ProjectLayout(root: root)
        try layout.createDirectories()
        let video = layout.speedAdjustedVideoURL(source: .fullVideo, language: .ru, factor: 1.25)
        let subtitles = layout.speedAdjustedSRTURL(source: .fullVideo, language: .ru, factor: 1.25)
        let report = layout.speedAdjustmentReportURL(source: .fullVideo, language: .ru, factor: 1.25)
        try Data("video".utf8).write(to: video)
        try service.writePreservingIDs(faster, to: subtitles)
        try Data("{}".utf8).write(to: report)
        let kinds = Set(ResultsDetector().discover(in: root).map(\.kind))
        try require(kinds.contains("speed-adjusted-video"), "видео скорости не обнаружено")
        try require(kinds.contains("speed-adjusted-subtitles"), "SRT скорости не обнаружен")
        try require(kinds.contains("speed-adjustment"), "отчёт скорости не обнаружен")
        print("SPEED_ADJUSTMENT_PROBE_PASS")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
