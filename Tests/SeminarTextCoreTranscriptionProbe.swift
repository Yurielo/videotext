import Foundation

@main
struct SeminarTextCoreTranscriptionProbe {
    static func main() async {
        do {
            try await verifyCoreRunner()
            try verifyAbsoluteOffsetImport()
            try await verifyReleaseBoundary()
            print("SEMINARTEXT_CORE_TRANSCRIPTION_PROBE_PASS")
        } catch {
            fputs("SEMINARTEXT_CORE_TRANSCRIPTION_PROBE_FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func verifyAbsoluteOffsetImport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("videotext-core-whisper-evidence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let parts = root.appendingPathComponent("parts", isDirectory: true)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        let media = root.appendingPathComponent("source.mp4")
        try Data("offset-media".utf8).write(to: media)
        let jsonURL = parts.appendingPathComponent("part_0000.json")
        let json: [String: Any] = [
            "result": ["language": "en"],
            "transcription": [[
                "offsets": ["from": 100, "to": 500],
                "no_speech_prob": 0.2,
                "tokens": [[
                    "text": " Offset",
                    "offsets": ["from": 100, "to": 500],
                    "timestamps": ["from": "00:00:00,100", "to": "00:00:00,500"],
                    "p": 0.73
                ]]
            ]]
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: jsonURL)
        let manifest: [String: Any] = [
            "schema_version": 1,
            "artifact_type": "seminartext.selected_whisper_timing",
            "source": ["media_sha256": SelectedTimingHash.file(media)],
            "transcription": ["language": "en"],
            "parts": [[
                "id": "part_0000",
                "order": 0,
                "absolute_offset_seconds": 300,
                "selected_timing_absolute_range": ["start_seconds": 300.1, "end_seconds": 300.5],
                "artifacts": ["json_full": [
                    "path": "parts/part_0000.json",
                    "sha256": SelectedTimingHash.file(jsonURL)
                ]]
            ]]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
        let data = try SeminarTextCoreWhisperEvidenceImporter().importSelectedWhisperJSON(
            packageRoot: root,
            expectedMediaURL: media,
            expectedLanguage: .en
        )
        let imported = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let token = ((imported?["transcription"] as? [[String: Any]])?.first?["tokens"] as? [[String: Any]])?.first
        let offsets = token?["offsets"] as? [String: Any]
        let timestamps = token?["timestamps"] as? [String: Any]
        try require((offsets?["from"] as? NSNumber)?.intValue == 300_100
                    && (offsets?["to"] as? NSNumber)?.intValue == 300_500,
                    "core whisper import did not shift selected token offsets by the manifest absolute offset")
        try require(timestamps?["from"] as? String == "00:05:00.100"
                    && timestamps?["to"] as? String == "00:05:00.500",
                    "core whisper import did not preserve absolute timestamp semantics")
        try require(token?["p"] as? Double == 0.73,
                    "core whisper import invented or lost token confidence")
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
        media="$2"
        mkdir -p "$SEMINARTEXT_OUTPUT/run/structured_timing/parts"
        cat > "$SEMINARTEXT_OUTPUT/run/transcript.srt" <<'SRT'
        00:00:00,000 --> 00:00:01,000
        Core transcription.

        00:00:00,900 --> 00:00:02,000
        Boundary continuation.
        SRT
        cat > "$SEMINARTEXT_OUTPUT/run/structured_timing/parts/part_0000.json" <<'JSON'
        {"result":{"language":"en"},"transcription":[{"offsets":{"from":0,"to":1000},"no_speech_prob":0.1,"tokens":[{"text":" Core","offsets":{"from":0,"to":450},"p":0.9},{"text":" transcription.","offsets":{"from":450,"to":1000},"p":0.8}]}]}
        JSON
        cat > "$SEMINARTEXT_OUTPUT/run/structured_timing/parts/part_0000.txt" <<'TXT'
        Core transcription.
        TXT
        cat > "$SEMINARTEXT_OUTPUT/run/structured_timing/parts/part_0000.srt" <<'SRT'
        00:00:00,000 --> 00:00:01,000
        Core transcription.
        SRT
        json_sha=$(shasum -a 256 "$SEMINARTEXT_OUTPUT/run/structured_timing/parts/part_0000.json" | awk '{print $1}')
        txt_sha=$(shasum -a 256 "$SEMINARTEXT_OUTPUT/run/structured_timing/parts/part_0000.txt" | awk '{print $1}')
        srt_sha=$(shasum -a 256 "$SEMINARTEXT_OUTPUT/run/structured_timing/parts/part_0000.srt" | awk '{print $1}')
        media_sha=$(shasum -a 256 "$media" | awk '{print $1}')
        cat > "$SEMINARTEXT_OUTPUT/run/structured_timing/manifest.json" <<JSON
        {"schema_version":1,"artifact_type":"seminartext.selected_whisper_timing","source":{"media_sha256":"$media_sha"},"transcription":{"language":"en"},"parts":[{"id":"part_0000","order":0,"absolute_offset_seconds":0,"selected_timing_absolute_range":{"start_seconds":0,"end_seconds":1},"artifacts":{"txt":{"path":"parts/part_0000.txt","sha256":"$txt_sha"},"srt":{"path":"parts/part_0000.srt","sha256":"$srt_sha"},"json_full":{"path":"parts/part_0000.json","sha256":"$json_sha"}}}]}
        JSON
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
        try require(invocation.contains("--structured-timing"), "core runner did not request selected JSON-full from the same Whisper attempt")
        let importedJSON = try SeminarTextCoreWhisperEvidenceImporter().importSelectedWhisperJSON(
            packageRoot: result.selectedTimingPackageURL,
            expectedMediaURL: media,
            expectedLanguage: .en
        )
        let importedURL = root.appendingPathComponent("whisper.json")
        try importedJSON.write(to: importedURL)
        try require(SeminarTextCoreWhisperEvidenceImporter().validateLegacyWhisperJSON(at: importedURL),
                    "selected JSON-full did not satisfy the legacy core whisper.json contract")
        let report = try FillerWordService().analyze(
            whisperJSONURL: importedURL,
            cues: [SubtitleCue(id: 1, start: 0, end: 1, text: "Core transcription.")],
            language: .en,
            transcriptRevisionID: "core-probe"
        )
        try require(report.words.count == 2 && report.words[0].confidence == 0.9,
                    "core whisper.json did not preserve selected token timing/confidence")
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
        try require(WorkflowOperation.translateTranscript.isEnabledForCurrentRelease, "explicit EN-to-RU translation is disabled")
        try require(!WorkflowOperation.createDubbing.isEnabledForCurrentRelease, "dubbing was enabled with translation")
        try require(WorkflowOperation.transcribe.isEnabledForCurrentRelease, "core transcription was disabled")
        try require(WorkflowOperation.topicTimecoding.isEnabledForCurrentRelease, "core topic operation was disabled")
        try require(WorkflowOperation.burnSubtitles.isEnabledForCurrentRelease, "core subtitle operation was disabled")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("videotext-core-release-boundary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = root.appendingPathComponent("source.mp4")
        try Data("release-boundary".utf8).write(to: media)
        let settings = WorkflowSettings(
            mediaURL: media,
            projectURL: root.appendingPathComponent("project"),
            selectedOperations: [.translateTranscript],
            mode: .newProject,
            rangeStart: 0,
            rangeEnd: 1,
            fragmentName: "probe",
            burnFragmentSubtitles: false,
            subtitleStyle: .standard,
            selectedTopicID: nil,
            whisperModelPath: "",
            whisperLanguage: "en",
            translationHumanReviewEnabled: true
        )
        do {
            _ = try await WorkflowEngine().run(settings: settings, onLog: { _ in })
            throw WorkflowError.processFailed("translation unexpectedly started without an approved EN project")
        } catch let error as WorkflowError {
            guard case .processFailed(let message) = error,
                  message.contains("существующего проекта с утверждённой английской") else {
                throw error
            }
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw WorkflowError.processFailed(message) }
    }
}
