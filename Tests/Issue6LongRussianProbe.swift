import Foundation

private enum Issue6ProbeFailure: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        }
    }
}

/// Local-only harness for Issue #6. The private meeting recording is supplied
/// as an argument and is never copied into the repository.
@main
struct Issue6LongRussianProbe {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 6 || CommandLine.arguments.count == 7 else {
                throw Issue6ProbeFailure.message(
                    "Usage: issue6-long-russian-probe <media> <prepared-wav> <model> <duration-seconds> <output-project> [context-file]"
                )
            }

            let mediaURL = URL(fileURLWithPath: CommandLine.arguments[1])
            let audioURL = URL(fileURLWithPath: CommandLine.arguments[2])
            let modelPath = CommandLine.arguments[3]
            guard let duration = TimeInterval(CommandLine.arguments[4]), duration > 0 else {
                throw Issue6ProbeFailure.message("Invalid duration")
            }
            let projectURL = URL(fileURLWithPath: CommandLine.arguments[5], isDirectory: true)
            let contextHint: String?
            if CommandLine.arguments.count == 7 {
                let contextURL = URL(fileURLWithPath: CommandLine.arguments[6])
                guard FileManager.default.fileExists(atPath: contextURL.path) else {
                    throw Issue6ProbeFailure.message("Missing context file: \(contextURL.path)")
                }
                contextHint = try String(contentsOf: contextURL, encoding: .utf8)
            } else {
                contextHint = nil
            }
            for path in [mediaURL.path, audioURL.path, modelPath] {
                guard FileManager.default.fileExists(atPath: path) else {
                    throw Issue6ProbeFailure.message("Missing input: \(path)")
                }
            }

            let durationReader = FFmpegAdapter(runner: ToolRunner())
            guard let mediaDuration = try await durationReader.duration(of: mediaURL),
                  let preparedDuration = try await durationReader.duration(of: audioURL),
                  abs(mediaDuration - duration) <= 1,
                  abs(preparedDuration - duration) <= 1 else {
                throw Issue6ProbeFailure.message(
                    "Media, prepared WAV and declared duration do not identify the same recording"
                )
            }

            let profile = WhisperLongFormProfile.forLanguage("ru")
            guard profile.overlap == 0 else {
                throw Issue6ProbeFailure.message("Issue #6 Russian profile unexpectedly uses chunk overlap")
            }
            let layout = ProjectLayout(root: projectURL)
            try FileManager.default.createDirectory(at: layout.textsDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: layout.supportDirectory, withIntermediateDirectories: true)

            let result = try await SegmentedWhisperTranscriber(
                runner: ToolRunner(),
                vadModelLocator: WhisperVADModelLocator()
            ).transcribe(
                audioURL: audioURL,
                mediaURL: mediaURL,
                projectURL: projectURL,
                mediaDuration: duration,
                modelPath: modelPath,
                language: "ru",
                contextHint: contextHint,
                onProgress: { progress in
                    print("ISSUE6_PROGRESS=\(Int((progress * 100).rounded()))")
                },
                onLog: { print("ISSUE6_LOG=\($0)") }
            )
            let cues = try SRTService().load(from: result.srtURL)
            let issues = SRTService().validateTimeline(cues, mediaDuration: duration)
            guard issues.isEmpty else {
                throw Issue6ProbeFailure.message("Merged SRT is invalid: \(issues.joined(separator: " "))")
            }
            print("ISSUE6_LONG_RUSSIAN_PROBE_PASS")
            print("PROFILE=\(profile.identifier)")
            print("SRT=\(result.srtURL.path)")
            print("CUES=\(cues.count)")
        } catch {
            fputs("ISSUE6_LONG_RUSSIAN_PROBE_FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
