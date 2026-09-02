import Foundation

struct FillerWordService {
    private let phrases: [ArtifactLanguage: [[String]]] = [
        .ru: [["ээ"], ["эм"], ["ну"], ["как", "бы"], ["короче"], ["значит"], ["типа"], ["вот"], ["в", "общем"]],
        .en: [["um"], ["uh"], ["er"], ["you", "know"], ["like"], ["basically"], ["actually"], ["well"], ["so"]]
    ]
    private let acoustic: [ArtifactLanguage: Set<String>] = [
        .ru: ["ээ", "эм"],
        .en: ["um", "uh", "er"]
    ]
    private let ambiguous: [ArtifactLanguage: Set<String>] = [
        .ru: ["ну", "значит", "типа", "вот", "короче"],
        .en: ["like", "actually", "well", "so"]
    ]

    func analyze(
        whisperJSONURL: URL,
        cues: [SubtitleCue],
        language: ArtifactLanguage,
        transcriptRevisionID: String
    ) throws -> FillerAnalysisReport {
        let words = try wordTimeline(
            whisperJSONURL: whisperJSONURL,
            cues: cues,
            transcriptRevisionID: transcriptRevisionID
        )
        let definitions = (phrases[language] ?? []).sorted { $0.count > $1.count }
        var matches: [(range: Range<Int>, phrase: [String])] = []
        var occupied = Set<Int>()
        for index in words.indices {
            for phrase in definitions where index + phrase.count <= words.count {
                let range = index..<(index + phrase.count)
                guard range.allSatisfy({ !occupied.contains($0) }),
                      Array(words[range].map(\.normalized)) == phrase else { continue }
                matches.append((range, phrase))
                occupied.formUnion(range)
                break
            }
        }
        let counts = Dictionary(grouping: matches, by: { $0.phrase.joined(separator: " ") }).mapValues(\.count)
        let candidates = matches.enumerated().map { matchIndex, match -> FillerWordCandidate in
            let matchedWords = Array(words[match.range])
            let normalized = match.phrase.joined(separator: " ")
            let confidenceValues = matchedWords.compactMap(\.confidence)
            let confidence = confidenceValues.isEmpty ? nil : confidenceValues.reduce(0, +) / Double(confidenceValues.count)
            let repeated = (counts[normalized] ?? 0) >= 2
            let isAcoustic = match.phrase.count == 1 && (acoustic[language]?.contains(normalized) == true)
            let isAmbiguous = match.phrase.count == 1 && (ambiguous[language]?.contains(normalized) == true)
            var reasons = ["dictionary-match"]
            if repeated { reasons.append("repeated-in-transcript") }
            if isAcoustic { reasons.append("acoustic-disfluency") }
            if isAmbiguous { reasons.append("ambiguous-semantic-usage") }
            if let confidence, confidence < 0.45 { reasons.append("low-token-confidence") }
            let highConfidence = repeated && !isAmbiguous && (confidence ?? 0.5) >= 0.45
            let contextStart = max(0, match.range.lowerBound - 4)
            let contextEnd = min(words.count, match.range.upperBound + 4)
            return FillerWordCandidate(
                id: "filler-\(transcriptRevisionID)-\(matchIndex)-\(matchedWords.first?.id ?? "word")",
                text: matchedWords.map(\.text).joined(separator: " "),
                normalized: normalized,
                start: matchedWords.first?.start ?? 0,
                end: matchedWords.last?.end ?? 0,
                cueID: matchedWords.first?.cueID ?? 0,
                transcriptRevisionID: transcriptRevisionID,
                language: language,
                confidence: confidence,
                highConfidence: highConfidence,
                reasonCodes: reasons,
                context: words[contextStart..<contextEnd].map(\.text).joined(separator: " "),
                decision: .pending
            )
        }
        return FillerAnalysisReport(
            schemaVersion: 1,
            language: language,
            transcriptRevisionID: transcriptRevisionID,
            createdAt: Date(),
            words: words,
            candidates: candidates
        )
    }

    func load(from url: URL) throws -> FillerAnalysisReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FillerAnalysisReport.self, from: Data(contentsOf: url))
    }

    private func wordTimeline(
        whisperJSONURL: URL,
        cues: [SubtitleCue],
        transcriptRevisionID: String
    ) throws -> [WordTimelineEntry] {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: whisperJSONURL))
        guard let object = root as? [String: Any],
              let segments = object["transcription"] as? [[String: Any]] else {
            throw WorkflowError.processFailed("whisper.json не содержит transcription для word-level timeline.")
        }
        var words: [WordTimelineEntry] = []
        for segment in segments {
            guard let tokens = segment["tokens"] as? [[String: Any]] else { continue }
            for token in tokens {
                guard let raw = (token["text"] as? String) ?? (token["token"] as? String) else { continue }
                let normalized = normalize(raw)
                guard !normalized.isEmpty, normalized.rangeOfCharacter(from: .letters) != nil,
                      let range = timeRange(from: token) else { continue }
                let cueID = cues.max { lhs, rhs in
                    overlap(lhs, range) < overlap(rhs, range)
                }?.id ?? 0
                words.append(WordTimelineEntry(
                    id: "word-\(words.count)-\(Int((range.start * 1000).rounded()))",
                    text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                    normalized: normalized,
                    start: range.start,
                    end: range.end,
                    cueID: cueID,
                    transcriptRevisionID: transcriptRevisionID,
                    confidence: number(token["p"]) ?? number(token["probability"])
                ))
            }
        }
        guard !words.isEmpty else {
            throw WorkflowError.processFailed("whisper.json не содержит слов с временными границами; требуется повторная расшифровка с token timestamps.")
        }
        return words.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
    }

    private func timeRange(from token: [String: Any]) -> (start: TimeInterval, end: TimeInterval)? {
        if let offsets = token["offsets"] as? [String: Any],
           let from = number(offsets["from"]), let to = number(offsets["to"]), to > from {
            return (from / 1000, to / 1000)
        }
        if let timestamps = token["timestamps"] as? [String: Any],
           let from = timestamp(timestamps["from"]), let to = timestamp(timestamps["to"]), to > from {
            return (from, to)
        }
        return nil
    }

    private func timestamp(_ value: Any?) -> TimeInterval? {
        if let value = number(value) { return value > 1000 ? value / 1000 : value }
        guard let text = value as? String else { return nil }
        return try? TimecodeParser.parse(text.replacingOccurrences(of: ",", with: "."))
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private func overlap(_ cue: SubtitleCue, _ range: (start: TimeInterval, end: TimeInterval)) -> TimeInterval {
        max(0, min(cue.end, range.end) - max(cue.start, range.start))
    }

    private func normalize(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        let characters: [Character] = lowered.unicodeScalars.map { scalar in
            CharacterSet.letters.contains(scalar) ? Character(String(scalar)) : Character(" ")
        }
        return String(characters).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
