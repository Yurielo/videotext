import Foundation

@main
struct SpeechSynthesisProbe {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("videotext-speech-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ToolRunner()
        guard let ffmpeg = runner.resolve("ffmpeg") else { throw WorkflowError.missingTool("ffmpeg") }
        let source = root.appendingPathComponent("source.mp4")
        let generated = try await runner.run(ffmpeg, [
            "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25:duration=4",
            "-f", "lavfi", "-i", "sine=frequency=220:sample_rate=48000:duration=4",
            "-map", "0:v:0", "-map", "1:a:0", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", source.path
        ])
        try require(generated.exitCode == 0, "не создан источник TTS probe")
        let adapter = SpeechSynthesisAdapter(runner: runner)

        let cases: [(ArtifactLanguage, DubbingMixMode, [SubtitleCue])] = [
            (.ru, .replace, [
                SubtitleCue(id: 1, start: 0.5, end: 1.8, text: "Здравствуйте."),
                SubtitleCue(id: 2, start: 2.0, end: 3.4, text: "Это проверка дубляжа.")
            ]),
            (.en, .mixQuietOriginal, [
                SubtitleCue(id: 1, start: 0.5, end: 1.8, text: "Hello."),
                SubtitleCue(id: 2, start: 2.0, end: 3.4, text: "This is a dubbing test.")
            ])
        ]
        for (language, mode, cues) in cases {
            let audio = root.appendingPathComponent("\(language.rawValue).m4a")
            let video = root.appendingPathComponent("\(language.rawValue).mp4")
            let result = try await adapter.synthesize(
                cues: cues,
                language: language,
                transcriptRevisionID: "revision-\(language.rawValue)",
                mediaURL: source,
                mediaDuration: 4,
                outputAudioURL: audio,
                outputVideoURL: video,
                mixMode: mode,
                onProgress: { _ in }
            )
            let expectedVoice = language == .ru ? "Yuri (Enhanced)" : "Daniel (Enhanced)"
            try require(result.voiceIdentifier == expectedVoice, "выбран неверный TTS-голос для \(language.rawValue)")
            try require(result.cues.count == cues.count, "потеряны TTS cue \(language.rawValue)")
            try require(result.cues.allSatisfy { $0.synthesizedDuration > 0 && $0.tempo >= 1 }, "не измерен темп TTS")
            try require(FileManager.default.fileExists(atPath: audio.path) && FileManager.default.fileExists(atPath: video.path), "не созданы TTS артефакты")
            let duration = try await FFmpegAdapter(runner: runner).duration(of: video)
            try require(abs((duration ?? 0) - 4) <= 0.25, "дубляж изменил длительность")
        }
        print("SPEECH_SYNTHESIS_PROBE_PASS")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
