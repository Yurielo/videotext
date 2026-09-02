import Foundation

struct SRTParseResult {
    var cues: [SubtitleCue]
    var skippedZeroDurationCount: Int
}

struct SRTService {
    func parse(_ text: String) throws -> [SubtitleCue] {
        try parseWithReport(text).cues
    }

    func parseWithReport(_ text: String) throws -> SRTParseResult {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !blocks.isEmpty else { throw WorkflowError.invalidSRT("файл не содержит субтитров.") }
        var cues: [SubtitleCue] = []
        var skippedZeroDurationCount = 0

        for (blockIndex, block) in blocks.enumerated() {
            let lines = block.components(separatedBy: "\n")
            guard lines.count >= 3, let id = Int(lines[0].trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw WorkflowError.invalidSRT("некорректный номер или текст в блоке \(blockIndex + 1).")
            }
            let times = lines[1].components(separatedBy: " --> ")
            guard times.count == 2,
                  let start = parseTimestamp(times[0]),
                  let end = parseTimestamp(times[1]),
                  end >= start else {
                throw WorkflowError.invalidSRT("некорректный временной диапазон в блоке \(blockIndex + 1).")
            }
            let text = lines.dropFirst(2).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw WorkflowError.invalidSRT("пустой текст в блоке \(blockIndex + 1).") }
            if end == start {
                skippedZeroDurationCount += 1
                continue
            }
            cues.append(SubtitleCue(id: id, start: start, end: end, text: text))
        }
        guard !cues.isEmpty else { throw WorkflowError.invalidSRT("файл содержит только реплики нулевой длительности.") }
        return SRTParseResult(cues: cues, skippedZeroDurationCount: skippedZeroDurationCount)
    }

    func load(from url: URL) throws -> [SubtitleCue] {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    func loadWithReport(from url: URL) throws -> SRTParseResult {
        try parseWithReport(String(contentsOf: url, encoding: .utf8))
    }

    func write(_ cues: [SubtitleCue], to url: URL) throws {
        let body = cues.enumerated().map { index, cue in
            "\(index + 1)\n\(formatTimestamp(cue.start)) --> \(formatTimestamp(cue.end))\n\(cue.text)"
        }.joined(separator: "\n\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    func writePreservingIDs(_ cues: [SubtitleCue], to url: URL) throws {
        let body = cues.map { cue in
            "\(cue.id)\n\(formatTimestamp(cue.start)) --> \(formatTimestamp(cue.end))\n\(cue.text)"
        }.joined(separator: "\n\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    func cues(in cues: [SubtitleCue], start: TimeInterval, end: TimeInterval, rebased: Bool) -> [SubtitleCue] {
        cues.compactMap { cue in
            let clippedStart = max(cue.start, start)
            let clippedEnd = min(cue.end, end)
            guard clippedEnd > clippedStart else { return nil }
            let offset = rebased ? start : 0
            return SubtitleCue(id: cue.id, start: clippedStart - offset, end: clippedEnd - offset, text: cue.text)
        }
    }

    func cues(_ cues: [SubtitleCue], adjustedForSpeed factor: Double) throws -> [SubtitleCue] {
        guard factor >= 0.5, factor <= 2 else {
            throw WorkflowError.processFailed("Коэффициент скорости должен быть от 0.5 до 2.0.")
        }
        return cues.map { cue in
            SubtitleCue(
                id: cue.id,
                start: cue.start / factor,
                end: cue.end / factor,
                text: cue.text
            )
        }
    }

    func topics(
        _ file: TopicsFile,
        adjustedForSpeed factor: Double,
        sourceRange: ClosedRangeRecord? = nil
    ) throws -> TopicsFile {
        guard factor >= 0.5, factor <= 2 else {
            throw WorkflowError.processFailed("Коэффициент скорости должен быть от 0.5 до 2.0.")
        }
        var adjusted = file
        adjusted.createdAt = Date()
        adjusted.sourceSignature = StableTopicHash.string("\(file.sourceSignature)|speed:\(factor)")
        let rangeStart = sourceRange?.start ?? 0
        let rangeEnd = sourceRange?.end ?? .greatestFiniteMagnitude
        adjusted.topics = file.topics.compactMap { topic in
            let clippedStart = max(topic.start, rangeStart)
            let clippedEnd = min(topic.end, rangeEnd)
            guard clippedEnd > clippedStart else { return nil }
            var value = topic
            value.id = "speed-\(factor)-\(topic.id)"
            value.start = (clippedStart - rangeStart) / factor
            value.end = (clippedEnd - rangeStart) / factor
            value.duration = max(0, value.end - value.start)
            return value
        }
        return adjusted
    }

    func reviewTasks(
        _ tasks: [ReviewTask],
        language: ArtifactLanguage,
        adjustedForSpeed factor: Double,
        sourceRange: ClosedRangeRecord? = nil
    ) throws -> [ReviewTask] {
        guard factor >= 0.5, factor <= 2 else {
            throw WorkflowError.processFailed("Коэффициент скорости должен быть от 0.5 до 2.0.")
        }
        return tasks.compactMap { task in
            guard task.language == language else { return nil }
            let rangeStart = sourceRange?.start ?? 0
            let rangeEnd = sourceRange?.end ?? .greatestFiniteMagnitude
            let clippedStart = max(task.start, rangeStart)
            let clippedEnd = min(task.end, rangeEnd)
            guard clippedEnd > clippedStart else { return nil }
            var adjusted = task
            adjusted.id = "speed-\(factor)-\(task.id)"
            adjusted.start = (clippedStart - rangeStart) / factor
            adjusted.end = (clippedEnd - rangeStart) / factor
            adjusted.createdAt = Date()
            return adjusted
        }
    }

    func validateTimeline(_ cues: [SubtitleCue], mediaDuration: TimeInterval?) -> [String] {
        var warnings: [String] = []
        if cues.isEmpty { warnings.append("SRT не содержит субтитров.") }
        var previousEnd: TimeInterval = 0
        var previousID = 0
        for cue in cues {
            if cue.end < cue.start {
                warnings.append("Субтитр \(cue.id): конец раньше начала.")
            }
            if cue.start < previousEnd {
                warnings.append("Субтитр \(cue.id): пересекается с предыдущим.")
            }
            if cue.start < 0 {
                warnings.append("Субтитр \(cue.id): начинается раньше нуля.")
            }
            if cue.id <= previousID {
                warnings.append("Субтитр \(cue.id): номера блоков нарушают порядок.")
            }
            if let mediaDuration, cue.end > mediaDuration + 1 {
                warnings.append("Субтитр \(cue.id): выходит за длительность медиа.")
            }
            previousEnd = max(previousEnd, cue.end)
            previousID = cue.id
        }
        return warnings
    }

    func parseTimestamp(_ value: String) -> TimeInterval? {
        let parts = value.trimmingCharacters(in: .whitespaces).components(separatedBy: CharacterSet(charactersIn: ":,"))
        guard parts.count == 4,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]),
              let milliseconds = Double(parts[3]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds + milliseconds / 1000
    }

    func formatTimestamp(_ time: TimeInterval) -> String {
        let clamped = max(0, time)
        let totalMilliseconds = Int((clamped * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let seconds = (totalMilliseconds % 60_000) / 1000
        let milliseconds = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, milliseconds)
    }
}
