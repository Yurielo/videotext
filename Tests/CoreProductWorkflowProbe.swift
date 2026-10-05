import Foundation

@main
struct CoreProductWorkflowProbe {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("CORE_PRODUCT_WORKFLOW_PROBE_FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mediaPath = environment["VIDEOTEXT_CORE_MEDIA"],
              let projectPath = environment["VIDEOTEXT_CORE_PROJECT"] else {
            throw WorkflowError.processFailed("Core workflow probe требует VIDEOTEXT_CORE_MEDIA и VIDEOTEXT_CORE_PROJECT.")
        }
        let media = URL(fileURLWithPath: mediaPath)
        let project = URL(fileURLWithPath: projectPath)
        let layout = ProjectLayout(root: project)
        let language = environment["VIDEOTEXT_CORE_LANGUAGE"] ?? "en"
        try require(FileManager.default.isReadableFile(atPath: media.path), "core media is not readable")
        try require(!FileManager.default.fileExists(atPath: project.path), "core probe project path must be fresh")

        let store = ProjectStore()
        let engine = WorkflowEngine(store: store)
        let settings = WorkflowSettings(
            mediaURL: media,
            projectURL: project,
            selectedOperations: [.transcribe],
            mode: .newProject,
            rangeStart: 0,
            rangeEnd: 1,
            fragmentName: "Core probe",
            burnFragmentSubtitles: false,
            subtitleStyle: .standard,
            selectedTopicID: nil,
            whisperModelPath: environment["VIDEOTEXT_CORE_MODEL"] ?? "",
            whisperLanguage: language,
            sourceHumanReviewEnabled: false,
            translationHumanReviewEnabled: false,
            fillerAnalysisBeforeReview: false
        )
        var logs: [String] = []
        _ = try await engine.run(settings: settings, onLog: { logs.append($0) })
        let cues = try SRTService().load(from: layout.fullSRTURL)
        try require(!cues.isEmpty, "core transcription produced an empty full.srt")
        try require(nonempty(layout.transcriptURL), "core transcription did not produce transcript.txt")
        try require(nonempty(layout.fullSRTURL), "core transcription did not produce full.srt")
        try require(nonempty(layout.seminarTextCoreEvidenceURL), "core SeminarText provenance was not persisted")
        try require(!FileManager.default.fileExists(atPath: layout.selectedTimingSourceUnitsURL.path), "core transcription wrote selected-timing source units")
        try require(!FileManager.default.fileExists(atPath: layout.selectedTimingSeminarTextDirectory.path), "core transcription wrote a selected-timing SeminarText package")
        let evidence = try JSONDecoder().decode(
            SeminarTextCoreTranscriptionEvidence.self,
            from: Data(contentsOf: layout.seminarTextCoreEvidenceURL)
        )
        let rawSRTs = try seminarTextSRTs(in: URL(fileURLWithPath: evidence.outputDirectory))
        try require(rawSRTs.count == 1 && evidence.sourceSRTSHA256 == SelectedTimingHash.file(rawSRTs[0]),
                    "core provenance does not bind the SeminarText SRT")
        try require(logs.contains(where: { $0.contains("Расшифровка bundled SeminarText") }), "core path did not use bundled SeminarText")
        try require(!logs.joined(separator: "\n").contains("selected timing"), "core path invoked selected timing")
        let outputs = try store.load(from: project).outputs
        try require(!outputs.contains(where: { $0.kind.contains("translation") }), "core path registered a translation output")

        var resumed = settings
        resumed.mode = .resumeProject
        let coreRunsBeforeResume = try coreRunDirectories(in: layout.seminarTextCoreDirectory).count
        _ = try await engine.run(settings: resumed, onLog: { logs.append($0) })
        let coreRunsAfterResume = try coreRunDirectories(in: layout.seminarTextCoreDirectory).count
        try require(coreRunsAfterResume == coreRunsBeforeResume,
                    "resume started another SeminarText transcription")

        let fragmentEnd = min(max(cues.first?.end ?? 1, 1), 5)
        var fragmentSettings = settings
        fragmentSettings.mode = .resumeProject
        fragmentSettings.selectedOperations = [.burnFragmentSubtitles]
        fragmentSettings.rangeStart = 0
        fragmentSettings.rangeEnd = fragmentEnd
        fragmentSettings.fragmentName = "Core subtitle fragment"
        let fragmentResult = try await engine.run(settings: fragmentSettings, onLog: { logs.append($0) })
        let manifest = try store.load(from: project)
        guard let fragment = manifest.fragments?.first else {
            throw WorkflowError.processFailed("core cut did not create a fragment record")
        }
        try require(FileManager.default.fileExists(atPath: fragment.videoPath), "core cut did not create the fragment video")
        try require(FileManager.default.fileExists(atPath: fragment.subtitlePath), "core cut did not create the fragment SRT")
        try require(fragment.subtitledVideoPath.map { FileManager.default.fileExists(atPath: $0) } == true,
                    "core subtitle burn did not create the subtitled fragment")
        try require(fragmentResult.projectURL == project, "core result lost project identity")

        let reopened = try store.openProject(at: project)
        try require(reopened.0.sourceMediaPath == media.path, "reopen lost core project source")
        try require(nonempty(layout.fullSRTURL) && nonempty(layout.transcriptURL), "reopen lost core transcript artifacts")
        print("CORE_PRODUCT_WORKFLOW_PROBE_PASS cues=\(cues.count) project=\(project.path) fragment=\(fragment.videoPath)")
    }

    private static func coreRunDirectories(in root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.lastPathComponent.hasPrefix("core-transcription-") }
            .sorted { $0.path < $1.path }
    }

    private static func seminarTextSRTs(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.pathExtension.lowercased() == "srt",
                  url.lastPathComponent.lowercased().hasPrefix("transcript"),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }

    private static func nonempty(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw WorkflowError.processFailed(message) }
    }
}
