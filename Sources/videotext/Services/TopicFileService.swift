import Foundation

struct TopicFileService {
    private let srt = SRTService()
    private let validator = TopicValidator()

    func save(_ file: TopicsFile, projectURL: URL) throws {
        let layout = ProjectLayout(root: projectURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(file).write(to: layout.topicsURL, options: .atomic)
        try textRepresentation(file).write(to: layout.topicsTextURL, atomically: true, encoding: .utf8)
    }

    func save(
        _ file: TopicsFile,
        projectURL: URL,
        language: ArtifactLanguage,
        granularity: TopicGranularity,
        updateLegacyFiles: Bool
    ) throws {
        let layout = ProjectLayout(root: projectURL)
        let jsonURL = layout.topicsURL(language: language, granularity: granularity)
        let textURL = layout.topicsTextURL(language: language, granularity: granularity)
        try FileManager.default.createDirectory(at: jsonURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(file).write(to: jsonURL, options: .atomic)
        try textRepresentation(file).write(to: textURL, atomically: true, encoding: .utf8)
        if updateLegacyFiles {
            try encoder.encode(file).write(to: layout.topicsURL, options: .atomic)
            try textRepresentation(file).write(to: layout.topicsTextURL, atomically: true, encoding: .utf8)
        }
    }

    func update(
        projectURL: URL,
        id: String,
        title: String,
        start: TimeInterval,
        end: TimeInterval
    ) throws -> TopicsFile {
        var file = try WorkflowEngine.loadTopics(projectURL: projectURL)
        guard let index = file.topics.firstIndex(where: { $0.id == id }) else { throw WorkflowError.missingTopics }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, end > start else { throw WorkflowError.invalidRange }
        let cues = try meaningfulCues(projectURL)
        let cuePositions = Dictionary(uniqueKeysWithValues: cues.enumerated().map { ($0.element.id, $0.offset) })
        guard let currentStart = cuePositions[file.topics[index].sourceCueStart],
              let currentEnd = cuePositions[file.topics[index].sourceCueEnd] else {
            throw WorkflowError.invalidTopics("выбранная тема содержит неизвестные cueId.")
        }

        let startPosition: Int
        if index == 0 {
            startPosition = 0
        } else {
            guard let previousStart = cuePositions[file.topics[index - 1].sourceCueStart] else {
                throw WorkflowError.invalidTopics("предыдущая тема содержит неизвестные cueId.")
            }
            startPosition = nearestCuePosition(
                to: start,
                in: (previousStart + 1)...currentEnd,
                cues: cues,
                keyPath: \.start
            )
        }

        let endPosition: Int
        if index == file.topics.count - 1 {
            endPosition = cues.count - 1
        } else {
            guard let nextEnd = cuePositions[file.topics[index + 1].sourceCueEnd] else {
                throw WorkflowError.invalidTopics("следующая тема содержит неизвестные cueId.")
            }
            endPosition = nearestCuePosition(
                to: end,
                in: max(startPosition, currentStart)...(nextEnd - 1),
                cues: cues,
                keyPath: \.end
            )
        }
        guard startPosition <= endPosition else { throw WorkflowError.invalidRange }

        if index > 0 {
            guard let previousStart = cuePositions[file.topics[index - 1].sourceCueStart] else {
                throw WorkflowError.invalidTopics("предыдущая тема содержит неизвестные cueId.")
            }
            applyCueRange(previousStart...(startPosition - 1), to: &file.topics[index - 1], cues: cues)
        }
        applyCueRange(startPosition...endPosition, to: &file.topics[index], cues: cues)
        if index + 1 < file.topics.count {
            guard let nextEnd = cuePositions[file.topics[index + 1].sourceCueEnd] else {
                throw WorkflowError.invalidTopics("следующая тема содержит неизвестные cueId.")
            }
            applyCueRange((endPosition + 1)...nextEnd, to: &file.topics[index + 1], cues: cues)
            file.topics[index + 1].boundaryReason = "Граница изменена пользователем."
        }
        file.topics[index].title = cleanTitle
        file.topics[index].boundaryReason = index == 0
            ? file.topics[index].boundaryReason
            : "Граница изменена пользователем."
        file.createdAt = Date()
        return try validateAndSave(file, projectURL: projectURL)
    }

    func split(projectURL: URL, id: String) throws -> TopicsFile {
        var file = try WorkflowEngine.loadTopics(projectURL: projectURL)
        guard let index = file.topics.firstIndex(where: { $0.id == id }) else { throw WorkflowError.missingTopics }
        let original = file.topics[index]
        let cueMap = try cueMap(projectURL)
        let cues = original.cueIds.compactMap { cueMap[$0] }.sorted { $0.start < $1.start }
        guard cues.count >= 2 else {
            throw WorkflowError.invalidTopics("в теме недостаточно реплик для разделения.")
        }
        let splitIndex = cues.count / 2
        let leftCues = Array(cues[..<splitIndex])
        let rightCues = Array(cues[splitIndex...])
        let leftIDs = leftCues.map(\.id)
        let rightIDs = rightCues.map(\.id)
        let left = TopicSegment(
            id: original.id,
            title: splitTitle(original.title, part: 1),
            start: original.start,
            end: leftCues.last!.end,
            summary: original.summary,
            keywords: original.keywords,
            confidence: min(original.confidence, 0.7),
            boundaryReason: original.boundaryReason,
            sourceCueStart: leftIDs.min(),
            sourceCueEnd: leftIDs.max(),
            cueIds: leftIDs
        )
        let right = TopicSegment(
            id: "temporary",
            title: splitTitle(original.title, part: 2),
            start: rightCues.first!.start,
            end: original.end,
            summary: original.summary,
            keywords: original.keywords,
            confidence: min(original.confidence, 0.7),
            boundaryReason: "Тема разделена пользователем.",
            sourceCueStart: rightIDs.min(),
            sourceCueEnd: rightIDs.max(),
            cueIds: rightIDs
        )
        file.topics.replaceSubrange(index...index, with: [left, right])
        normalizeIDs(&file)
        return try validateAndSave(file, projectURL: projectURL)
    }

    func mergeWithNext(projectURL: URL, id: String) throws -> TopicsFile {
        var file = try WorkflowEngine.loadTopics(projectURL: projectURL)
        guard let index = file.topics.firstIndex(where: { $0.id == id }), index + 1 < file.topics.count else {
            throw WorkflowError.invalidTopics("после выбранной темы нет раздела для объединения.")
        }
        file.topics[index] = merged(file.topics[index], file.topics[index + 1])
        file.topics.remove(at: index + 1)
        normalizeIDs(&file)
        return try validateAndSave(file, projectURL: projectURL)
    }

    func removeBoundary(projectURL: URL, id: String) throws -> TopicsFile {
        var file = try WorkflowEngine.loadTopics(projectURL: projectURL)
        guard file.topics.count > 1,
              let index = file.topics.firstIndex(where: { $0.id == id }) else {
            throw WorkflowError.invalidTopics("единственную тему удалить нельзя.")
        }
        if index > 0 {
            file.topics[index - 1] = merged(file.topics[index - 1], file.topics[index])
            file.topics.remove(at: index)
        } else {
            file.topics[1] = merged(file.topics[0], file.topics[1], preferRightTitle: true)
            file.topics.remove(at: 0)
        }
        normalizeIDs(&file)
        return try validateAndSave(file, projectURL: projectURL)
    }

    private func validateAndSave(_ file: TopicsFile, projectURL: URL) throws -> TopicsFile {
        let cues = try meaningfulCues(projectURL)
        let duration = (try? ProjectStore().load(from: projectURL))?.durationSeconds
        let issues = validator.validate(file, expectedCues: cues, mediaDuration: duration)
        guard issues.isEmpty else { throw WorkflowError.invalidTopics(issues.joined(separator: " ")) }
        try save(file, projectURL: projectURL)
        return file
    }

    private func meaningfulCues(_ projectURL: URL) throws -> [SubtitleCue] {
        let cues = try srt.load(from: ProjectLayout(root: projectURL).fullSRTURL)
        let meaningfulIDs = Set(TopicTextPreprocessor().prepare(cues).flatMap(\.cueIDs))
        return cues
            .filter { meaningfulIDs.contains($0.id) }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }

    private func nearestCuePosition(
        to value: TimeInterval,
        in range: ClosedRange<Int>,
        cues: [SubtitleCue],
        keyPath: KeyPath<SubtitleCue, TimeInterval>
    ) -> Int {
        range.min { lhs, rhs in
            abs(cues[lhs][keyPath: keyPath] - value) < abs(cues[rhs][keyPath: keyPath] - value)
        } ?? range.lowerBound
    }

    private func applyCueRange(_ range: ClosedRange<Int>, to topic: inout TopicSegment, cues: [SubtitleCue]) {
        let selected = Array(cues[range])
        topic.cueIds = selected.map(\.id)
        topic.sourceCueStart = selected.first!.id
        topic.sourceCueEnd = selected.last!.id
        topic.start = selected.first!.start
        topic.end = selected.last!.end
        topic.duration = topic.end - topic.start
    }

    private func cueMap(_ projectURL: URL) throws -> [Int: SubtitleCue] {
        let cues = try srt.load(from: ProjectLayout(root: projectURL).fullSRTURL)
        return Dictionary(uniqueKeysWithValues: cues.map { ($0.id, $0) })
    }

    private func merged(_ left: TopicSegment, _ right: TopicSegment, preferRightTitle: Bool = false) -> TopicSegment {
        let cueIDs = left.cueIds + right.cueIds
        let summary = [left.summary, right.summary].filter { !$0.isEmpty }.joined(separator: " ")
        var keywords: [String] = []
        for keyword in left.keywords + right.keywords where !keywords.contains(keyword) { keywords.append(keyword) }
        return TopicSegment(
            id: left.id,
            title: preferRightTitle ? right.title : left.title,
            start: left.start,
            end: right.end,
            summary: summary,
            keywords: Array(keywords.prefix(8)),
            confidence: min(left.confidence, right.confidence),
            boundaryReason: preferRightTitle ? right.boundaryReason : left.boundaryReason,
            sourceCueStart: cueIDs.min(),
            sourceCueEnd: cueIDs.max(),
            cueIds: cueIDs
        )
    }

    private func splitTitle(_ title: String, part: Int) -> String {
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(5)
        return words.map(String.init).joined(separator: " ") + " часть \(part)"
    }

    private func normalizeIDs(_ file: inout TopicsFile) {
        for index in file.topics.indices { file.topics[index].id = "topic-\(index + 1)" }
        file.createdAt = Date()
    }

    private func textRepresentation(_ file: TopicsFile) -> String {
        let header = file.status == .ready ? "Статус: готов" : "Статус: черновой"
        let body = file.topics.map { topic in
            let confidence = Int((topic.confidence * 100).rounded())
            return """
            \(srt.formatTimestamp(topic.start)) --> \(srt.formatTimestamp(topic.end))
            \(topic.title)
            \(topic.summary)
            Ключевые слова: \(topic.keywords.joined(separator: ", "))
            Уверенность: \(confidence)%
            Причина границы: \(topic.boundaryReason)
            """
        }.joined(separator: "\n\n")
        return "\(header)\nДетализация: \(file.granularity.title)\n\n\(body)\n"
    }
}
