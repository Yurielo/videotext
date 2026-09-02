import Foundation

enum TimecodeParser {
    static func parse(_ rawValue: String) throws -> TimeInterval {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw WorkflowError.invalidTimecode(rawValue) }
        if !value.contains(":") {
            let normalized = value.replacingOccurrences(of: ",", with: ".")
            guard let seconds = TimeInterval(normalized), seconds >= 0 else {
                throw WorkflowError.invalidTimecode(rawValue)
            }
            return seconds
        }

        let components = value.replacingOccurrences(of: ",", with: ".").split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 3,
              let hours = Double(components[0]),
              let minutes = Double(components[1]),
              let seconds = Double(components[2]),
              hours >= 0,
              (0..<60).contains(minutes),
              (0..<60).contains(seconds) else {
            throw WorkflowError.invalidTimecode(rawValue)
        }
        return hours * 3600 + minutes * 60 + seconds
    }

    static func display(_ interval: TimeInterval) -> String {
        let totalMilliseconds = Int((max(0, interval) * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let seconds = (totalMilliseconds % 60_000) / 1000
        let milliseconds = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
    }

    static func identifier(_ interval: TimeInterval) -> String {
        display(interval)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "_")
    }
}

enum TopicPickerFormatter {
    private static let maximumTitleLength = 36

    static func title(for topic: TopicSegment) -> String {
        let start = displayedSeconds(topic.start)
        let end = max(start, displayedSeconds(topic.end))
        let range = "\(clock(start))–\(clock(end))"
        let duration = TimeTextFormatter.string(TimeInterval(end - start))
        return "\(topic.id) · \(range) · \(duration) · \(shortTitle(topic.title))"
    }

    static func help(for topic: TopicSegment) -> String {
        """
        \(topic.id): \(topic.title)
        Начало: \(TimecodeParser.display(topic.start))
        Конец: \(TimecodeParser.display(topic.end))
        Длительность: \(TimecodeParser.display(max(0, topic.end - topic.start)))
        """
    }

    private static func displayedSeconds(_ interval: TimeInterval) -> Int {
        max(0, Int(interval.rounded()))
    }

    private static func clock(_ totalSeconds: Int) -> String {
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private static func shortTitle(_ title: String) -> String {
        guard title.count > maximumTitleLength else { return title }
        return String(title.prefix(maximumTitleLength - 1)) + "…"
    }
}
