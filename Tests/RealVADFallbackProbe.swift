import Foundation

@main
struct RealVADFallbackProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw WorkflowError.processFailed("Usage: real-vad-fallback <media> <whisper-model>")
        }

        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let model = CommandLine.arguments[2]
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("videotext-real-vad-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let media = root.appendingPathComponent("source.\(source.pathExtension)")
        try FileManager.default.copyItem(at: source, to: media)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let layout = ProjectLayout(root: project)
        try layout.createDirectories()
        let badVADDirectory = root.appendingPathComponent("bad-vad", isDirectory: true)
        try FileManager.default.createDirectory(at: badVADDirectory, withIntermediateDirectories: true)
        let badVAD = badVADDirectory.appendingPathComponent("ggml-silero-v5.1.2.bin")
        try Data([0, 1, 2, 3]).write(to: badVAD)

        let runner = ToolRunner()
        guard let duration = try await FFmpegAdapter(runner: runner).duration(of: media), duration > 0 else {
            throw WorkflowError.processFailed("Test media has no duration")
        }
        let transcriber = SegmentedWhisperTranscriber(
            runner: runner,
            vadModelLocator: WhisperVADModelLocator(searchRoots: [badVADDirectory.path])
        )
        let srt = SRTService()

        func run(context: String) async throws -> [String] {
            var messages: [String] = []
            _ = try await transcriber.transcribe(
                audioURL: media,
                mediaURL: media,
                projectURL: project,
                mediaDuration: duration,
                modelPath: model,
                language: "ru",
                contextHint: context,
                onProgress: { _ in },
                onLog: { messages.append($0) }
            )
            let cues = try srt.load(from: layout.fullSRTURL)
            guard !cues.isEmpty, srt.validateTimeline(cues, mediaDuration: duration).isEmpty else {
                throw WorkflowError.processFailed("Fallback produced empty or invalid SRT")
            }
            guard FileManager.default.fileExists(atPath: layout.whisperJSONURL.path) else {
                throw WorkflowError.processFailed("Fallback did not produce Whisper JSON")
            }
            return messages
        }

        let first = try await run(context: "Проверка разговорной речи")
        guard first.contains(where: { $0.contains("standard segmentation after VAD failure") }) else {
            throw WorkflowError.processFailed("Real no-VAD fallback was not executed")
        }
        let repeated = try await run(context: "Проверка   разговорной речи")
        guard repeated.contains(where: { $0.contains("восстановлен из проверенного кэша") }) else {
            throw WorkflowError.processFailed("Equivalent normalized context did not reuse cache")
        }
        let changed = try await run(context: "Другая предметная область")
        guard changed.contains(where: { $0.contains("standard segmentation after VAD failure") }),
              !changed.contains(where: { $0.contains("восстановлен из проверенного кэша") }) else {
            throw WorkflowError.processFailed("Changed context did not invalidate chunk cache")
        }

        print("REAL_VAD_FALLBACK_PASS duration=\(duration) first_attempts=3 cache_reuse=PASS context_invalidation=PASS")
    }
}
