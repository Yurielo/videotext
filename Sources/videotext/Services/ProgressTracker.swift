import Foundation

struct WorkflowProgress: Equatable {
    var operation: WorkflowOperation?
    var operationFraction: Double
    var overallFraction: Double
    var elapsed: TimeInterval
    var estimatedTotal: TimeInterval?
    var remaining: TimeInterval?
    var isIndeterminate: Bool

    static let idle = WorkflowProgress(operation: nil, operationFraction: 0, overallFraction: 0, elapsed: 0, estimatedTotal: nil, remaining: nil, isIndeterminate: true)
}

struct ETAContext: Codable, Equatable {
    var mediaDuration: TimeInterval?
    var model: String
    var language: String
    var codec: String
    var hardware: String
}

struct ETAHistorySample: Codable, Equatable {
    var operation: WorkflowOperation
    var context: ETAContext
    var predictedDuration: TimeInterval?
    var actualDuration: TimeInterval
    var createdAt: Date
}

struct ETAHistoryStore {
    let url: URL

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else if let override = ProcessInfo.processInfo.environment["VIDEOTEXT_ETA_HISTORY_PATH"] {
            self.url = URL(fileURLWithPath: override)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.url = support.appendingPathComponent("videotext/eta-history.json")
        }
    }

    func load() -> [ETAHistorySample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ETAHistorySample].self, from: data)) ?? []
    }

    func append(_ sample: ETAHistorySample) {
        var samples = load()
        samples.append(sample)
        if samples.count > 500 { samples.removeFirst(samples.count - 500) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(samples) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func expectedDuration(operation: WorkflowOperation, context: ETAContext) -> TimeInterval? {
        let all = load().filter { $0.operation == operation && $0.actualDuration > 0.05 }
        let exact = all.filter {
            $0.context.model == context.model && $0.context.language == context.language
                && $0.context.codec == context.codec && $0.context.hardware == context.hardware
        }
        if exact.count >= 2 { return estimate(exact, context: context) }
        return all.count >= 3 ? estimate(all, context: context) : nil
    }

    private func estimate(_ samples: [ETAHistorySample], context: ETAContext) -> TimeInterval? {
        let values: [Double]
        if let duration = context.mediaDuration, duration > 0,
           samples.filter({ ($0.context.mediaDuration ?? 0) > 0 }).count >= 2 {
            values = samples.compactMap { sample in
                guard let source = sample.context.mediaDuration, source > 0 else { return nil }
                return sample.actualDuration / source * duration
            }
        } else {
            values = samples.map(\.actualDuration)
        }
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

final class WorkflowProgressTracker {
    private let operations: [WorkflowOperation]
    private let totalWeight: Double
    private let startedAt = Date()
    private let onProgress: (WorkflowProgress) -> Void
    private let context: ETAContext
    private let history: ETAHistoryStore
    private var completedWeight = 0.0
    private var fractions: [WorkflowOperation: Double] = [:]
    private var operationStartedAt: Date?
    private var expectedDurations: [WorkflowOperation: TimeInterval] = [:]
    private var smoothedRemaining: TimeInterval?

    init(
        operations: [WorkflowOperation],
        context: ETAContext = ETAContext(mediaDuration: nil, model: "unknown", language: "unknown", codec: "unknown", hardware: "unknown"),
        history: ETAHistoryStore = ETAHistoryStore(),
        onProgress: @escaping (WorkflowProgress) -> Void
    ) {
        self.operations = operations
        self.context = context
        self.history = history
        totalWeight = max(operations.reduce(0) { $0 + $1.progressWeight }, 1)
        self.onProgress = onProgress
        for operation in operations {
            expectedDurations[operation] = history.expectedDuration(operation: operation, context: context)
        }
    }

    func begin(_ operation: WorkflowOperation, indeterminate: Bool = true) {
        fractions[operation] = 0
        operationStartedAt = Date()
        emit(operation: operation, fraction: 0, indeterminate: indeterminate)
    }

    func update(_ operation: WorkflowOperation, fraction: Double, indeterminate: Bool = false) {
        let clamped = min(max(fraction, fractions[operation] ?? 0), 0.999)
        fractions[operation] = clamped
        emit(operation: operation, fraction: clamped, indeterminate: indeterminate)
    }

    func finish(_ operation: WorkflowOperation, recordActual: Bool = true) {
        fractions[operation] = 1
        if recordActual, let operationStartedAt {
            history.append(ETAHistorySample(
                operation: operation,
                context: context,
                predictedDuration: expectedDurations[operation],
                actualDuration: Date().timeIntervalSince(operationStartedAt),
                createdAt: Date()
            ))
        }
        emit(operation: operation, fraction: 1, indeterminate: false)
        completedWeight += operation.progressWeight
        operationStartedAt = nil
    }

    func complete() {
        let elapsed = Date().timeIntervalSince(startedAt)
        onProgress(WorkflowProgress(operation: operations.last, operationFraction: 1, overallFraction: 1, elapsed: elapsed, estimatedTotal: elapsed, remaining: 0, isIndeterminate: false))
    }

    private func emit(operation: WorkflowOperation, fraction: Double, indeterminate: Bool) {
        let elapsed = Date().timeIntervalSince(startedAt)
        let overall = min(max((completedWeight + operation.progressWeight * fraction) / totalWeight, 0), 1)
        let currentIndex = operations.firstIndex(of: operation) ?? 0
        var current = expectedDurations[operation]
        if let historical = current, fraction >= 0.1, let operationStartedAt {
            let live = Date().timeIntervalSince(operationStartedAt) / fraction
            current = historical * 0.8 + min(max(live, historical * 0.5), historical * 2) * 0.2
        }
        let pending = operations.indices.dropFirst(currentIndex + 1).map { expectedDurations[operations[$0]] }
        let reliable = current != nil && pending.allSatisfy { $0 != nil }
        var estimatedTotal: TimeInterval?
        var remaining: TimeInterval?
        if reliable, let current {
            let raw = current * max(0, 1 - fraction) + pending.compactMap { $0 }.reduce(0, +)
            if let previous = smoothedRemaining {
                smoothedRemaining = previous * 0.7 + min(raw, previous * 1.1 + 1) * 0.3
            } else {
                smoothedRemaining = raw
            }
            let value = fraction < 1 || currentIndex < operations.count - 1 ? max(1, smoothedRemaining ?? raw) : 0
            remaining = value
            estimatedTotal = elapsed + value
        }
        onProgress(WorkflowProgress(
            operation: operation,
            operationFraction: fraction,
            overallFraction: overall,
            elapsed: elapsed,
            estimatedTotal: estimatedTotal,
            remaining: remaining,
            isIndeterminate: indeterminate || !reliable
        ))
    }
}

enum TimeTextFormatter {
    static func string(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, remainder) : String(format: "%02d:%02d", minutes, remainder)
    }
}
