import Foundation

/// Presentation-only mode selection. It is deliberately not persisted in a
/// project manifest, so changing the surface cannot alter project data.
enum ProjectPresentationMode: String, CaseIterable, Identifiable {
    case simple
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simple: return "Простой"
        case .advanced: return "Расширенный"
        }
    }
}

enum SimpleProjectHomeReadiness: Equatable {
    case ready
    case needsReview
    case missing
    case failed

    var title: String {
        switch self {
        case .ready: return "Готово"
        case .needsReview: return "Требуется проверка"
        case .missing: return "Отсутствует"
        case .failed: return "Ошибка"
        }
    }
}

enum SimpleProjectNavigationAction: Equatable {
    case openKnownProjects
    case createFromMedia
    case locateProjectOnDisk

    var usesSystemPicker: Bool {
        switch self {
        case .openKnownProjects: return false
        case .createFromMedia, .locateProjectOnDisk: return true
        }
    }
}

enum SimpleProjectHomeReviewTarget: String, Identifiable, Equatable {
    case source
    case topics
    case translation

    var id: Self { self }

    var checkpointKind: HumanReviewCheckpointKind? {
        switch self {
        case .source: return .sourceTranscript
        case .translation: return .translatedTranscript
        case .topics: return nil
        }
    }
}

struct SimpleProjectHomeArtifact: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case transcription
        case topics
        case translation

        var id: String { rawValue }

        var title: String {
            switch self {
            case .transcription: return "Расшифровка"
            case .topics: return "Темы"
            case .translation: return "Перевод"
            }
        }
    }

    var id: Kind { kind }
    var kind: Kind
    var readiness: SimpleProjectHomeReadiness
    var detail: String
    var language: ArtifactLanguage?
    var topicGranularity: TopicGranularity?
    var openOutputPath: String?
    var reviewTarget: SimpleProjectHomeReviewTarget?

    var displayTitle: String {
        switch kind {
        case .translation:
            guard let language else { return kind.title }
            return "Перевод \(language.rawValue.uppercased())"
        case .topics:
            guard let language, let topicGranularity else { return kind.title }
            return "Темы \(language.rawValue.uppercased()) · \(topicGranularity.title)"
        case .transcription:
            return kind.title
        }
    }
}

/// A deliberately small, presentation-only list item. Simple mode owns this
/// classification so it cannot accidentally expose project-support files from
/// the generic result detector.
struct SimpleProjectHomeResult: Identifiable, Equatable {
    var id: String { path }
    var title: String
    var path: String
    var createdAt: Date
    var isGeneratedMedia: Bool
}

struct SimpleProjectHomeState {
    var projectName: String
    var mediaName: String
    var durationSeconds: TimeInterval?
    var sourceLanguage: ArtifactLanguage?
    var currentState: String
    var artifacts: [SimpleProjectHomeArtifact]
    var recentResults: [SimpleProjectHomeResult]

    func artifact(_ kind: SimpleProjectHomeArtifact.Kind) -> SimpleProjectHomeArtifact {
        artifacts.first(where: { $0.kind == kind })
            ?? SimpleProjectHomeArtifact(
                kind: kind,
                readiness: .missing,
                detail: "Не создан",
                language: nil,
                topicGranularity: nil,
                openOutputPath: nil,
                reviewTarget: nil
            )
    }
}

/// Reads the accepted manifest/revision state and existing discovery output.
/// It owns no workflow or persistence transition.
struct SimpleProjectHomeStateService {
    func make(
        projectURL: URL,
        manifest: ProjectManifest?,
        topicsDetail: String?,
        discoveredOutputs: [ProjectOutput],
        topicLanguage: ArtifactLanguage? = nil,
        topicGranularity: TopicGranularity = .normal
    ) -> SimpleProjectHomeState {
        let mediaName = manifest.map { URL(fileURLWithPath: $0.sourceMediaPath).lastPathComponent }
            ?? projectURL.lastPathComponent
        let sourceLanguage = manifest?.languageProfile?.effective
        let checkpoint = manifest?.humanReviewState?.pendingCheckpoint
        let topicCheckpoint = manifest?.topicReviewState?.pendingCheckpoint

        let transcription = transcriptionState(
            projectURL: projectURL,
            manifest: manifest,
            sourceLanguage: sourceLanguage,
            checkpoint: checkpoint
        )
        let topics = topicsState(
            projectURL: projectURL,
            manifest: manifest,
            checkpoint: topicCheckpoint,
            detail: topicsDetail,
            language: topicLanguage ?? sourceLanguage,
            granularity: topicGranularity
        )
        let translation = translationState(
            projectURL: projectURL,
            manifest: manifest,
            sourceLanguage: sourceLanguage,
            checkpoint: checkpoint
        )

        return SimpleProjectHomeState(
            projectName: projectURL.lastPathComponent,
            mediaName: mediaName,
            durationSeconds: manifest?.durationSeconds,
            sourceLanguage: sourceLanguage,
            currentState: projectState(checkpoint: checkpoint, topicCheckpoint: topicCheckpoint, manifest: manifest),
            artifacts: [transcription, topics, translation],
            recentResults: userFacingResults(
                artifacts: [transcription, topics, translation],
                outputs: discoveredOutputs,
                fragments: manifest?.fragments ?? []
            )
        )
    }

    private func transcriptionState(
        projectURL: URL,
        manifest: ProjectManifest?,
        sourceLanguage: ArtifactLanguage?,
        checkpoint: HumanReviewCheckpoint?
    ) -> SimpleProjectHomeArtifact {
        if let checkpoint, checkpoint.kind == .sourceTranscript,
           checkpoint.language == sourceLanguage {
            return artifact(
                .transcription,
                .needsReview,
                languageDetail(sourceLanguage),
                language: sourceLanguage,
                reviewTarget: .source
            )
        }
        guard let sourceLanguage,
              let revision = manifest?.activeTranscriptRevision(for: sourceLanguage),
              revision.reviewStatus == .approved else {
            if operationFailed(.transcribe, manifest: manifest) {
                return artifact(.transcription, .failed, "Расшифровка не завершена")
            }
            return artifact(.transcription, .missing, "Не создан")
        }
        let openOutputPath = readableTextPath(
            ProjectLayout(root: projectURL).transcriptURL
        )
        guard let openOutputPath else {
            return artifact(.transcription, .missing, "Текст расшифровки недоступен")
        }
        return artifact(
            .transcription,
            .ready,
            languageDetail(sourceLanguage),
            language: sourceLanguage,
            openOutputPath: openOutputPath,
            reviewTarget: .source
        )
    }

    private func topicsState(
        projectURL: URL,
        manifest: ProjectManifest?,
        checkpoint: TopicReviewCheckpoint?,
        detail: String?,
        language: ArtifactLanguage?,
        granularity: TopicGranularity
    ) -> SimpleProjectHomeArtifact {
        if checkpoint != nil {
            return artifact(.topics, .needsReview, "Темы готовы", language: language)
        }
        guard let language else {
            return artifact(.topics, .missing, "Язык тем не определён")
        }
        let variantKey = "\(language.rawValue).\(granularity.rawValue)"
        let hasApprovedTopics = manifest?.topicReviewState?.activeRevisionIDs[variantKey].flatMap { revisionID in
            manifest?.topicRevisions?.first(where: { $0.id == revisionID })
        }.map { $0.status == .approved } ?? false
        guard hasApprovedTopics else {
            if operationFailed(.topicTimecoding, manifest: manifest) {
                return artifact(.topics, .failed, "Темы не созданы", language: language)
            }
            return artifact(.topics, .missing, "Не созданы", language: language)
        }
        guard let openOutputPath = readableTextPath(
            ProjectLayout(root: projectURL).topicsTextURL(language: language, granularity: granularity)
        ) else {
            return artifact(.topics, .missing, "Текст тем недоступен", language: language)
        }
        let detail = detail ?? "Готовы"
        return artifact(
            .topics,
            .ready,
            detail,
            language: language,
            topicGranularity: granularity,
            openOutputPath: openOutputPath
        )
    }

    private func translationState(
        projectURL: URL,
        manifest: ProjectManifest?,
        sourceLanguage: ArtifactLanguage?,
        checkpoint: HumanReviewCheckpoint?
    ) -> SimpleProjectHomeArtifact {
        guard let sourceLanguage else {
            return artifact(.translation, .missing, "Не создан")
        }
        let target = sourceLanguage.translationTarget
        if checkpoint?.kind == .translatedTranscript, checkpoint?.language == target {
            return artifact(
                .translation,
                .needsReview,
                target.russianTitle,
                language: target,
                reviewTarget: .translation
            )
        }
        guard let revision = manifest?.activeTranscriptRevision(for: target),
              revision.reviewStatus == .approved,
              revision.origin == .translated || revision.origin == .userEdited else {
            if operationFailed(.translateTranscript, manifest: manifest) {
                return artifact(.translation, .failed, "Перевод не завершён", language: target)
            }
            return artifact(.translation, .missing, "Не создан", language: target)
        }
        let openOutputPath = readableTextPath(
            ProjectLayout(root: projectURL).transcriptURL(language: target)
        )
        guard let openOutputPath else {
            return artifact(.translation, .missing, "Текст перевода недоступен", language: target)
        }
        return artifact(
            .translation,
            .ready,
            target.russianTitle,
            language: target,
            openOutputPath: openOutputPath,
            reviewTarget: .translation
        )
    }

    private func projectState(
        checkpoint: HumanReviewCheckpoint?,
        topicCheckpoint: TopicReviewCheckpoint?,
        manifest: ProjectManifest?
    ) -> String {
        if let checkpoint {
            switch checkpoint.kind {
            case .sourceTranscript: return "Расшифровка готова — требуется проверка"
            case .translatedTranscript: return "Перевод готов — требуется проверка"
            }
        }
        if topicCheckpoint != nil { return "Темы готовы — требуется проверка" }
        if manifest?.workflow?.status == .failed { return "Требуется внимание" }
        return "Проект готов"
    }

    private func artifact(
        _ kind: SimpleProjectHomeArtifact.Kind,
        _ readiness: SimpleProjectHomeReadiness,
        _ detail: String,
        language: ArtifactLanguage? = nil,
        topicGranularity: TopicGranularity? = nil,
        openOutputPath: String? = nil,
        reviewTarget: SimpleProjectHomeReviewTarget? = nil
    ) -> SimpleProjectHomeArtifact {
        SimpleProjectHomeArtifact(
            kind: kind,
            readiness: readiness,
            detail: detail,
            language: language,
            topicGranularity: topicGranularity,
            openOutputPath: openOutputPath,
            reviewTarget: reviewTarget
        )
    }

    private func languageDetail(_ language: ArtifactLanguage?) -> String {
        language?.russianTitle ?? "Язык не определён"
    }

    private func operationFailed(_ operation: WorkflowOperation, manifest: ProjectManifest?) -> Bool {
        manifest?.workflow?.operations[operation.rawValue]?.status == .failed
    }

    private func readableTextPath(_ expectedURL: URL) -> String? {
        guard let text = try? String(contentsOf: expectedURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return expectedURL.path
    }

    private func userFacingResults(
        artifacts: [SimpleProjectHomeArtifact],
        outputs: [ProjectOutput],
        fragments: [FragmentRecord]
    ) -> [SimpleProjectHomeResult] {
        let readableArtifacts = artifacts.compactMap { artifact -> SimpleProjectHomeResult? in
            guard artifact.readiness == .ready, let path = artifact.openOutputPath else { return nil }
            return SimpleProjectHomeResult(
                title: artifact.displayTitle,
                path: path,
                createdAt: fileDate(at: path),
                isGeneratedMedia: false
            )
        }
        // A fragment is one user-facing result even when its persisted record
        // has technical source, subtitled, and processed media paths. Prefer its
        // finished representation, then retain all other generated media from
        // discovery. This reconciles an opened project's manifest with a fresh
        // result scan without adding or changing any persisted result record.
        let fragmentPaths = Set(fragments.flatMap { fragment in
            [fragment.videoPath, fragment.subtitledVideoPath, fragment.processedVideoPath].compactMap { $0 }
        })
        let discoveredMedia = outputs
            .filter { $0.isGeneratedMedia && !fragmentPaths.contains($0.path) && isNonemptyFile(at: $0.path) }
            .map { output in
                SimpleProjectHomeResult(
                    title: output.title,
                    path: output.path,
                    createdAt: output.createdAt,
                    isGeneratedMedia: true
                )
            }
        let persistedFragments = fragments.compactMap(fragmentResult)
        return Dictionary(grouping: readableArtifacts + discoveredMedia + persistedFragments, by: \.path)
            .compactMap { $0.value.first }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(6)
            .map { $0 }
    }

    private func fragmentResult(_ fragment: FragmentRecord) -> SimpleProjectHomeResult? {
        let candidates: [(path: String?, kind: String)] = [
            (fragment.processedVideoPath, "processed-fragment-video"),
            (fragment.subtitledVideoPath, fragment.language.map { "fragment-subtitled-video-\($0.rawValue)" } ?? "fragment-subtitled-video"),
            (fragment.videoPath, "fragment-video")
        ]
        guard let candidate = candidates.first(where: { path, _ in
            path.map(isNonemptyFile) == true
        }), let path = candidate.path else {
            return nil
        }
        return SimpleProjectHomeResult(
            title: ProjectOutput(id: path, kind: candidate.kind, path: path, createdAt: fragment.createdAt).title,
            path: path,
            createdAt: fragment.createdAt,
            isGeneratedMedia: true
        )
    }

    private func fileDate(at path: String) -> Date {
        let url = URL(fileURLWithPath: path)
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func isNonemptyFile(at path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }
}
