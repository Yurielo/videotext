import Foundation

@main
struct SeminarTextCoreTranscriptionProbe {
    static func main() async {
        do {
            try await verifyCoreRunner()
            try await verifyReleaseBoundary()
            print("SEMINARTEXT_CORE_TRANSCRIPTION_PROBE_PASS")
        } catch {
            fputs("SEMINARTEXT_CORE_TRANSCRIPTION_PROBE_FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func verifyCoreRunner() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("videotext-core-transcription-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = root.appendingPathComponent("source.mp4")
        try Data("media".utf8).write(to: media)
        let invocationLog = root.appendingPathComponent("invocations.log")
        let executable = root.appendingPathComponent("fake-seminartext")
        let script = """
        #!/bin/sh
        printf '%s|model=%s\\n' "$*" "$SEMINARTEXT_MODEL" >> '\(invocationLog.path)'
        mkdir -p "$SEMINARTEXT_OUTPUT/run"
        cat > "$SEMINARTEXT_OUTPUT/run/transcript.srt" <<'SRT'
        00:00:00,000 --> 00:00:01,000
        Core transcription.

        00:00:00,900 --> 00:00:02,000
        Boundary continuation.
        SRT
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let result = try await SeminarTextCoreTranscriptionRunner().transcribe(
            mediaURL: media,
            language: .en,
            executable: executable,
            modelPath: "/models/core.bin",
            outputRoot: root.appendingPathComponent("seminartext-output")
        )
        try require(result.srtURL.lastPathComponent == "transcript.srt", "core runner did not select the ordinary SeminarText SRT")
        try require(FileManager.default.fileExists(atPath: result.srtURL.path), "core SRT was not retained")
        let invocation = try String(contentsOf: invocationLog, encoding: .utf8)
        try require(invocation.contains("transcribe"), "core runner did not invoke SeminarText transcribe")
        try require(invocation.contains("--language en"), "core runner did not pass the source language")
        try require(invocation.contains("--no-open"), "core runner did not keep SeminarText headless")
        try require(invocation.contains("|model=/models/core.bin"), "core runner did not pass the selected Whisper model")
        try require(!invocation.contains("--structured-timing"), "core runner requested translation-only selected timing")
        let cues = try SeminarTextCoreTranscriptionRunner().loadCoreSRT(from: result.srtURL)
        try require(cues.map(\.id) == [1, 2] && cues[0].text == "Core transcription.", "core importer did not assign VideoText cue IDs")
        let reconciled = try SeminarTextCoreTranscriptionRunner().reconcileForVideoTextTimeline(cues)
        try require(reconciled[1].start == reconciled[0].end, "core timeline did not reconcile a bounded chunk-boundary overlap")

        let malformed = root.appendingPathComponent("malformed.srt")
        try Data("00:00:01,000 --> 00:00:00,000\\nBroken\n".utf8).write(to: malformed)
        do {
            _ = try SeminarTextCoreTranscriptionRunner().loadCoreSRT(from: malformed)
            throw WorkflowError.processFailed("core importer accepted an invalid SeminarText time range")
        } catch let error as WorkflowError where error.localizedDescription.contains("accepted") {
            throw error
        } catch {
            // Expected: the dedicated adapter remains strict about time ranges.
        }

        var unsafeOverlap = cues
        unsafeOverlap[1].start = 0.2
        do {
            _ = try SeminarTextCoreTranscriptionRunner().reconcileForVideoTextTimeline(unsafeOverlap)
            throw WorkflowError.processFailed("core timeline accepted an unsafe overlap")
        } catch let error as WorkflowError where error.localizedDescription.contains("accepted") {
            throw error
        } catch {
            // Expected: only tiny chunk-boundary overlaps may be reconciled.
        }
    }

    private static func verifyReleaseBoundary() async throws {
        try require(!WorkflowOperation.userSelectable.contains(.translateTranscript), "translation remains user-selectable in the core release")
        try require(!WorkflowOperation.translateTranscript.isEnabledForCurrentRelease, "translation is enabled in the core release")
        try require(!WorkflowOperation.createDubbing.isEnabledForCurrentRelease, "translation-dependent dubbing is enabled in the core release")
        try require(WorkflowOperation.transcribe.isEnabledForCurrentRelease, "core transcription was disabled")
        try require(WorkflowOperation.topicTimecoding.isEnabledForCurrentRelease, "core topic operation was disabled")
        try require(WorkflowOperation.burnSubtitles.isEnabledForCurrentRelease, "core subtitle operation was disabled")

        let settings = WorkflowSettings(
            mediaURL: URL(fileURLWithPath: "/tmp/videotext-core-release-boundary.mp4"),
            projectURL: nil,
            selectedOperations: [.translateTranscript],
            mode: .newProject,
            rangeStart: 0,
            rangeEnd: 1,
            fragmentName: "probe",
            burnFragmentSubtitles: false,
            subtitleStyle: .standard,
            selectedTopicID: nil,
            whisperModelPath: "",
            whisperLanguage: "en"
        )
        do {
            _ = try await WorkflowEngine().run(settings: settings, onLog: { _ in })
            throw WorkflowError.processFailed("disabled translation unexpectedly entered the workflow")
        } catch let error as WorkflowError {
            guard case .processFailed(let message) = error,
                  message.contains("временно недоступны") else {
                throw error
            }
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw WorkflowError.processFailed(message) }
    }
}
