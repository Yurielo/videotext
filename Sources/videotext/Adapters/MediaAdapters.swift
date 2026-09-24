import Foundation

struct TranscriptionResult {
    var srtURL: URL
    var jsonURL: URL
}

struct WhisperCLITranscriber {
    let runner: ToolRunner
    let vadModelLocator: WhisperVADModelLocator

    init(
        runner: ToolRunner = ToolRunner(),
        vadModelLocator: WhisperVADModelLocator = WhisperVADModelLocator()
    ) {
        self.runner = runner
        self.vadModelLocator = vadModelLocator
    }

    func transcribe(
        mediaURL: URL,
        projectURL: URL,
        mediaDuration: TimeInterval,
        modelPath: String,
        language: String,
        onProgress: @escaping (Double) -> Void,
        onLog: @escaping (String) -> Void = { _ in }
    ) async throws -> TranscriptionResult {
        guard let whisper = runner.resolve("whisper-cli") else { throw WorkflowError.missingTool("whisper-cli") }
        let layout = ProjectLayout(root: projectURL)
        let audioURL = try await prepareAudio(mediaURL: mediaURL, projectURL: projectURL, mediaDuration: mediaDuration) { fraction in
            onProgress(fraction * 0.08)
        }
        if WhisperChunkPlanner.shouldSegment(duration: mediaDuration) {
            return try await SegmentedWhisperTranscriber(
                runner: runner,
                vadModelLocator: vadModelLocator
            ).transcribe(
                audioURL: audioURL,
                mediaURL: mediaURL,
                projectURL: projectURL,
                mediaDuration: mediaDuration,
                modelPath: modelPath,
                language: language,
                onProgress: onProgress,
                onLog: onLog
            )
        }
        let outputBase = layout.textsDirectory.appendingPathComponent("full.partial")
        let partialSRT = layout.textsDirectory.appendingPathComponent("full.partial.srt")
        let partialJSON = layout.textsDirectory.appendingPathComponent("full.partial.json")
        try? FileManager.default.removeItem(at: partialSRT)
        try? FileManager.default.removeItem(at: partialJSON)
        defer {
            try? FileManager.default.removeItem(at: partialSRT)
            try? FileManager.default.removeItem(at: partialJSON)
        }

        let vadModelPath = vadModelLocator.bestModelPath()
        var args = commandArguments(
            audioURL: audioURL,
            outputBase: outputBase,
            modelPath: modelPath,
            language: language,
            vadModelPath: vadModelPath
        )
        if let vadModelPath {
            onLog("Silero VAD: \(vadModelPath)")
        } else {
            onLog("Silero VAD не найден; используется стандартная сегментация Whisper.")
        }

        var parser = WhisperProgressParser()
        var result = try await runner.run(whisper, args, currentDirectory: projectURL) { _, chunk in
            if let fraction = parser.consume(chunk) {
                onProgress(0.08 + fraction * 0.92)
            }
        }
        var diagnostic = result.stderr + "\n" + result.stdout
        if result.exitCode != 0,
           vadModelPath != nil,
           diagnostic.localizedCaseInsensitiveContains("vad") || diagnostic.localizedCaseInsensitiveContains("silero") {
            onLog("Silero VAD не загрузился. Расшифровка повторяется со стандартной сегментацией Whisper.")
            try? FileManager.default.removeItem(at: partialSRT)
            try? FileManager.default.removeItem(at: partialJSON)
            args = commandArguments(
                audioURL: audioURL,
                outputBase: outputBase,
                modelPath: modelPath,
                language: language,
                vadModelPath: nil
            )
            parser = WhisperProgressParser()
            result = try await runner.run(whisper, args, currentDirectory: projectURL) { _, chunk in
                if let fraction = parser.consume(chunk) {
                    onProgress(0.08 + fraction * 0.92)
                }
            }
            diagnostic = result.stderr + "\n" + result.stdout
        }
        if result.exitCode != 0,
           (diagnostic.localizedCaseInsensitiveContains("OutOfMemory")
            || diagnostic.localizedCaseInsensitiveContains("Insufficient Memory")) {
            onLog("Whisper не смог выделить память Metal. Повторный запуск выполняется на CPU.")
            try? FileManager.default.removeItem(at: partialSRT)
            try? FileManager.default.removeItem(at: partialJSON)
            parser = WhisperProgressParser()
            result = try await runner.run(whisper, args + ["--no-gpu"], currentDirectory: projectURL) { _, chunk in
                if let fraction = parser.consume(chunk) {
                    onProgress(0.08 + fraction * 0.92)
                }
            }
        }
        guard result.exitCode == 0,
              FileManager.default.fileExists(atPath: partialSRT.path),
              FileManager.default.fileExists(atPath: partialJSON.path) else {
            throw WorkflowError.processFailed("Ошибка whisper-cli: \(result.stderr.isEmpty ? result.stdout : result.stderr)")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: partialSRT.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
            throw WorkflowError.processFailed("whisper-cli создал пустой full.srt. Проверьте, есть ли в выбранном медиа речь.")
        }
        let jsonAttributes = try FileManager.default.attributesOfItem(atPath: partialJSON.path)
        guard (jsonAttributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
            throw WorkflowError.processFailed("whisper-cli создал пустой whisper.json.")
        }
        try replaceItem(at: layout.whisperJSONURL, with: partialJSON)
        try replaceItem(at: layout.fullSRTURL, with: partialSRT)
        onProgress(1)
        return TranscriptionResult(srtURL: layout.fullSRTURL, jsonURL: layout.whisperJSONURL)
    }

    func commandArguments(
        audioURL: URL,
        outputBase: URL,
        modelPath: String,
        language: String,
        vadModelPath: String?
    ) -> [String] {
        var args = [
            "-f", audioURL.path,
            "-osrt",
            "-ojf",
            "-of", outputBase.path,
            "--print-progress",
            "--print-confidence"
        ]
        if !modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-m", modelPath]
        }
        if !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-l", language]
        }
        if let vadModelPath,
           !vadModelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["--vad", "-vm", vadModelPath]
        }
        return args
    }

    private func prepareAudio(
        mediaURL: URL,
        projectURL: URL,
        mediaDuration: TimeInterval,
        onProgress: @escaping (Double) -> Void
    ) async throws -> URL {
        guard let ffmpeg = runner.resolve("ffmpeg") else { throw WorkflowError.missingTool("ffmpeg") }
        guard try await hasAudioStream(in: mediaURL) else {
            throw WorkflowError.processFailed("В выбранном медиафайле отсутствует аудиодорожка.")
        }
        let layout = ProjectLayout(root: projectURL)
        let partialAudio = layout.supportDirectory.appendingPathComponent("source_audio.partial.wav")
        try? FileManager.default.removeItem(at: partialAudio)
        defer { try? FileManager.default.removeItem(at: partialAudio) }
        var parser = FFmpegProgressParser(duration: mediaDuration)
        let result = try await runner.run(ffmpeg, [
            "-y",
            "-i", mediaURL.path,
            "-map", "0:a:0",
            "-vn",
            "-ac", "1",
            "-ar", "16000",
            "-c:a", "pcm_s16le",
            "-progress", "pipe:1",
            "-nostats",
            partialAudio.path
        ], currentDirectory: projectURL) { stream, chunk in
            guard stream == .stdout, let fraction = parser.consume(chunk) else { return }
            onProgress(fraction)
        }
        guard result.exitCode == 0, FileManager.default.fileExists(atPath: partialAudio.path) else {
            throw WorkflowError.processFailed("Не удалось подготовить аудио для whisper-cli: \(result.stderr)")
        }
        try replaceItem(at: layout.sourceAudioURL, with: partialAudio)
        onProgress(1)
        return layout.sourceAudioURL
    }

    private func hasAudioStream(in mediaURL: URL) async throws -> Bool {
        guard let ffprobe = runner.resolve("ffprobe") else { throw WorkflowError.missingTool("ffprobe") }
        let result = try await runner.run(ffprobe, [
            "-v", "error",
            "-select_streams", "a:0",
            "-show_entries", "stream=index",
            "-of", "csv=p=0",
            mediaURL.path
        ])
        return result.exitCode == 0 && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct FFmpegAdapter {
    let runner: ToolRunner

    init(runner: ToolRunner = ToolRunner()) {
        self.runner = runner
    }

    func duration(of mediaURL: URL) async throws -> TimeInterval? {
        guard let ffprobe = runner.resolve("ffprobe") else { throw WorkflowError.missingTool("ffprobe") }
        let result = try await runner.run(ffprobe, [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            mediaURL.path
        ])
        guard result.exitCode == 0 else { return nil }
        return TimeInterval(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func cutAccurate(
        mediaURL: URL,
        start: TimeInterval,
        end: TimeInterval,
        outputURL: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        guard let ffmpeg = runner.resolve("ffmpeg") else { throw WorkflowError.missingTool("ffmpeg") }
        guard end > start else { throw WorkflowError.invalidRange }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = partialURL(for: outputURL)
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }
        let clipDuration = end - start
        var parser = FFmpegProgressParser(duration: clipDuration)
        let result = try await runner.run(ffmpeg, [
            "-y",
            "-ss", String(format: "%.3f", start),
            "-i", mediaURL.path,
            "-t", String(format: "%.3f", clipDuration),
            "-map", "0:v:0",
            "-map", "0:a:0?",
            "-c:v", "libx264",
            "-preset", "medium",
            "-crf", "18",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-b:a", "192k",
            "-movflags", "+faststart",
            "-progress", "pipe:1",
            "-nostats",
            partial.path
        ]) { stream, chunk in
            guard stream == .stdout, let fraction = parser.consume(chunk) else { return }
            onProgress(fraction)
        }
        guard result.exitCode == 0, FileManager.default.fileExists(atPath: partial.path) else {
            throw WorkflowError.processFailed("Ошибка точной вырезки ffmpeg: \(result.stderr)")
        }
        try replaceItem(at: outputURL, with: partial)
        onProgress(1)
    }

    func burnSubtitles(
        mediaURL: URL,
        srtURL: URL,
        outputURL: URL,
        mediaDuration: TimeInterval,
        style: SubtitleStyleSettings = .standard,
        copyAudio: Bool = true,
        onProgress: @escaping (Double) -> Void
    ) async throws -> String {
        guard let ffmpeg = await ffmpegWithSubtitlesFilter() else {
            throw WorkflowError.processFailed("Не найден FFmpeg с фильтром subtitles (libass). Установите или выберите сборку ffmpeg-full.")
        }
        let temporarySRT = FileManager.default.temporaryDirectory
            .appendingPathComponent("videotext-subtitles-\(UUID().uuidString).srt")
        try Data(contentsOf: srtURL).write(to: temporarySRT, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporarySRT) }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = partialURL(for: outputURL)
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }

        var parser = FFmpegProgressParser(duration: mediaDuration)
        var arguments = [
            "-y",
            "-i", mediaURL.path,
            "-vf", "subtitles=filename='\(temporarySRT.path)':force_style='\(assStyle(style))'",
            "-c:v", "libx264",
            "-preset", "medium",
            "-crf", "18",
            "-pix_fmt", "yuv420p"
        ]
        arguments += copyAudio ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "192k"]
        arguments += [
            "-map_chapters", "-1",
            "-movflags", "+faststart",
            "-progress", "pipe:1",
            "-nostats",
            partial.path
        ]
        let result = try await runner.run(ffmpeg, arguments) { stream, chunk in
            guard stream == .stdout, let fraction = parser.consume(chunk) else { return }
            onProgress(fraction)
        }
        guard result.exitCode == 0, FileManager.default.fileExists(atPath: partial.path) else {
            throw WorkflowError.processFailed("Ошибка вшивания субтитров ffmpeg: \(result.stderr)")
        }
        try replaceItem(at: outputURL, with: partial)
        onProgress(1)
        return ffmpeg
    }

    func adjustSpeed(
        mediaURL: URL,
        outputURL: URL,
        speedFactor: Double,
        mediaDuration: TimeInterval,
        onProgress: @escaping (Double) -> Void
    ) async throws -> String {
        guard speedFactor >= 0.5, speedFactor <= 2 else {
            throw WorkflowError.processFailed("Коэффициент скорости должен быть от 0.5 до 2.0.")
        }
        guard let selection = await ffmpegForSpeedAdjustment() else {
            throw WorkflowError.missingTool("ffmpeg")
        }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = partialURL(for: outputURL)
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }

        let expectedDuration = mediaDuration / speedFactor
        var parser = FFmpegProgressParser(duration: expectedDuration)
        let factor = String(format: "%.6f", speedFactor)
        let hasAudio = try await containsAudioStream(mediaURL)
        let audioFilter = hasAudio
            ? (selection.hasRubberband ? "rubberband=tempo=\(factor)" : "atempo=\(factor)")
            : "none"
        var arguments = [
            "-y",
            "-i", mediaURL.path,
            "-map", "0:v:0",
            "-filter:v", "setpts=PTS/\(factor)",
            "-c:v", "libx264",
            "-preset", "medium",
            "-crf", "18",
            "-pix_fmt", "yuv420p"
        ]
        if hasAudio {
            arguments += [
                "-map", "0:a:0",
                "-filter:a", audioFilter,
                "-c:a", "aac",
                "-b:a", "192k"
            ]
        }
        arguments += [
            "-movflags", "+faststart",
            "-progress", "pipe:1",
            "-nostats",
            partial.path
        ]
        let result = try await runner.run(selection.path, arguments) { stream, chunk in
            guard stream == .stdout, let fraction = parser.consume(chunk) else { return }
            onProgress(fraction)
        }
        guard result.exitCode == 0, FileManager.default.fileExists(atPath: partial.path) else {
            throw WorkflowError.processFailed("Ошибка изменения скорости ffmpeg: \(result.stderr)")
        }
        try replaceItem(at: outputURL, with: partial)
        _ = try await strictValidationReport(mediaURL: outputURL, expectedDuration: expectedDuration)
        onProgress(1)
        return audioFilter
    }

    func applyStaticBlur(
        mediaURL: URL,
        outputURL: URL,
        region: NormalizedVideoRect,
        intensity: Double,
        start: TimeInterval?,
        end: TimeInterval?,
        mediaDuration: TimeInterval,
        onProgress: @escaping (Double) -> Void
    ) async throws -> String {
        let region = try region.validated()
        guard intensity >= 1, intensity <= 30 else {
            throw WorkflowError.processFailed("Интенсивность blur должна быть от 1 до 30.")
        }
        if (start == nil) != (end == nil) {
            throw WorkflowError.processFailed("Для blur укажите обе границы времени или отключите временной диапазон.")
        }
        if let start, let end {
            guard start >= 0, end > start, end <= mediaDuration + 0.01 else { throw WorkflowError.invalidRange }
        }
        guard let ffmpeg = await ffmpegWithFilter("gblur") else {
            throw WorkflowError.processFailed("Не найден FFmpeg с фильтром gblur.")
        }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = partialURL(for: outputURL)
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }

        let x = String(format: "%.8f", region.x)
        let y = String(format: "%.8f", region.y)
        let width = String(format: "%.8f", region.width)
        let height = String(format: "%.8f", region.height)
        let sigma = String(format: "%.3f", intensity)
        let enable = start.flatMap { start in
            end.map { end in ":enable='between(t,\(String(format: "%.3f", start)),\(String(format: "%.3f", end)))'" }
        } ?? ""
        let graph = "[0:v]setsar=1,split=2[base][region];" +
            "[region]crop=w='iw*\(width)':h='ih*\(height)':x='iw*\(x)':y='ih*\(y)',gblur=sigma=\(sigma)[blurred];" +
            "[base][blurred]overlay=x='main_w*\(x)':y='main_h*\(y)'\(enable)[outv]"
        var parser = FFmpegProgressParser(duration: mediaDuration)
        let result = try await runner.run(ffmpeg, [
            "-y",
            "-i", mediaURL.path,
            "-filter_complex", graph,
            "-map", "[outv]",
            "-map", "0:a:0?",
            "-c:v", "libx264",
            "-preset", "medium",
            "-crf", "18",
            "-pix_fmt", "yuv420p",
            "-c:a", "copy",
            "-movflags", "+faststart",
            "-progress", "pipe:1",
            "-nostats",
            partial.path
        ]) { stream, chunk in
            guard stream == .stdout, let fraction = parser.consume(chunk) else { return }
            onProgress(fraction)
        }
        guard result.exitCode == 0, FileManager.default.fileExists(atPath: partial.path) else {
            throw WorkflowError.processFailed("Ошибка применения blur ffmpeg: \(result.stderr)")
        }
        try replaceItem(at: outputURL, with: partial)
        _ = try await strictValidationReport(mediaURL: outputURL, expectedDuration: mediaDuration)
        onProgress(1)
        return graph
    }

    func applyWatermark(
        mediaURL: URL,
        imageURL: URL,
        outputURL: URL,
        position: WatermarkPosition,
        manualX: Double,
        manualY: Double,
        relativeWidth: Double,
        margin: Double,
        opacity: Double,
        start: TimeInterval?,
        end: TimeInterval?,
        mediaDuration: TimeInterval,
        blurRegion: NormalizedVideoRect? = nil,
        blurIntensity: Double = 12,
        blurStart: TimeInterval? = nil,
        blurEnd: TimeInterval? = nil,
        srtURL: URL? = nil,
        subtitleStyle: SubtitleStyleSettings = .standard,
        onProgress: @escaping (Double) -> Void
    ) async throws -> String {
        guard relativeWidth >= 0.03, relativeWidth <= 0.6,
              margin >= 0, margin <= 0.2,
              opacity > 0, opacity <= 1,
              manualX >= 0, manualX <= 1,
              manualY >= 0, manualY <= 1 else {
            throw WorkflowError.processFailed("Параметры watermark выходят за безопасные границы.")
        }
        if (start == nil) != (end == nil) {
            throw WorkflowError.processFailed("Для watermark укажите обе границы времени или отключите временной диапазон.")
        }
        if let start, let end {
            guard start >= 0, end > start, end <= mediaDuration + 0.01 else { throw WorkflowError.invalidRange }
        }
        var requiredFilters = ["overlay"]
        if blurRegion != nil { requiredFilters.append("gblur") }
        if srtURL != nil { requiredFilters.append("subtitles") }
        guard let ffmpeg = await ffmpegWithFilters(requiredFilters) else {
            throw WorkflowError.processFailed("Не найден FFmpeg с фильтрами: \(requiredFilters.joined(separator: ", ")).")
        }
        let dimensions = try await displayDimensions(of: mediaURL)
        let targetWidth = max(2, Int((Double(dimensions.width) * relativeWidth / 2).rounded()) * 2)
        let marginText = String(format: "%.8f", margin)
        let manualXText = String(format: "%.8f", manualX)
        let manualYText = String(format: "%.8f", manualY)
        let xExpression: String
        let yExpression: String
        switch position {
        case .topLeft:
            xExpression = "main_w*\(marginText)"
            yExpression = "main_h*\(marginText)"
        case .topRight:
            xExpression = "main_w-overlay_w-main_w*\(marginText)"
            yExpression = "main_h*\(marginText)"
        case .bottomLeft:
            xExpression = "main_w*\(marginText)"
            yExpression = "main_h-overlay_h-main_h*\(marginText)"
        case .bottomRight:
            xExpression = "main_w-overlay_w-main_w*\(marginText)"
            yExpression = "main_h-overlay_h-main_h*\(marginText)"
        case .manual:
            xExpression = "min(main_w-overlay_w,max(0,main_w*\(manualXText)))"
            yExpression = "min(main_h-overlay_h,max(0,main_h*\(manualYText)))"
        }
        let enable = start.flatMap { start in
            end.map { end in ":enable='between(t,\(String(format: "%.3f", start)),\(String(format: "%.3f", end)))'" }
        } ?? ""
        var graphParts: [String] = []
        let baseLabel: String
        if let blurRegion {
            let blurRegion = try blurRegion.validated()
            guard blurIntensity >= 1, blurIntensity <= 30 else {
                throw WorkflowError.processFailed("Интенсивность blur должна быть от 1 до 30.")
            }
            let bx = String(format: "%.8f", blurRegion.x)
            let by = String(format: "%.8f", blurRegion.y)
            let bw = String(format: "%.8f", blurRegion.width)
            let bh = String(format: "%.8f", blurRegion.height)
            let blurEnable = blurStart.flatMap { start in
                blurEnd.map { end in ":enable='between(t,\(String(format: "%.3f", start)),\(String(format: "%.3f", end)))'" }
            } ?? ""
            graphParts += [
                "[0:v]setsar=1,split=2[plain][blur-region]",
                "[blur-region]crop=w='iw*\(bw)':h='ih*\(bh)':x='iw*\(bx)':y='ih*\(by)',gblur=sigma=\(String(format: "%.3f", blurIntensity))[blurred]",
                "[plain][blurred]overlay=x='main_w*\(bx)':y='main_h*\(by)'\(blurEnable)[base]"
            ]
            baseLabel = "[base]"
        } else {
            graphParts.append("[0:v]setsar=1[base]")
            baseLabel = "[base]"
        }
        graphParts.append("[1:v]format=rgba,colorchannelmixer=aa=\(String(format: "%.4f", opacity)),scale=\(targetWidth):-2[wm]")
        let watermarkedLabel = srtURL == nil ? "[outv]" : "[watermarked]"
        graphParts.append("\(baseLabel)[wm]overlay=x='\(xExpression)':y='\(yExpression)'\(enable)\(watermarkedLabel)")

        var temporarySRT: URL?
        if let srtURL {
            guard FileManager.default.fileExists(atPath: srtURL.path) else { throw WorkflowError.missingFullSRT }
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("videotext-watermark-subtitles-\(UUID().uuidString).srt")
            try Data(contentsOf: srtURL).write(to: copy, options: .atomic)
            temporarySRT = copy
            graphParts.append("[watermarked]subtitles=filename='\(copy.path)':force_style='\(assStyle(subtitleStyle))'[outv]")
        }
        defer { if let temporarySRT { try? FileManager.default.removeItem(at: temporarySRT) } }
        let graph = graphParts.joined(separator: ";")
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = partialURL(for: outputURL)
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }
        var parser = FFmpegProgressParser(duration: mediaDuration)
        let result = try await runner.run(ffmpeg, [
            "-y",
            "-i", mediaURL.path,
            "-i", imageURL.path,
            "-filter_complex", graph,
            "-map", "[outv]",
            "-map", "0:a:0?",
            "-c:v", "libx264",
            "-preset", "medium",
            "-crf", "18",
            "-pix_fmt", "yuv420p",
            "-c:a", "copy",
            "-movflags", "+faststart",
            "-progress", "pipe:1",
            "-nostats",
            partial.path
        ]) { stream, chunk in
            guard stream == .stdout, let fraction = parser.consume(chunk) else { return }
            onProgress(fraction)
        }
        guard result.exitCode == 0, FileManager.default.fileExists(atPath: partial.path) else {
            throw WorkflowError.processFailed("Ошибка добавления watermark ffmpeg: \(result.stderr)")
        }
        try replaceItem(at: outputURL, with: partial)
        _ = try await strictValidationReport(mediaURL: outputURL, expectedDuration: mediaDuration)
        onProgress(1)
        return graph
    }

    func muteAudioIntervals(
        mediaURL: URL,
        outputAudioURL: URL,
        outputVideoURL: URL,
        intervals: [ClosedRangeRecord],
        mediaDuration: TimeInterval,
        fadeDuration: TimeInterval = 0.025,
        onProgress: @escaping (Double) -> Void
    ) async throws -> String {
        guard let ffmpeg = runner.resolve("ffmpeg") else { throw WorkflowError.missingTool("ffmpeg") }
        guard try await containsAudioStream(mediaURL) else {
            throw WorkflowError.processFailed("В видео нет аудиодорожки для mute.")
        }
        let merged = mergedMuteIntervals(intervals, mediaDuration: mediaDuration)
        guard !merged.isEmpty else {
            throw WorkflowError.processFailed("Не выбраны интервалы слов-паразитов для mute.")
        }
        let filters = merged.map { interval -> String in
            let start = interval.start
            let end = interval.end
            let fade = min(fadeDuration, max(0.005, (end - start) / 4))
            let s = String(format: "%.6f", start)
            let sf = String(format: "%.6f", start + fade)
            let ef = String(format: "%.6f", end - fade)
            let e = String(format: "%.6f", end)
            let f = String(format: "%.6f", fade)
            let expression = "if(lt(t\\,\(s))\\,1\\,if(lt(t\\,\(sf))\\,1-(t-\(s))/\(f)\\,if(lt(t\\,\(ef))\\,0\\,if(lt(t\\,\(e))\\,(t-\(ef))/\(f)\\,1))))"
            return "volume=volume='\(expression)':eval=frame"
        }
        let graph = filters.joined(separator: ",")
        try FileManager.default.createDirectory(at: outputAudioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputVideoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partialAudio = partialURL(for: outputAudioURL)
        let partialVideo = partialURL(for: outputVideoURL)
        try? FileManager.default.removeItem(at: partialAudio)
        try? FileManager.default.removeItem(at: partialVideo)
        defer {
            try? FileManager.default.removeItem(at: partialAudio)
            try? FileManager.default.removeItem(at: partialVideo)
        }
        var audioParser = FFmpegProgressParser(duration: mediaDuration)
        let audioResult = try await runner.run(ffmpeg, [
            "-y", "-i", mediaURL.path,
            "-vn", "-af", graph,
            "-c:a", "aac", "-b:a", "192k",
            "-progress", "pipe:1", "-nostats",
            partialAudio.path
        ]) { stream, chunk in
            guard stream == .stdout, let fraction = audioParser.consume(chunk) else { return }
            onProgress(fraction * 0.65)
        }
        guard audioResult.exitCode == 0, FileManager.default.fileExists(atPath: partialAudio.path) else {
            throw WorkflowError.processFailed("Ошибка mute аудио ffmpeg: \(audioResult.stderr)")
        }
        try replaceItem(at: outputAudioURL, with: partialAudio)

        var muxParser = FFmpegProgressParser(duration: mediaDuration)
        let muxResult = try await runner.run(ffmpeg, [
            "-y", "-i", mediaURL.path, "-i", outputAudioURL.path,
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "copy", "-c:a", "copy",
            "-movflags", "+faststart",
            "-progress", "pipe:1", "-nostats",
            partialVideo.path
        ]) { stream, chunk in
            guard stream == .stdout, let fraction = muxParser.consume(chunk) else { return }
            onProgress(0.65 + fraction * 0.35)
        }
        guard muxResult.exitCode == 0, FileManager.default.fileExists(atPath: partialVideo.path) else {
            throw WorkflowError.processFailed("Ошибка замены аудиодорожки ffmpeg: \(muxResult.stderr)")
        }
        try replaceItem(at: outputVideoURL, with: partialVideo)
        _ = try await strictValidationReport(mediaURL: outputVideoURL, expectedDuration: mediaDuration)
        guard let audioDuration = try await duration(of: outputAudioURL), abs(audioDuration - mediaDuration) <= 0.25 else {
            throw WorkflowError.processFailed("Mute-аудио изменило длительность исходного файла.")
        }
        onProgress(1)
        return graph
    }

    func validate(mediaURL: URL) async throws -> String {
        guard let ffprobe = runner.resolve("ffprobe") else { throw WorkflowError.missingTool("ffprobe") }
        let result = try await runner.run(ffprobe, [
            "-v", "error",
            "-show_streams",
            "-show_format",
            mediaURL.path
        ])
        guard result.exitCode == 0 else {
            throw WorkflowError.processFailed("Ошибка проверки ffprobe: \(result.stderr)")
        }
        return result.stdout
    }

    func strictValidationReport(mediaURL: URL, expectedDuration: TimeInterval) async throws -> String {
        let report = try await validate(mediaURL: mediaURL)
        guard report.contains("codec_type=video") else {
            throw WorkflowError.processFailed("ffprobe не обнаружил видеопоток в \(mediaURL.lastPathComponent).")
        }
        guard let actual = try await duration(of: mediaURL), abs(actual - expectedDuration) <= 0.25 else {
            let actual = (try? await duration(of: mediaURL)) ?? nil
            throw WorkflowError.processFailed("Длительность \(mediaURL.lastPathComponent) не соответствует диапазону: \(actual ?? -1) с.")
        }
        return "Ожидаемая длительность: \(String(format: "%.3f", expectedDuration))\n" + report
    }

    private func ffmpegWithSubtitlesFilter() async -> String? {
        let candidates = [
            runner.resolve("ffmpeg"),
            "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg",
            "/usr/local/opt/ffmpeg-full/bin/ffmpeg"
        ].compactMap { $0 }

        for candidate in orderedUnique(candidates) where FileManager.default.isExecutableFile(atPath: candidate) {
            guard let result = try? await runner.run(candidate, ["-hide_banner", "-filters"]), result.exitCode == 0 else { continue }
            if result.stdout.split(separator: "\n").contains(where: { line in
                line.split(whereSeparator: { $0.isWhitespace }).dropFirst().first == "subtitles"
            }) {
                return candidate
            }
        }
        return nil
    }

    private func ffmpegForSpeedAdjustment() async -> (path: String, hasRubberband: Bool)? {
        let candidates = [
            "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg",
            "/usr/local/opt/ffmpeg-full/bin/ffmpeg",
            runner.resolve("ffmpeg")
        ].compactMap { $0 }

        var fallback: String?
        for candidate in orderedUnique(candidates) where FileManager.default.isExecutableFile(atPath: candidate) {
            fallback = fallback ?? candidate
            guard let result = try? await runner.run(candidate, ["-hide_banner", "-filters"]), result.exitCode == 0 else { continue }
            if result.stdout.contains("rubberband") { return (candidate, true) }
        }
        return fallback.map { ($0, false) }
    }

    private func ffmpegWithFilter(_ filter: String) async -> String? {
        await ffmpegWithFilters([filter])
    }

    private func ffmpegWithFilters(_ filters: [String]) async -> String? {
        let candidates = [
            "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg",
            "/usr/local/opt/ffmpeg-full/bin/ffmpeg",
            runner.resolve("ffmpeg")
        ].compactMap { $0 }
        for candidate in orderedUnique(candidates) where FileManager.default.isExecutableFile(atPath: candidate) {
            guard let result = try? await runner.run(candidate, ["-hide_banner", "-filters"]), result.exitCode == 0 else { continue }
            let available = Set(result.stdout.split(separator: "\n").compactMap { line in
                line.split(whereSeparator: { $0.isWhitespace }).dropFirst().first.map(String.init)
            })
            if filters.allSatisfy(available.contains) { return candidate }
        }
        return nil
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func containsAudioStream(_ mediaURL: URL) async throws -> Bool {
        guard let ffprobe = runner.resolve("ffprobe") else { throw WorkflowError.missingTool("ffprobe") }
        let result = try await runner.run(ffprobe, [
            "-v", "error",
            "-select_streams", "a:0",
            "-show_entries", "stream=index",
            "-of", "csv=p=0",
            mediaURL.path
        ])
        return result.exitCode == 0 && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func displayDimensions(of mediaURL: URL) async throws -> (width: Int, height: Int) {
        guard let ffprobe = runner.resolve("ffprobe") else { throw WorkflowError.missingTool("ffprobe") }
        let result = try await runner.run(ffprobe, [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=width,height:stream_side_data=rotation",
            "-of", "json",
            mediaURL.path
        ])
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]],
              let stream = streams.first,
              let width = stream["width"] as? Int,
              let height = stream["height"] as? Int else {
            throw WorkflowError.processFailed("ffprobe не вернул размер кадра.")
        }
        let sideData = stream["side_data_list"] as? [[String: Any]]
        let rotation = sideData?.compactMap { $0["rotation"] as? Int }.first ?? 0
        return abs(rotation) % 180 == 90 ? (height, width) : (width, height)
    }

    private func mergedMuteIntervals(_ intervals: [ClosedRangeRecord], mediaDuration: TimeInterval) -> [ClosedRangeRecord] {
        let prepared = intervals.compactMap { interval -> ClosedRangeRecord? in
            let start = max(0, interval.start - 0.03)
            let end = min(mediaDuration, interval.end + 0.03)
            return end > start ? ClosedRangeRecord(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        var merged: [ClosedRangeRecord] = []
        for interval in prepared {
            if let last = merged.last, interval.start <= last.end + 0.01 {
                merged[merged.count - 1].end = max(last.end, interval.end)
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    private func assStyle(_ style: SubtitleStyleSettings) -> String {
        let alignment: Int
        switch style.position {
        case .bottom: alignment = 2
        case .middle: alignment = 5
        case .top: alignment = 8
        }
        let opacity = min(max(style.backgroundOpacity, 0), 1)
        let backgroundAlpha = Int(((1 - opacity) * 255).rounded())
        let borderStyle = opacity > 0.001 ? 3 : 1
        let outlineAlpha = opacity > 0.001 ? backgroundAlpha : 0
        let fontName = style.fontName.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "'", with: " ")
        return [
            "FontName=\(fontName)",
            "FontSize=\(String(format: "%.1f", style.fontSize))",
            "PrimaryColour=\(assColor(style.textColorHex, alpha: 0))",
            "OutlineColour=\(assColor(style.outlineColorHex, alpha: outlineAlpha))",
            "BackColour=\(assColor("#000000", alpha: backgroundAlpha))",
            "BorderStyle=\(borderStyle)",
            "Outline=\(String(format: "%.1f", style.outlineWidth))",
            "Shadow=0",
            "Alignment=\(alignment)",
            "MarginV=28"
        ].joined(separator: ",")
    }

    private func assColor(_ hex: String, alpha: Int) -> String {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        guard clean.count == 6 else { return "&H00FFFFFF&" }
        let red = clean.prefix(2)
        let green = clean.dropFirst(2).prefix(2)
        let blue = clean.suffix(2)
        return String(format: "&H%02X", min(max(alpha, 0), 255)) + blue + green + red + "&"
    }

    private func partialURL(for outputURL: URL) -> URL {
        outputURL.deletingPathExtension()
            .appendingPathExtension("partial")
            .appendingPathExtension(outputURL.pathExtension)
    }
}

private func replaceItem(at destination: URL, with source: URL) throws {
    if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: source, to: destination)
}
