import Foundation

@main
struct RUENTranslationRealProbe {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mediaPath = environment["VIDEOTEXT_RU_SOURCE"],
              let templatePath = environment["VIDEOTEXT_RU_APPROVED_PROJECT"],
              let outputPath = environment["VIDEOTEXT_RU_EN_REAL_ROOT"] else {
            throw ProbeFailure(message: "Set VIDEOTEXT_RU_SOURCE, VIDEOTEXT_RU_APPROVED_PROJECT, and VIDEOTEXT_RU_EN_REAL_ROOT.")
        }
        let media = URL(fileURLWithPath: mediaPath)
        let template = URL(fileURLWithPath: templatePath, isDirectory: true)
        let root = URL(fileURLWithPath: outputPath, isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        guard FileManager.default.fileExists(atPath: media.path), FileManager.default.fileExists(atPath: template.path) else {
            throw ProbeFailure(message: "controlled source media or approved RU template is unavailable")
        }
        guard !FileManager.default.fileExists(atPath: project.path) else {
            throw ProbeFailure(message: "real-probe output project already exists")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: template, to: project)

        let store = ProjectStore(history: ProjectHistoryStore(indexURL: root.appendingPathComponent("history.json")))
        let layout = ProjectLayout(root: project)
        try resetCopyToApprovedRussianSource(project: project, media: media, store: store, layout: layout)

        let sourceSRT = try Data(contentsOf: layout.fullSRTURL)
        let sourceTXT = try Data(contentsOf: layout.transcriptURL)
        let sourceManifest = try store.load(from: project)
        let sourceTranscription = try operationData(sourceManifest.workflow?.operations[WorkflowOperation.transcribe.rawValue])
        let packagesBefore = packageFingerprints(in: layout.seminarTextCoreDirectory)
        var log: [String] = []
        let engine = WorkflowEngine(store: store)
        let result = try await engine.run(settings: settings(media: media, project: project), onLog: {
            log.append($0)
            fputs("\($0)\n", stderr)
        })

        try require(result.checkpoint?.kind == .translatedTranscript && result.checkpoint?.language == .en,
                    "real RU→EN run did not stop at Translation Human Review")
        try require(!log.contains(where: { $0.contains("Расшифровка bundled SeminarText") }),
                    "real RU→EN run started ASR")
        let pending = try store.load(from: project)
        try require(try operationData(pending.workflow?.operations[WorkflowOperation.transcribe.rawValue]) == sourceTranscription,
                    "real RU→EN run changed the transcription operation")
        try require(try Data(contentsOf: layout.fullSRTURL) == sourceSRT
                    && Data(contentsOf: layout.transcriptURL) == sourceTXT,
                    "real RU→EN run changed approved source evidence")
        try require(packageFingerprints(in: layout.seminarTextCoreDirectory) == packagesBefore,
                    "real RU→EN run created or changed a SeminarText package")
        try require(pending.activeTranscriptRevision(for: .en) == nil,
                    "real RU→EN translation became active before review")

        let document = try JSONDecoder().decode(
            TimedTranslationDocument.self,
            from: Data(contentsOf: layout.selectedTimingTranslationsURL(source: .ru, target: .en))
        )
        try document.validate()
        try require(document.model.model == "translategemma:4b", "real translation used an unexpected model")
        try require(document.model.protocolVersion == "translategemma-simple-text-v1", "real translation used an unexpected protocol")
        try require(document.sourceLanguage == .ru && document.targetLanguage == .en,
                    "real translation recorded the wrong language direction")
        try require(zip(document.source.units, document.units).allSatisfy {
            $0.id == $1.sourceUnitID && $0.textSHA256 == $1.sourceTextSHA256 && $0.start == $1.start && $0.end == $1.end
                && !$1.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }, "real RU→EN translation lost source order, provenance, timing, or text")
        let output = document.units.map(\.text).joined(separator: " ")
        try require(output.range(of: "[A-Za-z]", options: .regularExpression) != nil,
                    "real TranslateGemma output does not contain English text")
        for (source, translated) in zip(document.source.units, document.units) {
            print("RU_EN_SOURCE_UNIT_\(source.id)=\(source.text)")
            print("RU_EN_TRANSLATED_UNIT_\(source.id)=\(translated.text)")
        }

        if environment["VIDEOTEXT_RU_EN_STOP_AT_HUMAN_REVIEW"] == "1" {
            print("RU_EN_TRANSLATION_REAL_REVIEW_BOUNDARY_PASS digest=\(document.model.digest ?? "missing")")
            print("RU_EN_TRANSLATION_REAL_PROJECT=\(project.path)")
            return
        }

        _ = try HumanReviewService(store: store).approve(projectURL: project)
        let approved = try store.load(from: project)
        try require(approved.activeTranscriptRevision(for: .ru)?.reviewStatus == .approved,
                    "source RU revision lost approval")
        try require(approved.activeTranscriptRevision(for: .en)?.reviewStatus == .approved,
                    "approved EN translation is missing")
        try require(SubtitleSourceResolver.availableSelections(manifest: approved, projectURL: project)
                    == [.source, .approvedTranslation(.en)],
                    "approved EN translation is not selectable")
        try require(FileManager.default.fileExists(atPath: layout.transcriptURL(language: .en).path)
                    && FileManager.default.fileExists(atPath: layout.subtitlesURL(language: .en).path),
                    "approved EN TXT/SRT are missing")

        let translatedBytes = try Data(contentsOf: layout.selectedTimingTranslationsURL(source: .ru, target: .en))
        var resumeLog: [String] = []
        let resumed = try await engine.run(settings: settings(media: media, project: project), onLog: { resumeLog.append($0) })
        try require(resumed.checkpoint == nil, "reopen/resume reopened approved EN Translation Human Review")
        try require(resumeLog.contains(where: { $0.contains("Пропуск: Перевести расшифровку") }),
                    "reopen/resume did not reuse approved RU→EN translation")
        try require(try Data(contentsOf: layout.selectedTimingTranslationsURL(source: .ru, target: .en)) == translatedBytes,
                    "reopen/resume changed the approved RU→EN translation")

        print("RU_EN_TRANSLATION_REAL_PROBE_PASS digest=\(document.model.digest ?? "missing")")
        print("RU_EN_TRANSLATION_REAL_PROJECT=\(project.path)")
    }

    private static func settings(media: URL, project: URL) -> WorkflowSettings {
        WorkflowSettings(
            mediaURL: media,
            projectURL: project,
            selectedOperations: [.translateTranscript],
            mode: .resumeProject,
            rangeStart: 0,
            rangeEnd: 10,
            fragmentName: "",
            burnFragmentSubtitles: false,
            subtitleStyle: .standard,
            selectedTopicID: nil,
            whisperModelPath: "",
            whisperLanguage: "ru",
            sourceHumanReviewEnabled: true,
            translationHumanReviewEnabled: true
        )
    }

    private static func resetCopyToApprovedRussianSource(
        project: URL,
        media: URL,
        store: ProjectStore,
        layout: ProjectLayout
    ) throws {
        var manifest = try store.load(from: project)
        guard manifest.languageProfile?.effective == .ru,
              let source = manifest.activeTranscriptRevision(for: .ru),
              source.reviewStatus == .approved else {
            throw ProbeFailure(message: "template is not an approved RU source project")
        }
        manifest.sourceMediaPath = media.path
        manifest.projectFolderPath = project.path
        manifest.transcriptRevisions = (manifest.transcriptRevisions ?? []).filter { $0.language == .ru }
        manifest.artifacts = (manifest.artifacts ?? []).filter { $0.language != .en }
        manifest.reviewTasks = (manifest.reviewTasks ?? []).filter { $0.language != .en }
        manifest.outputs = []
        var review = manifest.humanReviewState ?? .newProjectDefault
        review.activeRevisionIDs.removeValue(forKey: ArtifactLanguage.en.rawValue)
        review.draftRevisionIDs.removeValue(forKey: ArtifactLanguage.en.rawValue)
        review.pendingCheckpoint = nil
        review.translationReviewEnabled = true
        manifest.humanReviewState = review
        manifest.workflow?.status = .completed
        manifest.workflow?.lastError = nil
        manifest.workflow?.operations.removeValue(forKey: WorkflowOperation.translateTranscript.rawValue)
        try store.save(manifest, to: project)

        for url in [
            layout.selectedTimingSourceUnitsURL,
            layout.selectedTimingTranslationsURL(source: .ru, target: .en),
            layout.transcriptURL(language: .en),
            layout.subtitlesURL(language: .en)
        ] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func packageFingerprints(in directory: URL) -> [String: String] {
        SeminarTextSelectedTimingRunner.findManifests(in: directory).reduce(into: [:]) { result, url in
            result[url.path] = SelectedTimingHash.file(url)
        }
    }

    private static func operationData(_ operation: ProjectOperationRecord?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(operation)
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
