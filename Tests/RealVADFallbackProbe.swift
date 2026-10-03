import Foundation

@main
struct RealVADFallbackProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else {
            throw WorkflowError.processFailed("Usage: real-vad-fallback <media> <whisper-model> <valid-vad-model>")
        }

        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let model = CommandLine.arguments[2]
        let root = (URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path, isDirectory: true))
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

        let cacheRoot = layout.supportDirectory.appendingPathComponent("Transcription cache", isDirectory: true)
        let cacheDirectories = try FileManager.default.contentsOfDirectory(
            at: cacheRoot, includingPropertiesForKeys: nil
        )
        guard cacheDirectories.count == 1 else {
            throw WorkflowError.processFailed("Expected one chunk cache before context change")
        }
        try Data("{invalid-json".utf8).write(
            to: cacheDirectories[0].appendingPathComponent("chunk-0001.json"), options: .atomic
        )
        let repairedJSON = try await run(context: "Проверка разговорной речи")
        guard repairedJSON.contains(where: { $0.contains("standard segmentation after VAD failure") }),
              !repairedJSON.contains(where: { $0.contains("восстановлен из проверенного кэша") }) else {
            throw WorkflowError.processFailed("Invalid cached JSON was reused")
        }

        let invalidSegments: [String: Any] = ["transcription": [[:]]]
        let invalidSegmentsData = try JSONSerialization.data(withJSONObject: invalidSegments)
        try invalidSegmentsData.write(
            to: cacheDirectories[0].appendingPathComponent("chunk-0001.json"), options: .atomic
        )
        let repairedSegments = try await run(context: "Проверка разговорной речи")
        guard repairedSegments.contains(where: { $0.contains("standard segmentation after VAD failure") }),
              !repairedSegments.contains(where: { $0.contains("восстановлен из проверенного кэша") }) else {
            throw WorkflowError.processFailed("Invalid cached transcription segment was reused")
        }

        let changed = try await run(context: "Другая предметная область")
        guard changed.contains(where: { $0.contains("standard segmentation after VAD failure") }),
              !changed.contains(where: { $0.contains("восстановлен из проверенного кэша") }) else {
            throw WorkflowError.processFailed("Changed context did not invalidate chunk cache")
        }

        try FileManager.default.removeItem(at: badVAD)
        try FileManager.default.copyItem(atPath: CommandLine.arguments[3], toPath: badVAD.path)
        let restored = try await run(context: "Проверка разговорной речи")
        guard restored.contains(where: { $0.contains("стратегия: VAD long-form") }),
              !restored.contains(where: { $0.contains("восстановлен из проверенного кэша") }) else {
            throw WorkflowError.processFailed("Repaired VAD model did not invalidate fallback cache")
        }

        print("REAL_VAD_FALLBACK_PASS duration=\(duration) fallback=PASS cache_reuse=PASS invalid_json_recovery=PASS invalid_segment_recovery=PASS context_invalidation=PASS vad_repair_invalidation=PASS")
    }
}
