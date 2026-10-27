import Foundation

@main
struct SeminarTextCoreTranscriptionProbe {
    static func main() async {
        do {
            try await verifyCoreRunner()
            try verifyRealCompletedRecoveryIfConfigured()
            try verifyAbsoluteOffsetImport()
            try verifyReverseRawImport()
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

    private static func verifyReverseRawImport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("videotext-core-reverse-raw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let parts = root.appendingPathComponent("parts", isDirectory: true)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        let media = root.appendingPathComponent("source.mp4")
        try Data("reverse-raw-media".utf8).write(to: media)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ReverseRawTokens.json")
        let jsonURL = parts.appendingPathComponent("part_0000.json")
        try Data(contentsOf: fixture).write(to: jsonURL)
        let manifest: [String: Any] = [
            "schema_version": 1,
            "artifact_type": "seminartext.selected_whisper_timing",
            "source": ["media_sha256": SelectedTimingHash.file(media)],
            "transcription": ["language": "en"],
            "parts": [[
                "id": "part_0000", "order": 0, "absolute_offset_seconds": 300.0,
                "selected_timing_absolute_range": ["start_seconds": 300.0, "end_seconds": 301.2],
                "artifacts": ["json_full": [
                    "path": "parts/part_0000.json", "sha256": SelectedTimingHash.file(jsonURL)
                ]]
            ]]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
        let data = try SeminarTextCoreWhisperEvidenceImporter().importSelectedWhisperJSON(
            packageRoot: root, expectedMediaURL: media, expectedLanguage: .en
        )
        let imported = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tokens = ((imported?["transcription"] as? [[String: Any]])?.first?["tokens"] as? [[String: Any]]) ?? []
        let expected: [(String, Int, Int)] = [
            (" Um", 300_120, 300_080), (" I", 300_150, 300_250),
            (" um", 300_340, 300_310), (" speak.", 300_400, 300_620)
        ]
        try require(tokens.count == expected.count, "core importer removed reverse raw tokens")
        try require(zip(tokens, expected).allSatisfy { token, item in
            let offsets = token["offsets"] as? [String: Any]
            return token["text"] as? String == item.0
                && (offsets?["from"] as? NSNumber)?.intValue == item.1
                && (offsets?["to"] as? NSNumber)?.intValue == item.2
        }, "core importer changed reverse raw endpoints or token order")
        let firstTimestamps = tokens[0]["timestamps"] as? [String: Any]
        try require(firstTimestamps?["from"] as? String == "00:05:00.120"
                    && firstTimestamps?["to"] as? String == "00:05:00.080",
                    "core importer changed reverse raw timestamp direction")
        let importedURL = root.appendingPathComponent("whisper.json")
        try data.write(to: importedURL)
        try require(SeminarTextCoreWhisperEvidenceImporter().validateLegacyWhisperJSON(at: importedURL),
                    "core whisper.json rejected reverse-only raw evidence")
        let report = try FillerWordService().analyze(
            whisperJSONURL: importedURL,
            cues: [SubtitleCue(id: 1, start: 300, end: 301.2, text: "Um I um speak.")],
            language: .en,
            transcriptRevisionID: "core-reverse-raw"
        )
        try require(report.words.map(\.text) == ["Um", "I", "um", "speak."],
                    "core filler analysis removed or reordered reverse raw words")
        try require(report.words[0].start == 300.12 && report.words[0].end == 300.08
                    && report.words[2].start == 300.34 && report.words[2].end == 300.31,
                    "core filler analysis changed reverse raw endpoints")
        try require(report.candidates.filter { $0.normalized == "um" }.count == 2
                    && report.candidates.allSatisfy { $0.start >= 0 && $0.end > $0.start },
                    "core filler analysis lost reverse words or emitted invalid executable candidates")
        print("REVERSE_RAW_CORE_IMPORT_PRESERVATION_PASS")
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
        printf '%s|model=%s|path=%s\\n' "$*" "$SEMINARTEXT_MODEL" "$PATH" >> '\(invocationLog.path)'
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
        touch "$SEMINARTEXT_OUTPUT/run/.seminartext_complete"
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
        guard let canonicalFFmpeg = ToolRunner().resolve("ffmpeg") else {
            throw WorkflowError.missingTool("ffmpeg")
        }
        let canonicalDirectory = URL(fileURLWithPath: canonicalFFmpeg).deletingLastPathComponent().path
        try require(invocation.contains("|path=\(canonicalDirectory):"),
                    "core runner did not expose the canonical resolved FFmpeg directory to SeminarText")
        try verifyCompletedRecovery(result: result, media: media, root: root)
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

        let splitBoundaryFragments = [
            SubtitleCue(id: 12, start: 2.82, end: 2.92, text: "Split first"),
            SubtitleCue(id: 13, start: 2.82, end: 2.92, text: "fragment."),
            SubtitleCue(id: 14, start: 2.82, end: 3.2, text: "Boundary continuation.")
        ]
        let merged = try SeminarTextCoreTranscriptionRunner().reconcileForVideoTextTimeline(splitBoundaryFragments)
        try require(merged.count == 2 && merged[0].id == 12 && merged[0].text == "Split first fragment."
                    && merged[1].start == merged[0].end,
                    "core timeline did not join only adjacent equal short SeminarText boundary fragments")

        let longEqualInterval = [
            SubtitleCue(id: 15, start: 3, end: 3.3, text: "Long first fragment."),
            SubtitleCue(id: 16, start: 3, end: 3.3, text: "Long second fragment.")
        ]
        do {
            _ = try SeminarTextCoreTranscriptionRunner().reconcileForVideoTextTimeline(longEqualInterval)
            throw WorkflowError.processFailed("core timeline accepted a long equal-interval overlap")
        } catch let error as WorkflowError where error.localizedDescription.contains("accepted") {
            throw error
        } catch {
            // Expected: only short boundary fragments can be joined.
        }

        let nonAdjacentEqualInterval = [
            SubtitleCue(id: 17, start: 4, end: 4.1, text: "First fragment."),
            SubtitleCue(id: 18, start: 4.1, end: 4.2, text: "Bridge."),
            SubtitleCue(id: 19, start: 4, end: 4.1, text: "Not adjacent.")
        ]
        do {
            _ = try SeminarTextCoreTranscriptionRunner().reconcileForVideoTextTimeline(nonAdjacentEqualInterval)
            throw WorkflowError.processFailed("core timeline accepted a non-adjacent equal-interval overlap")
        } catch let error as WorkflowError where error.localizedDescription.contains("accepted") {
            throw error
        } catch {
            // Expected: only immediately adjacent fragments may be merged.
        }

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

    private static func verifyCompletedRecovery(
        result: SeminarTextCoreTranscriptionRunner.Result,
        media: URL,
        root: URL
    ) throws {
        let runner = SeminarTextCoreTranscriptionRunner()
        let outputRoot = root.appendingPathComponent("seminartext-output")
        let recovered = try runner.recoverCompletedResult(
            mediaURL: media,
            language: .en,
            outputRoot: outputRoot
        )
        try require(recovered?.srtURL.standardizedFileURL == result.srtURL.standardizedFileURL,
                    "completed matching SeminarText package was not recovered")

        let fixtureRoot = root.appendingPathComponent("recovery-fixtures", isDirectory: true)
        let sourcePackage = result.outputDirectory
        func copiedPackage(_ name: String) throws -> URL {
            let destination = fixtureRoot
                .appendingPathComponent("core-transcription-\(name)", isDirectory: true)
                .appendingPathComponent("run", isDirectory: true)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourcePackage, to: destination)
            return destination
        }
        func modifyManifest(in package: URL, _ body: (inout [String: Any]) -> Void) throws {
            let manifestURL = package.appendingPathComponent("structured_timing/manifest.json")
            var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
            body(&manifest)
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL, options: .atomic)
        }

        let wrongMedia = try copiedPackage("wrong-media")
        try modifyManifest(in: wrongMedia) { manifest in
            var source = manifest["source"] as! [String: Any]
            source["media_sha256"] = "not-the-current-media"
            manifest["source"] = source
        }
        let mediaMismatchRecovery = try runner.recoverCompletedResult(mediaURL: media, language: .en, outputRoot: fixtureRoot)
        try require(mediaMismatchRecovery == nil,
                    "recovery accepted a mismatched source media hash")
        try FileManager.default.removeItem(at: wrongMedia.deletingLastPathComponent())

        let wrongLanguage = try copiedPackage("wrong-language")
        try modifyManifest(in: wrongLanguage) { manifest in
            var transcription = manifest["transcription"] as! [String: Any]
            transcription["language"] = "ru"
            manifest["transcription"] = transcription
        }
        let languageMismatchRecovery = try runner.recoverCompletedResult(mediaURL: media, language: .en, outputRoot: fixtureRoot)
        try require(languageMismatchRecovery == nil,
                    "recovery accepted a mismatched source language")
        try FileManager.default.removeItem(at: wrongLanguage.deletingLastPathComponent())

        let missingMarker = try copiedPackage("missing-marker")
        try FileManager.default.removeItem(at: missingMarker.appendingPathComponent(".seminartext_complete"))
        let incompleteRecovery = try runner.recoverCompletedResult(mediaURL: media, language: .en, outputRoot: fixtureRoot)
        try require(incompleteRecovery == nil,
                    "recovery accepted an incomplete SeminarText package")
        try FileManager.default.removeItem(at: missingMarker.deletingLastPathComponent())

        _ = try copiedPackage("first")
        _ = try copiedPackage("second")
        let ambiguousRecovery = try runner.recoverCompletedResult(mediaURL: media, language: .en, outputRoot: fixtureRoot)
        try require(ambiguousRecovery == nil,
                    "recovery accepted ambiguous completed SeminarText packages")
    }

    /// An opt-in read-only check for a retained real SeminarText package. It
    /// exercises recovery, exact media binding, strict selected-timing import,
    /// and the VideoText SRT reconciliation without launching ASR or touching
    /// the project.
    private static func verifyRealCompletedRecoveryIfConfigured() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mediaPath = environment["VIDEOTEXT_REAL_RECOVERY_MEDIA"],
              let outputRootPath = environment["VIDEOTEXT_REAL_RECOVERY_OUTPUT_ROOT"],
              let languageValue = environment["VIDEOTEXT_REAL_RECOVERY_LANGUAGE"],
              let language = ArtifactLanguage(rawValue: languageValue) else {
            return
        }
        let media = URL(fileURLWithPath: mediaPath)
        let outputRoot = URL(fileURLWithPath: outputRootPath, isDirectory: true)
        let runner = SeminarTextCoreTranscriptionRunner()
        guard let result = try runner.recoverCompletedResult(
            mediaURL: media,
            language: language,
            outputRoot: outputRoot
        ) else {
            throw WorkflowError.processFailed("real completed SeminarText package was not safely recoverable")
        }
        let rawCues = try runner.loadCoreSRT(from: result.srtURL)
        let reconciled = try runner.reconcileForVideoTextTimeline(rawCues)
        try require(!rawCues.isEmpty && !reconciled.isEmpty && reconciled.count < rawCues.count,
                    "real completed package did not contain safely mergeable short equal-boundary fragments")
        let imported = try SeminarTextCoreWhisperEvidenceImporter().importSelectedWhisperJSON(
            packageRoot: result.selectedTimingPackageURL,
            expectedMediaURL: media,
            expectedLanguage: language
        )
        let importedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("videotext-real-recovered-whisper-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: importedURL) }
        try imported.write(to: importedURL)
        try require(SeminarTextCoreWhisperEvidenceImporter().validateLegacyWhisperJSON(at: importedURL),
                    "real completed package did not pass selected timing JSON integrity validation")
        print("REAL_COMPLETED_SEMINARTEXT_RECOVERY_PASS cues=\(rawCues.count)->\(reconciled.count)")
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
                  message.contains("существующего проекта с утверждённой исходной расшифровкой") else {
                throw error
            }
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw WorkflowError.processFailed(message) }
    }
}
