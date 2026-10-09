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

enum SimpleProjectHomeReviewTarget: Equatable {
    case source
    case topics
    case translation
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
    var openOutputPath: String?
    var reviewTarget: SimpleProjectHomeReviewTarget?
}

struct SimpleProjectHomeState {
    var projectName: String
    var mediaName: String
    var durationSeconds: TimeInterval?
    var sourceLanguage: ArtifactLanguage?
    var currentState: String
    var artifacts: [SimpleProjectHomeArtifact]
    var recentResults: [ProjectOutput]

    func artifact(_ kind: SimpleProjectHomeArtifact.Kind) -> SimpleProjectHomeArtifact {
        artifacts.first(where: { $0.kind == kind })
            ?? SimpleProjectHomeArtifact(
                kind: kind,
                readiness: .missing,
                detail: "Не создан",
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
        topicsAreViewable: Bool,
        discoveredOutputs: [ProjectOutput]
    ) -> SimpleProjectHomeState {
        let mediaName = manifest.map { URL(fileURLWithPath: $0.sourceMediaPath).lastPathComponent }
            ?? projectURL.lastPathComponent
        let sourceLanguage = manifest?.languageProfile?.effective
        let checkpoint = manifest?.humanReviewState?.pendingCheckpoint
        let topicCheckpoint = manifest?.topicReviewState?.pendingCheckpoint

        return SimpleProjectHomeState(
            projectName: projectURL.lastPathComponent,
            mediaName: mediaName,
            durationSeconds: manifest?.durationSeconds,
            sourceLanguage: sourceLanguage,
            currentState: projectState(checkpoint: checkpoint, topicCheckpoint: topicCheckpoint, manifest: manifest),
            artifacts: [
                transcriptionState(
                    manifest: manifest,
                    sourceLanguage: sourceLanguage,
                    checkpoint: checkpoint,
                    outputs: discoveredOutputs
                ),
                topicsState(
                    manifest: manifest,
                    checkpoint: topicCheckpoint,
                    detail: topicsDetail,
                    isViewable: topicsAreViewable,
                    outputs: discoveredOutputs
                ),
                translationState(
                    manifest: manifest,
                    sourceLanguage: sourceLanguage,
                    checkpoint: checkpoint,
                    outputs: discoveredOutputs
                )
            ],
            recentResults: discoveredOutputs
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(6)
                .map { $0 }
        )
    }

    private func transcriptionState(
        manifest: ProjectManifest?,
        sourceLanguage: ArtifactLanguage?,
        checkpoint: HumanReviewCheckpoint?,
        outputs: [ProjectOutput]
    ) -> SimpleProjectHomeArtifact {
        if checkpoint?.kind == .sourceTranscript {
            return artifact(
                .transcription,
                .needsReview,
                languageDetail(sourceLanguage),
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
        let openOutputPath = firstPath(in: outputs, kinds: ["transcript", "full-srt"])
        guard let openOutputPath else {
            return artifact(.transcription, .missing, "Файлы расшифровки недоступны")
        }
        return artifact(
            .transcription,
            .ready,
            languageDetail(sourceLanguage),
            openOutputPath: openOutputPath
        )
    }

    private func topicsState(
        manifest: ProjectManifest?,
        checkpoint: TopicReviewCheckpoint?,
        detail: String?,
        isViewable: Bool,
        outputs: [ProjectOutput]
    ) -> SimpleProjectHomeArtifact {
        if checkpoint != nil {
            return artifact(.topics, .needsReview, "Темы готовы", reviewTarget: .topics)
        }
        let hasApprovedTopics = manifest?.topicReviewState?.activeRevisionIDs.values.contains { revisionID in
            manifest?.topicRevisions?.contains {
                $0.id == revisionID && $0.status == .approved
            } == true
        } ?? false
        guard hasApprovedTopics, isViewable else {
            if operationFailed(.topicTimecoding, manifest: manifest) {
                return artifact(.topics, .failed, "Темы не созданы")
            }
            return artifact(.topics, .missing, "Не созданы")
        }
        let detail = detail ?? "Готовы"
        return artifact(
            .topics,
            .ready,
            detail,
            openOutputPath: firstPath(in: outputs, kinds: ["topics", "topics-text"])
        )
    }

    private func translationState(
        manifest: ProjectManifest?,
        sourceLanguage: ArtifactLanguage?,
        checkpoint: HumanReviewCheckpoint?,
        outputs: [ProjectOutput]
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
                reviewTarget: .translation
            )
        }
        guard let revision = manifest?.activeTranscriptRevision(for: target),
              revision.reviewStatus == .approved,
              revision.origin == .translated || revision.origin == .userEdited else {
            if operationFailed(.translateTranscript, manifest: manifest) {
                return artifact(.translation, .failed, "Перевод не завершён")
            }
            return artifact(.translation, .missing, "Не создан")
        }
        let openOutputPath = firstPath(in: outputs, kinds: ["localized-transcript", "localized-subtitles"])
        guard let openOutputPath else {
            return artifact(.translation, .missing, "Файлы перевода недоступны")
        }
        return artifact(
            .translation,
            .ready,
            target.russianTitle,
            openOutputPath: openOutputPath
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
        openOutputPath: String? = nil,
        reviewTarget: SimpleProjectHomeReviewTarget? = nil
    ) -> SimpleProjectHomeArtifact {
        SimpleProjectHomeArtifact(
            kind: kind,
            readiness: readiness,
            detail: detail,
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

    private func firstPath(in outputs: [ProjectOutput], kinds: [String]) -> String? {
        for kind in kinds {
            if let output = outputs.first(where: { $0.kind == kind }) { return output.path }
        }
        return nil
    }
}
