import Foundation

struct LocalWhisperRetryService {
    let runner: ToolRunner
    private let srt = SRTService()

    init(runner: ToolRunner = ToolRunner()) {
        self.runner = runner
    }

    func addSuggestions(
        to tasks: [ReviewTask],
        mediaURL: URL,
        projectURL: URL,
        modelPath: String,
        language: ArtifactLanguage,
        onLog: @escaping (String) -> Void
    ) async throws -> [ReviewTask] {
        var updated = tasks
        let eligible = updated.indices.filter { index in
            let reasons = Set(updated[index].reasonCodes)
            return reasons.contains("low-confidence") || reasons.contains("implausible-text-rate")
        }
        guard !eligible.isEmpty else { return updated }
        guard let ffmpeg = runner.resolve("ffmpeg"), let whisper = runner.resolve("whisper-cli") else {
            return markUnavailable(updated, indices: eligible, onLog: onLog)
        }

        for (position, index) in eligible.enumerated() {
            try Task.checkCancellation()
            let task = updated[index]
            do {
                let candidate = try await retry(
                    task: task,
                    mediaURL: mediaURL,
                    projectURL: projectURL,
                    modelPath: modelPath,
                    language: language,
                    ffmpeg: ffmpeg,
                    whisper: whisper
                )
                if isImprovement(candidate, over: task.originalText, language: language) {
                    updated[index].suggestedText = candidate
                    updated[index].reasonCodes.append("local-whisper-retry-suggested")
                } else {
                    updated[index].reasonCodes.append("local-whisper-retry-no-improvement")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                updated[index].reasonCodes.append("local-whisper-retry-failed")
                onLog("Локальный повтор Whisper для cue \(task.cueIDs.first ?? -1) не дал результата: \(error.localizedDescription)")
            }
            updated[index].reasonCodes = Array(Set(updated[index].reasonCodes)).sorted()
            onLog("Локальная перепроверка Whisper: \(position + 1)/\(eligible.count).")
        }
        return updated
    }

    private func retry(
        task: ReviewTask,
        mediaURL: URL,
        projectURL: URL,
        modelPath: String,
        language: ArtifactLanguage,
        ffmpeg: String,
        whisper: String
    ) async throws -> String {
        let directory = ProjectLayout(root: projectURL).qualityDirectory
            .appendingPathComponent(".local-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = max(0, task.start - 0.6)
        let duration = max(1, task.end - task.start + 1.2)
        let audioURL = directory.appendingPathComponent("fragment.wav")
        let extract = try await runner.run(ffmpeg, [
            "-y",
            "-ss", String(format: "%.3f", start),
            "-i", mediaURL.path,
            "-t", String(format: "%.3f", duration),
            "-map", "0:a:0",
            "-vn",
            "-ac", "1",
            "-ar", "16000",
            "-c:a", "pcm_s16le",
            audioURL.path
        ])
        guard extract.exitCode == 0, FileManager.default.fileExists(atPath: audioURL.path) else {
            throw WorkflowError.processFailed("не удалось извлечь локальный аудиофрагмент")
        }
        let outputBase = directory.appendingPathComponent("retry")
        let result = try await runner.run(whisper, [
            "-f", audioURL.path,
            "-m", modelPath,
            "-l", language.rawValue,
            "-osrt",
            "-of", outputBase.path,
            "-nf",
            "-sns"
        ], currentDirectory: projectURL)
        let outputSRT = directory.appendingPathComponent("retry.srt")
        guard result.exitCode == 0, FileManager.default.fileExists(atPath: outputSRT.path) else {
            throw WorkflowError.processFailed("whisper-cli отклонил локальный повтор")
        }
        let cues = try srt.load(from: outputSRT)
        let text = cues.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WorkflowError.processFailed("локальный повтор вернул пустой текст") }
        return text
    }

    func isImprovement(_ candidate: String, over original: String, language: ArtifactLanguage) -> Bool {
        let normalizedCandidate = normalize(candidate)
        guard !normalizedCandidate.isEmpty, normalizedCandidate != normalize(original) else { return false }
        let words = normalizedCandidate.split(separator: " ")
        guard words.count < 3 || Set(words).count > 1 else { return false }
        let cyrillic = candidate.unicodeScalars.filter { (0x0400...0x04FF).contains(Int($0.value)) }.count
        let latin = candidate.unicodeScalars.filter {
            (0x0041...0x005A).contains(Int($0.value)) || (0x0061...0x007A).contains(Int($0.value))
        }.count
        return language == .ru ? cyrillic >= latin : latin >= cyrillic
    }

    private func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .joined(separator: " ")
    }

    private func markUnavailable(
        _ tasks: [ReviewTask],
        indices: [Int],
        onLog: (String) -> Void
    ) -> [ReviewTask] {
        var updated = tasks
        for index in indices {
            updated[index].reasonCodes.append("local-whisper-retry-unavailable")
            updated[index].reasonCodes = Array(Set(updated[index].reasonCodes)).sorted()
        }
        onLog("Локальная перепроверка Whisper недоступна; задания ручной проверки сохранены.")
        return updated
    }
}
