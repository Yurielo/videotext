import Foundation

struct SelectedTimingVerticalSliceProbe {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("videotext-selected-timing-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = root.appendingPathComponent("led.mp4")
        try Data("LED media".utf8).write(to: media)
        let package = root.appendingPathComponent("package")
        try makePackage(at: package, media: media)
        try verifyManifestDiscovery(root: root, media: media, package: package)
        try await verifySingleSeminarTextEntry(root: root, media: media, package: package)

        let importer = SelectedTimingImporter()
        let source = try importer.importSelectedPackage(packageRoot: package, expectedMediaURL: media, expectedLanguage: .en)
        try require(source.sourceText == source.units.map(\.text).joined(), "source loss or duplication")
        try require(source.units.contains(where: { $0.text.contains("save a lot of energy.") }), "energy sentence split")
        try require(source.units.contains(where: { $0.text.contains("The LED has got a blue spike.") }), "LED sentence split")
        try require(source.units.contains(where: { $0.text.localizedCaseInsensitiveContains("warm LEDs") }), "warm LEDs split")
        try require(source.units.contains(where: { $0.text.contains("mitochondria") }), "mitochondria missing")
        try require(source.units.map(\.id) == Array(1...source.units.count), "source order changed")
        try require(source.units.allSatisfy { $0.end >= $0.start }, "invalid time range")
        try require(source.units.first?.start == 0, "selected JSON token timing was not shifted from its own timebase")
        try require(source.units.last?.end == 2.4, "selected JSON token timing was inferred from SRT/segment boundaries")
        try require(source.selectedTimingEnd == 5.5, "selected timing envelope was not preserved")
        try require(
            source.tokenTimeline.contains(where: { $0.text == " They" && $0.start == 0 && $0.end == 0.1 }),
            "valid token timing was modified"
        )
        print("VALID_TOKEN_TIMING_UNCHANGED_PASS")

        let reverseRawPackage = root.appendingPathComponent("reverse-raw-package")
        try makeReverseRawPackage(at: reverseRawPackage, media: media)
        let reverseRawSource = try importer.importSelectedPackage(
            packageRoot: reverseRawPackage,
            expectedMediaURL: media,
            expectedLanguage: .en
        )
        let expectedRawTokens: [(String, Double, Double)] = [
            (" Um", 0.12, 0.08), (" I", 0.15, 0.25),
            (" um", 0.34, 0.31), (" speak.", 0.4, 0.62)
        ]
        try require(reverseRawSource.tokenTimeline.count == expectedRawTokens.count,
                    "reverse raw tokens were removed")
        try require(zip(reverseRawSource.tokenTimeline, expectedRawTokens).allSatisfy { token, expected in
            token.text == expected.0 && token.start == expected.1 && token.end == expected.2
        }, "reverse raw token endpoints or source order changed")
        try require(reverseRawSource.units.allSatisfy { $0.start >= 0 && $0.end >= $0.start },
                    "reverse raw evidence produced invalid executable source units")
        try reverseRawSource.validateCoverage()
        let reverseRawRoundTrip = try JSONDecoder().decode(
            TimedSourceDocument.self, from: JSONEncoder().encode(reverseRawSource)
        )
        try require(reverseRawRoundTrip == reverseRawSource,
                    "reverse raw token timing or order did not survive Codable round-trip")
        let reverseFillerReport = try FillerWordService().analyze(
            selectedTiming: reverseRawRoundTrip,
            cues: try reverseRawRoundTrip.subtitleCues(),
            language: .en,
            transcriptRevisionID: "reverse-raw-evidence"
        )
        try require(reverseFillerReport.words.map(\.text) == ["Um", "I", "um", "speak."],
                    "selected filler analysis lost or reordered reverse raw tokens")
        try require(reverseFillerReport.words[0].start == 0.12 && reverseFillerReport.words[0].end == 0.08
                    && reverseFillerReport.words[2].start == 0.34 && reverseFillerReport.words[2].end == 0.31,
                    "selected filler analysis changed reverse raw endpoints")
        try require(reverseFillerReport.candidates.filter { $0.normalized == "um" }.count == 2
                    && reverseFillerReport.candidates.allSatisfy { $0.start >= 0 && $0.end > $0.start },
                    "selected filler analysis lost reverse words or emitted invalid executable candidates")
        var invalidReverseUnit = reverseRawSource
        invalidReverseUnit.units[0].start = invalidReverseUnit.units[0].end + 0.01
        try expectFailure { try invalidReverseUnit.validateCoverage() }
        print("REVERSE_RAW_SELECTED_TIMING_PRESERVATION_PASS")

        let twoSentencePackage = root.appendingPathComponent("two-sentence-reverse-raw-package")
        try makeReverseRawPackage(
            at: twoSentencePackage, media: media,
            fixtureName: "ReverseRawMultiSentence.json", sourceText: " One. Two.", srtText: "One. Two."
        )
        let twoSentenceSource = try importer.importSelectedPackage(
            packageRoot: twoSentencePackage, expectedMediaURL: media, expectedLanguage: .en
        )
        try require(twoSentenceSource.sourceText == " One. Two."
                    && twoSentenceSource.tokenTimeline.map(\.text) == [" One", ".", " Two", "."]
                    && twoSentenceSource.tokenTimeline[0].start == 0.1
                    && twoSentenceSource.tokenTimeline[0].end == 0.08,
                    "two-sentence import changed reverse speech tokens or retained [_TT_128] as source text")
        try require(twoSentenceSource.units.map(\.text) == [" One.", " Two."]
                    && twoSentenceSource.units[0].end <= twoSentenceSource.units[1].start
                    && twoSentenceSource.units.allSatisfy { $0.start >= 0 && $0.end > $0.start },
                    "reverse token expanded its derived unit across the next sentence")
        try twoSentenceSource.validateCoverage()
        var overlappingDerivedUnit = twoSentenceSource
        overlappingDerivedUnit.units[1].start = overlappingDerivedUnit.units[0].end - 0.01
        try expectFailure { try overlappingDerivedUnit.validateCoverage() }
        var zeroWidthDerivedUnit = twoSentenceSource
        zeroWidthDerivedUnit.units[0].end = zeroWidthDerivedUnit.units[0].start
        try expectFailure { try zeroWidthDerivedUnit.validateCoverage() }
        let twoSentenceFiller = try FillerWordService().analyze(
            selectedTiming: twoSentenceSource,
            cues: try twoSentenceSource.subtitleCues(),
            language: .en, transcriptRevisionID: "two-sentence-control-filter"
        )
        try require(twoSentenceFiller.words.map(\.text) == ["One", "Two"],
                    "selected filler words retained [_TT_128] control marker")
        let twoSentenceCoreJSON = try SeminarTextCoreWhisperEvidenceImporter().importSelectedWhisperJSON(
            packageRoot: twoSentencePackage, expectedMediaURL: media, expectedLanguage: .en
        )
        let twoSentenceCoreObject = try JSONSerialization.jsonObject(with: twoSentenceCoreJSON) as? [String: Any]
        let twoSentenceCoreTokens = ((twoSentenceCoreObject?["transcription"] as? [[String: Any]])?.first?["tokens"] as? [[String: Any]]) ?? []
        try require(twoSentenceCoreTokens.map { $0["text"] as? String ?? "" }
                    == [" One", ".", " Two", ".", "[_TT_128]"],
                    "core whisper.json removed or reordered raw [_TT_128] marker")
        print("REVERSE_RAW_TWO_SENTENCE_DERIVED_UNIT_BOUNDARY_PASS")

        let overlappingPreparedRanges = root.appendingPathComponent("overlapping-prepared-ranges")
        try makeOverlappingPreparedRangePackage(at: overlappingPreparedRanges, media: media)
        let overlappingPreparedSource = try importer.importSelectedPackage(
            packageRoot: overlappingPreparedRanges,
            expectedMediaURL: media,
            expectedLanguage: .en
        )
        try require(
            overlappingPreparedSource.sourceText == " First. Second.",
            "valid prepared chunk overlap lost or duplicated selected source text"
        )
        try require(
            overlappingPreparedSource.selectedTimingEnd == 330,
            "valid prepared chunk overlap did not retain the selected timing envelope"
        )
        print("VALID_PREPARED_CHUNK_OVERLAP_PASS")

        let malformedPreparedRange = root.appendingPathComponent("malformed-prepared-range")
        try makeOverlappingPreparedRangePackage(at: malformedPreparedRange, media: media, malformedRange: true)
        try expectFailure {
            _ = try importer.importSelectedPackage(
                packageRoot: malformedPreparedRange,
                expectedMediaURL: media,
                expectedLanguage: .en
            )
        }
        print("MALFORMED_RANGE_REJECTION_PASS")
        let selectedProject = root.appendingPathComponent("selected-project")
        try FileManager.default.createDirectory(at: selectedProject, withIntermediateDirectories: true)
        try SelectedTimingVerticalSlice().persistSource(source, to: selectedProject)
        try require(
            SelectedTimingTimeline.permittedEnd(projectURL: selectedProject, measuredDuration: 1.96) == 5.5,
            "topic/review validation did not consume the published selected timing envelope"
        )
        try require(
            SelectedTimingTimeline.permittedEnd(projectURL: root.appendingPathComponent("ordinary-project"), measuredDuration: 1.96) == 1.96,
            "ordinary projects received a selected timing extension"
        )
        var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as! [String: Any]
        legacyObject.removeValue(forKey: "tokenTimeline")
        legacyObject.removeValue(forKey: "selectedTimingEnd")
        legacyObject.removeValue(forKey: "qualityEvidence")
        let legacySource = try JSONDecoder().decode(
            TimedSourceDocument.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        try require(legacySource.tokenTimeline.isEmpty && legacySource.selectedTimingEnd == nil && legacySource.qualityEvidence.isEmpty,
                    "existing selected timing documents no longer decode")
        try require(
            source.qualityEvidence.count == source.units.count
                && source.qualityEvidence.allSatisfy { $0.averageTokenConfidence != nil && $0.averageNoSpeechProbability != nil },
            "selected Whisper quality evidence was not preserved with source timing"
        )
        var acceptedCues = try source.subtitleCues()
        acceptedCues = acceptedCues.map { cue in
            SubtitleCue(id: cue.id, start: cue.start, end: cue.end, text: cue.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let reconciled = try SelectedTimingVerticalSlice().sourceDocument(source, reconciledWith: acceptedCues)
        try require(reconciled == source, "SRT whitespace normalization changed selected source provenance")
        let reconciledAgain = try SelectedTimingVerticalSlice().sourceDocument(reconciled, reconciledWith: acceptedCues)
        try require(reconciledAgain == reconciled, "selected timing reconciliation is not idempotent at shared unit boundaries")
        acceptedCues[1].text = "Corrected accepted source text."
        let corrected = try SelectedTimingVerticalSlice().sourceDocument(source, reconciledWith: acceptedCues)
        try require(corrected.units[1].text == " Corrected accepted source text.", "accepted source correction was not bound to selected timing")
        try require(corrected.units[1].textSHA256 != source.units[1].textSHA256, "accepted source correction did not invalidate unit cache identity")
        var temporallyIncompatibleCues = acceptedCues
        temporallyIncompatibleCues.append(SubtitleCue(id: 99, start: 3.0, end: 3.1, text: "Unmapped approved cue."))
        do {
            _ = try SelectedTimingVerticalSlice().sourceDocument(source, reconciledWith: temporallyIncompatibleCues)
            throw WorkflowError.processFailed("temporally incompatible selected timing unexpectedly reconciled")
        } catch SelectedTimingSourceCompatibilityError.temporalCoverage(let cueID) {
            try require(cueID == 99, "selected timing incompatibility reported the wrong approved cue")
        }
        print("SELECTED_TIMING_TEMPORAL_COMPATIBILITY_CLASSIFICATION_PASS")

        var fillerSource = source
        fillerSource.tokenTimeline = [
            TimedSourceToken(text: " Um", start: 0.55, end: 0.65, sourcePartID: "part_0000"),
            TimedSourceToken(text: " um", start: 0.70, end: 0.80, sourcePartID: "part_0000")
        ]
        let fillerReport = try FillerWordService().analyze(
            selectedTiming: fillerSource,
            cues: try source.subtitleCues(),
            language: .en,
            transcriptRevisionID: "selected-timing-revision"
        )
        try require(fillerReport.candidates.filter { $0.normalized == "um" }.count == 2,
                    "selected Whisper token evidence was not used for filler analysis")

        var overlapping = source
        overlapping.units[1].start = overlapping.units[0].end - 0.01
        try expectFailure { try overlapping.validateCoverage() }
        var negative = source
        negative.units[0].start = -0.01
        try expectFailure { try negative.validateCoverage() }
        let zeroWidthPackage = root.appendingPathComponent("zero-width-package")
        try makePackage(at: zeroWidthPackage, media: media, zeroWidthSpokenToken: true)
        let zeroWidthSource = try importer.importSelectedPackage(
            packageRoot: zeroWidthPackage,
            expectedMediaURL: media,
            expectedLanguage: .en
        )
        try require(
            zeroWidthSource.sourceText == zeroWidthSource.units.map(\.text).joined(),
            "zero-width selected token lost or duplicated source text"
        )
        try require(
            zeroWidthSource.tokenTimeline.contains(where: {
                $0.text == " save" && $0.start == 0.1 && $0.end == 0.1
            }),
            "zero-width selected token timing was rewritten"
        )
        try require(
            zeroWidthSource.units.allSatisfy { $0.end >= $0.start },
            "zero-width selected token corrupted source-unit envelope"
        )
        let zeroWidthSegmentPackage = root.appendingPathComponent("zero-width-segment-package")
        try makeZeroWidthSegmentPackage(at: zeroWidthSegmentPackage, media: media)
        let zeroWidthSegmentSource = try importer.importSelectedPackage(
            packageRoot: zeroWidthSegmentPackage,
            expectedMediaURL: media,
            expectedLanguage: .en
        )
        try require(
            zeroWidthSegmentSource.tokenTimeline.contains(where: { $0.text == " Brief" && $0.start == 0.1 && $0.end == 0.1 }),
            "zero-width selected segment was rejected or rewritten"
        )
        try require(
            zeroWidthSegmentSource.units.last?.start == 0.2 && zeroWidthSegmentSource.units.last?.end == 0.3,
            "collapsed token segment did not use its native source-unit envelope"
        )
        print("COLLAPSED_TOKEN_VALID_SEGMENT_ENVELOPE_PASS")
        let collapsedBoundaryPackage = root.appendingPathComponent("collapsed-boundary-package")
        try makeSentenceBoundaryPackage(at: collapsedBoundaryPackage, media: media, firstSentenceCollapsed: true, nextSentenceStart: 200)
        let collapsedBoundarySource = try importer.importSelectedPackage(
            packageRoot: collapsedBoundaryPackage, expectedMediaURL: media, expectedLanguage: .en
        )
        let expectedCollapsedTokens: [(String, TimeInterval, TimeInterval)] = [
            (" First", 0.1, 0.1), (".", 0.1, 0.1), (" Second", 0.2, 0.23), (".", 0.23, 0.25)
        ]
        try require(
            collapsedBoundarySource.tokenTimeline.count == expectedCollapsedTokens.count
                && zip(collapsedBoundarySource.tokenTimeline, expectedCollapsedTokens).allSatisfy {
                    $0.text == $1.0 && $0.start == $1.1 && $0.end == $1.2
                },
            "collapsed boundary correction rewrote raw token evidence"
        )
        try require(
            collapsedBoundarySource.sourceText == " First. Second."
                && collapsedBoundarySource.units.count == 2
                && collapsedBoundarySource.units[0].start == 0.1
                && collapsedBoundarySource.units[0].end == 0.2
                && collapsedBoundarySource.units[1].start == 0.2
                && collapsedBoundarySource.units[1].end == 0.25,
            "collapsed native envelope was not bounded at the following raw sentence start"
        )
        try collapsedBoundarySource.validateCoverage()
        print("COLLAPSED_ENVELOPE_BOUNDARY_CORRECTION_PASS")
        let uncorrectableCollapsedBoundary = root.appendingPathComponent("uncorrectable-collapsed-boundary")
        try makeSentenceBoundaryPackage(at: uncorrectableCollapsedBoundary, media: media, firstSentenceCollapsed: true, nextSentenceStart: 100)
        try expectFailure {
            _ = try importer.importSelectedPackage(
                packageRoot: uncorrectableCollapsedBoundary, expectedMediaURL: media, expectedLanguage: .en
            )
        }
        let ordinaryOverlapBoundary = root.appendingPathComponent("ordinary-overlap-boundary")
        try makeSentenceBoundaryPackage(at: ordinaryOverlapBoundary, media: media, firstSentenceCollapsed: false, nextSentenceStart: 140)
        try expectFailure {
            _ = try importer.importSelectedPackage(
                packageRoot: ordinaryOverlapBoundary, expectedMediaURL: media, expectedLanguage: .en
            )
        }
        print("UNCORRECTABLE_AND_ORDINARY_BOUNDARY_OVERLAPS_REJECTED")
        let invalidCollapsedSegmentPackage = root.appendingPathComponent("invalid-collapsed-segment-package")
        try makeZeroWidthSegmentPackage(at: invalidCollapsedSegmentPackage, media: media, invalidSegment: true)
        try expectFailure {
            _ = try importer.importSelectedPackage(
                packageRoot: invalidCollapsedSegmentPackage,
                expectedMediaURL: media,
                expectedLanguage: .en
            )
        }
        print("INVALID_SEGMENT_WITH_COLLAPSED_TOKENS_REJECTED")
        let overlappingRawPackage = root.appendingPathComponent("overlapping-raw-package")
        try makePackage(at: overlappingRawPackage, media: media, overlappingTokens: true)
        let overlappingRawSource = try importer.importSelectedPackage(
            packageRoot: overlappingRawPackage, expectedMediaURL: media, expectedLanguage: .en
        )
        try require(overlappingRawSource.tokenTimeline[1].text == " save"
                    && overlappingRawSource.tokenTimeline[1].start == 0.05
                    && overlappingRawSource.tokenTimeline[1].end == 0.2,
                    "overlapping raw token evidence was rejected or rewritten")
        try overlappingRawSource.validateCoverage()

        let originalSRT = root.appendingPathComponent("full.srt")
        let srtBytes = Data("1\n00:00:00,000 --> 00:00:01,000\nLegacy full SRT\n".utf8)
        try srtBytes.write(to: originalSRT)
        _ = try importer.importSelectedPackage(packageRoot: package, expectedMediaURL: media, expectedLanguage: .en)
        let persistedSRT = try Data(contentsOf: originalSRT)
        try require(persistedSRT == srtBytes, "selected timing altered valid full.srt")

        let provider = RecordingSimpleTranslator()
        let cache = root.appendingPathComponent("cache")
        let slice = SelectedTimingVerticalSlice(translator: provider)
        let first = try await slice.translate(sourceDocument: source, source: .en, target: .ru, cacheDirectory: cache)
        try first.validate()
        try require(first.units.map(\.sourceUnitID) == source.units.map(\.id), "translated unit ordering changed")
        try require(zip(first.units, source.units).allSatisfy { $0.start == $1.start && $0.end == $1.end && $0.sourceTextSHA256 == $1.textSHA256 }, "translated time provenance changed")
        try require(provider.requests.allSatisfy { !$0.contains("cueId") && !$0.contains("sourceEcho") && !$0.contains("timestamp") }, "provider received ownership metadata")
        let firstCalls = provider.requests.count
        _ = try await slice.translate(sourceDocument: source, source: .en, target: .ru, cacheDirectory: cache)
        try require(provider.requests.count == firstCalls, "cache did not reuse exact source unit")
        var changed = source
        changed.units[0].text += " changed"
        changed.units[0].textSHA256 = SelectedTimingHash.string(changed.units[0].text)
        changed.sourceText = changed.units.map(\.text).joined()
        _ = try await slice.translate(sourceDocument: changed, source: .en, target: .ru, cacheDirectory: cache)
        try require(provider.requests.count == firstCalls + 1, "cache reused another source text/unit")
        let reverse = try await slice.translate(
            sourceDocument: source,
            source: .ru,
            target: .en,
            cacheDirectory: root.appendingPathComponent("reverse-cache")
        )
        try reverse.validate()
        try require(
            zip(reverse.units, source.units).allSatisfy {
                $0.sourceUnitID == $1.id && $0.sourceTextSHA256 == $1.textSHA256 && $0.start == $1.start && $0.end == $1.end
            },
            "RU-to-EN selected timing translation lost structural provenance"
        )

        let promptCapture = try await simplePromptCapture()
        try require(!promptCapture.contains("cueId") && !promptCapture.contains("sourceEcho") && !promptCapture.contains("timestamp"), "Ollama prompt leaked provenance")
        print("SELECTED_TIMING_VERTICAL_SLICE_PROBE_PASS")
    }

    private static func makePackage(
        at root: URL,
        media: URL,
        overlappingTokens: Bool = false,
        zeroWidthSpokenToken: Bool = false
    ) throws {
        let parts = root.appendingPathComponent("parts")
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        let partID = "part_0000"
        var tokens: [[String: Any]] = [
            token(" They", 0, 100), token(" save", 100, 200), token(" a", 200, 250), token(" lot", 250, 350), token(" of", 350, 400), token(" energy", 400, 500), token(".", 500, 520),
            token(" The", 520, 600), token(" LED", 600, 700), token(" has", 700, 760), token(" got", 760, 820), token(" a", 820, 840), token(" blue", 840, 920), token(" spike", 920, 1000), token(".", 1000, 1020),
            token(" Warm", 1020, 1100), token(" LEDs", 1100, 1200), token(" have", 1200, 1270), token(" no", 1270, 1320), token(" red", 1320, 1400), token(".", 1400, 1420),
            token(" We", 1420, 1480), token(" watch", 1480, 1550), token(" the", 1550, 1600), token(" mitochondria", 1600, 1760), token(" gently", 1760, 1820), token(" go", 1820, 1860), token(" downhill", 1860, 1940), token(".", 1940, 2400), token("[_EOT_]", 2400, 2400)
        ]
        if overlappingTokens { tokens[1] = token(" save", 50, 200) }
        if zeroWidthSpokenToken { tokens[1] = token(" save", 100, 100) }
        // Two native JSON segments emulate an old SRT cue boundary in the
        // middle of a sentence. Source units must follow punctuation instead.
        let json: [String: Any] = ["transcription": [
            ["offsets": ["from": 3540, "to": 4560], "no_speech_prob": 0.04, "tokens": Array(tokens[0..<11])],
            ["offsets": ["from": 4560, "to": 5500], "no_speech_prob": 0.08, "tokens": Array(tokens[11...])]
        ]]
        let jsonURL = parts.appendingPathComponent("\(partID).json")
        try JSONSerialization.data(withJSONObject: json).write(to: jsonURL)
        let sourceText = tokens.compactMap { $0["text"] as? String }.filter { !$0.hasPrefix("[_") }.joined()
        let txtURL = parts.appendingPathComponent("\(partID).txt")
        try Data(sourceText.utf8).write(to: txtURL)
        let srtURL = parts.appendingPathComponent("\(partID).srt")
        try Data("1\n00:00:00,000 --> 00:00:01,960\n\(sourceText)\n".utf8).write(to: srtURL)
        func artifact(_ url: URL) -> [String: String] { ["path": "parts/\(url.lastPathComponent)", "sha256": SelectedTimingHash.file(url)] }
        let manifest: [String: Any] = [
            "schema_version": 1,
            "artifact_type": "seminartext.selected_whisper_timing",
            "source": ["media_sha256": SelectedTimingHash.file(media)],
            "transcription": ["language": "en"],
            "parts": [["id": partID, "order": 0, "absolute_offset_seconds": 0.0, "absolute_range": ["start_seconds": 0.0, "end_seconds": 5.5], "selected_timing_absolute_range": ["start_seconds": 0.0, "end_seconds": 5.5], "selected_attempt": "initial", "artifacts": ["txt": artifact(txtURL), "srt": artifact(srtURL), "json_full": artifact(jsonURL)]]]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
    }

    private static func makeReverseRawPackage(
        at root: URL, media: URL,
        fixtureName: String = "ReverseRawTokens.json",
        sourceText: String = " Um I um speak.",
        srtText: String = "Um I um speak."
    ) throws {
        let parts = root.appendingPathComponent("parts")
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(fixtureName)")
        let jsonURL = parts.appendingPathComponent("part_0000.json")
        try Data(contentsOf: fixture).write(to: jsonURL)
        let txtURL = parts.appendingPathComponent("part_0000.txt")
        try Data(sourceText.utf8).write(to: txtURL)
        let srtURL = parts.appendingPathComponent("part_0000.srt")
        try Data("1\n00:00:00,000 --> 00:00:01,200\n\(srtText)\n".utf8).write(to: srtURL)
        func artifact(_ url: URL) -> [String: String] {
            ["path": "parts/\(url.lastPathComponent)", "sha256": SelectedTimingHash.file(url)]
        }
        let manifest: [String: Any] = [
            "schema_version": 1,
            "artifact_type": "seminartext.selected_whisper_timing",
            "source": ["media_sha256": SelectedTimingHash.file(media)],
            "transcription": ["language": "en"],
            "parts": [[
                "id": "part_0000", "order": 0, "absolute_offset_seconds": 0.0,
                "absolute_range": ["start_seconds": 0.0, "end_seconds": 1.2],
                "selected_timing_absolute_range": ["start_seconds": 0.0, "end_seconds": 1.2],
                "selected_attempt": "initial",
                "artifacts": ["txt": artifact(txtURL), "srt": artifact(srtURL), "json_full": artifact(jsonURL)]
            ]]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
    }

    private static func makeOverlappingPreparedRangePackage(
        at root: URL,
        media: URL,
        malformedRange: Bool = false
    ) throws {
        let parts = root.appendingPathComponent("parts")
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)

        func writePart(_ id: String, text: String, offset: Int) throws -> [String: [String: String]] {
            let jsonURL = parts.appendingPathComponent("\(id).json")
            let tokens: [[String: Any]] = text == " First."
                ? [token(" First", 0, 70), token(".", 70, 100)]
                : [token(" Second", 0, 70), token(".", 70, 100)]
            let json: [String: Any] = [
                "transcription": [[
                    "offsets": ["from": 0, "to": 100],
                    "tokens": tokens
                ]]
            ]
            try JSONSerialization.data(withJSONObject: json).write(to: jsonURL)
            let txtURL = parts.appendingPathComponent("\(id).txt")
            try Data(text.utf8).write(to: txtURL)
            let srtURL = parts.appendingPathComponent("\(id).srt")
            try Data("1\n00:00:00,000 --> 00:00:00,100\n\(text)\n".utf8).write(to: srtURL)
            func artifact(_ url: URL) -> [String: String] {
                ["path": "parts/\(url.lastPathComponent)", "sha256": SelectedTimingHash.file(url)]
            }
            return ["txt": artifact(txtURL), "srt": artifact(srtURL), "json_full": artifact(jsonURL)]
        }

        let firstArtifacts = try writePart("part_0000", text: " First.", offset: 0)
        let secondArtifacts = try writePart("part_0001", text: " Second.", offset: 300)
        let firstStart = malformedRange ? 0.001 : 0.0
        let manifest: [String: Any] = [
            "schema_version": 1,
            "artifact_type": "seminartext.selected_whisper_timing",
            "source": ["media_sha256": SelectedTimingHash.file(media)],
            "transcription": ["language": "en"],
            "parts": [
                [
                    "id": "part_0000", "order": 0, "absolute_offset_seconds": 0.0,
                    "absolute_range": ["start_seconds": firstStart, "end_seconds": 300.032],
                    "selected_timing_absolute_range": ["start_seconds": 0.0, "end_seconds": 300.130],
                    "selected_attempt": "initial", "artifacts": firstArtifacts
                ],
                [
                    "id": "part_0001", "order": 1, "absolute_offset_seconds": 300.0,
                    "absolute_range": ["start_seconds": 300.0, "end_seconds": 326.278063],
                    "selected_timing_absolute_range": ["start_seconds": 300.0, "end_seconds": 330.0],
                    "selected_attempt": "initial", "artifacts": secondArtifacts
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
    }

    private static func makeZeroWidthSegmentPackage(
        at root: URL,
        media: URL,
        invalidSegment: Bool = false
    ) throws {
        let parts = root.appendingPathComponent("parts")
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        let partID = "part_0000"
        let jsonURL = parts.appendingPathComponent("\(partID).json")
        let collapsedSegmentEnd = invalidSegment ? 100 : 300
        let json: [String: Any] = ["transcription": [
            ["offsets": ["from": 0, "to": 100], "tokens": [token(" Stable", 0, 70), token(".", 70, 100)]],
            ["offsets": ["from": 200, "to": collapsedSegmentEnd], "tokens": [token(" Brief", 100, 100), token(".", 100, 100)]]
        ]]
        try JSONSerialization.data(withJSONObject: json).write(to: jsonURL)
        let txtURL = parts.appendingPathComponent("\(partID).txt")
        try Data(" Stable. Brief.".utf8).write(to: txtURL)
        let srtURL = parts.appendingPathComponent("\(partID).srt")
        try Data("1\n00:00:00,000 --> 00:00:00,100\nStable.\n\n2\n00:00:00,200 --> 00:00:00,300\nBrief.\n".utf8).write(to: srtURL)
        func artifact(_ url: URL) -> [String: String] {
            ["path": "parts/\(url.lastPathComponent)", "sha256": SelectedTimingHash.file(url)]
        }
        let manifest: [String: Any] = [
            "schema_version": 1,
            "artifact_type": "seminartext.selected_whisper_timing",
            "source": ["media_sha256": SelectedTimingHash.file(media)],
            "transcription": ["language": "en"],
            "parts": [[
                "id": partID, "order": 0, "absolute_offset_seconds": 0.0,
                "absolute_range": ["start_seconds": 0.0, "end_seconds": 0.3],
                "selected_timing_absolute_range": ["start_seconds": 0.0, "end_seconds": 0.3],
                "selected_attempt": "initial",
                "artifacts": ["txt": artifact(txtURL), "srt": artifact(srtURL), "json_full": artifact(jsonURL)]
            ]]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
    }

    private static func makeSentenceBoundaryPackage(
        at root: URL,
        media: URL,
        firstSentenceCollapsed: Bool,
        nextSentenceStart: Int
    ) throws {
        let parts = root.appendingPathComponent("parts")
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        let firstTokens: [[String: Any]] = firstSentenceCollapsed
            ? [token(" First", 100, 100), token(".", 100, 100)]
            : [token(" First", 100, 130), token(".", 130, 160)]
        let firstSegmentEnd = firstSentenceCollapsed ? 300 : 160
        let json: [String: Any] = ["transcription": [
            ["offsets": ["from": 100, "to": firstSegmentEnd], "tokens": firstTokens],
            ["offsets": ["from": nextSentenceStart, "to": nextSentenceStart + 50], "tokens": [
                token(" Second", nextSentenceStart, nextSentenceStart + 30),
                token(".", nextSentenceStart + 30, nextSentenceStart + 50)
            ]]
        ]]
        let jsonURL = parts.appendingPathComponent("part_0000.json")
        try JSONSerialization.data(withJSONObject: json).write(to: jsonURL)
        let txtURL = parts.appendingPathComponent("part_0000.txt")
        try Data(" First. Second.".utf8).write(to: txtURL)
        let srtURL = parts.appendingPathComponent("part_0000.srt")
        let firstSRTEnd = firstSentenceCollapsed ? nextSentenceStart : 160
        let srt = """
        1
        00:00:00,100 --> 00:00:00,\(String(format: "%03d", firstSRTEnd))
        First.

        2
        00:00:00,\(String(format: "%03d", nextSentenceStart)) --> 00:00:00,\(String(format: "%03d", nextSentenceStart + 50))
        Second.
        """
        try Data(srt.utf8).write(to: srtURL)
        func artifact(_ url: URL) -> [String: String] {
            ["path": "parts/\(url.lastPathComponent)", "sha256": SelectedTimingHash.file(url)]
        }
        let manifest: [String: Any] = [
            "schema_version": 1,
            "artifact_type": "seminartext.selected_whisper_timing",
            "source": ["media_sha256": SelectedTimingHash.file(media)],
            "transcription": ["language": "en"],
            "parts": [[
                "id": "part_0000", "order": 0, "absolute_offset_seconds": 0.0,
                "absolute_range": ["start_seconds": 0.0, "end_seconds": 0.5],
                "selected_timing_absolute_range": ["start_seconds": 0.0, "end_seconds": 0.5],
                "selected_attempt": "initial",
                "artifacts": ["txt": artifact(txtURL), "srt": artifact(srtURL), "json_full": artifact(jsonURL)]
            ]]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
    }

    private static func token(_ text: String, _ from: Int, _ to: Int) -> [String: Any] {
        ["text": text, "offsets": ["from": from, "to": to], "p": 0.9]
    }

    private static func verifyManifestDiscovery(root: URL, media: URL, package: URL) throws {
        let invocation = root.appendingPathComponent("discovery-invocation", isDirectory: true)
        let run = invocation.appendingPathComponent("run", isDirectory: true)
        let stage = run.appendingPathComponent(".parts/selected_timing", isDirectory: true)
        let stagedDecoy = run.appendingPathComponent(".parts/structured_timing-staged", isDirectory: true)
        let nonregular = run.appendingPathComponent("structured_timing-directory/manifest.json", isDirectory: true)
        try FileManager.default.createDirectory(at: stage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: package, to: stage)
        try FileManager.default.copyItem(at: package, to: stagedDecoy)
        try FileManager.default.createDirectory(at: nonregular, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: run.appendingPathComponent(".marker"))
        try require(SeminarTextSelectedTimingRunner.findManifests(in: invocation).isEmpty,
                    "discovery accepted hidden staging or a nonregular manifest")

        var published = run.appendingPathComponent("structured_timing4", isDirectory: true)
        try FileManager.default.moveItem(at: stage, to: published)
        var hiddenMetadata = URLResourceValues()
        hiddenMetadata.isHidden = true
        try published.setResourceValues(hiddenMetadata)
        let publishedMetadata = try published.resourceValues(forKeys: [.isHiddenKey])
        try require(publishedMetadata.isHidden == true, "fixture did not retain hidden package metadata")

        guard let oldEnumerator = FileManager.default.enumerator(
            at: invocation,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { throw WorkflowError.processFailed("could not enumerate discovery fixture") }
        let oldManifests = oldEnumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  url.lastPathComponent == "manifest.json",
                  url.deletingLastPathComponent().lastPathComponent.hasPrefix("structured_timing"),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return url
        }
        try require(oldManifests.isEmpty, "fixture did not reproduce skipsHiddenFiles manifest loss")
        let expected = published.appendingPathComponent("manifest.json")
        let discovered = SeminarTextSelectedTimingRunner.findManifests(in: invocation)
        try require(discovered.map { $0.resolvingSymlinksInPath().path } == [expected.resolvingSymlinksInPath().path],
                    "discovery lost a published hidden-metadata package or included staging: expected \(expected.path), found \(discovered.map(\.path))")
        _ = try SelectedTimingImporter().importSelectedPackage(
            packageRoot: discovered[0].deletingLastPathComponent(),
            expectedMediaURL: media,
            expectedLanguage: .en
        )

        let second = run.appendingPathComponent("structured_timing3", isDirectory: true)
        try FileManager.default.copyItem(at: package, to: second)
        let expectedPaths = [expected, second.appendingPathComponent("manifest.json")]
            .map { $0.resolvingSymlinksInPath().path }.sorted()
        let ambiguousPaths = SeminarTextSelectedTimingRunner.findManifests(in: invocation)
            .map { $0.resolvingSymlinksInPath().path }
        try require(ambiguousPaths == expectedPaths,
                    "discovery hid an ambiguous second package or changed sorted order")
        print("SELECTED_TIMING_HIDDEN_METADATA_DISCOVERY_PASS")
    }

    private static func verifySingleSeminarTextEntry(root: URL, media: URL, package: URL) async throws {
        let outputRoot = root.appendingPathComponent("seminartext-output")
        let stale = outputRoot.appendingPathComponent("stale/structured_timing")
        try FileManager.default.createDirectory(at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: package, to: stale)
        let invocationLog = root.appendingPathComponent("seminartext-invocations.txt")
        let executable = root.appendingPathComponent("fake-seminartext")
        let script = """
        #!/bin/sh
        printf '%s|model=%s\\n' \"$*\" \"$SEMINARTEXT_MODEL\" >> '\(invocationLog.path)'
        mkdir -p \"$SEMINARTEXT_OUTPUT/run\"
        cp -R '\(package.path)' \"$SEMINARTEXT_OUTPUT/run/structured_timing\"
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let selected = try await SeminarTextSelectedTimingRunner().transcribe(
            mediaURL: media,
            language: .en,
            executable: executable,
            modelPath: "/models/selected.bin",
            outputRoot: outputRoot
        )
        let selectedPath = selected.resolvingSymlinksInPath().path
        try require(selectedPath.hasPrefix(outputRoot.resolvingSymlinksInPath().path), "runner selected package outside its output root")
        try require(!selectedPath.contains("/stale/"), "runner selected stale timing evidence")
        let invocations = try String(contentsOf: invocationLog, encoding: .utf8)
            .split(separator: "\\n")
            .map(String.init)
        try require(invocations.count == 1, "runner invoked SeminarText more than once")
        let arguments = invocations[0]
        try require(arguments.contains("transcribe"), "runner missed SeminarText transcribe command")
        try require(arguments.contains("--structured-timing"), "runner missed selected timing request")
        try require(arguments.contains("--language en"), "runner missed source language")
        try require(arguments.contains("--no-open"), "runner did not keep SeminarText headless")
        try require(arguments.contains("|model=/models/selected.bin"), "runner missed selected Whisper model")

        for count in [0, 2] {
            let copies = (0..<count).map { index in
                "cp -R '\(package.path)' \"$SEMINARTEXT_OUTPUT/run/structured_timing\(index)\""
            }.joined(separator: "\n")
            let cardinalityScript = """
            #!/bin/sh
            set -eu
            mkdir -p "$SEMINARTEXT_OUTPUT/run"
            \(copies)
            """
            try cardinalityScript.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            do {
                _ = try await SeminarTextSelectedTimingRunner().transcribe(
                    mediaURL: media,
                    language: .en,
                    executable: executable,
                    modelPath: "/models/selected.bin",
                    outputRoot: outputRoot
                )
                throw WorkflowError.processFailed("runner accepted \(count) selected timing manifests")
            } catch WorkflowError.processFailed(let message) {
                try require(message.contains("(найдено: \(count))"),
                            "runner did not reject \(count) manifests within its own invocation: \(message)")
            }
        }
        print("SELECTED_TIMING_MANIFEST_CARDINALITY_PASS")
    }

    private static func simplePromptCapture() async throws -> String {
        var captured = ""
        let provider = OllamaSimpleTextTranslateGemma { request in
            if request.url?.path == "/api/tags" {
                return try JSONSerialization.data(withJSONObject: ["models": [["name": "translategemma:4b", "digest": "digest"]]])
            }
            captured = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            return try JSONSerialization.data(withJSONObject: ["done": true, "message": ["content": "Перевод"]])
        }
        _ = try await provider.translate(text: "The LED saves energy.", source: .en, target: .ru)
        return captured
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw WorkflowError.processFailed(message) }
    }

    private static func expectFailure(_ operation: () throws -> Void) throws {
        do {
            try operation()
            throw WorkflowError.processFailed("corrupt selected timing unexpectedly passed validation")
        } catch let error as WorkflowError where String(describing: error).contains("unexpectedly") {
            throw error
        } catch {
            return
        }
    }
}

private final class RecordingSimpleTranslator: SimpleTextTranslationProvider {
    private(set) var requests: [String] = []
    func identity() async throws -> TranslationModelIdentity {
        TranslationModelIdentity(model: "translategemma:4b", digest: "test-digest", protocolVersion: "simple-text-test")
    }
    func translate(text: String, source: ArtifactLanguage, target: ArtifactLanguage) async throws -> String {
        requests.append(text)
        return target == .ru
            ? "Проверенный русский перевод \(requests.count)."
            : "Verified English translation \(requests.count)."
    }
}

@main
struct SelectedTimingVerticalSliceProbeMain {
    static func main() async {
        do { try await SelectedTimingVerticalSliceProbe.main() }
        catch { fputs("SELECTED_TIMING_VERTICAL_SLICE_PROBE_FAIL: \(error)\n", stderr); exit(1) }
    }
}
