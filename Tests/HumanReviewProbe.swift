import Foundation

@main
struct HumanReviewProbe {
    static func main() throws {
        let fileManager = FileManager.default
        let root = (URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? fileManager.temporaryDirectory.path, isDirectory: true)).appendingPathComponent("videotext-human-review-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let media = root.appendingPathComponent("source.mp4")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("media".utf8).write(to: media)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let history = ProjectHistoryStore(indexURL: root.appendingPathComponent("history.json"))
        let store = ProjectStore(history: history)
        var manifest = try store.ensureProject(at: project, mediaURL: media, mode: .newProject)
        let layout = ProjectLayout(root: project)
        let cues = [
            SubtitleCue(id: 1, start: 0, end: 2, text: "Исходный первый фрагмент."),
            SubtitleCue(id: 2, start: 2, end: 4, text: "Исходный второй фрагмент.")
        ]
        try SRTService().writePreservingIDs(cues, to: layout.fullSRTURL)
        try SRTService().writePreservingIDs(cues, to: layout.subtitlesURL(language: .ru))
        try "Исходный первый фрагмент.\n\nИсходный второй фрагмент.\n".write(
            to: layout.transcriptURL(language: .ru), atomically: true, encoding: .utf8
        )

        let baselineID = "transcript-ru-machine-fixture"
        let baseline = TranscriptRevision(
            id: baselineID,
            language: .ru,
            origin: .machineGenerated,
            parentRevisionID: nil,
            transcriptArtifactID: "artifact-baseline-txt",
            subtitleArtifactID: "artifact-baseline-srt",
            contentHash: "baseline",
            createdAt: Date(),
            reviewStatus: nil
        )
        try SRTService().writePreservingIDs(cues, to: layout.subtitleRevisionURL(id: baselineID, language: .ru))
        try "baseline".write(to: layout.transcriptRevisionURL(id: baselineID, language: .ru), atomically: true, encoding: .utf8)
        manifest.languageProfile = LanguageProfile(
            detected: .ru,
            effective: .ru,
            confidence: 1,
            method: "fixture",
            model: nil,
            modelVersion: nil,
            sampleRanges: [],
            manuallyOverridden: false,
            detectedAt: Date()
        )
        manifest.transcriptRevisions = [baseline]
        manifest.reviewTasks = [ReviewTask(
            id: "review-cue-1",
            transcriptRevisionID: baselineID,
            status: .needsReview,
            language: .ru,
            start: 0,
            end: 2,
            cueIDs: [1],
            reasonCodes: ["low-confidence"],
            confidence: 0.4,
            originalText: cues[0].text,
            suggestedText: nil,
            createdAt: Date(),
            resolvedAt: nil,
            dependentArtifactIDs: ["artifact-baseline-srt"]
        )]
        manifest.humanReviewState = .newProjectDefault
        manifest.artifacts = [
            artifact(id: "artifact-baseline-srt", sourceRevision: baselineID, dependencies: [baselineID]),
            artifact(id: "artifact-topics", sourceRevision: baselineID, dependencies: ["artifact-baseline-srt"]),
            artifact(id: "artifact-video", sourceRevision: baselineID, dependencies: ["artifact-topics"])
        ]
        try store.save(manifest, to: project)

        let service = HumanReviewService(store: store)
        let checkpoint = try service.transitionAfterGeneration(
            projectURL: project,
            kind: .sourceTranscript,
            language: .ru,
            revisionID: baselineID,
            pendingOperations: [.topicTimecoding, .discoverResults],
            sourceReviewEnabled: true,
            translationReviewEnabled: false
        )
        try require(checkpoint?.revisionID == baselineID, "source checkpoint не создан")
        try require(try store.load(from: project).activeTranscriptRevision(for: .ru) == nil, "pending revision стала активной")

        var criticalManifest = try store.load(from: project)
        criticalManifest.reviewTasks?.append(ReviewTask(
            id: "critical-retranscription",
            transcriptRevisionID: baselineID,
            status: .needsReview,
            language: .ru,
            start: 0,
            end: 4,
            cueIDs: [1, 2],
            reasonCodes: ["progressive-repetition-loop", "automatic-retranscription-required"],
            confidence: nil,
            originalText: cues[0].text,
            suggestedText: nil,
            createdAt: Date(),
            resolvedAt: nil,
            dependentArtifactIDs: []
        ))
        try store.save(criticalManifest, to: project)
        do {
            _ = try service.approve(projectURL: project)
            throw ProbeFailure(message: "Human Review утвердил расшифровку с критической ошибкой")
        } catch WorkflowError.processFailed {
            // Expected: a structural ASR failure requires retranscription.
        }
        criticalManifest.reviewTasks?.removeAll { $0.id == "critical-retranscription" }
        try store.save(criticalManifest, to: project)

        let draftCues = try service.saveDraftCue(
            projectURL: project,
            language: .ru,
            cueID: 1,
            replacementText: "Исправленный первый фрагмент."
        )
        try require(draftCues[0].start == 0 && draftCues[0].end == 2, "черновик изменил таймкод")
        var afterDraft = try store.load(from: project)
        try require(afterDraft.humanReviewState?.draftRevisionIDs["ru"] != nil, "draft revision не сохранена")
        try require(afterDraft.reviewTasks?.first?.status == .resolved, "исправленный ReviewTask не закрыт")

        var tampered = draftCues
        tampered[0].start = 0.25
        try SRTService().writePreservingIDs(tampered, to: layout.fullSRTURL)
        do {
            _ = try service.approve(projectURL: project)
            throw ProbeFailure(message: "утверждён изменённый таймкод")
        } catch WorkflowError.invalidSRT {
            // Expected strict rejection.
        }
        try SRTService().writePreservingIDs(draftCues, to: layout.fullSRTURL)
        let approval = try service.approve(projectURL: project)
        try require(approval.pendingOperations == [.topicTimecoding, .discoverResults], "очередь продолжения потеряна")
        try require(approval.revision.reviewStatus == .approved, "approved revision не создана")
        let approvedManifest = try store.load(from: project)
        try require(approvedManifest.humanReviewState?.pendingCheckpoint == nil, "checkpoint не закрыт")
        try require(approvedManifest.activeTranscriptRevision(for: .ru)?.id == approval.revision.id, "approved revision не активирована")
        let approvedSourceText = try String(contentsOf: layout.transcriptURL, encoding: .utf8)
        try require(approvedSourceText.contains("Исправленный первый фрагмент."), "исправленный source TXT не записан")
        for id in ["artifact-baseline-srt", "artifact-topics", "artifact-video"] {
            try require(approvedManifest.artifacts?.first(where: { $0.id == id })?.validationStatus == .pending, "потомок \(id) не инвалидирован")
        }

        afterDraft = approvedManifest
        let translatedID = "translation-ru-en-fixture"
        let translated = TranscriptRevision(
            id: translatedID,
            language: .en,
            origin: .translated,
            parentRevisionID: approval.revision.id,
            transcriptArtifactID: "artifact-translation-txt",
            subtitleArtifactID: "artifact-translation-srt",
            contentHash: "translated",
            createdAt: Date()
        )
        afterDraft.transcriptRevisions?.append(translated)
        try store.save(afterDraft, to: project)
        let translationCheckpoint = try service.transitionAfterGeneration(
            projectURL: project,
            kind: .translatedTranscript,
            language: .en,
            revisionID: translatedID,
            pendingOperations: [.createDubbing],
            sourceReviewEnabled: true,
            translationReviewEnabled: false
        )
        try require(translationCheckpoint == nil, "выключенный translated checkpoint приостановил pipeline")
        try require(try store.load(from: project).activeTranscriptRevision(for: .en)?.id == translatedID, "перевод не активирован без review")

        var finalManifest = try store.load(from: project)
        let reviewedTranslationID = "translation-ru-en-final-fixture"
        let translatedCues = [
            SubtitleCue(id: 1, start: 0, end: 2, text: "Translated first fragment."),
            SubtitleCue(id: 2, start: 2, end: 4, text: "Translated second fragment.")
        ]
        try SRTService().writePreservingIDs(translatedCues, to: layout.subtitlesURL(language: .en))
        try SRTService().writePreservingIDs(
            translatedCues,
            to: layout.subtitleRevisionURL(id: reviewedTranslationID, language: .en)
        )
        try "Translated first fragment.\n\nTranslated second fragment.\n".write(
            to: layout.transcriptRevisionURL(id: reviewedTranslationID, language: .en),
            atomically: true,
            encoding: .utf8
        )
        finalManifest.transcriptRevisions?.append(TranscriptRevision(
            id: reviewedTranslationID,
            language: .en,
            origin: .translated,
            parentRevisionID: approval.revision.id,
            transcriptArtifactID: "artifact-final-translation-txt",
            subtitleArtifactID: "artifact-final-translation-srt",
            contentHash: StableTopicHash.string(try String(contentsOf: layout.subtitlesURL(language: .en), encoding: .utf8)),
            createdAt: Date()
        ))
        finalManifest.workflow = ProjectWorkflowState(
            status: .awaitingReview,
            progress: 0.8,
            mode: .resumeProject,
            operations: [:],
            lastError: nil
        )
        finalManifest.reviewTasks?.append(ReviewTask(
            id: "unrelated-old-task",
            transcriptRevisionID: "older-en-revision",
            status: .needsReview,
            language: .en,
            start: 0,
            end: 2,
            cueIDs: [1],
            reasonCodes: ["legacy"],
            confidence: nil,
            originalText: "old",
            suggestedText: nil,
            createdAt: Date(),
            resolvedAt: nil,
            dependentArtifactIDs: []
        ))
        try store.save(finalManifest, to: project)
        _ = try service.transitionAfterGeneration(
            projectURL: project,
            kind: .translatedTranscript,
            language: .en,
            revisionID: reviewedTranslationID,
            pendingOperations: [],
            sourceReviewEnabled: true,
            translationReviewEnabled: true
        )
        let translatedDraft = try service.saveDraftCue(
            projectURL: project,
            language: .en,
            cueID: 1,
            replacementText: "Reviewed first fragment."
        )
        try require(translatedDraft[0].start == 0 && translatedDraft[0].end == 2, "translation review изменил таймкод")
        let afterTranslationDraft = try store.load(from: project)
        try require(
            afterTranslationDraft.reviewTasks?.first(where: { $0.id == "unrelated-old-task" })?.status == .needsReview,
            "правка translation review закрыла задание другой ревизии"
        )
        let finalApproval = try service.approve(projectURL: project)
        let completedManifest = try store.load(from: project)
        try require(finalApproval.pendingOperations.isEmpty, "пустая очередь изменилась")
        try require(completedManifest.workflow?.status == .completed, "последний checkpoint не завершил workflow")
        try require(
            completedManifest.reviewTasks?.first(where: { $0.id == "unrelated-old-task" })?.status == .needsReview,
            "утверждение закрыло задание другой ревизии"
        )
        let approvedTranslationText = try String(contentsOf: layout.transcriptURL(language: .en), encoding: .utf8)
        try require(approvedTranslationText.contains("Reviewed first fragment."), "исправленный translated TXT не записан")
        let simpleState = SimpleProjectHomeStateService().make(
            projectURL: project,
            manifest: completedManifest,
            topicsDetail: nil,
            discoveredOutputs: []
        )
        try require(simpleState.artifact(.transcription).openOutputPath == layout.transcriptURL.path, "Simple source result не ведёт к transcript TXT")
        try require(simpleState.artifact(.translation).openOutputPath == layout.transcriptURL(language: .en).path, "Simple translation result не ведёт к translated TXT")
        try require(simpleState.artifact(.transcription).reviewTarget == .source, "approved Source потерял correction target")
        try require(simpleState.artifact(.translation).reviewTarget == .translation, "approved Translation потерял correction target")
        try require(simpleState.artifact(.topics).reviewTarget == nil, "Topics correction появился в Simple")
        try require(
            !simpleState.recentResults.contains(where: { $0.path.hasSuffix(".srt") }),
            "Simple recent results после Human Review не должны раскрывать SRT"
        )
        let activeRU = try requireValue(completedManifest.activeTranscriptRevision(for: .ru), "нет активной RU-ревизии")
        let reopened = try service.beginReview(projectURL: project, language: .ru)
        try require(reopened.kind == .sourceTranscript && reopened.language == .ru, "ручной Source Review имеет неверный kind/language")
        try require(reopened.revisionID == activeRU.id, "ручной Human Review открыт не для активной ревизии")
        try require(reopened.pendingOperations.isEmpty, "ручной Human Review создал лишнюю очередь")
        let reopenedManifest = try store.load(from: project)
        try require(reopenedManifest.workflow?.status == .awaitingReview, "ручной Human Review не приостановил проект")
        _ = try service.approve(projectURL: project)
        try require(try store.load(from: project).workflow?.status == .completed, "ручной Human Review не завершил проект")
        let beforeTranslationReopen = try store.load(from: project)
        let activeEN = try requireValue(beforeTranslationReopen.activeTranscriptRevision(for: .en), "нет активной approved EN-ревизии")
        let sourceBeforeTranslation = beforeTranslationReopen.activeTranscriptRevision(for: .ru)?.id
        let reopenedTranslation = try service.beginReview(projectURL: project, language: .en)
        try require(reopenedTranslation.kind == .translatedTranscript && reopenedTranslation.language == .en, "ручной Translation Review имеет неверный kind/language")
        try require(reopenedTranslation.revisionID == activeEN.id, "ручной Translation Review открыт не для active approved revision")
        try require(reopenedTranslation.pendingOperations.isEmpty, "ручной Translation Review создал downstream operations")
        let persistedTranslationCheckpoint = try store.load(from: project).humanReviewState?.pendingCheckpoint
        do {
            _ = try service.beginReview(projectURL: project, language: .ru)
            throw ProbeFailure(message: "Source Review заменил уже открытый Translation checkpoint")
        } catch WorkflowError.processFailed {
            // A different-language review must not replace the pending checkpoint.
        }
        try require(try store.load(from: project).humanReviewState?.pendingCheckpoint == persistedTranslationCheckpoint, "pending Translation checkpoint изменился")
        let translationCuesBefore = try SRTService().load(from: layout.subtitlesURL(language: .en))
        let reopenedTranslationDraft = try service.saveDraftCue(
            projectURL: project, language: .en, cueID: 1,
            replacementText: "Reviewed again without changing timing."
        )
        try require(
            zip(translationCuesBefore, reopenedTranslationDraft).allSatisfy { original, edited in
                original.id == edited.id && original.start == edited.start && original.end == edited.end
            } && translationCuesBefore.count == reopenedTranslationDraft.count,
            "повторная Translation correction изменила cue IDs/timing"
        )
        _ = try service.approve(projectURL: project)
        let afterTranslationReopen = try store.load(from: project)
        try require(afterTranslationReopen.humanReviewState?.pendingCheckpoint == nil, "повторный Translation checkpoint не закрыт")
        try require(afterTranslationReopen.activeTranscriptRevision(for: .ru)?.id == sourceBeforeTranslation, "Translation correction сменила Source revision")
        try require(afterTranslationReopen.reviewTasks?.first(where: { $0.id == "unrelated-old-task" })?.status == .needsReview, "повторная Translation correction закрыла старое задание")
        let correctedTranslation = try String(contentsOf: layout.transcriptURL(language: .en), encoding: .utf8)
        try require(correctedTranslation.contains("Reviewed again without changing timing."), "повторная Translation correction не опубликована в TXT")
        print("HUMAN_REVIEW_PROBE_PASS")
    }

    private static func artifact(id: String, sourceRevision: String, dependencies: [String]) -> ProjectArtifactRecord {
        ProjectArtifactRecord(
            id: id,
            kind: .subtitles,
            path: "/tmp/\(id)",
            language: .ru,
            origin: .source,
            granularity: nil,
            sourceArtifactID: nil,
            sourceRevision: sourceRevision,
            dependencyIDs: dependencies,
            contentHash: nil,
            createdAt: Date(),
            generator: BuildInfo.name,
            generatorVersion: BuildInfo.version,
            model: nil,
            validationStatus: .ready,
            qualityStatus: .ready,
            reviewTaskCount: 0
        )
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw ProbeFailure(message: message) }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw ProbeFailure(message: message) }
        return value
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
