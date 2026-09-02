import Foundation

struct ReviewResolution {
    var revision: TranscriptRevision
    var tasks: [ReviewTask]
    var cues: [SubtitleCue]
}

struct ReviewTaskService {
    let store: ProjectStore
    let srt = SRTService()
    let quality = TranscriptionQualityService()

    init(store: ProjectStore = ProjectStore()) {
        self.store = store
    }

    func resolve(projectURL: URL, taskID: String, replacementText: String) throws -> ReviewResolution {
        let replacement = replacementText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty else {
            throw WorkflowError.processFailed("Исправленный текст не может быть пустым.")
        }
        let layout = ProjectLayout(root: projectURL)
        var manifest = try store.load(from: projectURL)
        guard var tasks = manifest.reviewTasks,
              let taskIndex = tasks.firstIndex(where: { $0.id == taskID }) else {
            throw WorkflowError.processFailed("Задание ручной проверки не найдено.")
        }
        let task = tasks[taskIndex]
        guard task.status == .needsReview else {
            throw WorkflowError.processFailed("Задание ручной проверки уже закрыто.")
        }
        guard task.cueIDs.count == 1, let cueID = task.cueIDs.first else {
            throw WorkflowError.processFailed("Автоматическое редактирование поддерживает одно cue на задание.")
        }
        let editsSourceLanguage = manifest.languageProfile?.effective == task.language
        let workingSRTURL = editsSourceLanguage ? layout.fullSRTURL : layout.subtitlesURL(language: task.language)
        var cues = try srt.load(from: workingSRTURL)
        guard let cueIndex = cues.firstIndex(where: { $0.id == cueID }) else {
            throw WorkflowError.processFailed("Cue \(cueID) из задания не найден в текущем SRT.")
        }

        let parentRevision = manifest.transcriptRevisions?.first(where: { $0.id == task.transcriptRevisionID })
        try preserveParentRevisionIfNeeded(
            parentRevision,
            language: task.language,
            layout: layout
        )

        cues[cueIndex].text = replacement
        try srt.writePreservingIDs(cues, to: workingSRTURL)
        try srt.writePreservingIDs(cues, to: layout.subtitlesURL(language: task.language))
        let transcript = cues.map(\.text).joined(separator: "\n\n") + "\n"
        if editsSourceLanguage {
            try transcript.write(to: layout.transcriptURL, atomically: true, encoding: .utf8)
        }
        try transcript.write(to: layout.transcriptURL(language: task.language), atomically: true, encoding: .utf8)

        let srtText = try String(contentsOf: workingSRTURL, encoding: .utf8)
        let contentHash = StableTopicHash.string(srtText)
        let revisionID = "transcript-\(task.language.rawValue)-user-\(contentHash)"
        let transcriptArtifactID = "artifact-\(revisionID)-txt"
        let subtitleArtifactID = "artifact-\(revisionID)-srt"
        let revisionTranscriptURL = layout.transcriptRevisionURL(id: revisionID, language: task.language)
        let revisionSubtitleURL = layout.subtitleRevisionURL(id: revisionID, language: task.language)
        try Data(contentsOf: layout.transcriptURL(language: task.language)).write(to: revisionTranscriptURL, options: .atomic)
        try Data(contentsOf: layout.subtitlesURL(language: task.language)).write(to: revisionSubtitleURL, options: .atomic)

        let revision = TranscriptRevision(
            id: revisionID,
            language: task.language,
            origin: .userEdited,
            parentRevisionID: task.transcriptRevisionID,
            transcriptArtifactID: transcriptArtifactID,
            subtitleArtifactID: subtitleArtifactID,
            contentHash: contentHash,
            createdAt: Date()
        )
        tasks[taskIndex].status = .resolved
        tasks[taskIndex].resolvedAt = Date()

        var revisions = manifest.transcriptRevisions ?? []
        revisions.removeAll { $0.id == revision.id }
        revisions.append(revision)
        manifest.transcriptRevisions = revisions
        manifest.reviewTasks = tasks
        var artifacts = manifest.artifacts ?? []
        for index in artifacts.indices where
            artifacts[index].sourceRevision == task.transcriptRevisionID
            || !Set(artifacts[index].dependencyIDs).isDisjoint(with: task.dependentArtifactIDs) {
            artifacts[index].validationStatus = .pending
        }
        artifacts.removeAll { $0.id == transcriptArtifactID || $0.id == subtitleArtifactID }
        artifacts.append(makeArtifact(
            id: transcriptArtifactID,
            kind: .transcript,
            path: revisionTranscriptURL.path,
            language: task.language,
            revisionID: revisionID,
            sourceArtifactID: parentRevision?.transcriptArtifactID,
            dependencyIDs: [task.transcriptRevisionID],
            contentHash: StableTopicHash.string(transcript)
        ))
        artifacts.append(makeArtifact(
            id: subtitleArtifactID,
            kind: .subtitles,
            path: revisionSubtitleURL.path,
            language: task.language,
            revisionID: revisionID,
            sourceArtifactID: transcriptArtifactID,
            dependencyIDs: [transcriptArtifactID],
            contentHash: contentHash
        ))
        manifest.artifacts = artifacts
        try store.save(manifest, to: projectURL)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(tasks).write(to: layout.reviewTasksURL, options: .atomic)
        let unresolved = tasks.filter { $0.status == .needsReview && $0.language == task.language }
        try quality.renderHTML(cues: cues, tasks: unresolved, language: task.language)
            .write(to: layout.transcriptReviewHTMLURL, atomically: true, encoding: .utf8)
        return ReviewResolution(revision: revision, tasks: tasks, cues: cues)
    }

    private func preserveParentRevisionIfNeeded(
        _ revision: TranscriptRevision?,
        language: ArtifactLanguage,
        layout: ProjectLayout
    ) throws {
        guard let revision else { return }
        let transcriptURL = layout.transcriptRevisionURL(id: revision.id, language: language)
        let subtitleURL = layout.subtitleRevisionURL(id: revision.id, language: language)
        if !FileManager.default.fileExists(atPath: transcriptURL.path) {
            try Data(contentsOf: layout.transcriptURL(language: language)).write(to: transcriptURL, options: .atomic)
        }
        if !FileManager.default.fileExists(atPath: subtitleURL.path) {
            try Data(contentsOf: layout.subtitlesURL(language: language)).write(to: subtitleURL, options: .atomic)
        }
    }

    private func makeArtifact(
        id: String,
        kind: ProjectArtifactRecordKind,
        path: String,
        language: ArtifactLanguage,
        revisionID: String,
        sourceArtifactID: String?,
        dependencyIDs: [String],
        contentHash: String
    ) -> ProjectArtifactRecord {
        ProjectArtifactRecord(
            id: id,
            kind: kind,
            path: path,
            language: language,
            origin: .userEdited,
            granularity: nil,
            sourceArtifactID: sourceArtifactID,
            sourceRevision: revisionID,
            dependencyIDs: dependencyIDs,
            contentHash: contentHash,
            createdAt: Date(),
            generator: BuildInfo.name,
            generatorVersion: BuildInfo.version,
            model: "manual-review",
            validationStatus: .ready,
            qualityStatus: .pending,
            reviewTaskCount: 0
        )
    }
}
