import Foundation

@main
struct WatermarkProbe {
    static func main() async throws {
        let root = (URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path, isDirectory: true)).appendingPathComponent("videotext-watermark-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ToolRunner()
        guard let ffmpeg = runner.resolve("ffmpeg") else { throw WorkflowError.missingTool("ffmpeg") }
        let source = root.appendingPathComponent("source.mp4")
        let watermark = root.appendingPathComponent("watermark.png")
        let output = root.appendingPathComponent("output.mp4")
        let subtitles = root.appendingPathComponent("subtitles.srt")
        let sourceResult = try await runner.run(ffmpeg, [
            "-y", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=1",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", source.path
        ])
        try require(sourceResult.exitCode == 0, "не создано синтетическое видео")
        let imageResult = try await runner.run(ffmpeg, [
            "-y", "-f", "lavfi", "-i", "color=size=200x80:color=red@0.5",
            "-frames:v", "1", "-threads", "1", watermark.path
        ])
        try require(imageResult.exitCode == 0, "не создан PNG watermark")
        try "1\n00:00:00,100 --> 00:00:00,900\nПроверка\n".write(to: subtitles, atomically: true, encoding: .utf8)

        let adapter = FFmpegAdapter(runner: runner)
        let graph = try await adapter.applyWatermark(
            mediaURL: source,
            imageURL: watermark,
            outputURL: output,
            position: .bottomRight,
            manualX: 0.5,
            manualY: 0.5,
            relativeWidth: 0.2,
            margin: 0.03,
            opacity: 0.75,
            start: 0.2,
            end: 0.8,
            mediaDuration: 1,
            blurRegion: NormalizedVideoRect(x: 0.05, y: 0.05, width: 0.2, height: 0.2),
            blurIntensity: 8,
            blurStart: 0.1,
            blurEnd: 0.9,
            srtURL: subtitles,
            onProgress: { _ in }
        )
        try require(graph.contains("scale=128:-2"), "размер watermark не рассчитан от кадра")
        try require(graph.contains("between(t,0.200,0.800)"), "интервал watermark потерян")
        try require(graph.contains("gblur") && graph.contains("subtitles="), "совместный blur/subtitles graph не создан")
        try require(FileManager.default.fileExists(atPath: output.path), "watermark-видео не создано")
        let report = try await adapter.validate(mediaURL: output)
        try require(report.contains("codec_type=video"), "результат не прошёл ffprobe")
        print("WATERMARK_PROBE_PASS")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
