import Foundation

struct SpeechSynthesisResult {
    var voiceIdentifier: String
    var voiceProviderVersion: String
    var cues: [DubbingCueRecord]
    var reviewTasks: [ReviewTask]
}

struct SpeechSynthesisAdapter {
    let runner: ToolRunner
    let voiceOverrides: [ArtifactLanguage: String]

    init(runner: ToolRunner = ToolRunner(), voiceOverrides: [ArtifactLanguage: String] = [:]) {
        self.runner = runner
        self.voiceOverrides = voiceOverrides
    }

    func synthesize(
        cues: [SubtitleCue],
        language: ArtifactLanguage,
        transcriptRevisionID: String,
        mediaURL: URL,
        mediaDuration: TimeInterval,
        outputAudioURL: URL,
        outputVideoURL: URL,
        mixMode: DubbingMixMode,
        onProgress: @escaping (Double) -> Void
    ) async throws -> SpeechSynthesisResult {
        guard !cues.isEmpty else { throw WorkflowError.missingFullSRT }
        let voice = try await selectedVoice(for: language)
        let ffmpeg = preferredFFmpeg()
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else { throw WorkflowError.missingTool("ffmpeg") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("videotext-dubbing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var concatFiles: [URL] = []
        var cueRecords: [DubbingCueRecord] = []
        var reviewTasks: [ReviewTask] = []
        var cursor: TimeInterval = 0
        let ordered = cues.sorted { $0.start < $1.start }

        for (index, cue) in ordered.enumerated() {
            try Task.checkCancellation()
            if cue.start > cursor {
                concatFiles.append(try await silence(duration: cue.start - cursor, index: concatFiles.count, directory: temp, ffmpeg: ffmpeg))
                cursor = cue.start
            }
            let overlap = max(0, cursor - cue.start)
            let targetDuration = max(0.08, cue.end - max(cursor, cue.start))
            let raw = temp.appendingPathComponent("raw-\(index).aiff")
            let spoken = try await runner.run("/usr/bin/say", ["-v", voice, "-o", raw.path, cue.text])
            guard spoken.exitCode == 0, FileManager.default.fileExists(atPath: raw.path) else {
                throw WorkflowError.processFailed("Системный TTS не создал cue \(cue.id): \(spoken.stderr)")
            }
            guard let spokenDuration = try await FFmpegAdapter(runner: runner).duration(of: raw), spokenDuration > 0 else {
                throw WorkflowError.processFailed("Не удалось измерить TTS cue \(cue.id).")
            }
            let tempo = max(1, spokenDuration / targetDuration)
            let needsReview = tempo > 1.35 || overlap > 0
            if needsReview {
                reviewTasks.append(ReviewTask(
                    id: "dubbing-review-\(transcriptRevisionID)-cue-\(cue.id)",
                    transcriptRevisionID: transcriptRevisionID,
                    status: .needsReview,
                    language: language,
                    start: cue.start,
                    end: cue.end,
                    cueIDs: [cue.id],
                    reasonCodes: overlap > 0 ? ["dubbing-overlapping-cue", "dubbing-tempo-review"] : ["dubbing-tempo-review"],
                    confidence: nil,
                    originalText: cue.text,
                    suggestedText: nil,
                    createdAt: Date(),
                    resolvedAt: nil,
                    dependentArtifactIDs: []
                ))
            }
            let fitted = temp.appendingPathComponent("cue-\(index).wav")
            let filter = "rubberband=tempo=\(String(format: "%.6f", tempo)),apad,atrim=duration=\(String(format: "%.6f", targetDuration))"
            let converted = try await runner.run(ffmpeg, [
                "-y", "-i", raw.path, "-af", filter,
                "-ar", "48000", "-ac", "1", "-c:a", "pcm_s16le", fitted.path
            ])
            guard converted.exitCode == 0, FileManager.default.fileExists(atPath: fitted.path) else {
                throw WorkflowError.processFailed("Не удалось синхронизировать TTS cue \(cue.id): \(converted.stderr)")
            }
            concatFiles.append(fitted)
            cursor += targetDuration
            cueRecords.append(DubbingCueRecord(
                cueID: cue.id,
                start: cue.start,
                end: cue.end,
                synthesizedDuration: spokenDuration,
                tempo: tempo,
                needsReview: needsReview
            ))
            onProgress(Double(index + 1) / Double(max(ordered.count, 1)) * 0.7)
        }
        if cursor < mediaDuration {
            concatFiles.append(try await silence(duration: mediaDuration - cursor, index: concatFiles.count, directory: temp, ffmpeg: ffmpeg))
        }
        let listURL = temp.appendingPathComponent("concat.txt")
        let list = concatFiles.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n") + "\n"
        try list.write(to: listURL, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: outputAudioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputVideoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partialAudio = partialURL(outputAudioURL)
        let partialVideo = partialURL(outputVideoURL)
        defer {
            try? FileManager.default.removeItem(at: partialAudio)
            try? FileManager.default.removeItem(at: partialVideo)
        }
        let joined = try await runner.run(ffmpeg, [
            "-y", "-f", "concat", "-safe", "0", "-i", listURL.path,
            "-c:a", "aac", "-b:a", "192k", partialAudio.path
        ])
        guard joined.exitCode == 0, FileManager.default.fileExists(atPath: partialAudio.path) else {
            throw WorkflowError.processFailed("Не удалось собрать дорожку дубляжа: \(joined.stderr)")
        }
        try replace(partialAudio, outputAudioURL)
        onProgress(0.8)

        var muxArguments = ["-y", "-i", mediaURL.path, "-i", outputAudioURL.path]
        switch mixMode {
        case .replace:
            muxArguments += ["-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-c:a", "copy"]
        case .mixQuietOriginal:
            muxArguments += [
                "-filter_complex", "[0:a]volume=0.18[original];[original][1:a]amix=inputs=2:duration=longest,loudnorm=I=-16:TP=-1.5:LRA=11[mixed]",
                "-map", "0:v:0", "-map", "[mixed]", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k"
            ]
        }
        muxArguments += ["-movflags", "+faststart", partialVideo.path]
        let mux = try await runner.run(ffmpeg, muxArguments)
        guard mux.exitCode == 0, FileManager.default.fileExists(atPath: partialVideo.path) else {
            throw WorkflowError.processFailed("Не удалось собрать видео с дубляжом: \(mux.stderr)")
        }
        try replace(partialVideo, outputVideoURL)
        _ = try await FFmpegAdapter(runner: runner).strictValidationReport(mediaURL: outputVideoURL, expectedDuration: mediaDuration)
        onProgress(1)
        return SpeechSynthesisResult(
            voiceIdentifier: voice,
            voiceProviderVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            cues: cueRecords,
            reviewTasks: reviewTasks
        )
    }

    private func selectedVoice(for language: ArtifactLanguage) async throws -> String {
        let preferred: String
        if let override = voiceOverrides[language] {
            preferred = override
        } else if language == .en {
            preferred = "Daniel (Enhanced)"
        } else {
            preferred = "Yuri (Enhanced)"
        }
        let result = try await runner.run("/usr/bin/say", ["-v", "?"])
        guard result.exitCode == 0,
              result.stdout.split(separator: "\n").contains(where: { $0.hasPrefix(preferred + " ") }) else {
            throw WorkflowError.processFailed(
                "Улучшенный мужской системный голос \(preferred) для \(language.rawValue.uppercased()) не установлен. Добавьте его в Системные настройки > Универсальный доступ > Чтение и речь > Системный голос."
            )
        }
        return preferred
    }

    private func preferredFFmpeg() -> String {
        for path in ["/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg", "/usr/local/opt/ffmpeg-full/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return runner.resolve("ffmpeg") ?? ""
    }

    private func silence(duration: TimeInterval, index: Int, directory: URL, ffmpeg: String) async throws -> URL {
        let output = directory.appendingPathComponent("silence-\(index).wav")
        let result = try await runner.run(ffmpeg, [
            "-y", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono",
            "-t", String(format: "%.6f", duration), "-c:a", "pcm_s16le", output.path
        ])
        guard result.exitCode == 0 else { throw WorkflowError.processFailed("Не удалось создать паузу TTS: \(result.stderr)") }
        return output
    }

    private func partialURL(_ output: URL) -> URL {
        output.deletingPathExtension().appendingPathExtension("partial").appendingPathExtension(output.pathExtension)
    }

    private func replace(_ source: URL, _ destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: source, to: destination)
    }
}
