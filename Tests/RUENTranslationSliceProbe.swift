import Foundation

@main
struct RUENTranslationSliceProbe {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("videotext-ru-en-slice-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try require(WorkflowOperation.translateTranscript.isEnabledForCurrentRelease, "RU→EN operation is disabled")
        try require(!WorkflowOperation.userSelectable.contains(.translateTranscript), "translation became automatic Core work")
        try require(!WorkflowOperation.createDubbing.isEnabledForCurrentRelease, "dubbing was enabled")
        try require(ArtifactLanguage.ru.translationTarget == .en && ArtifactLanguage.en.translationTarget == .ru,
                    "translation directions are not limited to the accepted RU↔EN pair")

        try await verifyTargetLanguagePromptContract()
        try await verifyDisabledHumanReviewPreflightDoesNotCreateProject(root: root.appendingPathComponent("preflight"))
        try await verifyLegacyFullSRTSuccessWithoutHumanReview(root: root.appendingPathComponent("legacy-success"))
        try await verifyRelocatedSourceReferenceRecovery(root: root.appendingPathComponent("relocated-ru"), sourceLanguage: .ru)
        try await verifyRelocatedSourceReferenceRecovery(root: root.appendingPathComponent("relocated-en"), sourceLanguage: .en)
        try await verifyRelocatedSourceReferenceRecovery(
            root: root.appendingPathComponent("relocated-malformed-reference-sha"),
            sourceLanguage: .ru,
            referenceSHAOverride: "stale-owner-reference-record"
        )
        try verifyRelocatedSourceReferenceFailures(root: root.appendingPathComponent("relocated-failures"))
        try await verifyApprovedSourceFlow(root: root.appendingPathComponent("success"))
        try await verifyRejectedResponseRetriesAndPersistsEvidence(root: root.appendingPathComponent("retry-success"))
        try await verifySourceFallbackFailsClosed(root: root.appendingPathComponent("source-fallback"))
        try await verifyWrongLanguageFailsClosed(root: root.appendingPathComponent("wrong-language"))
        try await verifyFailureIsolation(root: root.appendingPathComponent("failure-isolation"))
        print("RU_EN_TRANSLATION_SLICE_PROBE_PASS")
    }

    private static func verifyTargetLanguagePromptContract() async throws {
        let recorder = PromptRequestRecorder()
        let translator = OllamaSimpleTextTranslateGemma(transport: { request in
            await recorder.record(request)
            return try JSONSerialization.data(withJSONObject: [
                "done": true,
                "message": ["content": "Translated output."]
            ])
        })

        _ = try await translator.translate(
            text: " А, что еще важно хотел добавить",
            source: .ru,
            target: .en
        )
        _ = try await translator.translate(
            text: " And I also wanted to add",
            source: .en,
            target: .ru
        )

        let prompts = await recorder.prompts()
        try require(prompts.count == 2, "prompt contract probe did not capture both translation directions")
        let ruToEn = prompts[0]
        let enToRu = prompts[1]
        let semanticInstruction = "Return only the translated passage. Preserve meaning, negation, numbers, names, terminology and natural repetitions. Do not add context or complete unstated meaning."

        try require(ruToEn.contains(semanticInstruction)
                    && ruToEn.contains("The output must be in English. Do not return Russian text.")
                    && ruToEn.hasSuffix("\n\n А, что еще важно хотел добавить"),
                    "RU→EN prompt lost its semantic contract, target-language contract, or leading whitespace")
        try require(enToRu.contains(semanticInstruction)
                    && enToRu.contains("The output must be in Russian. Do not return English text.")
                    && enToRu.hasSuffix("\n\n And I also wanted to add"),
                    "EN→RU prompt lost its semantic contract, target-language contract, or source text")
    }

    private static func verifyDisabledHumanReviewPreflightDoesNotCreateProject(root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = root.appendingPathComponent("source.mp4")
        try Data("preflight media".utf8).write(to: media)
        let store = ProjectStore(history: ProjectHistoryStore(indexURL: root.appendingPathComponent("history.json")))
        let settings = WorkflowSettings(
            mediaURL: media,
            projectURL: nil,
            selectedOperations: [.translateTranscript],
            mode: .resumeProject,
            rangeStart: 0,
            rangeEnd: 1,
            fragmentName: "",
            burnFragmentSubtitles: false,
            subtitleStyle: .standard,
            selectedTopicID: nil,
            whisperModelPath: "/must-not-be-used/whisper.bin",
            whisperLanguage: "ru",
            sourceHumanReviewEnabled: true,
            translationHumanReviewEnabled: false,
            fillerAnalysisBeforeReview: true
        )
        do {
            _ = try await WorkflowEngine(store: store).run(settings: settings, onLog: { _ in })
            throw ProbeFailure(message: "Translation without project URL bypassed Human Review preflight")
        } catch WorkflowError.processFailed(let message) {
            try require(message == "Перевод требует обязательного Translation Human Review.",
                        "Translation without project URL returned the wrong preflight error")
        }
        let rootContents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        try require(rootContents == [media.lastPathComponent],
                    "Translation without project URL created a project before Human Review preflight")
    }

    private static func verifyLegacyFullSRTSuccessWithoutHumanReview(root: URL) async throws {
        let fixture = try makeFixture(root: root)
        try FileManager.default.removeItem(at: fixture.layout.subtitlesURL(language: .ru))
        try FileManager.default.removeItem(at: fixture.layout.transcriptURL(language: .ru))
        let provider = ScriptedLegacyTranslationProvider()
        let engine = WorkflowEngine(
            store: fixture.store,
            translationAdapter: TranslationAdapter(provider: provider)
        )
        var legacySettings = settings(fixture)
        legacySettings.translationHumanReviewEnabled = false
        var log: [String] = []
        let result = try await engine.run(settings: legacySettings, onLog: { log.append($0) })

        try require(result.checkpoint == nil,
                    "Valid legacy full.srt translation unexpectedly opened Human Review")
        try require(provider.calls == 1,
                    "Valid legacy full.srt translation did not use the scripted ownership adapter exactly once")
        try require(!log.contains(where: { $0.contains("Расшифровка bundled SeminarText") }),
                    "Valid legacy full.srt translation reran ASR")
        let completed = try fixture.store.load(from: fixture.project)
        try require(completed.activeTranscriptRevision(for: .en)?.reviewStatus == .approved,
                    "Valid legacy full.srt translation did not activate the ready target revision")
        try require(completed.workflow?.operations[WorkflowOperation.transcribe.rawValue] == nil,
                    "Valid legacy full.srt translation recorded an ASR operation")
        let reportDecoder = JSONDecoder()
        reportDecoder.dateDecodingStrategy = .iso8601
        let report = try reportDecoder.decode(
            TranslationReport.self,
            from: Data(contentsOf: fixture.layout.translationReportURL(source: .ru, target: .en))
        )
        try require(report.status == .ready && report.reviewTaskIDs.isEmpty,
                    "Valid legacy full.srt translation retained review tasks")
        try require(FileManager.default.fileExists(atPath: fixture.layout.subtitlesURL(language: .ru).path)
                    && FileManager.default.fileExists(atPath: fixture.layout.transcriptURL(language: .ru).path)
                    && FileManager.default.fileExists(atPath: fixture.layout.subtitlesURL(language: .en).path)
                    && FileManager.default.fileExists(atPath: fixture.layout.transcriptURL(language: .en).path),
                    "Valid legacy full.srt translation did not materialize source and target TXT/SRT")
        try require(SubtitleSourceResolver.availableSelections(manifest: completed, projectURL: fixture.project)
                    == [.source, .approvedTranslation(.en)],
                    "Ready legacy target is unavailable through Text and Content")

        let callsBeforeReopen = provider.calls
        let reopened = try fixture.store.openProject(at: fixture.project).0
        try require(provider.calls == callsBeforeReopen
                    && reopened.activeTranscriptRevision(for: .en)?.reviewStatus == .approved,
                    "Reopen lost the ready legacy translation")
    }

    private static func verifyRelocatedSourceReferenceRecovery(
        root: URL,
        sourceLanguage: ArtifactLanguage,
        referenceSHAOverride: String? = nil
    ) async throws {
        // This mirrors the frozen Owner Retest: an accepted project was copied,
        // retaining its old Core output path, manifest association, and a
        // reference SHA from an earlier QA location.
        let fixture = try ownerRetestStyleCopiedFixture(root: root, sourceLanguage: sourceLanguage)
        let manifestURL = try selectedTimingManifestURL(for: fixture)
        let evidenceBefore = try JSONDecoder().decode(
            SeminarTextCoreTranscriptionEvidence.self,
            from: Data(contentsOf: fixture.layout.seminarTextCoreEvidenceURL)
        )
        if let referenceSHAOverride {
            try replaceSourceReferenceSHA(in: manifestURL, with: referenceSHAOverride)
        }
        let candidateSource = try manifestSource(in: manifestURL)
        let reference = try requiredString(candidateSource["reference"], "Owner-style fixture has no source reference")
        let staleReferenceSHA = try requiredString(candidateSource["reference_sha256"], "Owner-style fixture has no reference SHA")
        try require(
            URL(fileURLWithPath: evidenceBefore.outputDirectory).standardizedFileURL
                != manifestURL.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
                && evidenceBefore.selectedTimingManifestSHA256 != SelectedTimingHash.file(manifestURL)
                && reference == fixture.media.path
                && staleReferenceSHA == (referenceSHAOverride ?? SelectedTimingHash.string(forensicLegacyReferencePath))
                && staleReferenceSHA != SelectedTimingHash.string(reference),
            "Owner-style copied fixture does not preserve stale Core location and reference provenance"
        )
        let adoptedManifestHash = SelectedTimingHash.file(manifestURL)

        let translator: SimpleTextTranslationProvider = sourceLanguage == .ru
            ? RecordingRUENTranslator()
            : RecordingENRUTranslator()
        let selectedTiming = SelectedTimingVerticalSlice(translator: translator)
        let engine = WorkflowEngine(store: fixture.store, selectedTimingTranslation: selectedTiming)
        var log: [String] = []
        let result = try await engine.run(settings: settings(fixture), onLog: { log.append($0) })
        let targetLanguage = sourceLanguage.translationTarget

        try require(result.checkpoint?.kind == .translatedTranscript
                    && result.checkpoint?.language == targetLanguage,
                    "Relocated package did not reach Translation Human Review")
        try require(!log.contains(where: { $0.contains("Расшифровка bundled SeminarText") || $0.contains("Тематический таймкодинг") }),
                    "Relocated package recovery started ASR or topics")
        let manifest = try fixture.store.load(from: fixture.project)
        try require(manifest.workflow?.operations[WorkflowOperation.transcribe.rawValue] == nil
                    && manifest.workflow?.operations[WorkflowOperation.topicTimecoding.rawValue] == nil,
                    "Relocated package recovery recorded ASR or topics work")
        let persisted = try selectedTiming.loadPersistedSource(projectURL: fixture.project, mediaURL: fixture.media)
        try require(persisted?.upstreamManifestSHA256 == adoptedManifestHash,
                    "Relocated package recovery did not persist adopted selected timing source")
        let evidence = try JSONDecoder().decode(
            SeminarTextCoreTranscriptionEvidence.self,
            from: Data(contentsOf: fixture.layout.seminarTextCoreEvidenceURL)
        )
        try require(evidence.selectedTimingManifestSHA256 == adoptedManifestHash
                    && evidence.outputDirectory == evidenceBefore.outputDirectory,
                    "Relocated package recovery did not reconcile only the canonical evidence association")

        _ = try HumanReviewService(store: fixture.store).approve(projectURL: fixture.project)
        let reopened = try fixture.store.openProject(at: fixture.project).0
        try require(reopened.activeTranscriptRevision(for: sourceLanguage)?.reviewStatus == .approved
                    && reopened.activeTranscriptRevision(for: targetLanguage)?.reviewStatus == .approved
                    && FileManager.default.fileExists(atPath: fixture.layout.transcriptURL(language: targetLanguage).path),
                    "Reopen lost the accepted translation after relocated package recovery")
    }

    private static func verifyRelocatedSourceReferenceFailures(root: URL) throws {
        try verifyRelocatedSourceReferenceFailure(root: root.appendingPathComponent("zero")) { fixture in
            try FileManager.default.removeItem(at: selectedTimingManifestURL(for: fixture))
        }
        try verifyRelocatedSourceReferenceFailure(root: root.appendingPathComponent("multiple")) { fixture in
            let manifestURL = try selectedTimingManifestURL(for: fixture)
            let package = manifestURL.deletingLastPathComponent()
            let duplicate = package.deletingLastPathComponent().appendingPathComponent("structured_timing_duplicate", isDirectory: true)
            try FileManager.default.copyItem(at: package, to: duplicate)
        }
        try verifyRelocatedSourceReferenceFailure(root: root.appendingPathComponent("tampered")) { fixture in
            let json = try selectedTimingManifestURL(for: fixture)
                .deletingLastPathComponent()
                .appendingPathComponent("parts/part_0000.json")
            try Data("tampered".utf8).write(to: json, options: .atomic)
        }
        try verifyRelocatedSourceReferenceFailure(root: root.appendingPathComponent("current-media-mismatch")) { fixture in
            let mismatchedMedia = fixture.project.appendingPathComponent("mismatched-media.mp4")
            try Data("different media".utf8).write(to: mismatchedMedia, options: .atomic)
            try replaceSourceReference(in: selectedTimingManifestURL(for: fixture), with: mismatchedMedia.path)
        }
        try verifyRelocatedSourceReferenceFailure(root: root.appendingPathComponent("manifest-media-mismatch")) { fixture in
            try replaceSourceMediaSHA(in: selectedTimingManifestURL(for: fixture), with: String(repeating: "0", count: 64))
        }
        try verifyRelocatedSourceReferenceFailure(root: root.appendingPathComponent("srt-mismatch")) { fixture in
            let srt = try selectedTimingManifestURL(for: fixture)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("transcript4.srt")
            try Data("tampered SRT".utf8).write(to: srt, options: .atomic)
        }
        try verifyRelocatedSourceReferenceFailure(root: root.appendingPathComponent("whisper-mismatch")) { fixture in
            try replaceEvidenceWhisperSHA(at: fixture.layout, with: String(repeating: "0", count: 64))
        }
        try verifyRelocatedSourceReferenceFailure(root: root.appendingPathComponent("language-mismatch")) { fixture in
            try replaceManifestLanguage(in: selectedTimingManifestURL(for: fixture), with: .en)
        }
    }

    private static func verifyRelocatedSourceReferenceFailure(
        root: URL,
        mutate: (Fixture) throws -> Void
    ) throws {
        let fixture = try ownerRetestStyleCopiedFixture(root: root, sourceLanguage: .ru)
        try mutate(fixture)
        let selectedTiming = SelectedTimingVerticalSlice(translator: RecordingRUENTranslator())
        do {
            _ = try selectedTiming.loadOrImportCoreSource(
                projectURL: fixture.project,
                mediaURL: fixture.media,
                language: .ru
            )
            throw ProbeFailure(message: "Incompatible relocated selected timing package was accepted")
        } catch let error as ProbeFailure {
            throw error
        } catch WorkflowError.processFailed(let message) {
            try require(message == missingSelectedTimingProvenanceMessage,
                        "Incompatible relocated package did not fail with the declared provenance error")
            try require(!FileManager.default.fileExists(atPath: fixture.layout.selectedTimingSourceUnitsURL.path),
                        "Incompatible relocated package persisted selected timing source")
        }
    }

    private static func selectedTimingManifestURL(for fixture: Fixture) throws -> URL {
        let manifests = SeminarTextSelectedTimingRunner.findManifests(in: fixture.layout.seminarTextCoreDirectory)
        guard manifests.count == 1, let manifestURL = manifests.first else {
            throw ProbeFailure(message: "Fixture does not contain exactly one selected timing manifest")
        }
        return manifestURL
    }

    private static func manifestSource(in manifestURL: URL) throws -> [String: Any] {
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        guard let source = manifest?["source"] as? [String: Any] else {
            throw ProbeFailure(message: "Selected timing fixture has no source record")
        }
        return source
    }

    private static func requiredString(_ value: Any?, _ message: String) throws -> String {
        guard let value = value as? String else { throw ProbeFailure(message: message) }
        return value
    }

    private static func replaceSourceReference(in manifestURL: URL, with reference: String) throws {
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        var source = manifest["source"] as! [String: Any]
        source["reference"] = reference
        source["reference_sha256"] = SelectedTimingHash.string(reference)
        manifest["source"] = source
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: manifestURL, options: .atomic)
    }

    private static func replaceSourceMediaSHA(in manifestURL: URL, with hash: String) throws {
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        var source = manifest["source"] as! [String: Any]
        source["media_sha256"] = hash
        manifest["source"] = source
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: manifestURL, options: .atomic)
    }

    private static func replaceSourceReferenceSHA(in manifestURL: URL, with hash: String) throws {
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        var source = manifest["source"] as! [String: Any]
        source["reference_sha256"] = hash
        manifest["source"] = source
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: manifestURL, options: .atomic)
    }

    private static func replaceManifestLanguage(in manifestURL: URL, with language: ArtifactLanguage) throws {
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        var transcription = manifest["transcription"] as! [String: Any]
        transcription["language"] = language.rawValue
        manifest["transcription"] = transcription
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: manifestURL, options: .atomic)
    }

    private static func replaceEvidenceWhisperSHA(at layout: ProjectLayout, with hash: String) throws {
        let evidence = try JSONDecoder().decode(
            SeminarTextCoreTranscriptionEvidence.self,
            from: Data(contentsOf: layout.seminarTextCoreEvidenceURL)
        )
        try writeEvidence(
            SeminarTextCoreTranscriptionEvidence(
                schemaVersion: evidence.schemaVersion,
                runtimeIdentity: evidence.runtimeIdentity,
                sourceSRTSHA256: evidence.sourceSRTSHA256,
                selectedTimingManifestSHA256: evidence.selectedTimingManifestSHA256,
                selectedWhisperJSONSHA256: hash,
                outputDirectory: evidence.outputDirectory
            ),
            to: layout.seminarTextCoreEvidenceURL
        )
    }

    private static func writeEvidence(_ evidence: SeminarTextCoreTranscriptionEvidence, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(evidence).write(to: url, options: .atomic)
    }

    private static func verifyApprovedSourceFlow(root: URL) async throws {
        let fixture = try makeFixture(root: root)
        let translator = RecordingRUENTranslator()
        let engine = WorkflowEngine(
            store: fixture.store,
            selectedTimingTranslation: SelectedTimingVerticalSlice(translator: translator)
        )
        let sourceSRT = try Data(contentsOf: fixture.layout.fullSRTURL)
        let sourceTXT = try Data(contentsOf: fixture.layout.transcriptURL)
        var log: [String] = []
        let result = try await engine.run(settings: settings(fixture), onLog: { log.append($0) })

        try require(result.checkpoint?.kind == .translatedTranscript && result.checkpoint?.language == .en,
                    "RU→EN translation did not open required English Translation Human Review")
        try require(!log.contains(where: { $0.contains("Расшифровка bundled SeminarText") }),
                    "RU→EN translation reran ASR")
        try require(translator.requests.allSatisfy { $0.source == .ru && $0.target == .en },
                    "provider received a direction other than RU→EN")
        try require(try Data(contentsOf: fixture.layout.fullSRTURL) == sourceSRT
                    && Data(contentsOf: fixture.layout.transcriptURL) == sourceTXT,
                    "RU→EN translation changed approved Russian source artifacts")

        let pending = try fixture.store.load(from: fixture.project)
        try require(pending.activeTranscriptRevision(for: .en) == nil,
                    "pending EN translation became active before Human Review")
        try require(pending.workflow?.operations[WorkflowOperation.transcribe.rawValue] == nil,
                    "RU→EN translation recorded an ASR operation")
        try require((pending.artifacts ?? []).filter { $0.language == .en }.allSatisfy { $0.validationStatus == .needsReview },
                    "pending EN translation artifacts were marked ready")
        try require(SubtitleSourceResolver.availableSelections(manifest: pending, projectURL: fixture.project) == [.source],
                    "pending EN translation was selectable as subtitles")

        let document = try JSONDecoder().decode(
            TimedTranslationDocument.self,
            from: Data(contentsOf: fixture.layout.selectedTimingTranslationsURL(source: .ru, target: .en))
        )
        try require(document.sourceLanguage == .ru && document.targetLanguage == .en,
                    "timed translation provenance recorded the wrong direction")
        try require(zip(document.source.units, document.units).allSatisfy {
            $0.id == $1.sourceUnitID && $0.textSHA256 == $1.sourceTextSHA256 && $0.start == $1.start && $0.end == $1.end
        }, "RU→EN translation lost source ordering, ownership, or timing")

        _ = try HumanReviewService(store: fixture.store).approve(projectURL: fixture.project)
        let approved = try fixture.store.load(from: fixture.project)
        try require(approved.activeTranscriptRevision(for: .ru)?.reviewStatus == .approved,
                    "RU source approval was lost")
        try require(approved.activeTranscriptRevision(for: .en)?.reviewStatus == .approved,
                    "EN translation was not approved")
        try require(FileManager.default.fileExists(atPath: fixture.layout.transcriptURL(language: .en).path)
                    && FileManager.default.fileExists(atPath: fixture.layout.subtitlesURL(language: .en).path),
                    "approved EN TXT/SRT are missing")
        try require(SubtitleSourceResolver.availableSelections(manifest: approved, projectURL: fixture.project)
                    == [.source, .approvedTranslation(.en)],
                    "approved EN translation was not selectable as Перевод (EN)")
        let selected = try SubtitleSourceResolver.resolve(.approvedTranslation(.en), manifest: approved, projectURL: fixture.project)
        try require(selected.language == .en && selected.isTranslation && selected.srtURL == fixture.layout.subtitlesURL(language: .en),
                    "approved EN subtitles resolved to the wrong source")

        let callsBeforeResume = translator.requests.count
        let resumed = try await engine.run(settings: settings(fixture), onLog: { log.append($0) })
        try require(resumed.checkpoint == nil && translator.requests.count == callsBeforeResume,
                    "reopen/resume reran approved RU→EN translation")
        let reopened = try fixture.store.openProject(at: fixture.project).0
        try require(reopened.activeTranscriptRevision(for: .ru)?.reviewStatus == .approved
                    && reopened.activeTranscriptRevision(for: .en)?.reviewStatus == .approved,
                    "reopen lost approved RU/EN revisions")
    }

    private static func verifySourceFallbackFailsClosed(root: URL) async throws {
        let fixture = try makeFixture(root: root)
        do {
            _ = try await WorkflowEngine(
                store: fixture.store,
                selectedTimingTranslation: SelectedTimingVerticalSlice(translator: SourceFallbackTranslator())
            ).run(settings: settings(fixture), onLog: { _ in })
            throw ProbeFailure(message: "Russian source fallback unexpectedly succeeded")
        } catch WorkflowError.processFailed(let message) {
            try require(message.contains("исходный текст без перевода"), "source fallback produced the wrong failure")
        }
        let manifest = try fixture.store.load(from: fixture.project)
        try require(manifest.activeTranscriptRevision(for: .en) == nil,
                    "source fallback became an active EN revision")
        try require(!FileManager.default.fileExists(atPath: fixture.layout.subtitlesURL(language: .en).path),
                    "source fallback published EN subtitles")
        let rejected = rejectedResponses(at: fixture.layout, source: .ru, target: .en)
        try require(rejected.count == 2,
                    "source fallback retained \(rejected.count) rejected attempts instead of two")
        try require(cachedTexts(at: fixture.layout).isEmpty,
                    "source fallback was cached as a valid translation")
        try require(manifest.workflow?.status == .completed, "source fallback invalidated the Core project")
    }

    private static func verifyRejectedResponseRetriesAndPersistsEvidence(root: URL) async throws {
        let fixture = try makeFixture(root: root)
        let translator = RejectThenTranslateRUENTranslator()
        let result = try await WorkflowEngine(
            store: fixture.store,
            selectedTimingTranslation: SelectedTimingVerticalSlice(translator: translator)
        ).run(settings: settings(fixture), onLog: { _ in })

        try require(result.checkpoint?.kind == .translatedTranscript && result.checkpoint?.language == .en,
                    "valid retry did not reach English Translation Human Review")
        try require(translator.calls == 3,
                    "translation did not make exactly one bounded retry before translating both units")
        let rejected = rejectedResponses(at: fixture.layout, source: .ru, target: .en)
        try require(rejected.count == 1, "valid retry retained the wrong number of rejected responses")
        guard let evidence = rejected.first else { throw ProbeFailure(message: "missing rejected response evidence") }
        try require(evidence.unitID == 1
                    && evidence.sourceLanguage == .ru
                    && evidence.targetLanguage == .en
                    && evidence.sourceTextSHA256 == SelectedTimingHash.string(" Юрий не отменил встречу в 7 часов.")
                    && evidence.model == "translategemma:4b"
                    && evidence.modelDigest == "fixture-digest"
                    && evidence.protocolVersion == "translategemma-simple-text-v1"
                    && evidence.attempt == 1
                    && evidence.rawResponse == "Русский ответ без перевода."
                    && evidence.latinLetterCount == 0
                    && evidence.cyrillicLetterCount > 0
                    && evidence.validationFailureReason.contains("преимущественно не на английском языке")
                    && !evidence.requestSHA256.isEmpty,
                    "rejected response evidence is incomplete or altered")
        let cache = cachedTexts(at: fixture.layout)
        try require(cache.count == 2, "accepted retry did not populate the normal cache")
        try require(!cache.contains("Русский ответ без перевода."),
                    "rejected response was cached as a valid translation")
    }

    private static func verifyWrongLanguageFailsClosed(root: URL) async throws {
        let fixture = try makeFixture(root: root)
        do {
            _ = try await WorkflowEngine(
                store: fixture.store,
                selectedTimingTranslation: SelectedTimingVerticalSlice(translator: RussianOutputTranslator())
            ).run(settings: settings(fixture), onLog: { _ in })
            throw ProbeFailure(message: "Russian output unexpectedly passed as English translation")
        } catch WorkflowError.processFailed(let message) {
            try require(message.contains("преимущественно не на английском языке"),
                        "wrong-language output produced the wrong failure")
        }
        let manifest = try fixture.store.load(from: fixture.project)
        try require(manifest.activeTranscriptRevision(for: .en) == nil,
                    "wrong-language output became an active EN revision")
        let rejected = rejectedResponses(at: fixture.layout, source: .ru, target: .en)
        try require(rejected.count == SelectedTimingVerticalSlice.maximumTranslationAttempts,
                    "retry exhaustion did not retain every rejected response")
        try require(rejected.map(\.attempt) == [1, 2]
                    && rejected.allSatisfy { $0.rawResponse == "Русский ответ без перевода." },
                    "retry evidence did not retain the exact rejected responses")
        try require(cachedTexts(at: fixture.layout).isEmpty,
                    "retry exhaustion cached rejected text as a valid translation")
        try Data("existing topics".utf8).write(to: fixture.layout.topicsURL)
        try require(FileManager.default.fileExists(atPath: fixture.layout.topicsURL.path),
                    "Core project is not usable after translation retry exhaustion")
    }

    private static func verifyFailureIsolation(root: URL) async throws {
        let fixture = try makeFixture(root: root)
        let preservedTopic = fixture.layout.topicsURL
        try Data("existing topics".utf8).write(to: preservedTopic)
        let sourceSRT = try Data(contentsOf: fixture.layout.fullSRTURL)
        do {
            _ = try await WorkflowEngine(
                store: fixture.store,
                selectedTimingTranslation: SelectedTimingVerticalSlice(translator: FailingRUENTranslator())
            ).run(settings: settings(fixture), onLog: { _ in })
            throw ProbeFailure(message: "controlled RU→EN failure unexpectedly succeeded")
        } catch WorkflowError.processFailed(let message) {
            try require(message.contains("controlled TranslateGemma failure"), "wrong controlled failure")
        }
        let failed = try fixture.store.load(from: fixture.project)
        try require(failed.workflow?.status == .completed,
                    "optional RU→EN failure changed completed Core workflow")
        try require(failed.workflow?.operations[WorkflowOperation.translateTranscript.rawValue]?.status == .failed,
                    "translation failure was not retained separately")
        try require(failed.activeTranscriptRevision(for: .ru)?.reviewStatus == .approved
                    && failed.activeTranscriptRevision(for: .en) == nil,
                    "translation failure changed source transcript authority")
        try require(try Data(contentsOf: fixture.layout.fullSRTURL) == sourceSRT
                    && Data(contentsOf: preservedTopic) == Data("existing topics".utf8),
                    "translation failure changed existing Core artifacts")
    }

    private static func settings(_ fixture: Fixture) -> WorkflowSettings {
        WorkflowSettings(
            mediaURL: fixture.media,
            projectURL: fixture.project,
            selectedOperations: [.translateTranscript],
            mode: .resumeProject,
            rangeStart: 0,
            rangeEnd: 2,
            fragmentName: "",
            burnFragmentSubtitles: false,
            subtitleStyle: .standard,
            selectedTopicID: nil,
            whisperModelPath: "/must-not-be-used/whisper.bin",
            whisperLanguage: fixture.sourceLanguage.rawValue,
            sourceHumanReviewEnabled: true,
            translationHumanReviewEnabled: true,
            fillerAnalysisBeforeReview: true
        )
    }

    private static let missingSelectedTimingProvenanceMessage =
        "Не найден единственный selected timing package, связанный с принятой расшифровкой. Повторный ASR не выполнялся."

    // The Owner Retest package layout and stale provenance contract. The test
    // creates it under a disposable directory; the frozen project is never
    // opened for mutation by the probe.
    private static let forensicLegacyReferencePath =
        "/Users/yurielokhin/Documents/Codex/videotext-issue19-evidence-20261010/qa-simple-short-ru-final-3/input/Short-RU.mp4"

    private static func ownerRetestStyleCopiedFixture(root: URL, sourceLanguage: ArtifactLanguage) throws -> Fixture {
        let original = try makeFixture(root: root.appendingPathComponent("original", isDirectory: true), sourceLanguage: sourceLanguage)
        let originalManifest = try selectedTimingManifestURL(for: original)
        let originalOutput = originalManifest.deletingLastPathComponent().deletingLastPathComponent()
        let ownerOutput = original.layout.seminarTextCoreDirectory
            .appendingPathComponent("core-transcription-4CDB0038-E2C1-4BCA-8A4E-ECBFC85EB3E8/Short-RU", isDirectory: true)
        try FileManager.default.createDirectory(at: ownerOutput.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: originalOutput, to: ownerOutput)
        try FileManager.default.moveItem(
            at: ownerOutput.appendingPathComponent("structured_timing", isDirectory: true),
            to: ownerOutput.appendingPathComponent("structured_timing4", isDirectory: true)
        )
        let ownerManifest = ownerOutput.appendingPathComponent("structured_timing4/manifest.json")
        let originalEvidence = try JSONDecoder().decode(
            SeminarTextCoreTranscriptionEvidence.self,
            from: Data(contentsOf: original.layout.seminarTextCoreEvidenceURL)
        )
        try writeEvidence(
            SeminarTextCoreTranscriptionEvidence(
                schemaVersion: originalEvidence.schemaVersion,
                runtimeIdentity: originalEvidence.runtimeIdentity,
                sourceSRTSHA256: originalEvidence.sourceSRTSHA256,
                selectedTimingManifestSHA256: originalEvidence.selectedTimingManifestSHA256,
                selectedWhisperJSONSHA256: originalEvidence.selectedWhisperJSONSHA256,
                outputDirectory: ownerOutput.path
            ),
            to: original.layout.seminarTextCoreEvidenceURL
        )
        // The field is stale in the Owner project. Its paired reference remains
        // the actual caller-selected media, and all immutable content hashes are
        // retained for compatibility validation.
        try replaceSourceReferenceSHA(
            in: ownerManifest,
            with: SelectedTimingHash.string(forensicLegacyReferencePath)
        )

        let copiedRoot = root.appendingPathComponent("copied", isDirectory: true)
        try FileManager.default.createDirectory(at: copiedRoot, withIntermediateDirectories: true)
        let project = copiedRoot.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.copyItem(at: original.project, to: project)
        return Fixture(
            media: original.media,
            project: project,
            layout: ProjectLayout(root: project),
            store: ProjectStore(history: ProjectHistoryStore(indexURL: copiedRoot.appendingPathComponent("history.json"))),
            sourceLanguage: sourceLanguage
        )
    }

    private static func makeFixture(root: URL, sourceLanguage: ArtifactLanguage = .ru) throws -> Fixture {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = root.appendingPathComponent("russian-source.mp4")
        let project = root.appendingPathComponent("project", isDirectory: true)
        try Data("controlled Russian media".utf8).write(to: media)
        let store = ProjectStore(history: ProjectHistoryStore(indexURL: root.appendingPathComponent("history.json")))
        var manifest = try store.ensureProject(at: project, mediaURL: media, mode: .newProject)
        let layout = ProjectLayout(root: project)
        let cues: [SubtitleCue]
        switch sourceLanguage {
        case .ru:
            cues = [
                SubtitleCue(id: 1, start: 0, end: 0.8, text: "Юрий не отменил встречу в 7 часов."),
                SubtitleCue(id: 3, start: 0.8, end: 1.6, text: "В отчёте указано 12 участников.")
            ]
        case .en:
            cues = [
                SubtitleCue(id: 1, start: 0, end: 0.8, text: "Yuri did not cancel the meeting at 7 o'clock."),
                SubtitleCue(id: 3, start: 0.8, end: 1.6, text: "The report lists 12 participants.")
            ]
        }
        try SRTService().writePreservingIDs(cues, to: layout.fullSRTURL)
        try SRTService().writePreservingIDs(cues, to: layout.subtitlesURL(language: sourceLanguage))
        let transcript = cues.map(\.text).joined(separator: "\n\n") + "\n"
        try transcript.write(to: layout.transcriptURL, atomically: true, encoding: .utf8)
        try transcript.write(to: layout.transcriptURL(language: sourceLanguage), atomically: true, encoding: .utf8)
        try makeCorePackage(layout: layout, media: media, language: sourceLanguage)

        let sourceID = "approved-\(sourceLanguage.rawValue)-source"
        let sourceSRT = try Data(contentsOf: layout.fullSRTURL)
        try sourceSRT.write(to: layout.subtitleRevisionURL(id: sourceID, language: sourceLanguage))
        try Data(contentsOf: layout.transcriptURL).write(to: layout.transcriptRevisionURL(id: sourceID, language: sourceLanguage))
        manifest.languageProfile = LanguageProfile(
            detected: sourceLanguage == .ru ? .ru : .en,
            effective: sourceLanguage,
            confidence: 1,
            method: "fixture",
            model: nil,
            modelVersion: nil,
            sampleRanges: [], manuallyOverridden: false, detectedAt: Date()
        )
        manifest.transcriptRevisions = [TranscriptRevision(
            id: sourceID, language: sourceLanguage, origin: .userEdited, parentRevisionID: "machine-\(sourceLanguage.rawValue)-source",
            transcriptArtifactID: "source-\(sourceLanguage.rawValue)-txt", subtitleArtifactID: "source-\(sourceLanguage.rawValue)-srt",
            contentHash: StableTopicHash.string(try String(contentsOf: layout.fullSRTURL, encoding: .utf8)),
            createdAt: Date(), reviewStatus: .approved
        )]
        var review = HumanReviewState.newProjectDefault
        review.sourceReviewEnabled = true
        review.translationReviewEnabled = true
        review.activeRevisionIDs[sourceLanguage.rawValue] = sourceID
        manifest.humanReviewState = review
        manifest.workflow?.status = .completed
        try store.save(manifest, to: project)
        return Fixture(media: media, project: project, layout: layout, store: store, sourceLanguage: sourceLanguage)
    }

    private static func makeCorePackage(layout: ProjectLayout, media: URL, language: ArtifactLanguage) throws {
        let package = layout.seminarTextCoreDirectory
            .appendingPathComponent("core-transcription-fixture/run/structured_timing", isDirectory: true)
        let parts = package.appendingPathComponent("parts", isDirectory: true)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        let jsonURL = parts.appendingPathComponent("part_0000.json")
        let txtURL = parts.appendingPathComponent("part_0000.txt")
        let srtURL = parts.appendingPathComponent("part_0000.srt")
        let coreSRTURL = package.deletingLastPathComponent().appendingPathComponent("transcript4.srt")
        let text = " Юрий не отменил встречу в 7 часов. В отчёте указано 12 участников."
        let tokens: [[String: Any]] = [
            token(" Юрий", 0, 100), token(" не", 100, 180), token(" отменил", 180, 300), token(" встречу", 300, 420),
            token(" в", 420, 470), token(" 7", 470, 520), token(" часов", 520, 760), token(".", 760, 800),
            token(" В", 800, 860), token(" отчёте", 860, 980), token(" указано", 980, 1100), token(" 12", 1100, 1160),
            token(" участников", 1160, 1560), token(".", 1560, 1600), token("[_EOT_]", 1600, 1600)
        ]
        let json: [String: Any] = ["transcription": [[
            "offsets": ["from": 0, "to": 1600], "no_speech_prob": 0.01, "tokens": tokens
        ]]]
        try JSONSerialization.data(withJSONObject: json).write(to: jsonURL)
        try Data(text.utf8).write(to: txtURL)
        try Data("1\n00:00:00,000 --> 00:00:01,600\n\(text)\n".utf8).write(to: srtURL)
        try Data("00:00:00,000 --> 00:00:01,600\n\(text)\n".utf8).write(to: coreSRTURL)
        func artifact(_ url: URL) -> [String: String] {
            ["path": "parts/\(url.lastPathComponent)", "sha256": SelectedTimingHash.file(url)]
        }
        let selectedManifest: [String: Any] = [
            "schema_version": 1,
            "artifact_type": "seminartext.selected_whisper_timing",
            "source": [
                "media_sha256": SelectedTimingHash.file(media),
                "reference": media.path,
                "reference_sha256": SelectedTimingHash.string(media.path)
            ],
            "transcription": ["language": language.rawValue],
            "parts": [[
                "id": "part_0000", "order": 0, "absolute_offset_seconds": 0.0,
                "absolute_range": ["start_seconds": 0.0, "end_seconds": 1.6],
                "selected_timing_absolute_range": ["start_seconds": 0.0, "end_seconds": 1.6],
                "selected_attempt": "initial",
                "artifacts": ["txt": artifact(txtURL), "srt": artifact(srtURL), "json_full": artifact(jsonURL)]
            ]]
        ]
        let manifestURL = package.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: selectedManifest).write(to: manifestURL)
        let evidence = SeminarTextCoreTranscriptionEvidence(
            schemaVersion: 1,
            runtimeIdentity: "fixture",
            sourceSRTSHA256: SelectedTimingHash.file(coreSRTURL),
            selectedTimingManifestSHA256: SelectedTimingHash.file(manifestURL),
            selectedWhisperJSONSHA256: SelectedTimingHash.data(
                try SeminarTextCoreWhisperEvidenceImporter().importSelectedWhisperJSON(
                    packageRoot: package,
                    expectedMediaURL: media,
                    expectedLanguage: language
                )
            ),
            outputDirectory: package.deletingLastPathComponent().path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(evidence).write(to: layout.seminarTextCoreEvidenceURL, options: .atomic)
    }

    private static func token(_ text: String, _ from: Int, _ to: Int) -> [String: Any] {
        ["text": text, "offsets": ["from": from, "to": to], "p": 0.95]
    }

    private static func rejectedResponses(
        at layout: ProjectLayout,
        source: ArtifactLanguage,
        target: ArtifactLanguage
    ) -> [SelectedTimingRejectedResponseEvidence] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try? decoder.decode(
            SelectedTimingRejectedResponseEvidenceDocument.self,
            from: Data(contentsOf: layout.selectedTimingTranslationRejectedResponsesURL(source: source, target: target))
        )
        return document?.responses ?? []
    }

    private static func cachedTexts(at layout: ProjectLayout) -> [String] {
        guard let runDirectories = try? FileManager.default.contentsOfDirectory(
            at: layout.selectedTimingTranslationCacheDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return runDirectories.flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        }.compactMap { url in
            guard let root = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { return nil }
            return root["text"] as? String
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw ProbeFailure(message: message) }
    }

    private struct Fixture {
        let media: URL
        let project: URL
        let layout: ProjectLayout
        let store: ProjectStore
        let sourceLanguage: ArtifactLanguage
    }
}

private protocol RUENTranslator: SimpleTextTranslationProvider {}

private actor PromptRequestRecorder {
    private var captured: [URLRequest] = []

    func record(_ request: URLRequest) {
        captured.append(request)
    }

    func prompts() -> [String] {
        captured.compactMap { request in
            guard let body = request.httpBody,
                  let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let messages = root["messages"] as? [[String: Any]],
                  let content = messages.first?["content"] as? String else {
                return nil
            }
            return content
        }
    }
}

private final class RecordingRUENTranslator: RUENTranslator {
    struct Request { let source: ArtifactLanguage; let target: ArtifactLanguage }
    private(set) var requests: [Request] = []

    func identity() async throws -> TranslationModelIdentity {
        TranslationModelIdentity(model: "translategemma:4b", digest: "fixture-digest", protocolVersion: "translategemma-simple-text-v1")
    }

    func translate(text: String, source: ArtifactLanguage, target: ArtifactLanguage) async throws -> String {
        requests.append(Request(source: source, target: target))
        return requests.count == 1 ? "Yuri did not cancel the meeting at 7 o'clock." : "The report lists 12 participants."
    }
}

private final class RecordingENRUTranslator: RUENTranslator {
    private(set) var calls = 0

    func identity() async throws -> TranslationModelIdentity {
        TranslationModelIdentity(model: "translategemma:4b", digest: "fixture-digest", protocolVersion: "translategemma-simple-text-v1")
    }

    func translate(text: String, source: ArtifactLanguage, target: ArtifactLanguage) async throws -> String {
        calls += 1
        guard source == .en && target == .ru else {
            throw ProbeFailure(message: "EN→RU fixture received the wrong translation direction")
        }
        return calls == 1
            ? "Юрий не отменил встречу в 7 часов."
            : "В отчёте указано 12 участников."
    }
}

private final class ScriptedLegacyTranslationProvider: TranslationAIProvider {
    private(set) var calls = 0

    func preferredModel() async throws -> String { "scripted-legacy-translation" }

    func preferredIdentity() async throws -> TranslationModelIdentity {
        TranslationModelIdentity(
            model: "scripted-legacy-translation",
            digest: "scripted-legacy-digest",
            protocolVersion: "scripted-legacy-v1"
        )
    }

    func translate(
        cues: [TranslationRequestCue],
        source: ArtifactLanguage,
        target: ArtifactLanguage,
        model: String,
        correction: String?
    ) async throws -> [Int: String] {
        calls += 1
        guard source == .ru && target == .en && model == "scripted-legacy-translation" && correction == nil else {
            throw ProbeFailure(message: "Legacy provider received an unexpected translation request")
        }
        return Dictionary(uniqueKeysWithValues: cues.map { cue in
            let text: String
            switch cue.id {
            case 1: text = "Yuri did not cancel the meeting at 7 o'clock."
            case 3: text = "The report lists 12 participants."
            default: text = "English translation \(cue.id)."
            }
            return (cue.id, text)
        })
    }
}

private struct SourceFallbackTranslator: RUENTranslator {
    func identity() async throws -> TranslationModelIdentity {
        TranslationModelIdentity(model: "translategemma:4b", digest: "fixture-digest", protocolVersion: "translategemma-simple-text-v1")
    }
    func translate(text: String, source: ArtifactLanguage, target: ArtifactLanguage) async throws -> String { text }
}

private struct RussianOutputTranslator: RUENTranslator {
    func identity() async throws -> TranslationModelIdentity {
        TranslationModelIdentity(model: "translategemma:4b", digest: "fixture-digest", protocolVersion: "translategemma-simple-text-v1")
    }
    func translate(text: String, source: ArtifactLanguage, target: ArtifactLanguage) async throws -> String { "Русский ответ без перевода." }
}

private final class RejectThenTranslateRUENTranslator: RUENTranslator {
    private(set) var calls = 0

    func identity() async throws -> TranslationModelIdentity {
        TranslationModelIdentity(model: "translategemma:4b", digest: "fixture-digest", protocolVersion: "translategemma-simple-text-v1")
    }

    func translate(text: String, source: ArtifactLanguage, target: ArtifactLanguage) async throws -> String {
        calls += 1
        if calls == 1 { return "Русский ответ без перевода." }
        return calls == 2 ? "Yuri did not cancel the meeting at 7 o'clock." : "The report lists 12 participants."
    }
}

private struct FailingRUENTranslator: RUENTranslator {
    func identity() async throws -> TranslationModelIdentity {
        TranslationModelIdentity(model: "translategemma:4b", digest: "fixture-digest", protocolVersion: "translategemma-simple-text-v1")
    }
    func translate(text: String, source: ArtifactLanguage, target: ArtifactLanguage) async throws -> String {
        throw WorkflowError.processFailed("controlled TranslateGemma failure")
    }
}

private struct ProbeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
