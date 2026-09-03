import Foundation

struct ParsedLanguageDetection: Equatable {
    var languageCode: String
    var confidence: Double?
}

struct WhisperLanguageDetectionParser {
    private static let expression = try! NSRegularExpression(
        pattern: #"(?:auto[- ]detected|detected)\s+language:\s*([a-zA-Z]{2,3})(?:\s*\(p\s*=\s*([0-9]*\.?[0-9]+)\))?"#,
        options: [.caseInsensitive]
    )

    func parse(_ text: String) -> ParsedLanguageDetection? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = Self.expression.matches(in: text, range: range).last,
              let languageRange = Range(match.range(at: 1), in: text) else { return nil }
        let language = String(text[languageRange]).lowercased()
        var confidence: Double?
        if match.range(at: 2).location != NSNotFound,
           let confidenceRange = Range(match.range(at: 2), in: text) {
            confidence = Double(text[confidenceRange])
        }
        return ParsedLanguageDetection(languageCode: language, confidence: confidence)
    }
}

struct LanguageDetectionService {
    let runner: ToolRunner
    let parser = WhisperLanguageDetectionParser()

    init(runner: ToolRunner = ToolRunner()) {
        self.runner = runner
    }

    func detect(
        mediaURL: URL,
        projectURL: URL,
        mediaDuration: TimeInterval,
        modelPath: String,
        requestedLanguage: String,
        onProgress: @escaping (Double) -> Void,
        onLog: @escaping (String) -> Void
    ) async throws -> LanguageProfile {
        let requested = requestedLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let language = ArtifactLanguage(rawValue: requested) {
            onProgress(1)
            return LanguageProfile(
                detected: language == .ru ? .ru : .en,
                effective: language,
                confidence: nil,
                method: "manual-override",
                model: nil,
                modelVersion: nil,
                sampleRanges: [],
                manuallyOverridden: true,
                detectedAt: Date()
            )
        }

        let layout = ProjectLayout(root: projectURL)
        try layout.createDirectories()
        guard let ffmpeg = runner.resolve("ffmpeg") else { throw WorkflowError.missingTool("ffmpeg") }
        guard let ffprobe = runner.resolve("ffprobe") else { throw WorkflowError.missingTool("ffprobe") }
        let audioProbe = try await runner.run(ffprobe, [
            "-v", "error",
            "-select_streams", "a:0",
            "-show_entries", "stream=index",
            "-of", "csv=p=0",
            mediaURL.path
        ], currentDirectory: projectURL)
        guard audioProbe.exitCode == 0 else {
            throw WorkflowError.processFailed("Не удалось проверить аудиодорожку: \(audioProbe.stderr)")
        }
        guard !audioProbe.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowError.processFailed("В выбранном медиафайле отсутствует аудиодорожка.")
        }
        guard let whisper = runner.resolve("whisper-cli") else { throw WorkflowError.missingTool("whisper-cli") }
        let ranges = sampleRanges(mediaDuration: mediaDuration)
        var candidates: [LanguageDetectionCandidate] = []

        for (index, range) in ranges.enumerated() {
            try Task.checkCancellation()
            let sampleURL = layout.languageDirectory.appendingPathComponent(".language-sample-\(index).wav")
            try? FileManager.default.removeItem(at: sampleURL)
            defer { try? FileManager.default.removeItem(at: sampleURL) }

            let extract = try await runner.run(ffmpeg, [
                "-y",
                "-ss", String(format: "%.3f", range.start),
                "-i", mediaURL.path,
                "-t", String(format: "%.3f", range.end - range.start),
                "-map", "0:a:0",
                "-vn",
                "-ac", "1",
                "-ar", "16000",
                "-c:a", "pcm_s16le",
                sampleURL.path
            ], currentDirectory: projectURL)
            guard extract.exitCode == 0, FileManager.default.fileExists(atPath: sampleURL.path) else {
                throw WorkflowError.processFailed("Не удалось подготовить аудио для определения языка: \(extract.stderr)")
            }

            var arguments = ["-f", sampleURL.path, "-l", "auto", "-dl"]
            if !modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                arguments = ["-m", modelPath] + arguments
            }
            let result = try await runner.run(whisper, arguments, currentDirectory: projectURL)
            let diagnostic = result.stdout + "\n" + result.stderr
            guard result.exitCode == 0 else {
                throw WorkflowError.processFailed("Ошибка определения языка whisper-cli: \(result.stderr.isEmpty ? result.stdout : result.stderr)")
            }
            if let parsed = parser.parse(diagnostic) {
                candidates.append(LanguageDetectionCandidate(
                    languageCode: parsed.languageCode,
                    confidence: parsed.confidence,
                    sampleRange: range
                ))
                onLog("Выборка \(index + 1)/\(ranges.count): язык \(parsed.languageCode), уверенность \(format(parsed.confidence)).")
            } else {
                onLog("Выборка \(index + 1)/\(ranges.count): whisper-cli не вернул распознаваемую оценку языка.")
            }
            onProgress(Double(index + 1) / Double(ranges.count))
        }

        let aggregate = aggregate(candidates)
        let profile = LanguageProfile(
            detected: aggregate.detected,
            effective: aggregate.effective,
            confidence: aggregate.confidence,
            method: "whisper-cli-multi-sample-v1",
            model: URL(fileURLWithPath: modelPath).lastPathComponent,
            modelVersion: nil,
            sampleRanges: ranges,
            manuallyOverridden: false,
            detectedAt: Date()
        )
        onProgress(1)
        return profile
    }

    func aggregate(_ candidates: [LanguageDetectionCandidate]) -> (
        detected: DetectedMediaLanguage,
        effective: ArtifactLanguage?,
        confidence: Double?
    ) {
        var scores: [ArtifactLanguage: Double] = [:]
        var counts: [ArtifactLanguage: Int] = [:]
        for candidate in candidates {
            guard let language = ArtifactLanguage(rawValue: candidate.languageCode) else { continue }
            scores[language, default: 0] += candidate.confidence ?? 0.5
            counts[language, default: 0] += 1
        }
        guard let best = ArtifactLanguage.allCases.max(by: { scores[$0, default: 0] < scores[$1, default: 0] }),
              counts[best, default: 0] > 0 else {
            return (.uncertain, nil, nil)
        }
        let other: ArtifactLanguage = best == .ru ? .en : .ru
        let bestAverage = scores[best, default: 0] / Double(counts[best, default: 1])
        let otherAverage = counts[other, default: 0] > 0
            ? scores[other, default: 0] / Double(counts[other, default: 1])
            : 0
        let supportedSamples = counts.values.reduce(0, +)
        let agreement = Double(counts[best, default: 0]) / Double(max(supportedSamples, 1))
        let confidence = min(max(bestAverage * agreement, 0), 1)
        let uncertain = agreement < 0.67 || bestAverage - otherAverage < 0.15 || confidence < 0.55
        if uncertain { return (.uncertain, best, confidence) }
        return (best == .ru ? .ru : .en, best, confidence)
    }

    private func sampleRanges(mediaDuration: TimeInterval) -> [ClosedRangeRecord] {
        let duration = max(mediaDuration, 1)
        let sampleDuration = min(30, duration)
        let centers = duration <= 45 ? [duration / 2] : [duration * 0.15, duration * 0.5, duration * 0.85]
        var ranges: [ClosedRangeRecord] = []
        for center in centers {
            let start = min(max(0, center - sampleDuration / 2), max(0, duration - sampleDuration))
            let range = ClosedRangeRecord(start: start, end: min(duration, start + sampleDuration))
            if !ranges.contains(where: { abs($0.start - range.start) < 0.01 }) {
                ranges.append(range)
            }
        }
        return ranges
    }

    private func format(_ value: Double?) -> String {
        value.map { String(format: "%.3f", $0) } ?? "не указана"
    }
}
