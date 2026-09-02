import Foundation

struct AudioEnhancementResult {
    var filterGraph: String
    var backendModel: String
    var before: AudioAnalysisReport
    var after: AudioAnalysisReport
}

struct AudioEnhancementAdapter {
    private static let backendRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/videotext/audio/audio-separator", isDirectory: true)

    let runner: ToolRunner

    init(runner: ToolRunner = ToolRunner()) {
        self.runner = runner
    }

    func analyze(mediaURL: URL) async throws -> AudioAnalysisReport {
        guard let ffmpeg = runner.resolve("ffmpeg") else { throw WorkflowError.missingTool("ffmpeg") }
        let ffmpegAdapter = FFmpegAdapter(runner: runner)
        guard let duration = try await ffmpegAdapter.duration(of: mediaURL), duration > 0 else {
            throw WorkflowError.processFailed("Не удалось определить длительность для анализа звука.")
        }
        let metrics = try await runner.run(ffmpeg, [
            "-hide_banner", "-i", mediaURL.path,
            "-af", "astats=metadata=0:reset=0,volumedetect,silencedetect=n=-45dB:d=0.3",
            "-f", "null", "-"
        ])
        guard metrics.exitCode == 0 else {
            throw WorkflowError.processFailed("Ошибка анализа звука ffmpeg: \(metrics.stderr)")
        }
        let loudness = try await runner.run(ffmpeg, [
            "-hide_banner", "-i", mediaURL.path,
            "-af", "loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json",
            "-f", "null", "-"
        ])
        guard loudness.exitCode == 0 else {
            throw WorkflowError.processFailed("Ошибка анализа loudness ffmpeg: \(loudness.stderr)")
        }
        let mean = capture(#"mean_volume:\s*(-?\d+(?:\.\d+)?) dB"#, in: metrics.stderr)
        let max = capture(#"max_volume:\s*(-?\d+(?:\.\d+)?) dB"#, in: metrics.stderr)
        let noise = capture(#"Noise floor dB:\s*(-?\d+(?:\.\d+)?)"#, in: metrics.stderr)
        let silence = captures(#"silence_duration:\s*(\d+(?:\.\d+)?)"#, in: metrics.stderr).reduce(0, +)
        let inputI = captureJSONNumber("input_i", in: loudness.stderr)
        let inputTP = captureJSONNumber("input_tp", in: loudness.stderr)
        var warnings: [String] = []
        if let max, max > -0.1 { warnings.append("Пики близки к clipping; требуется ограничение true peak.") }
        if let mean, mean < -35 { warnings.append("Средняя громкость очень низкая.") }
        warnings.append("Эхо/реверберация не оцениваются надёжно стандартными метриками FFmpeg; нужен контрольный benchmark.")
        return AudioAnalysisReport(
            schemaVersion: 1,
            analyzedAt: Date(),
            sourceMediaPath: mediaURL.path,
            duration: duration,
            meanVolumeDB: mean,
            maxVolumeDB: max,
            integratedLoudnessLUFS: inputI,
            truePeakDB: inputTP,
            silenceDuration: silence,
            stationaryNoiseEstimateDB: noise,
            echoAssessment: "not-assessed-without-benchmark",
            warnings: warnings
        )
    }

    func enhance(
        mediaURL: URL,
        outputAudioURL: URL,
        outputVideoURL: URL,
        profile: AudioEnhancementProfile,
        sourceLanguage: ArtifactLanguage?,
        before: AudioAnalysisReport,
        onProgress: @escaping (Double) -> Void
    ) async throws -> AudioEnhancementResult {
        guard let ffmpeg = runner.resolve("ffmpeg") else { throw WorkflowError.missingTool("ffmpeg") }
        let separator = Self.backendRoot.appendingPathComponent("venv/bin/audio-separator")
        let modelDirectory = Self.backendRoot.appendingPathComponent("models", isDirectory: true)
        guard FileManager.default.isExecutableFile(atPath: separator.path) else {
            throw WorkflowError.missingTool("audio-separator (запустите scripts/setup_uvr_dereverb.sh)")
        }
        let model = profile.backendModel(for: sourceLanguage)
        guard FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent(model).path) else {
            throw WorkflowError.processFailed("Не найдена модель \(model). Запустите scripts/setup_uvr_dereverb.sh.")
        }
        let noiseFloor: Int
        let highPass: Int
        switch profile {
        case .light: (highPass, noiseFloor) = (70, -35)
        case .normal: (highPass, noiseFloor) = (80, -30)
        case .strong: (highPass, noiseFloor) = (90, -25)
        }
        let graph = "highpass=f=\(highPass),afftdn=nf=\(noiseFloor):tn=1,loudnorm=I=-16:TP=-1.5:LRA=11"
        try FileManager.default.createDirectory(at: outputAudioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputVideoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let separatorOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent("videotext-uvr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: separatorOutput, withIntermediateDirectories: true)
        let dereverbedAudio = separatorOutput.appendingPathComponent("dereverbed.wav")
        let partialAudio = partialURL(for: outputAudioURL)
        let partialVideo = partialURL(for: outputVideoURL)
        defer {
            try? FileManager.default.removeItem(at: separatorOutput)
            try? FileManager.default.removeItem(at: partialAudio)
            try? FileManager.default.removeItem(at: partialVideo)
        }
        onProgress(0.02)
        let separated = try await runner.run(separator.path, [
            "--log_level", "warning",
            "--model_file_dir", modelDirectory.path,
            "--model_filename", model,
            "--output_format", "WAV",
            "--output_dir", separatorOutput.path,
            "--single_stem", "No Echo",
            "--custom_output_names", "{\"No Echo\":\"dereverbed\"}",
            mediaURL.path
        ])
        guard separated.exitCode == 0, FileManager.default.fileExists(atPath: dereverbedAudio.path) else {
            throw WorkflowError.processFailed("Ошибка удаления реверберации UVR: \(separated.stderr)")
        }
        onProgress(0.55)
        var parser = FFmpegProgressParser(duration: before.duration)
        let audio = try await runner.run(ffmpeg, [
            "-y", "-i", dereverbedAudio.path,
            "-vn", "-af", graph,
            "-c:a", "aac", "-b:a", "192k",
            "-progress", "pipe:1", "-nostats",
            partialAudio.path
        ]) { stream, chunk in
            guard stream == .stdout, let fraction = parser.consume(chunk) else { return }
            onProgress(0.55 + fraction * 0.25)
        }
        guard audio.exitCode == 0, FileManager.default.fileExists(atPath: partialAudio.path) else {
            throw WorkflowError.processFailed("Ошибка улучшения звука ffmpeg: \(audio.stderr)")
        }
        try replace(partialAudio, outputAudioURL)
        let after = try await analyze(mediaURL: outputAudioURL)
        if let max = after.maxVolumeDB, max > 0.05 {
            throw WorkflowError.processFailed("Улучшенная дорожка отклонена: обнаружен clipping \(max) dB.")
        }
        if let truePeak = after.truePeakDB, truePeak > -1.0 {
            throw WorkflowError.processFailed("Улучшенная дорожка отклонена: true peak \(truePeak) dB выше безопасного предела -1 dB.")
        }
        if let loudness = after.integratedLoudnessLUFS, !(-19.0 ... -13.0).contains(loudness) {
            throw WorkflowError.processFailed("Улучшенная дорожка отклонена: громкость \(loudness) LUFS вне допуска -19...-13 LUFS.")
        }
        guard abs(after.duration - before.duration) <= 0.25 else {
            throw WorkflowError.processFailed("Улучшенная дорожка изменила длительность.")
        }
        var muxParser = FFmpegProgressParser(duration: before.duration)
        let mux = try await runner.run(ffmpeg, [
            "-y", "-i", mediaURL.path, "-i", outputAudioURL.path,
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "copy", "-c:a", "copy", "-movflags", "+faststart",
            "-progress", "pipe:1", "-nostats", partialVideo.path
        ]) { stream, chunk in
            guard stream == .stdout, let fraction = muxParser.consume(chunk) else { return }
            onProgress(0.80 + fraction * 0.20)
        }
        guard mux.exitCode == 0, FileManager.default.fileExists(atPath: partialVideo.path) else {
            throw WorkflowError.processFailed("Ошибка сборки видео с улучшенным звуком: \(mux.stderr)")
        }
        try replace(partialVideo, outputVideoURL)
        _ = try await FFmpegAdapter(runner: runner).strictValidationReport(mediaURL: outputVideoURL, expectedDuration: before.duration)
        onProgress(1)
        return AudioEnhancementResult(filterGraph: graph, backendModel: model, before: before, after: after)
    }

    private func capture(_ pattern: String, in text: String) -> Double? {
        captures(pattern, in: text).first
    }

    private func captures(_ pattern: String, in text: String) -> [Double] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            return Double(text[valueRange])
        }
    }

    private func captureJSONNumber(_ key: String, in text: String) -> Double? {
        capture("\\\"\(NSRegularExpression.escapedPattern(for: key))\\\"\\s*:\\s*\\\"?(-?\\d+(?:\\.\\d+)?)", in: text)
    }

    private func partialURL(for output: URL) -> URL {
        output.deletingPathExtension().appendingPathExtension("partial").appendingPathExtension(output.pathExtension)
    }

    private func replace(_ source: URL, _ destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: source, to: destination)
    }
}

private extension AudioEnhancementProfile {
    func backendModel(for language: ArtifactLanguage?) -> String {
        if self == .strong, language == .en {
            return "UVR-De-Echo-Aggressive.pth"
        }
        return "UVR-De-Echo-Normal.pth"
    }
}
