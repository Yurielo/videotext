import Foundation

struct TopicReviewApproval {
    var revisions: [TopicRevision]
    var pendingOperations: [WorkflowOperation]
}

struct TopicReviewService {
    private let store: ProjectStore
    private let srt = SRTService()
    private let validator = TopicValidator()

    init(store: ProjectStore = ProjectStore()) {
        self.store = store
    }

    func beginReview(
        projectURL: URL,
        pendingOperations: [WorkflowOperation] = [],
        enabled: Bool = true,
        force: Bool = false
    ) throws -> TopicReviewCheckpoint? {
        let layout = ProjectLayout(root: projectURL)
        var manifest = try store.load(from: projectURL)
        var state = manifest.topicReviewState ?? .newProjectDefault
        state.enabled = enabled
        guard state.pendingCheckpoint == nil else { return state.pendingCheckpoint }

        let variants = try availableVariants(layout: layout)
        guard !variants.isEmpty else { throw WorkflowError.missingTopics }
        if !force && variants.allSatisfy({ variant in
            guard let activeID = state.activeRevisionIDs[variant.key],
                  let revision = manifest.topicRevisions?.first(where: { $0.id == activeID }) else { return false }
            return revision.contentHash == variant.hash
        }) {
            manifest.topicReviewState = state
            try store.save(manifest, to: projectURL)
            return nil
        }

        var revisions = manifest.topicRevisions ?? []
        var checkpointIDs: [String: String] = [:]
        for variant in variants {
            let revision = try snapshot(
                variant: variant,
                status: enabled ? .pending : .approved,
                parentRevisionID: state.activeRevisionIDs[variant.key],
                layout: layout
            )
            revisions.append(revision)
            checkpointIDs[variant.key] = revision.id
            if !enabled { state.activeRevisionIDs[variant.key] = revision.id }
        }
        manifest.topicRevisions = revisions

        guard enabled else {
            state.pendingCheckpoint = nil
            manifest.topicReviewState = state
            try store.save(manifest, to: projectURL)
            return nil
        }

        let checkpoint = TopicReviewCheckpoint(
            revisionIDs: checkpointIDs,
            pendingOperations: pendingOperations,
            createdAt: Date()
        )
        state.pendingCheckpoint = checkpoint
        manifest.topicReviewState = state
        manifest.workflow?.status = .awaitingReview
        try store.save(manifest, to: projectURL)
        return checkpoint
    }

    func approve(projectURL: URL) throws -> TopicReviewApproval {
        let layout = ProjectLayout(root: projectURL)
        var manifest = try store.load(from: projectURL)
        guard let checkpoint = manifest.topicReviewState?.pendingCheckpoint else {
            throw WorkflowError.processFailed("Нет тематического таймкодинга, ожидающего утверждения.")
        }

        var state = manifest.topicReviewState ?? .newProjectDefault
        var revisions = manifest.topicRevisions ?? []
        var validated: [(key: String, baselineID: String, variant: Variant)] = []
        for (key, baselineID) in checkpoint.revisionIDs.sorted(by: { $0.key < $1.key }) {
            guard let baseline = revisions.first(where: { $0.id == baselineID }) else {
                throw WorkflowError.invalidTopics("не найдена исходная topic-ревизия \(baselineID).")
            }
            let jsonURL = layout.topicsURL(language: baseline.language, granularity: baseline.granularity)
            let file = try decodeTopics(jsonURL)
            try validate(file, language: baseline.language, projectURL: projectURL, manifest: manifest)
            validated.append((
                key: key,
                baselineID: baselineID,
                variant: try variant(
                    language: baseline.language,
                    granularity: baseline.granularity,
                    layout: layout
                )
            ))
        }

        var approved: [TopicRevision] = []
        for item in validated {
            let revision = try snapshot(
                variant: item.variant,
                status: .approved,
                parentRevisionID: item.baselineID,
                layout: layout
            )
            for index in revisions.indices where revisions[index].variantKey == item.key
                && revisions[index].status != .superseded {
                revisions[index].status = .superseded
            }
            revisions.append(revision)
            state.activeRevisionIDs[item.key] = revision.id
            approved.append(revision)
        }
        state.pendingCheckpoint = nil
        manifest.topicRevisions = revisions
        manifest.topicReviewState = state
        manifest.workflow?.status = checkpoint.pendingOperations.isEmpty ? .completed : .ready
        if checkpoint.pendingOperations.isEmpty {
            manifest.workflow?.progress = 1
            manifest.workflow?.lastError = nil
        }
        try store.save(manifest, to: projectURL)
        return TopicReviewApproval(revisions: approved, pendingOperations: checkpoint.pendingOperations)
    }

    private func availableVariants(layout: ProjectLayout) throws -> [Variant] {
        try ArtifactLanguage.allCases.flatMap { language in
            try TopicGranularity.allCases.compactMap { granularity in
                let url = layout.topicsURL(language: language, granularity: granularity)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return try variant(language: language, granularity: granularity, layout: layout)
            }
        }
    }

    private func variant(
        language: ArtifactLanguage,
        granularity: TopicGranularity,
        layout: ProjectLayout
    ) throws -> Variant {
        let jsonURL = layout.topicsURL(language: language, granularity: granularity)
        let textURL = layout.topicsTextURL(language: language, granularity: granularity)
        let data = try Data(contentsOf: jsonURL)
        return Variant(
            language: language,
            granularity: granularity,
            jsonURL: jsonURL,
            textURL: textURL,
            hash: StableTopicHash.string(String(decoding: data, as: UTF8.self))
        )
    }

    private func snapshot(
        variant: Variant,
        status: TopicRevisionStatus,
        parentRevisionID: String?,
        layout: ProjectLayout
    ) throws -> TopicRevision {
        try FileManager.default.createDirectory(at: layout.topicRevisionsDirectory, withIntermediateDirectories: true)
        let id = "topics-\(variant.key)-\(status.rawValue)-\(UUID().uuidString.lowercased())"
        let jsonTarget = layout.topicRevisionJSONURL(id: id)
        let textTarget = layout.topicRevisionTextURL(id: id)
        try Data(contentsOf: variant.jsonURL).write(to: jsonTarget, options: .atomic)
        if FileManager.default.fileExists(atPath: variant.textURL.path) {
            try Data(contentsOf: variant.textURL).write(to: textTarget, options: .atomic)
        } else {
            try Data().write(to: textTarget, options: .atomic)
        }
        return TopicRevision(
            id: id,
            language: variant.language,
            granularity: variant.granularity,
            parentRevisionID: parentRevisionID,
            jsonPath: jsonTarget.path,
            textPath: textTarget.path,
            contentHash: variant.hash,
            status: status,
            createdAt: Date()
        )
    }

    private func validate(
        _ file: TopicsFile,
        language: ArtifactLanguage,
        projectURL: URL,
        manifest: ProjectManifest
    ) throws {
        let cues = try srt.load(from: ProjectLayout(root: projectURL).subtitlesURL(language: language))
        let meaningfulIDs = Set(TopicTextPreprocessor().prepare(cues).flatMap(\.cueIDs))
        let meaningful = cues.filter { meaningfulIDs.contains($0.id) }
        let issues = validator.validate(file, expectedCues: meaningful, mediaDuration: manifest.durationSeconds)
        guard issues.isEmpty else { throw WorkflowError.invalidTopics(issues.joined(separator: " ")) }
    }

    private func decodeTopics(_ url: URL) throws -> TopicsFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TopicsFile.self, from: Data(contentsOf: url))
    }

    private struct Variant {
        var language: ArtifactLanguage
        var granularity: TopicGranularity
        var jsonURL: URL
        var textURL: URL
        var hash: String
        var key: String { "\(language.rawValue).\(granularity.rawValue)" }
    }
}
