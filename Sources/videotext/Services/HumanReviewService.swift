import Foundation

struct HumanReviewApproval {
    var revision: TranscriptRevision
    var pendingOperations: [WorkflowOperation]
    var cues: [SubtitleCue]
}

struct HumanReviewService {
    let store: ProjectStore
    let srt = SRTService()

    init(store: ProjectStore = ProjectStore()) {
        self.store = store
    }

    func beginReview(
        projectURL: URL,
        language: ArtifactLanguage,
        pendingOperations: [WorkflowOperation] = []
    ) throws -> HumanReviewCheckpoint {
        var created: HumanReviewCheckpoint?
        try store.mutate(projectURL) { manifest in
            var state = manifest.humanReviewState ?? .newProjectDefault
            guard state.pendingCheckpoint == nil else {
                throw WorkflowError.processFailed("Human Review уже выполняется.")
            }
            guard let revision = manifest.activeTranscriptRevision(for: language)
                ?? manifest.transcriptRevisions?.last(where: { $0.language == language }) else {
                throw WorkflowError.processFailed("Для выбранного языка нет расшифровки, доступной для Human Review.")
            }
            let sourceLanguage = manifest.languageProfile?.effective
            let checkpoint = HumanReviewCheckpoint(
                kind: sourceLanguage == language ? .sourceTranscript : .translatedTranscript,
                language: language,
                revisionID: revision.id,
                pendingOperations: pendingOperations,
                createdAt: Date()
            )
            if checkpoint.kind == .sourceTranscript {
                state.sourceReviewEnabled = true
            } else {
                state.translationReviewEnabled = true
            }
            state.pendingCheckpoint = checkpoint
            manifest.humanReviewState = state
            manifest.workflow?.status = .awaitingReview
            created = checkpoint
        }
        guard let created else {
            throw WorkflowError.processFailed("Не удалось начать Human Review.")
        }
        return created
    }

    func transitionAfterGeneration(
        projectURL: URL,
        kind: HumanReviewCheckpointKind,
        language: ArtifactLanguage,
        revisionID: String,
        pendingOperations: [WorkflowOperation],
        sourceReviewEnabled: Bool,
        translationReviewEnabled: Bool
    ) throws -> HumanReviewCheckpoint? {
        var checkpoint: HumanReviewCheckpoint?
        try store.mutate(projectURL) { manifest in
            var state = manifest.humanReviewState ?? .newProjectDefault
            state.sourceReviewEnabled = sourceReviewEnabled
            state.translationReviewEnabled = translationReviewEnabled
            let enabled = kind == .sourceTranscript ? sourceReviewEnabled : translationReviewEnabled
            var revisions = manifest.transcriptRevisions ?? []
            guard let index = revisions.firstIndex(where: { $0.id == revisionID }) else {
                throw WorkflowError.processFailed("Ревизия для Human Review не найдена: \(revisionID).")
            }

            if !enabled {
                let hasUnresolvedTranslationTasks = kind == .translatedTranscript
                    && (manifest.reviewTasks ?? []).contains { task in
                        task.transcriptRevisionID == revisionID && task.status == .needsReview
                    }
                guard !hasUnresolvedTranslationTasks else {
                    throw WorkflowError.processFailed(
                        "Перевод содержит непроверенные или неполученные реплики и не может быть автоматически утверждён. Включите Human Review либо повторите перевод."
                    )
                }
                revisions[index].reviewStatus = .approved
                state.activeRevisionIDs[language.rawValue] = revisionID
                state.pendingCheckpoint = nil
                var artifacts = manifest.artifacts ?? []
                for artifactIndex in artifacts.indices where artifacts[artifactIndex].sourceRevision == revisionID {
                    artifacts[artifactIndex].validationStatus = .ready
                }
                manifest.artifacts = artifacts
            } else if state.activeRevisionIDs[language.rawValue] != revisionID
                        || revisions[index].reviewStatus != .approved {
                if revisions[index].reviewStatus != .draft {
                    revisions[index].reviewStatus = .pending
                }
                let value = HumanReviewCheckpoint(
                    kind: kind,
                    language: language,
                    revisionID: revisionID,
                    pendingOperations: pendingOperations,
                    createdAt: Date()
                )
                state.pendingCheckpoint = value
                checkpoint = value
                var artifacts = manifest.artifacts ?? []
                for artifactIndex in artifacts.indices where artifacts[artifactIndex].sourceRevision == revisionID {
                    artifacts[artifactIndex].validationStatus = .needsReview
                }
                manifest.artifacts = artifacts
            }
            manifest.transcriptRevisions = revisions
            manifest.humanReviewState = state
        }
        return checkpoint
    }

    func saveDraftCue(
        projectURL: URL,
        language: ArtifactLanguage,
        cueID: Int,
        replacementText: String
    ) throws -> [SubtitleCue] {
        let replacement = replacementText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty else {
            throw WorkflowError.processFailed("Исправленный текст не может быть пустым.")
        }
        let layout = ProjectLayout(root: projectURL)
        var manifest = try store.load(from: projectURL)
        guard let checkpoint = manifest.humanReviewState?.pendingCheckpoint,
              checkpoint.language == language else {
            throw WorkflowError.processFailed("Для выбранного языка нет активного Human Review.")
        }
        let workingSRT = workingSubtitleURL(manifest: manifest, language: language, layout: layout)
        var cues = try srt.load(from: workingSRT)
        guard let index = cues.firstIndex(where: { $0.id == cueID }) else {
            throw WorkflowError.processFailed("Cue \(cueID) не найден в текущей расшифровке.")
        }
        cues[index].text = replacement
        try validateTimeline(cues, againstRevisionID: checkpoint.revisionID, language: language, layout: layout)
        try writeWorkingFiles(cues, manifest: manifest, language: language, layout: layout)

        let subtitleText = try String(contentsOf: layout.subtitlesURL(language: language), encoding: .utf8)
        let hash = StableTopicHash.string("\(checkpoint.revisionID)|\(subtitleText)")
        let revisionID = "transcript-\(language.rawValue)-draft-\(hash)"
        let revision = try persistRevision(
            id: revisionID,
            origin: .userEdited,
            status: .draft,
            parentRevisionID: checkpoint.revisionID,
            language: language,
            cues: cues,
            layout: layout
        )

        var revisions = manifest.transcriptRevisions ?? []
        revisions.removeAll { $0.id == revisionID }
        revisions.append(revision)
        manifest.transcriptRevisions = revisions
        var state = manifest.humanReviewState ?? .newProjectDefault
        state.draftRevisionIDs[language.rawValue] = revisionID
        manifest.humanReviewState = state
        var tasks = manifest.reviewTasks ?? []
        for taskIndex in tasks.indices where tasks[taskIndex].transcriptRevisionID == checkpoint.revisionID
            && tasks[taskIndex].language == language
            && tasks[taskIndex].cueIDs.contains(cueID)
            && tasks[taskIndex].status == .needsReview {
            tasks[taskIndex].status = .resolved
            tasks[taskIndex].resolvedAt = Date()
        }
        manifest.reviewTasks = tasks
        try store.save(manifest, to: projectURL)
        try writeReviewTasks(tasks, to: layout.reviewTasksURL)
        return cues
    }

    func approve(projectURL: URL) throws -> HumanReviewApproval {
        let layout = ProjectLayout(root: projectURL)
        var manifest = try store.load(from: projectURL)
        guard let checkpoint = manifest.humanReviewState?.pendingCheckpoint else {
            throw WorkflowError.processFailed("Нет расшифровки, ожидающей утверждения.")
        }
        let language = checkpoint.language
        if (manifest.reviewTasks ?? []).contains(where: {
            $0.transcriptRevisionID == checkpoint.revisionID
                && $0.status == .needsReview
                && $0.reasonCodes.contains("automatic-retranscription-required")
        }) {
            throw WorkflowError.processFailed("Расшифровка содержит критическую ошибку и требует повторной расшифровки; Human Review не может утвердить этот результат.")
        }
        let workingSRT = workingSubtitleURL(manifest: manifest, language: language, layout: layout)
        let cues = try srt.load(from: workingSRT)
        try validateTimeline(cues, againstRevisionID: checkpoint.revisionID, language: language, layout: layout)
        try writeWorkingFiles(cues, manifest: manifest, language: language, layout: layout)

        let subtitleText = try String(contentsOf: layout.subtitlesURL(language: language), encoding: .utf8)
        let hash = StableTopicHash.string("\(checkpoint.revisionID)|approved|\(subtitleText)")
        let revisionID = "transcript-\(language.rawValue)-approved-\(hash)"
        let revision = try persistRevision(
            id: revisionID,
            origin: .userEdited,
            status: .approved,
            parentRevisionID: manifest.humanReviewState?.draftRevisionIDs[language.rawValue] ?? checkpoint.revisionID,
            language: language,
            cues: cues,
            layout: layout
        )

        var revisions = manifest.transcriptRevisions ?? []
        for index in revisions.indices where revisions[index].language == language
            && (revisions[index].reviewStatus == .pending || revisions[index].reviewStatus == .draft) {
            revisions[index].reviewStatus = .superseded
        }
        revisions.removeAll { $0.id == revisionID }
        revisions.append(revision)
        manifest.transcriptRevisions = revisions

        var state = manifest.humanReviewState ?? .newProjectDefault
        let previousActiveRevisionID = state.activeRevisionIDs[language.rawValue]
        state.activeRevisionIDs[language.rawValue] = revisionID
        state.draftRevisionIDs.removeValue(forKey: language.rawValue)
        state.pendingCheckpoint = nil
        manifest.humanReviewState = state

        var tasks = manifest.reviewTasks ?? []
        for index in tasks.indices where tasks[index].transcriptRevisionID == checkpoint.revisionID
            && tasks[index].status == .needsReview {
            tasks[index].status = .resolved
            tasks[index].resolvedAt = Date()
        }
        manifest.reviewTasks = tasks
        manifest.workflow?.status = checkpoint.pendingOperations.isEmpty ? .completed : .ready
        if checkpoint.pendingOperations.isEmpty {
            manifest.workflow?.progress = 1
            manifest.workflow?.lastError = nil
        }
        markDependentArtifactsPending(&manifest, replacedRevisionID: checkpoint.revisionID)
        if let previousActiveRevisionID, previousActiveRevisionID != checkpoint.revisionID {
            markDependentArtifactsPending(&manifest, replacedRevisionID: previousActiveRevisionID)
        }
        appendRevisionArtifacts(revision, manifest: &manifest, layout: layout)
        try store.save(manifest, to: projectURL)
        try writeReviewTasks(tasks, to: layout.reviewTasksURL)
        return HumanReviewApproval(revision: revision, pendingOperations: checkpoint.pendingOperations, cues: cues)
    }

    private func validateTimeline(
        _ cues: [SubtitleCue],
        againstRevisionID revisionID: String,
        language: ArtifactLanguage,
        layout: ProjectLayout
    ) throws {
        let baselineURL = layout.subtitleRevisionURL(id: revisionID, language: language)
        guard FileManager.default.fileExists(atPath: baselineURL.path) else {
            throw WorkflowError.processFailed("Не найден базовый SRT Human Review.")
        }
        let baseline = try srt.load(from: baselineURL)
        guard cues.count == baseline.count else {
            throw WorkflowError.invalidSRT("Human Review не может добавлять или удалять cue.")
        }
        for (edited, source) in zip(cues, baseline) {
            guard edited.id == source.id,
                  abs(edited.start - source.start) <= 0.001,
                  abs(edited.end - source.end) <= 0.001 else {
                throw WorkflowError.invalidSRT("Human Review изменил cue ID или таймкод cue \(source.id).")
            }
            guard !edited.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowError.invalidSRT("После Human Review cue \(edited.id) остался пустым.")
            }
        }
    }

    private func workingSubtitleURL(
        manifest: ProjectManifest,
        language: ArtifactLanguage,
        layout: ProjectLayout
    ) -> URL {
        manifest.languageProfile?.effective == language ? layout.fullSRTURL : layout.subtitlesURL(language: language)
    }

    private func writeWorkingFiles(
        _ cues: [SubtitleCue],
        manifest: ProjectManifest,
        language: ArtifactLanguage,
        layout: ProjectLayout
    ) throws {
        try srt.writePreservingIDs(cues, to: layout.subtitlesURL(language: language))
        if manifest.languageProfile?.effective == language {
            try srt.writePreservingIDs(cues, to: layout.fullSRTURL)
        }
        let transcript = cues.map(\.text).joined(separator: "\n\n") + "\n"
        try transcript.write(to: layout.transcriptURL(language: language), atomically: true, encoding: .utf8)
        if manifest.languageProfile?.effective == language {
            try transcript.write(to: layout.transcriptURL, atomically: true, encoding: .utf8)
        }
    }

    private func persistRevision(
        id: String,
        origin: TranscriptRevisionOrigin,
        status: TranscriptReviewStatus,
        parentRevisionID: String,
        language: ArtifactLanguage,
        cues: [SubtitleCue],
        layout: ProjectLayout
    ) throws -> TranscriptRevision {
        let transcriptURL = layout.transcriptRevisionURL(id: id, language: language)
        let subtitleURL = layout.subtitleRevisionURL(id: id, language: language)
        try srt.writePreservingIDs(cues, to: subtitleURL)
        let transcript = cues.map(\.text).joined(separator: "\n\n") + "\n"
        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
        return TranscriptRevision(
            id: id,
            language: language,
            origin: origin,
            parentRevisionID: parentRevisionID,
            transcriptArtifactID: "artifact-\(id)-txt",
            subtitleArtifactID: "artifact-\(id)-srt",
            contentHash: StableTopicHash.string(try String(contentsOf: subtitleURL, encoding: .utf8)),
            createdAt: Date(),
            reviewStatus: status
        )
    }

    private func markDependentArtifactsPending(_ manifest: inout ProjectManifest, replacedRevisionID: String) {
        var artifacts = manifest.artifacts ?? []
        var invalidatedIDs: Set<String> = [replacedRevisionID]
        var changed = true
        while changed {
            changed = false
            for artifact in artifacts where artifact.sourceRevision == replacedRevisionID
                || !Set(artifact.dependencyIDs).isDisjoint(with: invalidatedIDs) {
                if invalidatedIDs.insert(artifact.id).inserted {
                    changed = true
                }
            }
        }
        for index in artifacts.indices where invalidatedIDs.contains(artifacts[index].id) {
            artifacts[index].validationStatus = .pending
        }
        manifest.artifacts = artifacts
    }

    private func appendRevisionArtifacts(
        _ revision: TranscriptRevision,
        manifest: inout ProjectManifest,
        layout: ProjectLayout
    ) {
        var artifacts = manifest.artifacts ?? []
        let origin: ArtifactOrigin = revision.origin == .translated ? .translated : .userEdited
        artifacts.removeAll { $0.id == revision.transcriptArtifactID || $0.id == revision.subtitleArtifactID }
        artifacts.append(ProjectArtifactRecord(
            id: revision.transcriptArtifactID,
            kind: .transcript,
            path: layout.transcriptRevisionURL(id: revision.id, language: revision.language).path,
            language: revision.language,
            origin: origin,
            granularity: nil,
            sourceArtifactID: nil,
            sourceRevision: revision.id,
            dependencyIDs: [revision.parentRevisionID].compactMap { $0 },
            contentHash: revision.contentHash,
            createdAt: revision.createdAt,
            generator: BuildInfo.name,
            generatorVersion: BuildInfo.version,
            model: "human-review",
            validationStatus: .ready,
            qualityStatus: .ready,
            reviewTaskCount: 0
        ))
        artifacts.append(ProjectArtifactRecord(
            id: revision.subtitleArtifactID,
            kind: .subtitles,
            path: layout.subtitleRevisionURL(id: revision.id, language: revision.language).path,
            language: revision.language,
            origin: origin,
            granularity: nil,
            sourceArtifactID: revision.transcriptArtifactID,
            sourceRevision: revision.id,
            dependencyIDs: [revision.transcriptArtifactID],
            contentHash: revision.contentHash,
            createdAt: revision.createdAt,
            generator: BuildInfo.name,
            generatorVersion: BuildInfo.version,
            model: "human-review",
            validationStatus: .ready,
            qualityStatus: .ready,
            reviewTaskCount: 0
        ))
        manifest.artifacts = artifacts
    }

    private func writeReviewTasks(_ tasks: [ReviewTask], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(tasks).write(to: url, options: .atomic)
    }
}
