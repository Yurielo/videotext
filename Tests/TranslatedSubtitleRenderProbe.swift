import Foundation

@main
struct TranslatedSubtitleRenderProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw ProbeFailure(message: "usage: TranslatedSubtitleRenderProbe <controlled-project>")
        }
        let projectURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let store = ProjectStore()
        let manifest = try store.load(from: projectURL)
        let mediaURL = URL(fileURLWithPath: manifest.sourceMediaPath)
        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            throw ProbeFailure(message: "controlled project source media is unavailable")
        }
        let layout = ProjectLayout(root: projectURL)
        let sourceBytes = try Data(contentsOf: layout.fullSRTURL)
        let translation = try SubtitleSourceResolver.resolve(.approvedTranslation(.ru), manifest: manifest, projectURL: projectURL)
        let translationBytes = try Data(contentsOf: translation.srtURL)
        let ffmpeg = FFmpegAdapter()
        guard let duration = try await ffmpeg.duration(of: mediaURL) else {
            throw ProbeFailure(message: "controlled project source duration is unavailable")
        }
        _ = try await ffmpeg.burnSubtitles(
            mediaURL: mediaURL,
            srtURL: translation.srtURL,
            outputURL: layout.subtitledVideoURL(language: .ru),
            mediaDuration: duration,
            style: .standard
        ) { _ in }
        _ = try await ffmpeg.strictValidationReport(mediaURL: layout.subtitledVideoURL(language: .ru), expectedDuration: duration)
        try store.registerOutput(kind: "subtitled-video-ru", url: layout.subtitledVideoURL(language: .ru), in: projectURL)

        try require(nonempty(layout.subtitledVideoURL(language: .ru)), "RU full subtitled video was not created")
        try require(try Data(contentsOf: layout.fullSRTURL) == sourceBytes, "full.srt changed while rendering RU subtitles")
        try require(try Data(contentsOf: translation.srtURL) == translationBytes, "approved RU SRT changed while rendering")
        let fullOutputs = ResultsDetector().discover(in: projectURL)
        try require(fullOutputs.contains { $0.kind == "subtitled-video-ru" }, "RU full video is not discoverable")

        let cues = try SRTService().load(from: translation.srtURL)
        guard let first = cues.first else { throw ProbeFailure(message: "approved RU SRT is empty") }
        let fragmentID = "ru-render-probe"
        let fragmentVideo = layout.fragmentVideoURL(kind: fragmentID)
        let fragmentSRT = layout.fragmentSRTURL(kind: fragmentID)
        let fragmentOutput = layout.fragmentSubtitledVideoURL(kind: fragmentID)
        let fragmentDuration = first.end - first.start
        try FileManager.default.createDirectory(at: fragmentSRT.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await ffmpeg.cutAccurate(mediaURL: mediaURL, start: first.start, end: first.end, outputURL: fragmentVideo, onProgress: { _ in })
        let fragmentCues = SRTService().cues(in: cues, start: first.start, end: first.end, rebased: true)
        try SRTService().write(fragmentCues, to: fragmentSRT)
        _ = try await ffmpeg.burnSubtitles(mediaURL: fragmentVideo, srtURL: fragmentSRT, outputURL: fragmentOutput, mediaDuration: fragmentDuration, style: .standard) { _ in }
        _ = try await ffmpeg.strictValidationReport(mediaURL: fragmentOutput, expectedDuration: fragmentDuration)
        let fragment = FragmentRecord(
            id: fragmentID, name: "RU subtitle render probe", start: first.start, end: first.end, createdAt: Date(),
            videoPath: fragmentVideo.path, subtitlePath: fragmentSRT.path, subtitledVideoPath: fragmentOutput.path,
            ffprobeReportPath: nil, style: .standard, language: .ru
        )
        try store.registerFragment(fragment, in: projectURL)
        try store.registerOutput(kind: "fragment-subtitled-video-ru", url: fragmentOutput, in: projectURL)
        try require(fragment.language == .ru && nonempty(fragmentOutput), "RU subtitled fragment was not created")
        let renderedFragmentCues = try SRTService().load(from: fragmentSRT)
        try require(renderedFragmentCues.map(\.text) == fragmentCues.map(\.text),
                    "fragment SRT does not preserve the selected RU subtitle text")
        try require(renderedFragmentCues.count == fragmentCues.count && zip(renderedFragmentCues, fragmentCues).allSatisfy {
            abs($0.start - $1.start) < 0.001 && abs($0.end - $1.end) < 0.001
        },
                    "fragment SRT does not preserve selected RU subtitle timing")
        let fragmentOutputs = ResultsDetector().discover(in: projectURL)
        try require(fragmentOutputs.contains { $0.kind == "fragment-subtitled-video-ru" },
                    "RU fragment is not discoverable")
        let finalManifest = try store.load(from: projectURL)
        try require(finalManifest.workflow?.operations[WorkflowOperation.transcribe.rawValue]?.status == manifest.workflow?.operations[WorkflowOperation.transcribe.rawValue]?.status,
                    "subtitle rendering changed ASR workflow state")
        try require(finalManifest.workflow?.operations[WorkflowOperation.translateTranscript.rawValue]?.status == manifest.workflow?.operations[WorkflowOperation.translateTranscript.rawValue]?.status,
                    "subtitle rendering changed translation workflow state")
        print("TRANSLATED_SUBTITLE_RENDER_PROBE_PASS")
    }

    private static func nonempty(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
