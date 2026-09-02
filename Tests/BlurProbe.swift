import Foundation

@main
struct BlurProbe {
    static func main() async throws {
        _ = try NormalizedVideoRect(x: 0.6, y: 0.1, width: 0.3, height: 0.25).validated()
        do {
            _ = try NormalizedVideoRect(x: 0.9, y: 0.1, width: 0.2, height: 0.2).validated()
            throw ProbeFailure(message: "область за границей кадра принята")
        } catch let error as WorkflowError {
            guard case .processFailed = error else { throw error }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("videotext-blur-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ToolRunner()
        guard let ffmpeg = runner.resolve("ffmpeg") else { throw WorkflowError.missingTool("ffmpeg") }
        let adapter = FFmpegAdapter(runner: runner)

        for (name, size) in [("landscape", "640x360"), ("portrait", "360x640")] {
            let source = root.appendingPathComponent("\(name).mp4")
            let output = root.appendingPathComponent("\(name)-blur.mp4")
            let generated = try await runner.run(ffmpeg, [
                "-y", "-f", "lavfi", "-i", "testsrc2=size=\(size):rate=25:duration=1",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", source.path
            ])
            try require(generated.exitCode == 0, "не создан синтетический \(name) клип")
            let graph = try await adapter.applyStaticBlur(
                mediaURL: source,
                outputURL: output,
                region: NormalizedVideoRect(x: 0.6, y: 0.1, width: 0.3, height: 0.25),
                intensity: 10,
                start: 0.2,
                end: 0.8,
                mediaDuration: 1,
                onProgress: { _ in }
            )
            try require(FileManager.default.fileExists(atPath: output.path), "blur-результат \(name) отсутствует")
            try require(graph.contains("crop") && graph.contains("gblur") && graph.contains("between(t,0.200,0.800)"), "filter graph неполон")
            let report = try await adapter.validate(mediaURL: output)
            try require(report.contains("codec_type=video"), "ffprobe не видит видео \(name)")
        }
        print("BLUR_PROBE_PASS")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
