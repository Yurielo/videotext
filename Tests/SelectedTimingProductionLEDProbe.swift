import Foundation

struct SelectedTimingProductionLEDProbe {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mediaPath = environment["VIDEOTEXT_LED_SOURCE"],
              let projectPath = environment["VIDEOTEXT_LED_PROJECT_ROOT"] else {
            throw WorkflowError.processFailed("Production LED probe требует VIDEOTEXT_LED_SOURCE и VIDEOTEXT_LED_PROJECT_ROOT.")
        }
        let media = URL(fileURLWithPath: mediaPath)
        let project = URL(fileURLWithPath: projectPath)
        let layout = ProjectLayout(root: project)
        let expectedSHA = "f53460e353437873e34f404b841134def1ffbbae6f719f3e618adb159ad84ecc"
        try require(SelectedTimingHash.file(media) == expectedSHA, "LED source SHA-256 differs from the accepted fixture")

        let settings = WorkflowSettings(
            mediaURL: media,
            projectURL: project,
            selectedOperations: [.translateTranscript],
            mode: .newProject,
            rangeStart: 0,
            rangeEnd: 1,
            fragmentName: "",
            burnFragmentSubtitles: false,
            subtitleStyle: .standard,
            selectedTopicID: nil,
            whisperModelPath: "",
            whisperLanguage: "en",
            sourceHumanReviewEnabled: false,
            translationHumanReviewEnabled: false,
            fillerAnalysisBeforeReview: false
        )
        let result = try await WorkflowEngine().run(settings: settings, onLog: { print($0) })
        try require(result.checkpoint == nil, "production translation unexpectedly opened Human Review")

        let source = try JSONDecoder().decode(TimedSourceDocument.self, from: Data(contentsOf: layout.selectedTimingSourceUnitsURL))
        let translation = try JSONDecoder().decode(
            TimedTranslationDocument.self,
            from: Data(contentsOf: layout.selectedTimingTranslationsURL(source: .en, target: .ru))
        )
        try source.validateCoverage()
        try translation.validate()
        try require(([source.units.map(\.text).joined()] == [source.sourceText]), "source loss or duplication")
        try require(abs((source.units.first?.start ?? -1) - 0) < 0.001, "selected JSON timing was inferred from VAD/SRT instead of its canonical timebase")
        try require(abs((source.selectedTimingEnd ?? -1) - 60) < 0.001, "selected timing envelope did not preserve Whisper padding")
        try require(source.sourceText.contains("save a lot of energy. The LED"), "energy-to-LED sequence was split")
        try require(source.units.contains { $0.text.localizedCaseInsensitiveContains("warm LEDs") }, "warm LEDs did not remain coherent")
        try require(source.units.contains { $0.text.localizedCaseInsensitiveContains("mitochondria") }, "mitochondria region was lost")
        try require(zip(source.units, translation.units).allSatisfy {
            $0.id == $1.sourceUnitID && $0.textSHA256 == $1.sourceTextSHA256 && $0.start == $1.start && $0.end == $1.end
        }, "translated units lost source timing provenance")

        let translatedSRT = try SRTService().load(from: layout.subtitlesURL(language: .ru))
        try require(translatedSRT.count == translation.units.count, "normal translated SRT did not use timed units")
        try require(zip(translatedSRT, translation.units).allSatisfy {
            $0.id == $1.sourceUnitID
                && abs($0.start - $1.start) <= 0.001
                && abs($0.end - $1.end) <= 0.001
                && $0.text == $1.text
        }, "normal translated SRT changed translated unit provenance")

        let sourceCues = try source.subtitleCues()
        let topicFixture = TopicsFile(
            adapter: "selected-timing-production-probe",
            createdAt: Date(),
            sourceSRT: layout.fullSRTURL.path,
            sourceSignature: "selected-timing-production-probe",
            status: .ready,
            topics: [TopicSegment(
                id: "topic-1",
                title: "LED energy and mitochondria discussion",
                start: sourceCues.first!.start,
                end: sourceCues.last!.end,
                summary: "The source discusses LED energy and the mitochondria region.",
                keywords: ["LED", "energy", "mitochondria"],
                confidence: 0.9,
                boundaryReason: "Single bounded probe topic.",
                cueIds: sourceCues.map(\.id)
            )]
        )
        let measuredDuration = (try ProjectStore().load(from: project)).durationSeconds ?? 0
        try require(
            TopicValidator().validate(topicFixture, expectedCues: sourceCues, mediaDuration: measuredDuration)
                .contains(where: { $0.contains("выходит за длительность") }),
            "probe did not reproduce the selected-timing topic-duration boundary"
        )
        try require(
            TopicValidator().validate(topicFixture, expectedCues: sourceCues, mediaDuration: source.selectedTimingEnd).isEmpty,
            "selected timing envelope did not validate a topic bound to selected source cues"
        )

        let manifestRoot = layout.selectedTimingSeminarTextDirectory
        let packages = findSelectedPackages(in: manifestRoot)
        try require(packages.count == 1, "native workflow ran SeminarText more than once")
        let transcriptionLog = packages[0]
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("transcription.log")
        let log = try String(contentsOf: transcriptionLog, encoding: .utf8)
        try require(log.components(separatedBy: "output_json: saving output").count - 1 == 1, "selected Whisper timing did not come from one attempt")
        try require(!log.localizedCaseInsensitiveContains("whisperx") && !log.localizedCaseInsensitiveContains("forced alignment"), "production workflow invoked forbidden alignment")
        try require(!FileManager.default.fileExists(atPath: layout.whisperJSONURL.path), "VideoText created a parallel Whisper JSON output")
        try require(FileManager.default.fileExists(atPath: layout.fullSRTURL.path), "normal source full.srt was not created")
        try require(FileManager.default.fileExists(atPath: layout.translationReportURL(source: .en, target: .ru).path), "normal translation report was not created")
        var timelineSettings = settings
        timelineSettings.mode = .resumeProject
        timelineSettings.selectedOperations = [.validateTimeline]
        _ = try await WorkflowEngine().run(settings: timelineSettings, onLog: { print($0) })
        let timelineReport = try String(contentsOf: layout.timelineValidationURL, encoding: .utf8)
        try require(timelineReport.contains("Временная шкала корректна"), "selected timing envelope did not pass normal timeline validation")
        var fillerSettings = settings
        fillerSettings.mode = .resumeProject
        fillerSettings.selectedOperations = [.detectFillerWords]
        _ = try await WorkflowEngine().run(settings: fillerSettings, onLog: { print($0) })
        let fillerReport = try FillerWordService().load(from: layout.fillerWordsURL)
        try require(!fillerReport.words.isEmpty, "filler analysis did not consume selected Whisper token evidence")
        try require(!FileManager.default.fileExists(atPath: layout.whisperJSONURL.path), "filler analysis created a parallel Whisper JSON output")
        let translationBytes = try Data(contentsOf: layout.selectedTimingTranslationsURL(source: .en, target: .ru))
        var resumeSettings = settings
        resumeSettings.mode = .resumeProject
        _ = try await WorkflowEngine().run(settings: resumeSettings, onLog: { print($0) })
        try require(findSelectedPackages(in: manifestRoot).count == 1, "resume started a second SeminarText transcription")
        let resumedTranslationBytes = try Data(contentsOf: layout.selectedTimingTranslationsURL(source: .en, target: .ru))
        try require(
            resumedTranslationBytes == translationBytes,
            "resume recomputed or corrupted selected timing translation"
        )
        print("SELECTED_TIMING_PRODUCTION_LED_PROBE_PASS units=\(translation.units.count) package=\(packages[0].path)")
    }

    private static func findSelectedPackages(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.lastPathComponent == "manifest.json",
                  url.deletingLastPathComponent().lastPathComponent.hasPrefix("structured_timing") else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw WorkflowError.processFailed(message) }
    }
}

@main
struct SelectedTimingProductionLEDProbeMain {
    static func main() async {
        do { try await SelectedTimingProductionLEDProbe.main() }
        catch { fputs("SELECTED_TIMING_PRODUCTION_LED_PROBE_FAIL: \(error)\n", stderr); exit(1) }
    }
}
