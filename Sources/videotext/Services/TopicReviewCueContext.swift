import Foundation

/// Read-only cue ranges used by the Topic Human Review surface.
/// The editor still delegates every persisted change to TopicFileService.
struct TopicReviewCueContext {
    let topicIndex: Int
    let topicCount: Int
    let contextCues: [SubtitleCue]
    let startChoices: [SubtitleCue]
    let endChoices: [SubtitleCue]
    let currentStartCueID: Int
    let currentEndCueID: Int
    private let insideCueIDs: Set<Int>
    private let beforeCueIDs: Set<Int>

    init?(topic: TopicSegment, topics: [TopicSegment], cues: [SubtitleCue]) {
        guard let topicIndex = topics.firstIndex(where: { $0.id == topic.id }) else { return nil }

        let meaningfulIDs = Set(TopicTextPreprocessor().prepare(cues).flatMap(\.cueIDs))
        let orderedCues = cues
            .filter { meaningfulIDs.contains($0.id) }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        let positions = Dictionary(uniqueKeysWithValues: orderedCues.enumerated().map { ($0.element.id, $0.offset) })
        guard let currentStartCueID = topic.cueIds.first,
              let currentEndCueID = topic.cueIds.last,
              let currentStart = positions[currentStartCueID],
              let currentEnd = positions[currentEndCueID],
              currentStart <= currentEnd else { return nil }

        let startRange: ClosedRange<Int>
        if topicIndex == 0 {
            startRange = currentStart...currentStart
        } else {
            guard let previousStartID = topics[topicIndex - 1].cueIds.first,
                  let previousStart = positions[previousStartID],
                  previousStart < currentEnd else { return nil }
            startRange = (previousStart + 1)...currentEnd
        }

        let endRange: ClosedRange<Int>
        if topicIndex == topics.count - 1 {
            endRange = currentEnd...currentEnd
        } else {
            guard let nextEndID = topics[topicIndex + 1].cueIds.last,
                  let nextEnd = positions[nextEndID],
                  currentStart < nextEnd else { return nil }
            endRange = currentStart...(nextEnd - 1)
        }

        let contextStart = max(0, currentStart - 2)
        let contextEnd = min(orderedCues.count - 1, currentEnd + 2)
        self.topicIndex = topicIndex
        self.topicCount = topics.count
        self.contextCues = Array(orderedCues[contextStart...contextEnd])
        self.startChoices = Array(orderedCues[startRange])
        self.endChoices = Array(orderedCues[endRange])
        self.currentStartCueID = currentStartCueID
        self.currentEndCueID = currentEndCueID
        self.insideCueIDs = Set(topic.cueIds)
        self.beforeCueIDs = Set(orderedCues[contextStart..<currentStart].map(\.id))
    }

    func cue(id: Int) -> SubtitleCue? {
        contextCues.first(where: { $0.id == id })
            ?? startChoices.first(where: { $0.id == id })
            ?? endChoices.first(where: { $0.id == id })
    }

    func role(for cue: SubtitleCue) -> Role {
        if insideCueIDs.contains(cue.id) { return .inside }
        return beforeCueIDs.contains(cue.id) ? .before : .after
    }

    enum Role {
        case before
        case inside
        case after
    }
}
