import Foundation

@main
struct AudioEnhancementProbe {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("videotext-audio-enhancement-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ToolRunner()
        guard let ffmpeg = runner.resolve("ffmpeg") else { throw WorkflowError.missingTool("ffmpeg") }
        let source = root.appendingPathComponent("source.mp4")
        let generated = try await runner.run(ffmpeg, [
            "-y",
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25:duration=2",
            "-f", "lavfi", "-i", "sine=frequency=220:sample_rate=48000:duration=2",
            "-f", "lavfi", "-i", "anoisesrc=color=white:amplitude=0.02:sample_rate=48000:duration=2",
            "-filter_complex", "[1:a][2:a]amix=inputs=2:weights='1 0.4'[a]",
            "-map", "0:v:0", "-map", "[a]", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", source.path
        ])
        try require(generated.exitCode == 0, "не создан шумовой тестовый ролик")
        let adapter = AudioEnhancementAdapter(runner: runner)
        let before = try await adapter.analyze(mediaURL: source)
        try require(before.duration > 1.9 && before.maxVolumeDB != nil, "анализ не вернул длительность/пики")
        try require(before.echoAssessment == "not-assessed-without-benchmark", "эхо ошибочно объявлено измеренным")

        var graphs = Set<String>()
        for profile in AudioEnhancementProfile.allCases {
            let audio = root.appendingPathComponent("\(profile.rawValue).m4a")
            let video = root.appendingPathComponent("\(profile.rawValue).mp4")
            let result = try await adapter.enhance(
                mediaURL: source,
                outputAudioURL: audio,
                outputVideoURL: video,
                profile: profile,
                sourceLanguage: profile == .strong ? .en : .ru,
                before: before,
                onProgress: { _ in }
            )
            graphs.insert(result.filterGraph)
            let expectedModel = profile == .strong ? "UVR-De-Echo-Aggressive.pth" : "UVR-De-Echo-Normal.pth"
            try require(result.backendModel == expectedModel, "профиль \(profile.rawValue) выбрал неверную UVR-модель")
            try require(FileManager.default.fileExists(atPath: audio.path) && FileManager.default.fileExists(atPath: video.path), "не созданы артефакты \(profile.rawValue)")
            try require(abs(result.after.duration - before.duration) <= 0.25, "профиль \(profile.rawValue) изменил длительность")
            try require((result.after.maxVolumeDB ?? 1) <= 0.05, "профиль \(profile.rawValue) дал clipping")
            try require((result.after.truePeakDB ?? 1) <= -1, "профиль \(profile.rawValue) не ограничил true peak")
            guard let loudness = result.after.integratedLoudnessLUFS else {
                throw ProbeFailure(message: "профиль \(profile.rawValue) не вернул LUFS")
            }
            try require((-19.0 ... -13.0).contains(loudness), "профиль \(profile.rawValue) вышел за допуск LUFS")
        }
        try require(graphs.count == 3, "профили используют одинаковые параметры")

        let safeRussian = try await adapter.enhance(
            mediaURL: source,
            outputAudioURL: root.appendingPathComponent("strong-ru.m4a"),
            outputVideoURL: root.appendingPathComponent("strong-ru.mp4"),
            profile: .strong,
            sourceLanguage: .ru,
            before: before,
            onProgress: { _ in }
        )
        try require(safeRussian.backendModel == "UVR-De-Echo-Normal.pth", "Aggressive ошибочно разрешён для русского")
        print("AUDIO_ENHANCEMENT_PROBE_PASS")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
