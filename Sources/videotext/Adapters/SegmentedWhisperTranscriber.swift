import Foundation
import CryptoKit

struct WhisperChunk: Equatable {
    var index: Int
    var coreStart: TimeInterval
    var coreEnd: TimeInterval
    var extractionStart: TimeInterval
    var extractionEnd: TimeInterval
}

enum WhisperChunkPlanner {
    static let segmentationThreshold: TimeInterval = 20 * 60
    static let coreDuration: TimeInterval = 5 * 60
    static let legacyOverlap: TimeInterval = 1.5

    static func shouldSegment(duration: TimeInterval) -> Bool {
        duration > segmentationThreshold
    }

    static func chunks(duration: TimeInterval, overlap: TimeInterval = legacyOverlap) -> [WhisperChunk] {
        guard duration > 0 else { return [] }
        var result: [WhisperChunk] = []
        var coreStart: TimeInterval = 0
        while coreStart < duration {
            let coreEnd = min(duration, coreStart + coreDuration)
            result.append(WhisperChunk(
                index: result.count,
                coreStart: coreStart,
                coreEnd: coreEnd,
                extractionStart: max(0, coreStart - overlap),
                extractionEnd: min(duration, coreEnd + overlap)
            ))
            coreStart = coreEnd
        }
        return result
    }
}

/// The long-form profile is deliberately limited to the Russian conversational
/// pipeline measured by Issue #6. It is not a meeting-specific vocabulary.
struct WhisperLongFormProfile: Equatable {
    let identifier: String
    let overlap: TimeInterval
    let primaryArguments: [String]
    let recoveryArguments: [String]
    let noVADArguments: [String]

    static func forLanguage(_ language: String) -> WhisperLongFormProfile {
        guard language.lowercased() == "ru" else {
            return WhisperLongFormProfile(
                identifier: "legacy-long-form-v1",
                overlap: WhisperChunkPlanner.legacyOverlap,
                primaryArguments: ["-mc", "0"],
                recoveryArguments: ["-mc", "0", "-nf"],
                noVADArguments: ["-mc", "0", "-nf"]
            )
        }

        // These are decoder and Silero VAD controls from the successful
        // SeminarText comparison. They do not alter the spoken text.
        return WhisperLongFormProfile(
            identifier: "russian-conversation-v1",
            overlap: 0,
            primaryArguments: [
                "-t", "8", "-bo", "5", "-bs", "5",
                "-vt", "0.55", "-vspd", "250", "-vsd", "550",
                "-vp", "200", "-vo", "0.10", "-nth", "0.60",
                "-sns", "-ml", "80", "-sow"
            ],
            recoveryArguments: [
                "-t", "8", "-bo", "3", "-bs", "3",
                "-vt", "0.68", "-vspd", "250", "-vsd", "350",
                "-vp", "200", "-vo", "0.10", "-nth", "0.60",
                "-sns", "-ml", "80", "-sow"
            ],
            noVADArguments: [
                "-t", "8", "-bo", "3", "-bs", "3",
                "-sns", "-ml", "80", "-sow", "-nf"
            ]
        )
    }

    func attempts(vadModelPath: String?) -> [(name: String, vad: String?, extra: [String])] {
        guard let vadModelPath else {
            return [("standard segmentation", nil, noVADArguments)]
        }
        return [
            ("VAD long-form", vadModelPath, primaryArguments),
            ("VAD long-form recovery", vadModelPath, recoveryArguments),
            ("standard segmentation after VAD failure", nil, noVADArguments)
        ]
    }
}

struct WhisperChunkOutput {
    var chunk: WhisperChunk
    var srtURL: URL
    var jsonURL: URL
}

struct SegmentedWhisperTranscriber {
    let runner: ToolRunner
    let vadModelLocator: WhisperVADModelLocator
    private let srt = SRTService()
    private let quality = TranscriptionQualityService()

    func transcribe(
        audioURL: URL,
        mediaURL: URL,
        projectURL: URL,
        mediaDuration: TimeInterval,
        modelPath: String,
        language: String,
        contextHint: String? = nil,
        onProgress: @escaping (Double) -> Void,
        onLog: @escaping (String) -> Void
    ) async throws -> TranscriptionResult {
        guard let whisper = runner.resolve("whisper-cli"), let ffmpeg = runner.resolve("ffmpeg") else {
            throw WorkflowError.missingTool("whisper-cli/ffmpeg")
        }
        let profile = WhisperLongFormProfile.forLanguage(language)
        let chunks = WhisperChunkPlanner.chunks(duration: mediaDuration, overlap: profile.overlap)
        guard !chunks.isEmpty else { throw WorkflowError.processFailed("Не удалось подготовить сегменты расшифровки.") }
        let layout = ProjectLayout(root: projectURL)
        let vadModel = vadModelLocator.bestModelPath()
        let cache = try cacheDirectory(
            layout: layout,
            mediaURL: mediaURL,
            modelPath: modelPath,
            language: language,
            mediaDuration: mediaDuration,
            profile: profile,
            contextHint: contextHint,
            vadModelPath: vadModel
        )
        onLog("Длинное видео: распознавание разделено на \(chunks.count) независимых сегментов по 5 минут (профиль \(profile.identifier)).")
        if let vadModel { onLog("Silero VAD: \(vadModel)") }

        var outputs: [WhisperChunkOutput] = []
        for chunk in chunks {
            try Task.checkCancellation()
            let output = try await transcribe(
                chunk: chunk,
                audioURL: audioURL,
                cacheDirectory: cache,
                projectURL: projectURL,
                modelPath: modelPath,
                language: language,
                contextHint: contextHint,
                whisper: whisper,
                ffmpeg: ffmpeg,
                vadModelPath: vadModel,
                profile: profile,
                chunkCount: chunks.count,
                onProgress: onProgress,
                onLog: onLog
            )
            outputs.append(output)
        }

        let partialSRT = layout.textsDirectory.appendingPathComponent("full.partial.srt")
        let partialJSON = layout.textsDirectory.appendingPathComponent("full.partial.json")
        defer {
            try? FileManager.default.removeItem(at: partialSRT)
            try? FileManager.default.removeItem(at: partialJSON)
        }
        let merged = try merge(outputs: outputs, mediaDuration: mediaDuration, jsonURL: partialJSON)
        guard !merged.isEmpty else {
            throw WorkflowError.processFailed("Сегментированная расшифровка не содержит речи.")
        }
        let timelineIssues = srt.validateTimeline(merged, mediaDuration: mediaDuration)
        guard timelineIssues.isEmpty else {
            throw WorkflowError.invalidSRT("ошибка объединения сегментов: \(timelineIssues.joined(separator: " "))")
        }
        if let issue = quality.recoveryIssue(cues: merged) {
            throw WorkflowError.processFailed("Автоматическое восстановление не устранило \(issue.message).")
        }
        try srt.write(merged, to: partialSRT)
        try atomicReplace(layout.fullSRTURL, with: partialSRT)
        try atomicReplace(layout.whisperJSONURL, with: partialJSON)
        onLog("Сегменты объединены: \(merged.count) cue; временная шкала и повторения проверены.")
        onProgress(1)
        return TranscriptionResult(srtURL: layout.fullSRTURL, jsonURL: layout.whisperJSONURL)
    }

    private func transcribe(
        chunk: WhisperChunk,
        audioURL: URL,
        cacheDirectory: URL,
        projectURL: URL,
        modelPath: String,
        language: String,
        contextHint: String?,
        whisper: String,
        ffmpeg: String,
        vadModelPath: String?,
        profile: WhisperLongFormProfile,
        chunkCount: Int,
        onProgress: @escaping (Double) -> Void,
        onLog: @escaping (String) -> Void
    ) async throws -> WhisperChunkOutput {
        let token = String(format: "chunk-%04d", chunk.index + 1)
        let cachedSRT = cacheDirectory.appendingPathComponent("\(token).srt")
        let cachedJSON = cacheDirectory.appendingPathComponent("\(token).json")
        if validCachedChunk(srtURL: cachedSRT, jsonURL: cachedJSON) {
            onLog("Сегмент \(chunk.index + 1)/\(chunkCount) восстановлен из проверенного кэша.")
            onProgress(0.08 + 0.92 * Double(chunk.index + 1) / Double(chunkCount))
            return WhisperChunkOutput(chunk: chunk, srtURL: cachedSRT, jsonURL: cachedJSON)
        }

        let audioPart = cacheDirectory.appendingPathComponent("\(token).partial.wav")
        defer { try? FileManager.default.removeItem(at: audioPart) }
        let extraction = try await runner.run(ffmpeg, [
            "-y", "-ss", String(format: "%.3f", chunk.extractionStart),
            "-i", audioURL.path,
            "-t", String(format: "%.3f", chunk.extractionEnd - chunk.extractionStart),
            "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", audioPart.path
        ], currentDirectory: projectURL)
        guard extraction.exitCode == 0, nonempty(audioPart) else {
            throw WorkflowError.processFailed("Не удалось извлечь аудио сегмента \(chunk.index + 1): \(extraction.stderr)")
        }

        let attempts = profile.attempts(vadModelPath: vadModelPath)
        var failures: [String] = []
        for (attemptIndex, attempt) in attempts.enumerated() {
            try Task.checkCancellation()
            let outputBase = cacheDirectory.appendingPathComponent("\(token).attempt")
            let attemptSRT = outputBase.appendingPathExtension("srt")
            let attemptJSON = outputBase.appendingPathExtension("json")
            try? FileManager.default.removeItem(at: attemptSRT)
            try? FileManager.default.removeItem(at: attemptJSON)
            let arguments = WhisperCLITranscriber(runner: runner, vadModelLocator: vadModelLocator).commandArguments(
                audioURL: audioPart,
                outputBase: outputBase,
                modelPath: modelPath,
                language: language,
                vadModelPath: attempt.vad,
                contextHint: contextHint,
                additionalArguments: attempt.extra
            )
            var parser = WhisperProgressParser()
            let result = try await runner.run(whisper, arguments, currentDirectory: projectURL) { _, text in
                guard let fraction = parser.consume(text) else { return }
                let base = Double(chunk.index) / Double(chunkCount)
                let current = (base + fraction / Double(chunkCount))
                onProgress(0.08 + current * 0.92)
            }
            guard result.exitCode == 0, nonempty(attemptSRT), nonempty(attemptJSON) else {
                failures.append("попытка \(attemptIndex + 1) (\(attempt.name)): whisper-cli завершился с ошибкой")
                continue
            }
            let cues = try srt.load(from: attemptSRT)
            if let issue = quality.recoveryIssue(cues: cues) {
                failures.append("попытка \(attemptIndex + 1) (\(attempt.name)): \(issue.message)")
                onLog("Сегмент \(chunk.index + 1)/\(chunkCount): обнаружена \(issue.message); выполняется автоматический повтор.")
                continue
            }
            try atomicReplace(cachedSRT, with: attemptSRT)
            try atomicReplace(cachedJSON, with: attemptJSON)
            onLog("Сегмент \(chunk.index + 1)/\(chunkCount) проверен, стратегия: \(attempt.name).")
            onProgress(0.08 + 0.92 * Double(chunk.index + 1) / Double(chunkCount))
            return WhisperChunkOutput(chunk: chunk, srtURL: cachedSRT, jsonURL: cachedJSON)
        }
        throw WorkflowError.processFailed(
            "Сегмент \(chunk.index + 1)/\(chunkCount) не прошёл автоматическое восстановление: \(failures.joined(separator: " | "))"
        )
    }

    func merge(
        outputs: [WhisperChunkOutput],
        mediaDuration: TimeInterval,
        jsonURL: URL
    ) throws -> [SubtitleCue] {
        var mergedCues: [SubtitleCue] = []
        var mergedSegments: [[String: Any]] = []
        var rootTemplate: [String: Any]?
        for output in outputs {
            let localCues = try srt.load(from: output.srtURL)
            for cue in localCues {
                let shiftedStart = output.chunk.extractionStart + cue.start
                let shiftedEnd = min(mediaDuration, output.chunk.extractionStart + cue.end)
                let midpoint = (shiftedStart + shiftedEnd) / 2
                let isLast = output.chunk.coreEnd >= mediaDuration - 0.001
                guard midpoint >= output.chunk.coreStart - 0.001,
                      midpoint < output.chunk.coreEnd || isLast else { continue }
                let start = max(shiftedStart, mergedCues.last?.end ?? 0)
                guard shiftedEnd > start else { continue }
                mergedCues.append(SubtitleCue(id: mergedCues.count + 1, start: start, end: shiftedEnd, text: cue.text))
            }

            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: output.jsonURL)) as? [String: Any]
            if rootTemplate == nil { rootTemplate = root }
            for segment in root?["transcription"] as? [[String: Any]] ?? [] {
                guard let range = localRange(segment) else { continue }
                let midpoint = output.chunk.extractionStart + (range.start + range.end) / 2
                let isLast = output.chunk.coreEnd >= mediaDuration - 0.001
                guard midpoint >= output.chunk.coreStart - 0.001,
                      midpoint < output.chunk.coreEnd || isLast else { continue }
                mergedSegments.append(shifted(segment, milliseconds: output.chunk.extractionStart * 1000))
            }
        }
        var root = rootTemplate ?? [:]
        root["transcription"] = mergedSegments
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: jsonURL, options: .atomic)
        return mergedCues
    }

    private func validCachedChunk(srtURL: URL, jsonURL: URL) -> Bool {
        guard nonempty(srtURL), nonempty(jsonURL), let cues = try? srt.load(from: srtURL) else { return false }
        return quality.recoveryIssue(cues: cues) == nil
    }

    private func cacheDirectory(
        layout: ProjectLayout,
        mediaURL: URL,
        modelPath: String,
        language: String,
        mediaDuration: TimeInterval,
        profile: WhisperLongFormProfile,
        contextHint: String?,
        vadModelPath: String?
    ) throws -> URL {
        let attributes = try FileManager.default.attributesOfItem(atPath: mediaURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let modelAttributes = try? FileManager.default.attributesOfItem(atPath: modelPath)
        let modelSize = (modelAttributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modelModified = (modelAttributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let vadIdentity: String
        if let vadModelPath {
            if let bytes = try? Data(contentsOf: URL(fileURLWithPath: vadModelPath)) {
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                vadIdentity = "\(vadModelPath)|\(digest)"
            } else {
                vadIdentity = "\(vadModelPath)|unreadable"
            }
        } else {
            vadIdentity = "none"
        }
        let identity = StableTopicHash.string(
            "segmented-whisper-v4|profile=\(profile.identifier)|overlap=\(profile.overlap)|" +
            "primary=\(profile.primaryArguments.joined(separator: ","))|" +
            "recovery=\(profile.recoveryArguments.joined(separator: ","))|" +
            "noVAD=\(profile.noVADArguments.joined(separator: ","))|" +
            "context=\(WhisperTranscriptionContext.normalized(contextHint) ?? "")|vad=\(vadIdentity)|" +
            "\(mediaURL.standardizedFileURL.path)|\(size)|\(modified)|" +
            "\(modelPath)|\(modelSize)|\(modelModified)|\(language)|\(mediaDuration)"
        )
        let url = layout.supportDirectory
            .appendingPathComponent("Transcription cache", isDirectory: true)
            .appendingPathComponent(identity, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func localRange(_ segment: [String: Any]) -> (start: TimeInterval, end: TimeInterval)? {
        if let offsets = segment["offsets"] as? [String: Any],
           let from = number(offsets["from"]), let to = number(offsets["to"]) {
            return (from / 1000, to / 1000)
        }
        if let timestamps = segment["timestamps"] as? [String: Any],
           let from = timestamp(timestamps["from"]), let to = timestamp(timestamps["to"]) {
            return (from, to)
        }
        return nil
    }

    private func shifted(_ value: [String: Any], milliseconds: Double) -> [String: Any] {
        shiftDictionary(value, milliseconds: milliseconds)
    }

    private func shiftDictionary(_ dictionary: [String: Any], milliseconds: Double) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dictionary {
            if key == "offsets", var offsets = value as? [String: Any] {
                for boundary in ["from", "to"] {
                    if let number = number(offsets[boundary]) { offsets[boundary] = number + milliseconds }
                }
                result[key] = offsets
            } else if key == "timestamps", var timestamps = value as? [String: Any] {
                for boundary in ["from", "to"] {
                    if let seconds = timestamp(timestamps[boundary]) {
                        timestamps[boundary] = formattedTimestamp(seconds + milliseconds / 1000)
                    }
                }
                result[key] = timestamps
            } else if let child = value as? [String: Any] {
                result[key] = shiftDictionary(child, milliseconds: milliseconds)
            } else if let children = value as? [[String: Any]] {
                result[key] = children.map { shiftDictionary($0, milliseconds: milliseconds) }
            } else {
                result[key] = value
            }
        }
        return result
    }

    private func timestamp(_ value: Any?) -> TimeInterval? {
        if let number = number(value) { return number > 1000 ? number / 1000 : number }
        guard let text = value as? String else { return nil }
        return try? TimecodeParser.parse(text.replacingOccurrences(of: ",", with: "."))
    }

    private func formattedTimestamp(_ value: TimeInterval) -> String {
        SRTService().formatTimestamp(value).replacingOccurrences(of: ",", with: ".")
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private func nonempty(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0
    }

    private func atomicReplace(_ destination: URL, with source: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }
}
