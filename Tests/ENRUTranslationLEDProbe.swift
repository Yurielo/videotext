import Foundation

@main
struct ENRUTranslationLEDProbe {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mediaPath = environment["VIDEOTEXT_LED_SOURCE"],
              let templatePath = environment["VIDEOTEXT_LED_APPROVED_EN_PROJECT"] else {
            throw ProbeFailure(message: "Set VIDEOTEXT_LED_SOURCE and VIDEOTEXT_LED_APPROVED_EN_PROJECT.")
        }
        let media = URL(fileURLWithPath: mediaPath)
        let template = URL(fileURLWithPath: templatePath, isDirectory: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("videotext-en-ru-led-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try require(
            SelectedTimingHash.file(media) == "f53460e353437873e34f404b841134def1ffbbae6f719f3e618adb159ad84ecc",
            "LED media does not match the accepted source"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: template, to: project)

        let history = root.appendingPathComponent("history.json")
        let store = ProjectStore(history: ProjectHistoryStore(indexURL: history))
        let layout = ProjectLayout(root: project)
        try resetCopyToApprovedEnglishSource(project: project, media: media, store: store, layout: layout)

        let sourceSRT = try Data(contentsOf: layout.fullSRTURL)
        let sourceTXT = try Data(contentsOf: layout.transcriptURL)
        try require(!FileManager.default.fileExists(atPath: layout.selectedTimingSourceUnitsURL.path),
                    "LED copy still contains precomputed translation-owned source units")
        let selectedPackagesBefore = selectedPackageFingerprints(in: layout.seminarTextCoreDirectory)
        let manifestBefore = try store.load(from: project)
        let transcriptionBefore = try operationData(
            manifestBefore.workflow?.operations[WorkflowOperation.transcribe.rawValue]
        )

        var firstLog: [String] = []
        let engine = WorkflowEngine(store: store)
        let first = try await engine.run(
            settings: settings(media: media, project: project),
            onLog: {
                firstLog.append($0)
                fputs("\($0)\n", stderr)
            }
        )
        try require(first.checkpoint?.kind == .translatedTranscript && first.checkpoint?.language == .ru,
                    "real EN→RU run did not stop at Translation Human Review")
        try require(!firstLog.contains(where: { $0.contains("Расшифровка bundled SeminarText") }),
                    "real EN→RU run started ASR")
        let pending = try store.load(from: project)
        try require(pending.activeTranscriptRevision(for: .ru) == nil,
                    "real EN→RU run activated translation before approval")
        try require(try operationData(
            pending.workflow?.operations[WorkflowOperation.transcribe.rawValue]
        ) == transcriptionBefore,
                    "real EN→RU run changed the transcription operation")
        try require(try Data(contentsOf: layout.fullSRTURL) == sourceSRT
                    && Data(contentsOf: layout.transcriptURL) == sourceTXT,
                    "real EN→RU run changed approved source evidence")
        let sourceUnits = try Data(contentsOf: layout.selectedTimingSourceUnitsURL)
        try require(selectedPackageFingerprints(in: layout.seminarTextCoreDirectory) == selectedPackagesBefore,
                    "real EN→RU run created or changed a SeminarText package")

        let translated = try JSONDecoder().decode(
            TimedTranslationDocument.self,
            from: Data(contentsOf: layout.selectedTimingTranslationsURL(source: .en, target: .ru))
        )
        try translated.validate()
        try require(translated.model.model == "translategemma:4b", "real translation used an unexpected model")
        try require(translated.model.protocolVersion == "translategemma-simple-text-v1",
                    "real translation used an unexpected protocol")
        try require(translated.source.sourceText.contains("save a lot of energy. The LED"),
                    "LED energy boundary was lost")
        try require(translated.source.units.contains { $0.text.localizedCaseInsensitiveContains("warm LEDs") },
                    "warm LEDs source unit was split or lost")
        try require(translated.source.units.contains { $0.text.localizedCaseInsensitiveContains("mitochondria") },
                    "mitochondria source unit was lost")
        try require(translated.source.units.contains { $0.text.localizedCaseInsensitiveContains("Under LED lighting") },
                    "Under LED lighting source unit was lost")
        try require(zip(translated.source.units, translated.units).allSatisfy {
            $0.id == $1.sourceUnitID
                && $0.textSHA256 == $1.sourceTextSHA256
                && $0.start == $1.start
                && $0.end == $1.end
                && !$1.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }, "real translation lost source order, ownership, timing, or text")
        let translatedText = translated.units.map(\.text).joined(separator: " ")
        try require(translatedText.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil,
                    "real TranslateGemma output does not contain Russian text")
        for (sourceUnit, translatedUnit) in zip(translated.source.units, translated.units) {
            print("LED_UNIT_\(sourceUnit.id)_EN=\(sourceUnit.text)")
            print("LED_UNIT_\(sourceUnit.id)_RU=\(translatedUnit.text)")
        }

        _ = try HumanReviewService(store: store).approve(projectURL: project)
        let approved = try store.load(from: project)
        try require(approved.activeTranscriptRevision(for: .en)?.reviewStatus == .approved,
                    "source approval was lost after translation approval")
        try require(approved.activeTranscriptRevision(for: .ru)?.reviewStatus == .approved,
                    "RU translation was not approved")
        try require(FileManager.default.fileExists(atPath: layout.transcriptURL(language: .ru).path)
                    && FileManager.default.fileExists(atPath: layout.subtitlesURL(language: .ru).path),
                    "approved RU TXT/SRT are missing")

        let translationBytes = try Data(
            contentsOf: layout.selectedTimingTranslationsURL(source: .en, target: .ru)
        )
        var resumeLog: [String] = []
        let resumed = try await engine.run(
            settings: settings(media: media, project: project),
            onLog: {
                resumeLog.append($0)
                fputs("\($0)\n", stderr)
            }
        )
        try require(resumed.checkpoint == nil, "reopen/resume reopened approved Translation Human Review")
        try require(resumeLog.contains(where: { $0.contains("Пропуск: Перевести расшифровку") }),
                    "reopen/resume did not reuse the approved translation")
        try require(try Data(contentsOf: layout.selectedTimingTranslationsURL(source: .en, target: .ru)) == translationBytes,
                    "reopen/resume changed the approved translation")
        try require(try Data(contentsOf: layout.selectedTimingSourceUnitsURL) == sourceUnits,
                    "reopen/resume changed imported source units")
        try require(selectedPackageFingerprints(in: layout.seminarTextCoreDirectory) == selectedPackagesBefore,
                    "reopen/resume created or changed a SeminarText package")

        print("EN_RU_TRANSLATION_LED_PROBE_PASS units=\(translated.units.count) digest=\(translated.model.digest ?? "missing")")
        print("EN_RU_TRANSLATION_LED_PROJECT=\(project.path)")
    }

    private static func settings(media: URL, project: URL) -> WorkflowSettings {
        WorkflowSettings(
            mediaURL: media,
            projectURL: project,
            selectedOperations: [.translateTranscript],
            mode: .resumeProject,
            rangeStart: 0,
            rangeEnd: 60,
            fragmentName: "",
            burnFragmentSubtitles: false,
            subtitleStyle: .standard,
            selectedTopicID: nil,
            whisperModelPath: "",
            whisperLanguage: "en",
            sourceHumanReviewEnabled: true,
            translationHumanReviewEnabled: true
        )
    }

    private static func resetCopyToApprovedEnglishSource(
        project: URL,
        media: URL,
        store: ProjectStore,
        layout: ProjectLayout
    ) throws {
        var manifest = try store.load(from: project)
        guard manifest.languageProfile?.effective == .en,
              let source = manifest.activeTranscriptRevision(for: .en),
              source.reviewStatus == .approved else {
            throw ProbeFailure(message: "LED template is not an approved EN source project")
        }
        manifest.sourceMediaPath = media.path
        manifest.projectFolderPath = project.path
        manifest.transcriptRevisions = (manifest.transcriptRevisions ?? []).filter { $0.language == .en }
        manifest.artifacts = (manifest.artifacts ?? []).filter { $0.language != .ru }
        manifest.reviewTasks = (manifest.reviewTasks ?? []).filter { $0.language != .ru }
        manifest.outputs = []
        var review = manifest.humanReviewState ?? .newProjectDefault
        review.activeRevisionIDs.removeValue(forKey: ArtifactLanguage.ru.rawValue)
        review.draftRevisionIDs.removeValue(forKey: ArtifactLanguage.ru.rawValue)
        review.pendingCheckpoint = nil
        review.translationReviewEnabled = true
        manifest.humanReviewState = review
        manifest.workflow?.status = .completed
        manifest.workflow?.lastError = nil
        manifest.workflow?.operations.removeValue(forKey: WorkflowOperation.translateTranscript.rawValue)
        try store.save(manifest, to: project)

        let selectedManifests = SeminarTextSelectedTimingRunner.findManifests(
            in: layout.selectedTimingSeminarTextDirectory
        )
        guard selectedManifests.count == 1, let sourceManifestURL = selectedManifests.first else {
            throw ProbeFailure(message: "LED template does not contain exactly one selected timing package")
        }
        let sourcePackage = sourceManifestURL.deletingLastPathComponent()
        let corePackage = layout.seminarTextCoreDirectory
            .appendingPathComponent("accepted-led-run", isDirectory: true)
            .appendingPathComponent(sourcePackage.lastPathComponent, isDirectory: true)
        if FileManager.default.fileExists(atPath: layout.seminarTextCoreDirectory.path) {
            try FileManager.default.removeItem(at: layout.seminarTextCoreDirectory)
        }
        try FileManager.default.createDirectory(
            at: corePackage.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sourcePackage, to: corePackage)
        let coreManifestURL = corePackage.appendingPathComponent("manifest.json")
        let jsonFiles = regularFiles(in: corePackage).filter {
            $0.pathExtension == "json" && $0.lastPathComponent != "manifest.json"
        }
        guard jsonFiles.count == 1, let selectedJSONURL = jsonFiles.first else {
            throw ProbeFailure(message: "LED selected timing package does not contain exactly one JSON-full artifact")
        }
        let coreEvidence = SeminarTextCoreTranscriptionEvidence(
            schemaVersion: 1,
            runtimeIdentity: "accepted-led-template",
            sourceSRTSHA256: SelectedTimingHash.file(layout.fullSRTURL),
            selectedTimingManifestSHA256: SelectedTimingHash.file(coreManifestURL),
            selectedWhisperJSONSHA256: SelectedTimingHash.file(selectedJSONURL),
            outputDirectory: layout.seminarTextCoreDirectory.path
        )
        let evidenceEncoder = JSONEncoder()
        evidenceEncoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try evidenceEncoder.encode(coreEvidence).write(to: layout.seminarTextCoreEvidenceURL, options: .atomic)

        let targets = [
            layout.transcriptURL(language: .ru),
            layout.subtitlesURL(language: .ru),
            layout.translationReportURL(source: .en, target: .ru),
            layout.selectedTimingSourceUnitsURL,
            layout.selectedTimingTranslationsURL(source: .en, target: .ru),
            layout.selectedTimingTranslationCacheDirectory,
            layout.selectedTimingSeminarTextDirectory
        ]
        for target in targets where FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        for directory in [layout.transcriptRevisionsDirectory, layout.subtitleRevisionsDirectory] {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { continue }
            for item in items where item.lastPathComponent.hasSuffix(".ru.txt")
                || item.lastPathComponent.hasSuffix(".ru.srt") {
                try FileManager.default.removeItem(at: item)
            }
        }
    }

    private static func selectedPackageFingerprints(in root: URL) -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [:] }
        var result: [String: String] = [:]
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  url.path.contains("/SeminarText/") else { continue }
            result[url.path.replacingOccurrences(of: root.path, with: "")] = SelectedTimingHash.file(url)
        }
        return result
    }

    private static func regularFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url
        }
    }

    private static func operationData(_ operation: ProjectOperationRecord?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(operation)
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
