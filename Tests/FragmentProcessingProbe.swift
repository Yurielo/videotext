import Foundation

@main
struct FragmentProcessingProbe {
    static func main() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("videotext-fragment-processing-\(UUID().uuidString)", isDirectory: true)
        let projectURL = root.appendingPathComponent("project", isDirectory: true)
        let sourceURL = root.appendingPathComponent("source.mp4")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let runner = ToolRunner()
        guard let ffmpegPath = runner.resolve("ffmpeg") else { throw WorkflowError.missingTool("ffmpeg") }
        let generated = try await runner.run(ffmpegPath, [
            "-y",
            "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=3",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=3",
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
            sourceURL.path
        ])
        try require(generated.exitCode == 0, "не создан синтетический исходник")

        let historyURL = root.appendingPathComponent("history.json")
        let store = ProjectStore(history: ProjectHistoryStore(indexURL: historyURL))
        _ = try store.ensureProject(at: projectURL, mediaURL: sourceURL, mode: .resumeProject)
        let layout = ProjectLayout(root: projectURL)
        let fragmentID = "combined-probe"
        let fragmentVideo = layout.fragmentVideoURL(kind: fragmentID)
        try fileManager.createDirectory(at: fragmentVideo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: sourceURL, to: fragmentVideo)
        let fragmentSRT = layout.fragmentSRTURL(kind: fragmentID)
        try fileManager.createDirectory(at: fragmentSRT.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SRTService().write([
            SubtitleCue(id: 1, start: 0.1, end: 1.4, text: "Тестовая первая строка"),
            SubtitleCue(id: 2, start: 1.5, end: 2.8, text: "Тестовая вторая строка")
        ], to: fragmentSRT)

        let fillerReport = FillerAnalysisReport(
            schemaVersion: 1,
            language: .ru,
            transcriptRevisionID: "revision-probe",
            createdAt: Date(),
            words: [],
            candidates: [FillerWordCandidate(
                id: "filler-probe",
                text: "ээ",
                normalized: "ээ",
                start: 1.0,
                end: 1.3,
                cueID: 1,
                transcriptRevisionID: "revision-probe",
                language: .ru,
                confidence: 0.9,
                highConfidence: true,
                reasonCodes: ["acoustic-disfluency"],
                context: "тест ээ фрагмента",
                decision: .pending
            )]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(fillerReport).write(to: layout.fillerWordsURL, options: .atomic)

        let fragment = FragmentRecord(
            id: fragmentID,
            name: "Combined probe",
            start: 0.5,
            end: 3.5,
            createdAt: Date(),
            videoPath: fragmentVideo.path,
            subtitlePath: fragmentSRT.path,
            subtitledVideoPath: nil,
            ffprobeReportPath: nil,
            style: .standard,
            language: .ru
        )
        try store.registerFragment(fragment, in: projectURL)
        let settings = WorkflowSettings(
            mediaURL: sourceURL,
            projectURL: projectURL,
            selectedOperations: [.renderFragment],
            mode: .resumeProject,
            rangeStart: fragment.start,
            rangeEnd: fragment.end,
            fragmentName: fragment.name,
            burnFragmentSubtitles: true,
            subtitleStyle: .standard,
            selectedTopicID: nil,
            whisperModelPath: "",
            whisperLanguage: "ru",
            speedFactor: 1.25,
            blurRegion: NormalizedVideoRect(x: 0.6, y: 0.05, width: 0.3, height: 0.25),
            blurIntensity: 8,
            blurStart: 1.5,
            blurEnd: 2.5,
            fillerMode: .muteAll,
            fragmentMuteFillerWords: true,
            fragmentAdjustSpeed: true,
            fragmentApplyBlur: true
        )

        let result = try await WorkflowEngine(store: store).renderProcessedFragment(
            fragment,
            projectURL: projectURL,
            settings: settings,
            removeSourceAfterSuccess: true,
            onProgress: { _ in },
            log: { _ in }
        )
        guard let outputPath = result.processedVideoPath,
              let recipe = result.processingRecipe else {
            throw ProbeFailure(message: "итоговый фрагмент или рецепт не сохранён")
        }
        try require(fileManager.fileExists(atPath: outputPath), "итоговый видеофайл отсутствует")
        try require(!fileManager.fileExists(atPath: fragmentVideo.path), "технический исходный cut не удалён")
        try require(fileManager.fileExists(atPath: layout.processedFragmentSRTURL(kind: fragmentID).path), "итоговый SRT отсутствует")
        try require(fileManager.fileExists(atPath: layout.processedFragmentRecipeURL(kind: fragmentID).path), "JSON-рецепт отсутствует")
        try require(recipe.muteFillerWords && recipe.adjustSpeed && recipe.applyBlur && recipe.burnSubtitles, "не все этапы записаны в рецепт")
        try require(recipe.fillerCandidateIDs == ["filler-probe"], "mute-кандидат потерян")
        try require(abs((recipe.blurStart ?? -1) - 0.8) < 0.001, "blur start не пересчитан после вырезки и скорости")
        try require(abs((recipe.blurEnd ?? -1) - 1.6) < 0.001, "blur end не пересчитан после вырезки и скорости")
        let duration = try await FFmpegAdapter(runner: runner).duration(of: URL(fileURLWithPath: outputPath))
        try require(abs((duration ?? -1) - 2.4) <= 0.25, "скорость дала неверную длительность")
        let persisted = try store.load(from: projectURL)
        try require(persisted.fragments?.first?.processingRecipe == recipe, "рецепт не прошёл manifest round-trip")
        try require(persisted.outputs.contains { $0.kind == "processed-fragment-video" && $0.path == outputPath }, "итоговый файл не зарегистрирован")
        let rediscovered = ResultsDetector().discover(in: projectURL)
        try require(rediscovered.contains {
            $0.kind == "processed-fragment-video"
                && URL(fileURLWithPath: $0.path).lastPathComponent == URL(fileURLWithPath: outputPath).lastPathComponent
        }, "переобнаружение потеряло тип итогового файла")
        try require(rediscovered.contains { $0.kind == "processed-fragment-recipe" }, "переобнаружение потеряло JSON-рецепт")
        print("FRAGMENT_PROCESSING_PROBE_PASS")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
