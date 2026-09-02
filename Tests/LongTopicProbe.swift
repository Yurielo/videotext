import Foundation

enum LongTopicProbeError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

@main
struct LongTopicProbe {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3 else {
                throw LongTopicProbeError.failed("Использование: LongTopicProbe <full.srt> <тестовый-проект>")
            }
            let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
            let projectURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let layout = ProjectLayout(root: projectURL)
            try layout.createDirectories()
            if sourceURL.standardizedFileURL != layout.fullSRTURL.standardizedFileURL {
                try FileManager.default.copyReplacingItem(at: sourceURL, to: layout.fullSRTURL)
            }

            let parsed = try SRTService().loadWithReport(from: layout.fullSRTURL)
            let duration = parsed.cues.map(\.end).max() ?? 0
            guard duration > 3_600 else {
                throw LongTopicProbeError.failed("Для длинного теста требуется SRT длительностью больше часа.")
            }
            print("LONG TOPIC SOURCE: \(parsed.cues.count) cue, \(Int(duration)) sec, skipped zero: \(parsed.skippedZeroDurationCount)")

            let started = Date()
            let file = try await HybridTopicAdapter().buildTopics(
                from: parsed.cues,
                sourceSRT: layout.fullSRTURL,
                context: TopicBuildContext(projectURL: projectURL, mediaDuration: duration, granularity: .normal),
                onProgress: { progress in
                    print(String(format: "LONG TOPIC PROGRESS: %.1f%%", progress * 100))
                },
                onLog: { print($0) }
            )
            try TopicFileService().save(file, projectURL: projectURL)

            let meaningfulIDs = Set(TopicTextPreprocessor().prepare(parsed.cues).flatMap(\.cueIDs))
            let meaningfulCues = parsed.cues
                .filter { meaningfulIDs.contains($0.id) }
                .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
            let issues = TopicValidator().validate(file, expectedCues: meaningfulCues, mediaDuration: duration)
            try require(issues.isEmpty, "строгая проверка не пройдена: \(issues.joined(separator: " "))")
            try require(file.status == .ready, "результат не имеет статус ready")
            try require(file.schemaVersion == 2, "неверная версия схемы")
            try require(file.topics.count >= 8, "для длинной расшифровки создано подозрительно мало тем: \(file.topics.count)")
            try require(file.topics.count <= 100, "для длинной расшифровки создано механически много тем: \(file.topics.count)")

            let normalizedTitles = file.topics.map { normalized($0.title) }
            try require(Set(normalizedTitles).count == normalizedTitles.count, "найдены повторяющиеся названия")
            let generic = ["основная тема видео", "продолжение основной темы", "обсуждение разных вопросов", "введение в основную тему"]
            try require(!normalizedTitles.contains(where: { generic.contains($0) }), "найдено общее название темы")
            let durationBuckets = Set(file.topics.map { Int(($0.duration / 10).rounded()) })
            try require(durationBuckets.count >= min(4, file.topics.count), "длительности тем выглядят как механическая нарезка")
            try require(file.topics.allSatisfy { !$0.boundaryReason.isEmpty }, "есть тема без причины границы")

            let sampleIndices = Array(Set([0, file.topics.count / 2, file.topics.count - 1])).sorted()
            var report = [
                "videotext long topic quality",
                "source: \(sourceURL.path)",
                "project: \(projectURL.path)",
                "topics: \(file.topics.count)",
                "models: \(file.embeddingModel ?? ""), \(file.languageModel ?? "")",
                "elapsed: \(Int(Date().timeIntervalSince(started))) sec",
                "samples:"
            ]
            for index in sampleIndices {
                let topic = file.topics[index]
                let line = "\(index + 1). \(timestamp(topic.start))-\(timestamp(topic.end)) | cue \(topic.sourceCueStart)-\(topic.sourceCueEnd) | \(topic.title)"
                report.append(line)
                print("LONG TOPIC SAMPLE: \(line)")
            }
            let reportURL = layout.supportDirectory.appendingPathComponent("long-topic-quality.txt")
            try (report.joined(separator: "\n") + "\n").write(to: reportURL, atomically: true, encoding: .utf8)
            print("LONG TOPIC PASS: \(file.topics.count) topics; \(reportURL.path)")
        } catch {
            fputs("LONG TOPIC FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func timestamp(_ value: TimeInterval) -> String {
        let seconds = Int(value.rounded())
        return String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw LongTopicProbeError.failed(message) }
    }
}

private extension FileManager {
    func copyReplacingItem(at source: URL, to destination: URL) throws {
        if fileExists(atPath: destination.path) {
            let existing = try Data(contentsOf: destination)
            let incoming = try Data(contentsOf: source)
            if existing == incoming { return }
            try removeItem(at: destination)
        }
        try copyItem(at: source, to: destination)
    }
}
