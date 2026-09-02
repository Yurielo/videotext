import Foundation

struct QuoteRangeCandidate: Identifiable, Equatable {
    var id: String
    var start: TimeInterval
    var end: TimeInterval
    var startCueID: Int
    var endCueID: Int
    var context: String
}

struct QuoteRangeMatcher {
    func candidates(
        cues: [SubtitleCue],
        startQuote: String,
        endQuote: String,
        leadPadding: TimeInterval = 0,
        trailingPadding: TimeInterval = 0
    ) -> [QuoteRangeCandidate] {
        let ordered = cues.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        let startMatches = matchingCueIndices(quote: startQuote, cues: ordered, useEndOfMatch: false)
        let endMatches = matchingCueIndices(quote: endQuote, cues: ordered, useEndOfMatch: true)
        guard !startMatches.isEmpty, !endMatches.isEmpty else { return [] }
        var results: [QuoteRangeCandidate] = []
        for startIndex in startMatches {
            for endIndex in endMatches where endIndex >= startIndex {
                let startCue = ordered[startIndex]
                let endCue = ordered[endIndex]
                let contextRange = max(0, startIndex - 1)...min(ordered.count - 1, endIndex + 1)
                let context = ordered[contextRange].map(\.text).joined(separator: " ")
                results.append(QuoteRangeCandidate(
                    id: "quote-\(startCue.id)-\(endCue.id)",
                    start: max(0, startCue.start - max(0, leadPadding)),
                    end: endCue.end + max(0, trailingPadding),
                    startCueID: startCue.id,
                    endCueID: endCue.id,
                    context: context
                ))
                break
            }
        }
        return Array(Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) }).values)
            .sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
    }

    private func matchingCueIndices(
        quote: String,
        cues: [SubtitleCue],
        useEndOfMatch: Bool
    ) -> [Int] {
        let needle = normalize(quote)
        guard !needle.isEmpty else { return [] }
        var exact = Set<Int>()
        for start in cues.indices {
            var parts: [String] = []
            for end in start..<min(cues.count, start + 8) {
                parts.append(normalize(cues[end].text))
                let combined = parts.joined(separator: " ")
                if let range = combined.range(of: needle) {
                    let characterOffset = useEndOfMatch
                        ? combined.distance(from: combined.startIndex, to: range.upperBound) - 1
                        : combined.distance(from: combined.startIndex, to: range.lowerBound)
                    var cursor = 0
                    for (partOffset, part) in parts.enumerated() {
                        let upper = cursor + part.count
                        if characterOffset <= upper {
                            exact.insert(start + partOffset)
                            break
                        }
                        cursor = upper + 1
                    }
                }
                if combined.count > needle.count * 3 + 120 { break }
            }
        }
        if !exact.isEmpty { return exact.sorted() }
        return cues.indices.filter { index in
            let candidate = normalize(cues[index].text)
            guard abs(candidate.count - needle.count) <= max(12, needle.count / 3) else { return false }
            return similarity(candidate, needle) >= 0.86
        }
    }

    func normalize(_ text: String) -> String {
        String(text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : " " }
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " "))
    }

    private func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty || !right.isEmpty else { return 1 }
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: right.count)
            for (rightIndex, rightCharacter) in right.enumerated() {
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return 1 - Double(previous[right.count]) / Double(max(left.count, right.count, 1))
    }
}
