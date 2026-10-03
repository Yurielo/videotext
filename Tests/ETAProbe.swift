import Foundation

@main
struct ETAProbe {
    static func main() async throws {
        let url = (URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path, isDirectory: true)).appendingPathComponent("videotext-eta-probe-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ETAHistoryStore(url: url)
        let context = ETAContext(mediaDuration: 100, model: "whisper-test", language: "ru", codec: "mp4", hardware: "test")
        var cold: [WorkflowProgress] = []
        let coldTracker = WorkflowProgressTracker(operations: [.transcribe], context: context, history: store) { cold.append($0) }
        coldTracker.begin(.transcribe)
        coldTracker.update(.transcribe, fraction: 0.5)
        try require(cold.last?.estimatedTotal == nil, "cold-start показал ненадёжный ETA")
        coldTracker.finish(.transcribe, recordActual: false)
        try require(store.load().isEmpty, "пропущенная/служебная операция попала в историю")

        for duration in [40.0, 44.0] {
            store.append(ETAHistorySample(operation: .transcribe, context: context, predictedDuration: nil, actualDuration: duration, createdAt: Date()))
        }
        var warm: [WorkflowProgress] = []
        let warmTracker = WorkflowProgressTracker(operations: [.transcribe], context: context, history: store) { warm.append($0) }
        warmTracker.begin(.transcribe)
        warmTracker.update(.transcribe, fraction: 0.2)
        let firstRemaining = try required(warm.last?.remaining, "warm ETA отсутствует")
        warmTracker.update(.transcribe, fraction: 0.8)
        let secondRemaining = try required(warm.last?.remaining, "warm ETA исчез")
        try require(firstRemaining >= secondRemaining, "ETA вырос при продвижении операции")
        try require(secondRemaining >= 1, "ETA достиг нуля до завершения")
        try await Task.sleep(nanoseconds: 80_000_000)
        warmTracker.finish(.transcribe)
        let samples = store.load()
        try require(samples.count == 3 && samples.last?.predictedDuration != nil, "прогноз и факт не сохранены")
        print("ETA_PROBE_PASS")
    }

    private static func required(_ value: Double?, _ message: String) throws -> Double {
        guard let value else { throw ProbeFailure(message: message) }
        return value
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
