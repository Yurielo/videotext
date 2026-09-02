import Foundation

struct BufferedLineParser {
    private var remainder = ""

    mutating func append(_ chunk: String) -> [String] {
        let normalized = (remainder + chunk).replacingOccurrences(of: "\r", with: "\n")
        var parts = normalized.components(separatedBy: "\n")
        remainder = parts.popLast() ?? ""
        return parts
    }
}

struct WhisperProgressParser {
    private var lines = BufferedLineParser()
    private(set) var lastProgress = 0.0

    mutating func consume(_ chunk: String) -> Double? {
        var newest: Double?
        for line in lines.append(chunk) {
            guard let marker = line.range(of: "progress =") else { continue }
            let tail = line[marker.upperBound...]
            let digits = tail.drop(while: { $0.isWhitespace }).prefix(while: { $0.isNumber })
            guard let value = Double(digits) else { continue }
            let fraction = min(max(value / 100, lastProgress), 1)
            lastProgress = fraction
            newest = fraction
        }
        return newest
    }
}

struct FFmpegProgressParser {
    private var lines = BufferedLineParser()
    private let duration: TimeInterval
    private(set) var lastProgress = 0.0

    init(duration: TimeInterval) {
        self.duration = max(duration, 0.001)
    }

    mutating func consume(_ chunk: String) -> Double? {
        var newest: Double?
        for line in lines.append(chunk) {
            if line == "progress=end" {
                lastProgress = 1
                newest = 1
                continue
            }
            guard line.hasPrefix("out_time_us="),
                  let microseconds = Double(line.dropFirst("out_time_us=".count)) else { continue }
            let fraction = min(max(microseconds / 1_000_000 / duration, lastProgress), 0.999)
            lastProgress = fraction
            newest = fraction
        }
        return newest
    }
}
