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
        let cueMap = try cueMap(projectURL)
        let cueIDs = file.topics[index].cueIds
        guard let first = cueIDs.compactMap({ cueMap[$0] }).min(by: { $0.start < $1.start }),
              let last = cueIDs.compactMap({ cueMap[$0] }).max(by: { $0.end < $1.end }),
              start <= first.start + 0.001,
              end >= last.end - 0.001 else {
            throw WorkflowError.invalidTopics("новые границы должны включать все реплики выбранной темы. Для переноса реплик сначала разделите или объедините темы.")
        }
        if index > 0, start < file.topics[index - 1].end - 0.001 {
            throw WorkflowError.invalidTopics("начало пересекается с предыдущей темой.")
        }
        if index + 1 < file.topics.count, end > file.topics[index + 1].start + 0.001 {
            throw WorkflowError.invalidTopics("конец пересекается со следующей темой.")
        }
        file.topics[index].title = cleanTitle
        file.topics[index].start = start
        file.topics[index].end = end
        file.topics[index].duration = end - start
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
        let leftTitle = splitTitle(original.title, part: 1)
        let rightTitle = splitTitle(original.title, part: 2)
        let left = TopicSegment(
            id: original.id,
            title: leftTitle,
            start: original.start,
            end: leftCues.last!.end,
            summary: original.summary,
            keywords: original.keywords,
            confidence: min(original.confidence, 0.7),
            sourceCueStart: leftCues.map(\.id).min(),
            sourceCueEnd: leftCues.map(\.id).max(),
            cueIds: leftCues.map(\.id)
        )
        let right = TopicSegment(
            id: "temporary",
            title: rightTitle,
            start: rightCues.first!.start,
            end: original.end,
            summary: original.summary,
            keywords: original.keywords,
            confidence: min(original.confidence, 0.7),
            sourceCueStart: rightCues.map(\.id).min(),
            sourceCueEnd: rightCues.map(\.id).max(),
            cueIds: rightCues.map(\.id)
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
        let layout = ProjectLayout(root: projectURL)
        let cues = try srt.load(from: layout.fullSRTURL)
        let expected = Set(TopicTextPreprocessor().prepare(cues).flatMap(\.cueIDs))
        let duration = try? ProjectStore().load(from: projectURL).durationSeconds
        let issues = validator.validate(file, expectedCueIDs: expected, mediaDuration: duration ?? nil)
        guard issues.isEmpty else { throw WorkflowError.invalidTopics(issues.joined(separator: " ")) }
        try save(file, projectURL: projectURL)
        return file
    }

    private func cueMap(_ projectURL: URL) throws -> [Int: SubtitleCue] {
        let cues = try srt.load(from: ProjectLayout(root: projectURL).fullSRTURL)
        return Dictionary(uniqueKeysWithValues: cues.map { ($0.id, $0) })
    }

    private func merged(_ left: TopicSegment, _ right: TopicSegment, preferRightTitle: Bool = false) -> TopicSegment {
        let cueIDs = left.cueIds + right.cueIds
        let title = preferRightTitle ? right.title : left.title
        let summary = [left.summary, right.summary].filter { !$0.isEmpty }.joined(separator: " ")
        var keywords: [String] = []
        for keyword in left.keywords + right.keywords where !keywords.contains(keyword) { keywords.append(keyword) }
        return TopicSegment(
            id: left.id,
            title: title,
            start: left.start,
            end: right.end,
            summary: summary,
            keywords: Array(keywords.prefix(8)),
            confidence: min(left.confidence, right.confidence),
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
            let keywords = topic.keywords.joined(separator: ", ")
            return """
            \(srt.formatTimestamp(topic.start)) --> \(srt.formatTimestamp(topic.end))
            \(topic.title)
            \(topic.summary)
            Ключевые слова: \(keywords)
            Уверенность: \(confidence)%
            """
        }.joined(separator: "\n\n")
        return "\(header)\nДетализация: \(file.granularity.title)\n\n\(body)\n"
    }
}
