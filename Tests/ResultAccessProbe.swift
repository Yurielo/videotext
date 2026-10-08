import Foundation

@main
struct ResultAccessProbe {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("videotext-result-access-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = ProjectLayout(root: root)
        try layout.createDirectories()
        let files: [(URL, String)] = [
            (layout.fragmentVideoURL(kind: "fragment"), "fragment-video"),
            (layout.fragmentSubtitledVideoURL(kind: "fragment"), "fragment-subtitled-video"),
            (layout.processedFragmentVideoURL(kind: "fragment"), "processed-fragment-video"),
            (layout.subtitledVideoURL, "subtitled-video"),
            (layout.speedAdjustedVideoURL(source: .fullVideo, language: .ru, factor: 1.25), "speed-adjusted-video"),
            (layout.blurredVideoURL(source: .fullVideo, id: "blur"), "blurred-video"),
            (layout.watermarkedVideoURL(source: .fullVideo, id: "watermark"), "watermarked-video"),
            (layout.fillerMutedAudioURL(id: "mute"), "filler-muted-audio"),
            (layout.fillerMutedVideoURL(id: "mute"), "filler-muted-video"),
            (layout.enhancedAudioURL(id: "enhanced"), "enhanced-audio"),
            (layout.enhancedVideoURL(id: "enhanced"), "enhanced-video")
        ]
        for (url, _) in files {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("result".utf8).write(to: url)
        }
        try Data("partial".utf8).write(to: layout.videoDirectory.appendingPathComponent("ignored.partial.mp4"))

        let outputs = ResultsDetector().discover(in: root)
        let byKind = Dictionary(grouping: outputs, by: \.kind)
        for (url, kind) in files {
            let expectedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard byKind[kind]?.contains(where: {
                URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path == expectedPath
            }) == true else {
                throw ProbeFailure(message: "Не обнаружен результат \(kind): \(url.path)")
            }
        }
        let generatedKinds = Set(outputs.filter(\.isGeneratedMedia).map(\.kind))
        let expectedKinds = Set(files.map(\.1))
        guard expectedKinds.isSubset(of: generatedKinds) else {
            throw ProbeFailure(message: "Не все core media results доступны общему действию")
        }
        guard !outputs.contains(where: { $0.path.contains(".partial.") }) else {
            throw ProbeFailure(message: "Частичный файл показан как готовый результат")
        }

        do {
            try FinderService().openResult(root.appendingPathComponent("missing.mp4"))
            throw ProbeFailure(message: "Исчезнувший результат ошибочно открыт")
        } catch WorkflowError.cannotOpenResult {
            // Expected fail-closed result action.
        }

        print("RESULT_ACCESS_PROBE_PASS outputs=\(outputs.count) generated=\(generatedKinds.count)")
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
