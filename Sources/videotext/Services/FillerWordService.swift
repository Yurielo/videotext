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
        transcriptRevisionID: String,
        mediaDuration: TimeInterval? = nil
    ) throws -> FillerAnalysisReport {
        let words = try wordTimeline(
            whisperJSONURL: whisperJSONURL,
            cues: cues,
            transcriptRevisionID: transcriptRevisionID
        )
        return report(words: words, cues: cues, language: language,
                      transcriptRevisionID: transcriptRevisionID, mediaDuration: mediaDuration)
    }

    /// Uses the selected Whisper attempt's token evidence for native
    /// SeminarText transcription. This keeps filler detection on the same ASR
    /// attempt and avoids creating a parallel VideoText Whisper JSON.
    func analyze(
        selectedTiming: TimedSourceDocument,
        cues: [SubtitleCue],
        language: ArtifactLanguage,
        transcriptRevisionID: String,
        mediaDuration: TimeInterval? = nil
    ) throws -> FillerAnalysisReport {
        try selectedTiming.validateCoverage()
        let words = selectedTiming.tokenTimeline.compactMap { token -> WordTimelineEntry? in
            guard !(token.text.hasPrefix("[_") && token.text.hasSuffix("]")) else { return nil }
            let normalized = normalize(token.text)
            guard !normalized.isEmpty, normalized.rangeOfCharacter(from: .letters) != nil else { return nil }
            let cueID = cues.max { lhs, rhs in
                overlap(lhs, (start: token.start, end: token.end)) < overlap(rhs, (start: token.start, end: token.end))
            }?.id ?? 0
            return WordTimelineEntry(
                id: "selected-token-\(Int((token.start * 1000).rounded()))-\(SelectedTimingHash.string(token.text).prefix(12))",
                text: token.text.trimmingCharacters(in: .whitespacesAndNewlines),
                normalized: normalized,
                start: token.start,
                end: token.end,
                cueID: cueID,
                transcriptRevisionID: transcriptRevisionID,
                confidence: nil
            )
        }
        guard !words.isEmpty else {
            throw WorkflowError.processFailed("Selected timing не содержит слов с временными границами для анализа слов-паразитов.")
        }
        return report(words: words, cues: cues, language: language,
                      transcriptRevisionID: transcriptRevisionID, mediaDuration: mediaDuration)
    }

    private func report(
        words: [WordTimelineEntry],
        cues: [SubtitleCue],
        language: ArtifactLanguage,
        transcriptRevisionID: String,
        mediaDuration: TimeInterval?
    ) -> FillerAnalysisReport {
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
        // Word entries retain raw Whisper boundaries, including reverse
        // intervals. Candidates are actionable preview/mute ranges, so only
        // their derived envelope must be ordered and usable for media.
        let validCueTimeline = !cues.isEmpty && cues.allSatisfy {
            $0.id > 0 && $0.start.isFinite && $0.end.isFinite
                && $0.start >= 0 && $0.end > $0.start
        }
        let playableStart = validCueTimeline ? cues.map(\.start).min() : nil
        let cueEnd = validCueTimeline ? cues.map(\.end).max() : nil
        let playableEnd = cueEnd.flatMap { end -> TimeInterval? in
            guard let mediaDuration else { return end }
            guard mediaDuration.isFinite, mediaDuration > 0 else { return nil }
            return min(end, mediaDuration)
        }
        let actionableMatches = matches.compactMap { match -> (range: Range<Int>, phrase: [String], start: TimeInterval, end: TimeInterval, cueID: Int)? in
            let boundaries = words[match.range].flatMap { [$0.start, $0.end] }
            guard let start = boundaries.min(), let end = boundaries.max(),
                  let playableStart, let playableEnd,
                  start.isFinite, end.isFinite, start >= playableStart, end <= playableEnd,
                  end > start,
                  let cue = cues.max(by: {
                      overlap($0, (start: start, end: end)) < overlap($1, (start: start, end: end))
                  }),
                  overlap(cue, (start: start, end: end)) > 0 else { return nil }
            return (match.range, match.phrase, start, end, cue.id)
        }
        let counts = Dictionary(grouping: actionableMatches, by: { $0.phrase.joined(separator: " ") }).mapValues(\.count)
        let candidates = actionableMatches.enumerated().map { matchIndex, match -> FillerWordCandidate in
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
                start: match.start,
                end: match.end,
                cueID: match.cueID,
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
                // Core whisper.json retains Whisper control markers as raw
                // provenance; they are not speech words for filler analysis.
                guard !(raw.hasPrefix("[_") && raw.hasSuffix("]")) else { continue }
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
        return words
    }

    private func timeRange(from token: [String: Any]) -> (start: TimeInterval, end: TimeInterval)? {
        if let offsets = token["offsets"] as? [String: Any],
           let from = number(offsets["from"]), let to = number(offsets["to"]), from >= 0, to >= 0 {
            return (from / 1000, to / 1000)
        }
        if let timestamps = token["timestamps"] as? [String: Any],
           let from = timestamp(timestamps["from"]), let to = timestamp(timestamps["to"]), from >= 0, to >= 0 {
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
        // Cue association consumes a derived envelope; report.words retains
        // the raw token start/end exactly as selected Whisper supplied them.
        let start = min(range.start, range.end)
        let end = max(range.start, range.end)
        return max(0, min(cue.end, end) - max(cue.start, start))
    }

    private func normalize(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        let characters: [Character] = lowered.unicodeScalars.map { scalar in
            CharacterSet.letters.contains(scalar) ? Character(String(scalar)) : Character(" ")
        }
        return String(characters).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
