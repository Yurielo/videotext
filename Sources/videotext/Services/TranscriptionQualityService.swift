import Foundation

struct TranscriptionQualityAssessment {
    var report: TranscriptionQualityReport
    var tasks: [ReviewTask]
    var html: String
    var catastrophicIssue: CatastrophicTranscriptionIssue?
    var recoveryIssue: TranscriptionRecoveryIssue?
}

struct CatastrophicTranscriptionIssue: Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var affectedCueIDs: [Int]
    var repeatedText: String
    var repetitionRatio: Double

    var message: String {
        "массовая петля Whisper: \(affectedCueIDs.count) cue (\(Int((repetitionRatio * 100).rounded()))%) в диапазоне \(time(start))-\(time(end)) повторяют «\(repeatedText)»"
    }

    private func time(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded()))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}

struct TranscriptionRecoveryIssue: Equatable {
    enum Kind: String, Equatable {
        case catastrophicRepetition
        case fuzzyContextualRepetition
        case progressiveRepetition
    }

    var kind: Kind
    var start: TimeInterval
    var end: TimeInterval
    var affectedCueIDs: [Int]
    var sampleText: String

    var message: String {
        let range = "\(time(start))-\(time(end))"
        switch kind {
        case .catastrophicRepetition:
            return "массовая петля Whisper в диапазоне \(range)"
        case .fuzzyContextualRepetition:
            return "нечёткая контекстная петля Whisper в диапазоне \(range)"
        case .progressiveRepetition:
            return "прогрессивное дублирование реплик Whisper в диапазоне \(range)"
        }
    }

    var reviewReasonCode: String {
        switch kind {
        case .catastrophicRepetition: return "catastrophic-repetition-loop"
        case .fuzzyContextualRepetition: return "fuzzy-contextual-repetition"
        case .progressiveRepetition: return "progressive-repetition-loop"
        }
    }

    private func time(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded()))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}

struct WhisperJSONInspector {
    func language(from url: URL) -> ArtifactLanguage? {
        guard let root = try? jsonObject(url),
              let code = firstString(keys: ["language"], in: root) else { return nil }
        return ArtifactLanguage(rawValue: code.lowercased())
    }

    func segmentConfidences(from url: URL) -> [Double?] {
        guard let root = try? jsonObject(url),
              let object = root as? [String: Any],
              let segments = object["transcription"] as? [[String: Any]] else { return [] }
        return segments.map { segment in
            guard let tokens = segment["tokens"] as? [[String: Any]] else { return nil }
            let values = tokens.compactMap { token -> Double? in
                if let value = token["p"] as? Double { return value }
                if let value = token["probability"] as? Double { return value }
                if let value = token["p"] as? NSNumber { return value.doubleValue }
                return nil
            }
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
    }

    func segmentNoSpeechProbabilities(from url: URL) -> [Double?] {
        guard let root = try? jsonObject(url),
              let object = root as? [String: Any],
              let segments = object["transcription"] as? [[String: Any]] else { return [] }
        let keys = ["no_speech_prob", "no_speech_probability", "noSpeechProbability"]
        return segments.map { segment in
            for key in keys {
                if let value = segment[key] as? Double { return value }
                if let value = segment[key] as? NSNumber { return value.doubleValue }
            }
            return nil
        }
    }

    private func jsonObject(_ url: URL) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }

    private func firstString(keys: Set<String>, in value: Any) -> String? {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                if keys.contains(key), let string = child as? String { return string }
            }
            for child in object.values {
                if let result = firstString(keys: keys, in: child) { return result }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let result = firstString(keys: keys, in: child) { return result }
            }
        }
        return nil
    }
}

struct TranscriptionQualityService {
    private let inspector = WhisperJSONInspector()

    func inferLanguage(cues: [SubtitleCue], whisperJSONURL: URL?) -> ArtifactLanguage {
        if let whisperJSONURL, let language = inspector.language(from: whisperJSONURL) {
            return language
        }
        let text = cues.map(\.text).joined(separator: " ")
        let cyrillic = text.unicodeScalars.filter { (0x0400...0x04FF).contains(Int($0.value)) }.count
        let latin = text.unicodeScalars.filter {
            (0x0041...0x005A).contains(Int($0.value)) || (0x0061...0x007A).contains(Int($0.value))
        }.count
        return latin > cyrillic ? .en : .ru
    }

    func assess(
        cues: [SubtitleCue],
        skippedZeroDurationCount: Int,
        whisperJSONURL: URL?,
        selectedTimingEvidence: [TimedSourceQualityEvidence] = [],
        language: ArtifactLanguage,
        transcriptRevisionID: String,
        mediaDuration: TimeInterval? = nil
    ) -> TranscriptionQualityAssessment {
        let legacyConfidences = whisperJSONURL.map(inspector.segmentConfidences) ?? []
        let legacyNoSpeech = whisperJSONURL.map(inspector.segmentNoSpeechProbabilities) ?? []
        let evidenceByCueID = Dictionary(
            uniqueKeysWithValues: selectedTimingEvidence.map { ($0.sourceUnitID, $0) }
        )
        let confidences: [Double?] = cues.enumerated().map { index, cue in
            selectedTimingEvidence.isEmpty
                ? (legacyConfidences.indices.contains(index) ? legacyConfidences[index] : nil)
                : evidenceByCueID[cue.id]?.averageTokenConfidence
        }
        let noSpeechProbabilities: [Double?] = cues.enumerated().map { index, cue in
            selectedTimingEvidence.isEmpty
                ? (legacyNoSpeech.indices.contains(index) ? legacyNoSpeech[index] : nil)
                : evidenceByCueID[cue.id]?.averageNoSpeechProbability
        }
        let normalized = cues.map { normalize($0.text) }
        let catastrophicIssue = catastrophicIssue(cues: cues, normalized: normalized)
        let recoveryIssue = recoveryIssue(
            cues: cues,
            normalized: normalized,
            catastrophicIssue: catastrophicIssue
        )
        let counts = Dictionary(grouping: normalized.filter { !$0.isEmpty }, by: { $0 }).mapValues(\.count)
        let suspiciousGlobal = Set(counts.compactMap { text, count in
            let ratio = Double(count) / Double(max(normalized.count, 1))
            return text.split(separator: " ").count <= 6 && count >= 12 && ratio >= 0.45 ? text : nil
        })
        let tailStart = max(0, normalized.count - 30)
        let tail = Array(normalized.dropFirst(tailStart).filter { !$0.isEmpty })
        let loopingTail = tail.count >= 15 && Set(tail).count <= 3
        let progressiveChains = progressiveRepetitionChains(cues: cues, normalized: normalized)

        let blockedCueIDs = Set(recoveryIssue?.affectedCueIDs ?? [])
        var tasks: [ReviewTask] = []
        for (index, cue) in cues.enumerated() {
            var reasons: [String] = []
            let confidence = confidences.indices.contains(index) ? confidences[index] : nil
            if let confidence, confidence < 0.45 { reasons.append("low-confidence") }
            let noSpeech = noSpeechProbabilities.indices.contains(index) ? noSpeechProbabilities[index] : nil
            if let noSpeech, noSpeech > 0.65 { reasons.append("high-no-speech-probability") }
            if cue.end <= cue.start { reasons.append("invalid-cue-duration") }
            if index > 0 {
                let previous = cues[index - 1]
                if cue.start < previous.end { reasons.append("overlapping-cues") }
                if cue.start - previous.end > 60 { reasons.append("long-untranscribed-gap") }
            } else if cue.start > 60 {
                reasons.append("long-untranscribed-gap")
            }
            if cue.end > cue.start {
                let charactersPerSecond = Double(cue.text.count) / (cue.end - cue.start)
                if charactersPerSecond > 28 { reasons.append("implausible-text-rate") }
            }
            if suspiciousGlobal.contains(normalized[index]) { reasons.append("global-repetition-loop") }
            if index >= 2,
               normalized[index] == normalized[index - 1],
               normalized[index] == normalized[index - 2],
               !normalized[index].isEmpty {
                reasons.append("consecutive-repetition")
            }
            if loopingTail && index >= tailStart { reasons.append("repetitive-tail") }
            guard !reasons.isEmpty, !blockedCueIDs.contains(cue.id) else { continue }
            tasks.append(ReviewTask(
                id: "quality-\(transcriptRevisionID)-cue-\(cue.id)",
                transcriptRevisionID: transcriptRevisionID,
                status: .needsReview,
                language: language,
                start: cue.start,
                end: cue.end,
                cueIDs: [cue.id],
                reasonCodes: Array(Set(reasons)).sorted(),
                confidence: confidence ?? nil,
                originalText: cue.text,
                suggestedText: nil,
                createdAt: Date(),
                resolvedAt: nil,
                dependentArtifactIDs: []
            ))
        }

        if let issue = recoveryIssue {
            tasks.append(ReviewTask(
                id: "quality-\(transcriptRevisionID)-automatic-retranscription-\(issue.kind.rawValue)",
                transcriptRevisionID: transcriptRevisionID,
                status: .needsReview,
                language: language,
                start: issue.start,
                end: issue.end,
                cueIDs: issue.affectedCueIDs,
                reasonCodes: [issue.reviewReasonCode, "automatic-retranscription-required"],
                confidence: nil,
                originalText: issue.sampleText,
                suggestedText: nil,
                createdAt: Date(),
                resolvedAt: nil,
                dependentArtifactIDs: []
            ))
        }

        for indices in progressiveChains {
            guard let firstIndex = indices.first, let lastIndex = indices.last else { continue }
            let chainCues = indices.map { cues[$0] }
            if chainCues.contains(where: { blockedCueIDs.contains($0.id) }) { continue }
            tasks.append(ReviewTask(
                id: "quality-\(transcriptRevisionID)-progressive-\(cues[firstIndex].id)-\(cues[lastIndex].id)",
                transcriptRevisionID: transcriptRevisionID,
                status: .needsReview,
                language: language,
                start: cues[firstIndex].start,
                end: cues[lastIndex].end,
                cueIDs: chainCues.map(\.id),
                reasonCodes: ["progressive-repetition"],
                confidence: nil,
                originalText: chainCues.max(by: { $0.text.count < $1.text.count })?.text ?? "",
                suggestedText: nil,
                createdAt: Date(),
                resolvedAt: nil,
                dependentArtifactIDs: []
            ))
        }

        let confidenceValues = confidences.compactMap { $0 }
        var metrics: [String: Double] = [
            "cueCount": Double(cues.count),
            "reviewTaskCount": Double(tasks.count),
            "skippedZeroDurationCount": Double(skippedZeroDurationCount)
        ]
        if let issue = catastrophicIssue {
            metrics["catastrophicRepetitionRatio"] = issue.repetitionRatio
            metrics["catastrophicRepetitionCueCount"] = Double(issue.affectedCueIDs.count)
            metrics["catastrophicRepetitionStart"] = issue.start
            metrics["catastrophicRepetitionEnd"] = issue.end
        }
        if let issue = recoveryIssue {
            metrics["automaticRetranscriptionCueCount"] = Double(issue.affectedCueIDs.count)
            metrics["automaticRetranscriptionStart"] = issue.start
            metrics["automaticRetranscriptionEnd"] = issue.end
        }
        if !confidenceValues.isEmpty {
            metrics["averageTokenConfidence"] = confidenceValues.reduce(0, +) / Double(confidenceValues.count)
            metrics["lowConfidenceSegmentCount"] = Double(confidenceValues.filter { $0 < 0.45 }.count)
        }
        let noSpeechValues = noSpeechProbabilities.compactMap { $0 }
        if !noSpeechValues.isEmpty {
            metrics["highNoSpeechSegmentCount"] = Double(noSpeechValues.filter { $0 > 0.65 }.count)
            metrics["averageNoSpeechProbability"] = noSpeechValues.reduce(0, +) / Double(noSpeechValues.count)
        }
        var warnings: [String] = []
        if let mediaDuration, let last = cues.last, mediaDuration - last.end > 60 {
            warnings.append("После последней реплики остаётся непокрытый участок более 60 секунд; требуется проверить наличие речи.")
        }
        if skippedZeroDurationCount > 0 {
            warnings.append("Исключено служебных cue нулевой длительности: \(skippedZeroDurationCount).")
        }
        if let issue = recoveryIssue {
            warnings.append("Обнаружена \(issue.message). Требуется автоматическая повторная расшифровка повреждённого диапазона.")
        } else if !tasks.isEmpty {
            warnings.append("Требуют ручной проверки фрагменты: \(tasks.count). Pipeline продолжен.")
        }
        let report = TranscriptionQualityReport(
            schemaVersion: 1,
            transcriptRevisionID: transcriptRevisionID,
            language: language,
            analyzedAt: Date(),
            status: recoveryIssue != nil ? .invalid : (tasks.isEmpty ? .ready : .needsReview),
            cueCount: cues.count,
            reviewTaskIDs: tasks.map(\.id),
            metrics: metrics,
            warnings: warnings
        )
        return TranscriptionQualityAssessment(
            report: report,
            tasks: tasks,
            html: renderHTML(cues: cues, tasks: tasks, language: language),
            catastrophicIssue: catastrophicIssue,
            recoveryIssue: recoveryIssue
        )
    }

    func catastrophicIssue(cues: [SubtitleCue]) -> CatastrophicTranscriptionIssue? {
        catastrophicIssue(cues: cues, normalized: cues.map { normalize($0.text) })
    }

    func recoveryIssue(cues: [SubtitleCue]) -> TranscriptionRecoveryIssue? {
        let normalized = cues.map { normalize($0.text) }
        return recoveryIssue(
            cues: cues,
            normalized: normalized,
            catastrophicIssue: catastrophicIssue(cues: cues, normalized: normalized)
        )
    }

    private func recoveryIssue(
        cues: [SubtitleCue],
        normalized: [String],
        catastrophicIssue: CatastrophicTranscriptionIssue?
    ) -> TranscriptionRecoveryIssue? {
        if let catastrophicIssue {
            return TranscriptionRecoveryIssue(
                kind: .catastrophicRepetition,
                start: catastrophicIssue.start,
                end: catastrophicIssue.end,
                affectedCueIDs: catastrophicIssue.affectedCueIDs,
                sampleText: catastrophicIssue.repeatedText
            )
        }
        if let issue = fuzzyContextualRepetitionIssue(cues: cues, normalized: normalized) {
            return issue
        }
        return severeProgressiveRepetitionIssue(cues: cues, normalized: normalized)
    }

    private func catastrophicIssue(
        cues: [SubtitleCue],
        normalized: [String]
    ) -> CatastrophicTranscriptionIssue? {
        guard cues.count >= 20 else { return nil }
        let counts = Dictionary(grouping: normalized.filter { !$0.isEmpty }, by: { $0 }).mapValues(\.count)
        guard let dominant = counts.max(by: { $0.value < $1.value }) else { return nil }
        let ratio = Double(dominant.value) / Double(cues.count)
        guard dominant.key.split(separator: " ").count <= 8,
              dominant.value >= 20,
              ratio >= 0.35 else { return nil }

        let matching = normalized.indices.filter { normalized[$0] == dominant.key }
        guard let sustainedStart = firstSustainedDominantIndex(normalized, dominant: dominant.key),
              let lastIndex = matching.last,
              cues[lastIndex].end - cues[sustainedStart].start >= 120 else { return nil }
        let affected = matching.filter { $0 >= sustainedStart }
        return CatastrophicTranscriptionIssue(
            start: cues[sustainedStart].start,
            end: cues[lastIndex].end,
            affectedCueIDs: affected.map { cues[$0].id },
            repeatedText: cues[matching[0]].text.trimmingCharacters(in: .whitespacesAndNewlines),
            repetitionRatio: ratio
        )
    }

    private func firstSustainedDominantIndex(_ values: [String], dominant: String) -> Int? {
        let windowSize = min(20, values.count)
        guard windowSize >= 10 else { return nil }
        for start in 0...(values.count - windowSize) {
            let window = values[start..<(start + windowSize)]
            if window.filter({ $0 == dominant }).count >= Int(ceil(Double(windowSize) * 0.8)) {
                return window.firstIndex(of: dominant)
            }
        }
        return nil
    }

    private func fuzzyContextualRepetitionIssue(
        cues: [SubtitleCue],
        normalized: [String]
    ) -> TranscriptionRecoveryIssue? {
        let phraseLength = 12
        let localWindow = 180
        let minimumGap = 8
        let minimumSharedTokens = 9
        let minimumSimilarity = 0.82
        let minimumMatches = 4
        let words = zip(cues, normalized).flatMap { cue, text in
            text.split(separator: " ").map { (String($0), cue.id) }
        }
        guard words.count >= phraseLength else { return nil }

        var start = 0
        while start <= words.count - phraseLength {
            let anchor = Array(words[start..<(start + phraseLength)])
            let anchorWords = anchor.map(\.0)
            let content = Set(anchorWords.filter { $0.count > 2 && !Self.fuzzyStopWords.contains($0) })
            guard content.count >= 3 else {
                start += 1
                continue
            }

            var matches = [start]
            var lastMatch = start
            let lastCandidate = min(words.count - phraseLength, start + localWindow)
            var candidateStart = start + minimumGap
            while candidateStart <= lastCandidate {
                if candidateStart - lastMatch < minimumGap {
                    candidateStart += 1
                    continue
                }
                let candidate = Array(words[candidateStart..<(candidateStart + phraseLength)]).map(\.0)
                guard sharedTokenCount(anchorWords, candidate) >= minimumSharedTokens,
                      orderedTokenSimilarity(anchorWords, candidate) >= minimumSimilarity else {
                    candidateStart += 1
                    continue
                }
                matches.append(candidateStart)
                lastMatch = candidateStart
                if matches.count >= minimumMatches {
                    let clusterEnd = candidateStart + phraseLength
                    let clusterWords = words[start..<clusterEnd].map(\.0)
                    if ordinalKinds(in: clusterWords).count >= 3 {
                        start = clusterEnd
                        break
                    }
                    let cueIDs = Array(Set(matches.flatMap { match in
                        words[match..<(match + phraseLength)].map(\.1)
                    })).sorted()
                    guard let firstCueID = cueIDs.first,
                          let lastCueID = cueIDs.last,
                          let firstCue = cues.first(where: { $0.id == firstCueID }),
                          let lastCue = cues.first(where: { $0.id == lastCueID }) else {
                        return nil
                    }
                    return TranscriptionRecoveryIssue(
                        kind: .fuzzyContextualRepetition,
                        start: firstCue.start,
                        end: lastCue.end,
                        affectedCueIDs: cueIDs,
                        sampleText: cues.first(where: { $0.id == firstCueID })?.text ?? ""
                    )
                }
                candidateStart += 1
            }
            start += 1
        }
        return nil
    }

    private func severeProgressiveRepetitionIssue(
        cues: [SubtitleCue],
        normalized: [String]
    ) -> TranscriptionRecoveryIssue? {
        for chain in progressiveRepetitionChains(cues: cues, normalized: normalized) {
            guard let first = chain.first, let last = chain.last else { continue }
            let duration = cues[last].end - cues[first].start
            guard chain.count >= 8, duration >= 12 else { continue }
            let chainCues = chain.map { cues[$0] }
            return TranscriptionRecoveryIssue(
                kind: .progressiveRepetition,
                start: chainCues[0].start,
                end: chainCues[chainCues.count - 1].end,
                affectedCueIDs: chainCues.map(\.id),
                sampleText: chainCues.max(by: { $0.text.count < $1.text.count })?.text ?? ""
            )
        }
        return nil
    }

    private func sharedTokenCount(_ lhs: [String], _ rhs: [String]) -> Int {
        let lhsCounts = Dictionary(grouping: lhs, by: { $0 }).mapValues(\.count)
        let rhsCounts = Dictionary(grouping: rhs, by: { $0 }).mapValues(\.count)
        return lhsCounts.reduce(0) { partial, entry in
            partial + min(entry.value, rhsCounts[entry.key] ?? 0)
        }
    }

    private func orderedTokenSimilarity(_ lhs: [String], _ rhs: [String]) -> Double {
        var previous = Array(repeating: 0, count: rhs.count + 1)
        for left in lhs {
            var current = Array(repeating: 0, count: rhs.count + 1)
            for index in rhs.indices {
                if left == rhs[index] {
                    current[index + 1] = previous[index] + 1
                } else {
                    current[index + 1] = max(previous[index + 1], current[index])
                }
            }
            previous = current
        }
        return Double(previous[rhs.count]) / Double(max(lhs.count, rhs.count, 1))
    }

    private func ordinalKinds(in words: [String]) -> Set<String> {
        let roots = ["перв", "втор", "трет", "четверт", "пят", "шест", "седьм", "восьм", "девят", "десят"]
        let english = Set(["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"])
        var kinds = Set(words.filter { english.contains($0) })
        for root in roots where words.contains(where: { $0.hasPrefix(root) }) {
            kinds.insert(root)
        }
        return kinds
    }

    private static let fuzzyStopWords: Set<String> = [
        "а", "без", "бы", "в", "во", "вот", "все", "всего", "всей", "всем", "всех", "вы", "где", "да", "для", "до", "его", "ее", "ей", "есть", "еще", "же", "за", "и", "из", "или", "им", "их", "к", "как", "ко", "кто", "ли", "меня", "мне", "мы", "на", "нам", "нас", "не", "нет", "но", "о", "об", "он", "она", "они", "оно", "от", "по", "при", "с", "себя", "так", "такой", "там", "тем", "то", "того", "тоже", "тут", "ты", "у", "уже", "чем", "чего", "что", "чтобы", "это", "этого", "этой", "я",
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "in", "is", "it", "of", "on", "or", "that", "the", "this", "to", "was", "we", "with"
    ]

    private func normalize(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        return String(scalars).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func progressiveRepetitionChains(cues: [SubtitleCue], normalized: [String]) -> [[Int]] {
        guard cues.count > 1 else { return [] }
        var chains: [[Int]] = []
        var current: [Int] = []
        for index in 1..<cues.count {
            let previous = cues[index - 1]
            let cue = cues[index]
            let old = normalized[index - 1]
            let new = normalized[index]
            let oldWords = old.split(separator: " ").map(String.init)
            let newWords = new.split(separator: " ").map(String.init)
            let close = cue.start <= previous.end + 1.2
            let overlappingOrigin = abs(cue.start - previous.start) < 0.8 || cue.start < previous.end
            let progressive = !old.isEmpty
                && !new.isEmpty
                && old != new
                && close
                && overlappingOrigin
                && (containsTokenSequence(oldWords, in: newWords) || containsTokenSequence(newWords, in: oldWords))
            if progressive {
                if current.isEmpty { current = [index - 1] }
                current.append(index)
            } else if !current.isEmpty {
                chains.append(current)
                current = []
            }
        }
        if !current.isEmpty { chains.append(current) }
        return chains
    }

    private func containsTokenSequence(_ candidate: [String], in container: [String]) -> Bool {
        guard !candidate.isEmpty, candidate.count <= container.count else { return false }
        if candidate.count == container.count { return candidate == container }
        for start in 0...(container.count - candidate.count) {
            if Array(container[start..<(start + candidate.count)]) == candidate { return true }
        }
        return false
    }

    func renderHTML(cues: [SubtitleCue], tasks: [ReviewTask], language: ArtifactLanguage) -> String {
        var tasksByCue: [Int: [ReviewTask]] = [:]
        for task in tasks {
            for cueID in task.cueIDs {
                tasksByCue[cueID, default: []].append(task)
            }
        }
        let rows = cues.map { cue -> String in
            let cueTasks = tasksByCue[cue.id] ?? []
            let className = cueTasks.isEmpty ? "" : " class=\"needs-review\""
            let reasons = Set(cueTasks.flatMap(\.reasonCodes)).sorted().joined(separator: ", ")
            return "<tr\(className)><td>\(cue.id)</td><td>\(time(cue.start))-\(time(cue.end))</td><td>\(escape(cue.text))</td><td>\(escape(reasons))</td></tr>"
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="\(language.rawValue)">
        <head><meta charset="utf-8"><title>videotext transcript review</title>
        <style>body{font-family:-apple-system,sans-serif;margin:24px}table{border-collapse:collapse;width:100%}td,th{border-bottom:1px solid #ddd;padding:8px;text-align:left}.needs-review{background:#ffd7d7;color:#8b0000}</style></head>
        <body><h1>Transcript review</h1><p>Красным отмечены фрагменты, требующие ручной проверки.</p>
        <table><thead><tr><th>ID</th><th>Время</th><th>Текст</th><th>Причина</th></tr></thead><tbody>
        \(rows)
        </tbody></table></body></html>
        """
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func time(_ value: TimeInterval) -> String {
        let milliseconds = max(0, Int((value * 1000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1000) % 60
        let remainder = milliseconds % 1000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, remainder)
    }
}
