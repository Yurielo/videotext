import Foundation
import Darwin

enum ToolRunnerProbeError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

@main
struct ToolRunnerProbe {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw ToolRunnerProbeError.failed("Использование: tool-runner-probe <видео>")
            }
            let videoURL = URL(fileURLWithPath: CommandLine.arguments[1])
            guard FileManager.default.fileExists(atPath: videoURL.path) else {
                throw ToolRunnerProbeError.failed("Контрольное видео не найдено")
            }
            let runner = ToolRunner()
            guard let ffmpeg = runner.resolve("ffmpeg") else {
                throw ToolRunnerProbeError.failed("ffmpeg не найден")
            }
            let output = (URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path, isDirectory: true))
                .appendingPathComponent("videotext-tool-runner-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: output) }
            let result = try await runner.run(ffmpeg, [
                "-y", "-ss", "0", "-i", videoURL.path, "-t", "20",
                "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000",
                "-c:a", "pcm_s16le", output.path
            ])
            guard result.exitCode == 0, FileManager.default.fileExists(atPath: output.path) else {
                throw ToolRunnerProbeError.failed("ToolRunner не завершила извлечение аудио: \(result.stderr)")
            }
            print("TOOL_RUNNER_PROBE_PASS")
        } catch {
            fputs("TOOL_RUNNER_PROBE_FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
