import Foundation

@main
struct LanguageDetectionProbe {
    static func main() async throws {
        let parser = WhisperLanguageDetectionParser()
        let russian = parser.parse("whisper_lang_auto_detect_with_state: detected language: ru (p = 0.982145)")
        try require(russian?.languageCode == "ru", "не разобран русский язык")
        try require(abs((russian?.confidence ?? 0) - 0.982145) < 0.000001, "не разобрана вероятность ru")

        let english = parser.parse("auto-detected language: en (p = 0.91)")
        try require(english == ParsedLanguageDetection(languageCode: "en", confidence: 0.91), "не разобран английский язык")
        try require(parser.parse("no language here") == nil, "принят текст без результата")

        let service = LanguageDetectionService()
        let stable = service.aggregate([
            candidate(.ru, 0.96, 0),
            candidate(.ru, 0.91, 30),
            candidate(.ru, 0.94, 60)
        ])
        try require(stable.detected == .ru && stable.effective == .ru, "стабильный ru не принят")
        try require((stable.confidence ?? 0) > 0.9, "неверная aggregate confidence")

        let uncertain = service.aggregate([
            candidate(.ru, 0.81, 0),
            candidate(.en, 0.79, 30),
            candidate(.ru, 0.77, 60)
        ])
        try require(uncertain.detected == .uncertain, "расходящиеся выборки не помечены uncertain")
        try require(uncertain.effective == .ru, "не сохранен наиболее вероятный язык")

        let unsupported = service.aggregate([
            LanguageDetectionCandidate(
                languageCode: "de",
                confidence: 0.99,
                sampleRange: ClosedRangeRecord(start: 0, end: 30)
            )
        ])
        try require(unsupported.detected == .uncertain && unsupported.effective == nil, "неподдерживаемый язык принят")

        try await validateMissingAudioError()

        print("LANGUAGE_DETECTION_PROBE_PASS")
    }

    private static func validateMissingAudioError() async throws {
        let runner = ToolRunner()
        guard let ffmpeg = runner.resolve("ffmpeg") else { throw ProbeFailure(message: "ffmpeg не найден") }
        let root = (URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path, isDirectory: true))
            .appendingPathComponent("videotext-language-no-audio-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mediaURL = root.appendingPathComponent("silent.mp4")
        let generated = try await runner.run(ffmpeg, [
            "-y", "-f", "lavfi", "-i", "color=c=black:s=320x240:d=1",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", mediaURL.path
        ])
        try require(generated.exitCode == 0, "не создано видео без аудио")
        do {
            _ = try await LanguageDetectionService(runner: runner).detect(
                mediaURL: mediaURL,
                projectURL: root.appendingPathComponent("project", isDirectory: true),
                mediaDuration: 1,
                modelPath: "",
                requestedLanguage: "auto",
                onProgress: { _ in },
                onLog: { _ in }
            )
            throw ProbeFailure(message: "видео без аудио принято языковым анализом")
        } catch let error as ProbeFailure {
            throw error
        } catch {
            try require(
                error.localizedDescription.contains("отсутствует аудиодорожка"),
                "для видео без аудио возвращена нестабильная ошибка"
            )
        }
    }

    private static func candidate(
        _ language: ArtifactLanguage,
        _ confidence: Double,
        _ start: TimeInterval
    ) -> LanguageDetectionCandidate {
        LanguageDetectionCandidate(
            languageCode: language.rawValue,
            confidence: confidence,
            sampleRange: ClosedRangeRecord(start: start, end: start + 30)
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
