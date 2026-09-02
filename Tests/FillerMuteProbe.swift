import Foundation

@main
struct FillerMuteProbe {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("videotext-filler-mute-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ToolRunner()
        guard let ffmpeg = runner.resolve("ffmpeg") else { throw WorkflowError.missingTool("ffmpeg") }
        let source = root.appendingPathComponent("source.mp4")
        let audio = root.appendingPathComponent("muted.m4a")
        let video = root.appendingPathComponent("muted.mp4")
        let generated = try await runner.run(ffmpeg, [
            "-y",
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25:duration=2",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2",
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", source.path
        ])
        try require(generated.exitCode == 0, "не создан тестовый ролик с тоном")
        let adapter = FFmpegAdapter(runner: runner)
        let graph = try await adapter.muteAudioIntervals(
            mediaURL: source,
            outputAudioURL: audio,
            outputVideoURL: video,
            intervals: [ClosedRangeRecord(start: 0.75, end: 1.25)],
            mediaDuration: 2,
            onProgress: { _ in }
        )
        try require(graph.contains("volume=volume") && graph.contains("eval=frame"), "fade volume graph не создан")
        try require(FileManager.default.fileExists(atPath: audio.path) && FileManager.default.fileExists(atPath: video.path), "mute-артефакты отсутствуют")
        let mutedLevel = try await volumeLevel(ffmpeg: ffmpeg, runner: runner, input: audio, start: 0.9, duration: 0.2)
        let audibleLevel = try await volumeLevel(ffmpeg: ffmpeg, runner: runner, input: audio, start: 0.2, duration: 0.2)
        try require(mutedLevel < -50, "выбранный интервал недостаточно заглушён: \(mutedLevel) dB")
        try require(audibleLevel > -35, "звук вне mute-интервала повреждён: \(audibleLevel) dB")
        print("FILLER_MUTE_PROBE_PASS")
    }

    private static func volumeLevel(ffmpeg: String, runner: ToolRunner, input: URL, start: Double, duration: Double) async throws -> Double {
        let result = try await runner.run(ffmpeg, [
            "-ss", String(start), "-t", String(duration), "-i", input.path,
            "-af", "volumedetect", "-f", "null", "-"
        ])
        let expression = try NSRegularExpression(pattern: #"max_volume:\s*(-?(?:inf|\d+(?:\.\d+)?)) dB"#)
        let range = NSRange(result.stderr.startIndex..<result.stderr.endIndex, in: result.stderr)
        guard let match = expression.firstMatch(in: result.stderr, range: range),
              let valueRange = Range(match.range(at: 1), in: result.stderr) else {
            throw ProbeFailure(message: "volumedetect не вернул max_volume")
        }
        let value = String(result.stderr[valueRange])
        return value == "-inf" ? -.infinity : (Double(value) ?? 0)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
