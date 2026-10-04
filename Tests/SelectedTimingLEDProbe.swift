import Foundation

struct SelectedTimingLEDProbe {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mediaPath = environment["VIDEOTEXT_LED_SOURCE"],
              let seminarTextPath = environment["VIDEOTEXT_SEMINARTEXT_EXECUTABLE"],
              let outputPath = environment["VIDEOTEXT_LED_OUTPUT_ROOT"],
              let projectPath = environment["VIDEOTEXT_LED_PROJECT_ROOT"] else {
            throw WorkflowError.processFailed("LED probe требует VIDEOTEXT_LED_SOURCE, VIDEOTEXT_SEMINARTEXT_EXECUTABLE, VIDEOTEXT_LED_OUTPUT_ROOT и VIDEOTEXT_LED_PROJECT_ROOT.")
        }
        let media = URL(fileURLWithPath: mediaPath)
        let seminarText = URL(fileURLWithPath: seminarTextPath)
        let output = URL(fileURLWithPath: outputPath)
        let project = URL(fileURLWithPath: projectPath)
        let layout = ProjectLayout(root: project)
        let expectedSHA = "f53460e353437873e34f404b841134def1ffbbae6f719f3e618adb159ad84ecc"
        try require(SelectedTimingHash.file(media) == expectedSHA, "LED source SHA-256 differs from the accepted fixture")

        let slice = SelectedTimingVerticalSlice()
        let result = try await slice.execute(
            mediaURL: media,
            source: .en,
            target: .ru,
            seminarTextExecutable: seminarText,
            upstreamOutputRoot: output,
            cacheDirectory: layout.selectedTimingTranslationCacheDirectory,
            onLog: { print($0, terminator: "") }
        )
        try result.validate()
        try slice.persist(result, to: project)

        let source = result.source.sourceText
        try require(source.contains("save a lot of energy. The LED"), "energy-to-LED source sequence was not preserved")
        try require(source.localizedCaseInsensitiveContains("warm LEDs"), "warm LEDs did not remain in one source unit")
        try require(source.localizedCaseInsensitiveContains("mitochondria"), "mitochondria source region was lost")
        try require(result.units.count == result.source.units.count, "timed translated units are incomplete")
        try require(zip(result.units, result.source.units).allSatisfy {
            $0.sourceUnitID == $1.id && $0.start == $1.start && $0.end == $1.end && $0.sourceTextSHA256 == $1.textSHA256
        }, "translated timing provenance is not truthful")
        try require(result.source.units.last?.end == 56.449125, "manifest media range did not bound Whisper padding")

        try require(FileManager.default.fileExists(atPath: layout.selectedTimingSourceUnitsURL.path), "source units were not persisted")
        try require(FileManager.default.fileExists(atPath: layout.selectedTimingTranslationsURL(source: .en, target: .ru).path), "timed translations were not persisted")
        print("SELECTED_TIMING_LED_PROBE_PASS units=\(result.units.count) upstream=\(result.source.upstreamManifestSHA256)")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw WorkflowError.processFailed(message) }
    }
}

@main
struct SelectedTimingLEDProbeMain {
    static func main() async {
        do { try await SelectedTimingLEDProbe.main() }
        catch { fputs("SELECTED_TIMING_LED_PROBE_FAIL: \(error)\n", stderr); exit(1) }
    }
}
