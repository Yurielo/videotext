import Foundation

@main
struct TopicReviewCueContextProbe {
    static func main() {
        do {
            let cues = (1...6).map { id in
                SubtitleCue(id: id, start: Double(id - 1) * 10, end: Double(id) * 10, text: "Реплика \(id)")
            }
            let topics = [
                topic(id: "topic-1", cueIDs: [1, 2, 3]),
                topic(id: "topic-2", cueIDs: [4, 5, 6])
            ]
            guard let first = TopicReviewCueContext(topic: topics[0], topics: topics, cues: cues) else {
                throw ProbeFailure(message: "не создан контекст первой темы")
            }
            try require(first.contextCues.map(\.id) == [1, 2, 3, 4, 5], "контекст первой темы не содержит соседние cue")
            try require(first.startChoices.map(\.id) == [1], "начало первой темы не зафиксировано")
            try require(first.endChoices.map(\.id) == [1, 2, 3, 4, 5], "не показаны допустимые cue конца первой темы")
            try require(first.role(for: cues[3]) == .after, "соседняя cue не отмечена после границы")

            guard let second = TopicReviewCueContext(topic: topics[1], topics: topics, cues: cues) else {
                throw ProbeFailure(message: "не создан контекст второй темы")
            }
            try require(second.contextCues.map(\.id) == [2, 3, 4, 5, 6], "контекст второй темы не содержит соседние cue")
            try require(second.startChoices.map(\.id) == [2, 3, 4, 5, 6], "не показаны допустимые cue начала второй темы")
            try require(second.endChoices.map(\.id) == [6], "конец последней темы не зафиксирован")
            try require(second.role(for: cues[1]) == .before, "соседняя cue не отмечена до границы")
            print("TOPIC_REVIEW_CUE_CONTEXT_PROBE_PASS")
        } catch {
            fputs("TOPIC_REVIEW_CUE_CONTEXT_PROBE_FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func topic(id: String, cueIDs: [Int]) -> TopicSegment {
        TopicSegment(
            id: id,
            title: id,
            start: Double((cueIDs.first ?? 1) - 1) * 10,
            end: Double(cueIDs.last ?? 1) * 10,
            summary: id,
            keywords: [],
            confidence: 1,
            boundaryReason: "probe",
            sourceCueStart: cueIDs.first,
            sourceCueEnd: cueIDs.last,
            cueIds: cueIDs
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
