import Foundation

enum ProjectSchema {
    static let minimumSupportedVersion = 1
    static let currentVersion = 8
}

enum ArtifactLanguage: String, CaseIterable, Codable, Identifiable, Equatable {
    case ru
    case en

    var id: String { rawValue }

    /// VideoText currently supports exactly the two product-approved
    /// TranslateGemma directions. Keeping the pairing here prevents a
    /// source-language branch from accidentally exposing an arbitrary target.
    var translationTarget: ArtifactLanguage {
        switch self {
        case .ru: return .en
        case .en: return .ru
        }
    }

    var russianTitle: String {
        switch self {
        case .ru: return "Русский"
        case .en: return "Английский"
        }
    }
}

/// An explicit subtitle choice for rendering. This is an in-memory workflow
/// setting: it does not alter the source or translation revision.
enum SubtitleSourceSelection: Hashable, Identifiable {
    case source
    case approvedTranslation(ArtifactLanguage)

    var id: String {
        switch self {
        case .source: return "source"
        case .approvedTranslation(let language): return "approved-\(language.rawValue)"
        }
    }
}

struct ResolvedSubtitleSource: Equatable {
    let language: ArtifactLanguage
    let srtURL: URL
    let isTranslation: Bool
}

enum DetectedMediaLanguage: String, Codable, Equatable {
    case ru
    case en
    case uncertain
}

enum ArtifactOrigin: String, Codable, Equatable {
    case source
    case translated
    case userEdited
}

enum ArtifactValidationStatus: String, Codable, Equatable {
    case pending
    case ready
    case needsReview
    case invalid
}

enum ProjectArtifactRecordKind: String, Codable, Equatable {
    case transcript
    case subtitles
    case topics
    case reviewReport
    case fillerAnalysis
    case fragment
    case watermarkImage
    case watermarkedVideo
    case subtitledVideo
    case blurredVideo
    case speedAdjustedVideo
    case enhancedAudio
    case mutedAudio
    case mutedVideo
    case dubbedAudio
    case dubbedVideo
}

struct ProjectArtifactRecord: Codable, Identifiable, Equatable {
    var id: String
    var kind: ProjectArtifactRecordKind
    var path: String
    var language: ArtifactLanguage?
    var origin: ArtifactOrigin
    var granularity: TopicGranularity?
    var sourceArtifactID: String?
    var sourceRevision: String?
    var dependencyIDs: [String]
    var contentHash: String?
    var createdAt: Date
    var generator: String
    var generatorVersion: String
    var model: String?
    var validationStatus: ArtifactValidationStatus
    var qualityStatus: ArtifactValidationStatus?
    var reviewTaskCount: Int
}

struct LanguageProfile: Codable, Equatable {
    var detected: DetectedMediaLanguage
    var effective: ArtifactLanguage?
    var confidence: Double?
    var method: String
    var model: String?
    var modelVersion: String?
    var sampleRanges: [ClosedRangeRecord]
    var manuallyOverridden: Bool
    var detectedAt: Date
}

struct LanguageDetectionCandidate: Codable, Equatable {
    var languageCode: String
    var confidence: Double?
    var sampleRange: ClosedRangeRecord
}

struct ClosedRangeRecord: Codable, Equatable {
    var start: TimeInterval
    var end: TimeInterval
}

enum TranscriptRevisionOrigin: String, Codable, Equatable {
    case machineGenerated
    case translated
    case userEdited
}

enum TranscriptReviewStatus: String, Codable, Equatable {
    case pending
    case draft
    case approved
    case superseded
}

struct TranscriptRevision: Codable, Identifiable, Equatable {
    var id: String
    var language: ArtifactLanguage
    var origin: TranscriptRevisionOrigin
    var parentRevisionID: String?
    var transcriptArtifactID: String
    var subtitleArtifactID: String
    var contentHash: String?
    var createdAt: Date
    var reviewStatus: TranscriptReviewStatus? = nil
}

enum HumanReviewCheckpointKind: String, Codable, Equatable {
    case sourceTranscript
    case translatedTranscript
}

struct HumanReviewCheckpoint: Codable, Equatable {
    var kind: HumanReviewCheckpointKind
    var language: ArtifactLanguage
    var revisionID: String
    var pendingOperations: [WorkflowOperation]
    var createdAt: Date
}

struct HumanReviewState: Codable, Equatable {
    var sourceReviewEnabled: Bool
    var translationReviewEnabled: Bool
    var fillerAnalysisBeforeReview: Bool? = nil
    var activeRevisionIDs: [String: String]
    var draftRevisionIDs: [String: String]
    var pendingCheckpoint: HumanReviewCheckpoint?

    static let newProjectDefault = HumanReviewState(
        sourceReviewEnabled: true,
        translationReviewEnabled: false,
        fillerAnalysisBeforeReview: true,
        activeRevisionIDs: [:],
        draftRevisionIDs: [:],
        pendingCheckpoint: nil
    )

    func activeRevisionID(for language: ArtifactLanguage) -> String? {
        activeRevisionIDs[language.rawValue]
    }
}

enum TopicRevisionStatus: String, Codable, Equatable {
    case pending
    case approved
    case superseded
}

struct TopicRevision: Codable, Equatable, Identifiable {
    var id: String
    var language: ArtifactLanguage
    var granularity: TopicGranularity
    var parentRevisionID: String?
    var jsonPath: String
    var textPath: String
    var contentHash: String
    var status: TopicRevisionStatus
    var createdAt: Date

    var variantKey: String { "\(language.rawValue).\(granularity.rawValue)" }
}

struct TopicReviewCheckpoint: Codable, Equatable {
    var revisionIDs: [String: String]
    var pendingOperations: [WorkflowOperation]
    var createdAt: Date
}

struct TopicReviewState: Codable, Equatable {
    var enabled: Bool
    var activeRevisionIDs: [String: String]
    var pendingCheckpoint: TopicReviewCheckpoint?

    static let newProjectDefault = TopicReviewState(
        enabled: true,
        activeRevisionIDs: [:],
        pendingCheckpoint: nil
    )
}

extension ProjectManifest {
    func activeTranscriptRevision(for language: ArtifactLanguage) -> TranscriptRevision? {
        if let id = humanReviewState?.activeRevisionID(for: language),
           let revision = transcriptRevisions?.first(where: { $0.id == id }) {
            return revision
        }
        return transcriptRevisions?.last(where: {
            $0.language == language && ($0.reviewStatus == .approved || $0.reviewStatus == nil)
        })
    }
}

enum SubtitleSourceResolver {
    static func availableSelections(manifest: ProjectManifest, projectURL: URL) -> [SubtitleSourceSelection] {
        guard let sourceLanguage = manifest.languageProfile?.effective,
              (try? resolve(
                .approvedTranslation(sourceLanguage.translationTarget),
                manifest: manifest,
                projectURL: projectURL
              )) != nil else {
            return [.source]
        }
        return [.source, .approvedTranslation(sourceLanguage.translationTarget)]
    }

    static func resolve(
        _ selection: SubtitleSourceSelection,
        manifest: ProjectManifest,
        projectURL: URL
    ) throws -> ResolvedSubtitleSource {
        let layout = ProjectLayout(root: projectURL)
        guard let sourceLanguage = manifest.languageProfile?.effective else {
            throw WorkflowError.processFailed("Не определён язык исходной расшифровки для выбора субтитров.")
        }

        switch selection {
        case .source:
            let srtURL = sourceLanguage == .en ? layout.fullSRTURL : layout.subtitlesURL(language: sourceLanguage)
            guard nonemptyFile(srtURL) else { throw WorkflowError.missingFullSRT }
            return ResolvedSubtitleSource(language: sourceLanguage, srtURL: srtURL, isTranslation: false)

        case .approvedTranslation(let language):
            guard language == sourceLanguage.translationTarget else {
                throw WorkflowError.processFailed("Для этого среза доступны только утверждённые субтитры EN→RU или RU→EN.")
            }
            guard let revision = manifest.activeTranscriptRevision(for: language),
                  revision.reviewStatus == .approved,
                  revision.origin == .translated || revision.origin == .userEdited else {
                throw WorkflowError.processFailed("Выбранные субтитры \(language.rawValue.uppercased()) недоступны: перевод ещё не утверждён.")
            }
            let workingURL = layout.subtitlesURL(language: language)
            let immutableURL = layout.subtitleRevisionURL(id: revision.id, language: language)
            guard nonemptyFile(workingURL), nonemptyFile(immutableURL),
                  let working = try? Data(contentsOf: workingURL),
                  let immutable = try? Data(contentsOf: immutableURL),
                  working == immutable else {
                throw WorkflowError.processFailed("Выбранные субтитры \(language.rawValue.uppercased()) не совпадают с утверждённой ревизией и не будут использованы.")
            }
            return ResolvedSubtitleSource(language: language, srtURL: workingURL, isTranslation: true)
        }
    }

    static func unavailableTranslationMessage(manifest: ProjectManifest?, projectURL: URL?) -> String? {
        guard let manifest, let projectURL, let sourceLanguage = manifest.languageProfile?.effective else { return nil }
        do {
            _ = try resolve(.approvedTranslation(sourceLanguage.translationTarget), manifest: manifest, projectURL: projectURL)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func nonemptyFile(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }
}

enum ReviewTaskStatus: String, Codable, Equatable {
    case needsReview
    case resolved
    case dismissed
}

struct ReviewTask: Codable, Identifiable, Equatable {
    var id: String
    var transcriptRevisionID: String
    var status: ReviewTaskStatus
    var language: ArtifactLanguage
    var start: TimeInterval
    var end: TimeInterval
    var cueIDs: [Int]
    var reasonCodes: [String]
    var confidence: Double?
    var originalText: String
    var suggestedText: String?
    var createdAt: Date
    var resolvedAt: Date?
    var dependentArtifactIDs: [String]
}

struct TranscriptionQualityReport: Codable, Equatable {
    var schemaVersion: Int
    var transcriptRevisionID: String
    var language: ArtifactLanguage
    var analyzedAt: Date
    var status: ArtifactValidationStatus
    var cueCount: Int
    var reviewTaskIDs: [String]
    var metrics: [String: Double]
    var warnings: [String]
}

struct TranslationReport: Codable, Equatable {
    var schemaVersion: Int
    var sourceRevisionID: String
    var targetRevisionID: String
    var sourceLanguage: ArtifactLanguage
    var targetLanguage: ArtifactLanguage
    var model: String
    var modelDigest: String?
    var protocolVersion: String?
    var translatedAt: Date
    var cueCount: Int
    var reviewTaskIDs: [String]
    var status: ArtifactValidationStatus
    var contextIdentity: String? = nil
    var subtitleSHA256: String? = nil
    var transcriptSHA256: String? = nil
}

struct SpeedAdjustmentRecord: Codable, Equatable {
    var schemaVersion: Int
    var sourceMediaPath: String
    var outputMediaPath: String
    var sourceSubtitlePath: String
    var outputSubtitlePath: String
    var sourceKind: SpeedSourceKind
    var sourceFragmentID: String?
    var sourceFragmentRange: ClosedRangeRecord?
    var language: ArtifactLanguage
    var speedFactor: Double
    var sourceDuration: TimeInterval
    var outputDuration: TimeInterval
    var audioFilter: String
    var outputTopicPaths: [String]
    var outputReviewTasksPath: String?
    var createdAt: Date
}

struct NormalizedVideoRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    func validated() throws -> NormalizedVideoRect {
        guard x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1, y + height <= 1 else {
            throw WorkflowError.processFailed("Область blur должна находиться внутри кадра и иметь ненулевой размер.")
        }
        return self
    }
}

struct BlurAdjustmentRecord: Codable, Equatable, Identifiable {
    var id: String
    var sourceMediaPath: String
    var outputMediaPath: String
    var sourceKind: SpeedSourceKind
    var sourceFragmentID: String?
    var region: NormalizedVideoRect
    var intensity: Double
    var start: TimeInterval?
    var end: TimeInterval?
    var sourceDuration: TimeInterval
    var filterGraph: String
    var createdAt: Date
}

enum WatermarkPosition: String, CaseIterable, Codable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: return "Слева сверху"
        case .topRight: return "Справа сверху"
        case .bottomLeft: return "Слева снизу"
        case .bottomRight: return "Справа снизу"
        case .manual: return "Вручную"
        }
    }
}

struct WatermarkAdjustmentRecord: Codable, Equatable, Identifiable {
    var id: String
    var sourceMediaPath: String
    var outputMediaPath: String
    var sourceKind: SpeedSourceKind
    var sourceFragmentID: String?
    var sourceImagePath: String
    var sourceImageHash: String
    var position: WatermarkPosition
    var manualX: Double
    var manualY: Double
    var relativeWidth: Double
    var margin: Double
    var opacity: Double
    var start: TimeInterval?
    var end: TimeInterval?
    var sourceDuration: TimeInterval
    var filterOrder: [String]
    var burnedSubtitlePath: String?
    var includedBlurRegion: NormalizedVideoRect?
    var filterGraph: String
    var createdAt: Date
}

struct WordTimelineEntry: Codable, Equatable, Identifiable {
    var id: String
    var text: String
    var normalized: String
    var start: TimeInterval
    var end: TimeInterval
    var cueID: Int
    var transcriptRevisionID: String
    var confidence: Double?
}

enum FillerCandidateDecision: String, Codable, Equatable {
    case pending
    case selectedForMute
    case keep
    case muted
}

struct FillerWordCandidate: Codable, Equatable, Identifiable {
    var id: String
    var text: String
    var normalized: String
    var start: TimeInterval
    var end: TimeInterval
    var cueID: Int
    var transcriptRevisionID: String
    var language: ArtifactLanguage
    var confidence: Double?
    var highConfidence: Bool
    var reasonCodes: [String]
    var context: String
    var decision: FillerCandidateDecision
}

struct FillerAnalysisReport: Codable, Equatable {
    var schemaVersion: Int
    var language: ArtifactLanguage
    var transcriptRevisionID: String
    var createdAt: Date
    var words: [WordTimelineEntry]
    var candidates: [FillerWordCandidate]
}

struct FillerMuteRecord: Codable, Equatable, Identifiable {
    var id: String
    var sourceMediaPath: String
    var outputAudioPath: String
    var outputVideoPath: String
    var transcriptRevisionID: String
    var candidateIDs: [String]
    var intervals: [ClosedRangeRecord]
    var fadeDuration: TimeInterval
    var filterGraph: String
    var createdAt: Date
}

enum FillerProcessingMode: String, CaseIterable, Codable, Identifiable {
    case detectOnly
    case muteAll
    case muteSelected
    case muteHighConfidence

    var id: String { rawValue }

    var title: String {
        switch self {
        case .detectOnly: return "Только определить"
        case .muteAll: return "Mute всех"
        case .muteSelected: return "Mute выбранных"
        case .muteHighConfidence: return "Mute уверенных"
        }
    }
}

enum AudioEnhancementProfile: String, CaseIterable, Codable, Identifiable {
    case light
    case normal
    case strong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Лёгкое"
        case .normal: return "Обычное"
        case .strong: return "Сильное"
        }
    }
}

struct AudioAnalysisReport: Codable, Equatable {
    var schemaVersion: Int
    var analyzedAt: Date
    var sourceMediaPath: String
    var duration: TimeInterval
    var meanVolumeDB: Double?
    var maxVolumeDB: Double?
    var integratedLoudnessLUFS: Double?
    var truePeakDB: Double?
    var silenceDuration: TimeInterval
    var stationaryNoiseEstimateDB: Double?
    var echoAssessment: String
    var warnings: [String]
}

struct AudioEnhancementRecord: Codable, Equatable, Identifiable {
    var id: String
    var sourceMediaPath: String
    var outputAudioPath: String
    var outputVideoPath: String
    var profile: AudioEnhancementProfile
    var backendModel: String? = nil
    var filterGraph: String
    var before: AudioAnalysisReport
    var after: AudioAnalysisReport
    var createdAt: Date
}

enum DubbingMixMode: String, CaseIterable, Codable, Identifiable {
    case replace
    case mixQuietOriginal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .replace: return "Заменить оригинал"
        case .mixQuietOriginal: return "Смешать с тихим оригиналом"
        }
    }
}

struct DubbingCueRecord: Codable, Equatable {
    var cueID: Int
    var start: TimeInterval
    var end: TimeInterval
    var synthesizedDuration: TimeInterval
    var tempo: Double
    var needsReview: Bool
}

struct DubbingRecord: Codable, Equatable, Identifiable {
    var id: String
    var sourceMediaPath: String
    var sourceSubtitlePath: String
    var outputAudioPath: String
    var outputVideoPath: String
    var language: ArtifactLanguage
    var voiceIdentifier: String
    var voiceProviderVersion: String
    var mixMode: DubbingMixMode
    var cues: [DubbingCueRecord]
    var reviewTaskIDs: [String]
    var createdAt: Date
}
