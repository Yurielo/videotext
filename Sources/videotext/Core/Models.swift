import Foundation

enum BuildInfo {
    static let name = "videotext"
    static let version = "0.6.8"
    static let build = "2026.09.25.1"
}

enum WorkflowOperation: String, CaseIterable, Identifiable, Codable {
    case diagnostics
    case createManifest
    case detectLanguage
    case transcribe
    case assessTranscriptionQuality
    case detectFillerWords
    case translateTranscript
    case validateTimeline
    case topicTimecoding
    case cutRange
    case burnFragmentSubtitles
    case cutTopic
    case renderFragment
    case burnSubtitles
    case adjustSpeed
    case applyBlur
    case applyWatermark
    case muteFillerWords
    case analyzeAudio
    case enhanceAudio
    case createDubbing
    case ffprobeValidate
    case discoverResults

    var id: String { rawValue }

    var title: String {
        switch self {
        case .diagnostics: return "Диагностика"
        case .createManifest: return "Манифест проекта"
        case .detectLanguage: return "Определение языка"
        case .transcribe: return "Расшифровать всё видео"
        case .assessTranscriptionQuality: return "Проверка качества расшифровки"
        case .translateTranscript: return "Перевести расшифровку"
        case .validateTimeline: return "Проверка временной шкалы"
        case .topicTimecoding: return "Тематический таймкодинг"
        case .discoverResults: return "Поиск результатов"
        case .cutRange: return "Создать точный фрагмент"
        case .cutTopic: return "Вырезать выбранную тему"
        case .renderFragment: return "Создать обработанный фрагмент"
        case .burnFragmentSubtitles: return "Вшить субтитры во фрагмент"
        case .burnSubtitles: return "Вшить субтитры в полное видео"
        case .adjustSpeed: return "Изменить скорость видео"
        case .applyBlur: return "Добавить статический blur"
        case .applyWatermark: return "Добавить watermark"
        case .detectFillerWords: return "Найти слова-паразиты"
        case .muteFillerWords: return "Заглушить слова-паразиты"
        case .analyzeAudio: return "Проанализировать звук"
        case .enhanceAudio: return "Улучшить звук"
        case .createDubbing: return "Создать нейтральный дубляж"
        case .ffprobeValidate: return "Проверка ffprobe"
        }
    }

    /// Translation is exposed only through the explicit EN-to-RU action for an
    /// approved source revision. Dubbing remains outside this product slice.
    static let translationEnabledForCurrentRelease = true
    static let dubbingEnabledForCurrentRelease = false

    var isEnabledForCurrentRelease: Bool {
        switch self {
        case .translateTranscript:
            return Self.translationEnabledForCurrentRelease
        case .createDubbing:
            return Self.dubbingEnabledForCurrentRelease
        default:
            return true
        }
    }

    static let userSelectable: [WorkflowOperation] = [
        .transcribe,
        .topicTimecoding,
        .burnSubtitles
    ]

    var dependencies: [WorkflowOperation] {
        switch self {
        case .diagnostics: return []
        case .createManifest: return [.diagnostics]
        case .detectLanguage: return [.createManifest]
        case .transcribe: return [.detectLanguage]
        case .assessTranscriptionQuality: return [.transcribe]
        case .translateTranscript: return []
        case .validateTimeline: return [.assessTranscriptionQuality]
        case .topicTimecoding: return [.validateTimeline]
        case .discoverResults: return [.createManifest]
        case .cutRange: return [.validateTimeline]
        case .cutTopic: return [.validateTimeline]
        case .renderFragment: return [.validateTimeline]
        case .burnFragmentSubtitles: return [.cutRange]
        case .burnSubtitles: return [.validateTimeline]
        case .adjustSpeed: return [.createManifest]
        case .applyBlur: return [.createManifest]
        case .applyWatermark: return [.createManifest]
        case .detectFillerWords: return [.assessTranscriptionQuality]
        case .muteFillerWords: return [.detectFillerWords]
        case .analyzeAudio: return [.createManifest]
        case .enhanceAudio: return [.analyzeAudio]
        case .createDubbing: return [.translateTranscript]
        case .ffprobeValidate: return [.createManifest]
        }
    }

    var progressWeight: Double {
        switch self {
        case .diagnostics: return 1
        case .createManifest: return 1
        case .detectLanguage: return 2
        case .transcribe: return 55
        case .assessTranscriptionQuality: return 3
        case .translateTranscript: return 18
        case .validateTimeline: return 3
        case .topicTimecoding: return 5
        case .discoverResults: return 1
        case .cutRange: return 12
        case .cutTopic: return 10
        case .renderFragment: return 35
        case .burnFragmentSubtitles: return 12
        case .burnSubtitles: return 15
        case .adjustSpeed: return 15
        case .applyBlur: return 15
        case .applyWatermark: return 12
        case .detectFillerWords: return 4
        case .muteFillerWords: return 12
        case .analyzeAudio: return 4
        case .enhanceAudio: return 15
        case .createDubbing: return 25
        case .ffprobeValidate: return 3
        }
    }
}

enum SpeedSourceKind: String, CaseIterable, Codable, Identifiable {
    case fullVideo
    case latestFragment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullVideo: return "Полное видео"
        case .latestFragment: return "Последний фрагмент"
        }
    }
}

enum FragmentSelectionMode: String, CaseIterable, Codable, Identifiable {
    case timecode
    case topic
    case quote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timecode: return "По таймкоду"
        case .topic: return "По теме"
        case .quote: return "По цитатам"
        }
    }
}

enum ProjectRunMode: String, Codable {
    case newProject
    case resumeProject
    case retryFailedOperations
}

enum ProjectStatus: String, Codable {
    case ready
    case running
    case completed
    case awaitingReview
    case stopped
    case failed

    var title: String {
        switch self {
        case .ready: return "Готово"
        case .running: return "Выполняется"
        case .completed: return "Завершено"
        case .awaitingReview: return "Ожидает проверки"
        case .stopped: return "Остановлено"
        case .failed: return "Ошибка"
        }
    }
}

enum ProjectOperationStatus: String, Codable {
    case pending
    case running
    case completed
    case stopped
    case failed
    case skipped
}

struct ProjectOperationRecord: Codable {
    var status: ProjectOperationStatus
    var startedAt: Date?
    var finishedAt: Date?
    var inputSignature: String?
    var outputPaths: [String]
    var errorMessage: String?
}

struct ProjectWorkflowState: Codable {
    var status: ProjectStatus
    var progress: Double
    var mode: ProjectRunMode
    var operations: [String: ProjectOperationRecord]
    var lastError: String?
}

struct SourceFingerprint: Codable, Equatable {
    var standardizedPath: String
    var fileSize: Int64
    var modificationTime: TimeInterval
}

enum SubtitlePosition: String, CaseIterable, Identifiable, Codable {
    case bottom
    case middle
    case top

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottom: return "Снизу"
        case .middle: return "По центру"
        case .top: return "Сверху"
        }
    }
}

struct SubtitleStyleSettings: Codable, Equatable {
    var textColorHex: String
    var outlineColorHex: String
    var fontName: String
    var fontSize: Double
    var outlineWidth: Double
    var position: SubtitlePosition
    var backgroundOpacity: Double

    static let standard = SubtitleStyleSettings(
        textColorHex: "#FFFFFF",
        outlineColorHex: "#000000",
        fontName: "Helvetica",
        fontSize: 20,
        outlineWidth: 2,
        position: .bottom,
        backgroundOpacity: 0
    )
}

struct FragmentRecord: Codable, Identifiable {
    var id: String
    var name: String
    var start: TimeInterval
    var end: TimeInterval
    var createdAt: Date
    var videoPath: String
    var subtitlePath: String
    var subtitledVideoPath: String?
    var ffprobeReportPath: String?
    var style: SubtitleStyleSettings
    var language: ArtifactLanguage? = nil
    var topicGranularity: TopicGranularity? = nil
    var topicID: String? = nil
    var quoteStart: String? = nil
    var quoteEnd: String? = nil
    var processedVideoPath: String? = nil
    var processingRecipe: FragmentProcessingRecipe? = nil
}

struct FragmentProcessingRecipe: Codable, Equatable {
    var burnSubtitles: Bool
    var muteFillerWords: Bool
    var fillerMode: FillerProcessingMode
    var fillerCandidateIDs: [String]
    var adjustSpeed: Bool
    var speedFactor: Double
    var applyBlur: Bool
    var blurRegion: NormalizedVideoRect
    var blurIntensity: Double
    var blurStart: TimeInterval?
    var blurEnd: TimeInterval?
    var filterGraphs: [String]
}

struct ProjectManifest: Codable {
    var appName: String
    var appVersion: String
    var build: String
    var createdAt: Date
    var updatedAt: Date
    var sourceMediaPath: String
    var projectFolderPath: String
    var durationSeconds: Double?
    var outputs: [ProjectOutput]
    var diagnostics: DiagnosticsReport?

    // Optional additions keep manifests from videotext 0.2 readable.
    var schemaVersion: Int?
    var sourceFingerprint: SourceFingerprint?
    var workflow: ProjectWorkflowState?
    var fragments: [FragmentRecord]?
    var subtitleStyle: SubtitleStyleSettings?
    var artifacts: [ProjectArtifactRecord]?
    var languageProfile: LanguageProfile?
    var transcriptRevisions: [TranscriptRevision]?
    var reviewTasks: [ReviewTask]?
    var humanReviewState: HumanReviewState? = nil
    var topicRevisions: [TopicRevision]? = nil
    var topicReviewState: TopicReviewState? = nil
    var blurAdjustments: [BlurAdjustmentRecord]? = nil
    var watermarkAdjustments: [WatermarkAdjustmentRecord]? = nil
    var fillerMuteRecords: [FillerMuteRecord]? = nil
    var audioEnhancements: [AudioEnhancementRecord]? = nil
    var dubbingRecords: [DubbingRecord]? = nil
    // Optional, user-provided recognition hint. It is never populated from a
    // project transcript or from a product-specific vocabulary.
    var transcriptionContext: String? = nil
}

struct ProjectHistoryEntry: Codable, Identifiable, Equatable {
    var id: String { projectPath }
    var projectPath: String
    var sourceMediaPath: String
    var mediaName: String
    var createdAt: Date
    var updatedAt: Date
    var status: ProjectStatus
    var progress: Double
    var completedOperations: [String]
}

struct ProjectOutput: Codable, Identifiable {
    var id: String
    var kind: String
    var path: String
    var createdAt: Date

    var isGeneratedMedia: Bool {
        [
            "fragment-video",
            "fragment-subtitled-video",
            "fragment-subtitled-video-ru",
            "fragment-subtitled-video-en",
            "processed-fragment-video",
            "subtitled-video",
            "subtitled-video-ru",
            "subtitled-video-en",
            "speed-adjusted-video",
            "blurred-video",
            "watermarked-video",
            "filler-muted-audio",
            "filler-muted-video",
            "enhanced-audio",
            "enhanced-video",
            "dubbed-audio",
            "dubbed-video"
        ].contains(kind)
    }

    var title: String {
        switch kind {
        case "manifest": return "Манифест"
        case "log": return "Журнал"
        case "source-audio": return "Подготовленное аудио"
        case "diagnostics": return "Диагностика"
        case "language-detection": return "Определение языка"
        case "transcription-quality": return "Качество расшифровки"
        case "review-tasks": return "Задания ручной проверки"
        case "transcript-review": return "Отчёт ручной проверки"
        case let value where value.hasPrefix("translation-"): return "Перевод расшифровки"
        case "timeline-validation": return "Проверка временной шкалы"
        case "ffprobe", "fragment-ffprobe": return "Проверка видео"
        case "full-srt": return "Полные субтитры"
        case "transcript": return "Расшифровка"
        case "selected-timing-source": return "Выбранные временные данные расшифровки"
        case let value where value.hasPrefix("selected-timing-translation-"): return "Перевод расшифровки"
        case "localized-transcript": return "Расшифровка по языку"
        case "localized-subtitles": return "Субтитры по языку"
        case "topics", "topics-text": return "Тематический таймкодинг"
        case let value where value.hasPrefix("topics-"): return "Тематический таймкодинг"
        case "fragment-video": return "Видеофрагмент"
        case "fragment-srt": return "Субтитры фрагмента"
        case "fragment-subtitled-video": return "Фрагмент с субтитрами"
        case "fragment-subtitled-video-ru": return "Фрагмент с русскими субтитрами"
        case "fragment-subtitled-video-en": return "Фрагмент с английскими субтитрами"
        case "processed-fragment-video": return "Обработанный фрагмент"
        case "processed-fragment-srt": return "Субтитры обработанного фрагмента"
        case "processed-fragment-recipe": return "Рецепт обработанного фрагмента"
        case "subtitled-video": return "Полное видео с субтитрами"
        case "subtitled-video-ru": return "Полное видео с русскими субтитрами"
        case "subtitled-video-en": return "Полное видео с английскими субтитрами"
        case "speed-adjusted-video": return "Видео с изменённой скоростью"
        case "speed-adjusted-subtitles": return "Субтитры для изменённой скорости"
        case "speed-adjusted-topics": return "Темы для изменённой скорости"
        case "speed-adjusted-review-tasks": return "Проверка для изменённой скорости"
        case "speed-adjustment": return "Параметры изменения скорости"
        case "blurred-video": return "Видео со статическим blur"
        case "blur-adjustment": return "Параметры статического blur"
        case "watermarked-video": return "Видео с watermark"
        case "watermark-adjustment": return "Параметры watermark"
        case "watermark-image": return "Изображение watermark"
        case "filler-analysis": return "Анализ слов-паразитов"
        case "filler-muted-audio": return "Аудио без выбранных слов-паразитов"
        case "filler-muted-video": return "Видео без выбранных слов-паразитов"
        case "filler-mute-report": return "Параметры mute слов-паразитов"
        case "audio-analysis": return "Анализ звука"
        case "enhanced-audio": return "Улучшенная аудиодорожка"
        case "enhanced-video": return "Видео с улучшенным звуком"
        case "audio-enhancement-report": return "Параметры улучшения звука"
        case "dubbed-audio": return "Нейтральный дубляж"
        case "dubbed-video": return "Видео с нейтральным дубляжом"
        case "dubbing-report": return "Параметры дубляжа"
        default: return "Файл проекта"
        }
    }
}

struct DiagnosticsReport: Codable {
    var path: String
    var homebrewPrefix: String?
    var tools: [ToolCheck]
    var canonicalFFmpegPath: String? = nil
    var capabilities: [String: Bool]? = nil
    var ollamaModels: [String]? = nil
    var systemVoices: [String]? = nil
    var warnings: [String]? = nil
    var terminalTasks: [TerminalTaskRecord]? = nil
}

struct TerminalTaskRecord: Codable, Identifiable {
    var id: String
    var title: String
    var command: String?
    var status: String
    var blockedBy: [String]
    var requiresExplicitApproval: Bool
}

struct ToolCheck: Codable, Identifiable {
    var id: String { name }
    var name: String
    var path: String?
    var version: String?
    var isAvailable: Bool
}

struct SubtitleCue: Codable, Identifiable {
    var id: Int
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

enum TopicGranularity: String, CaseIterable, Identifiable, Codable, Equatable {
    case detailed
    case normal
    case coarse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .detailed: return "Подробный"
        case .normal: return "Обычный"
        case .coarse: return "Крупный"
        }
    }

    var durationRange: ClosedRange<TimeInterval> {
        switch self {
        case .detailed: return 60...180
        case .normal: return 180...480
        case .coarse: return 480...900
        }
    }

    var targetDuration: TimeInterval {
        switch self {
        case .detailed: return 120
        case .normal: return 300
        case .coarse: return 660
        }
    }
}

enum TopicAlgorithmIdentity {
    static let schemaVersion = 2
    static let hybridAdapter = "HybridTopicAdapter"
    static let hybridVersion = "hybrid-cue-review-v10"

    static func recognizes(_ file: TopicsFile) -> Bool {
        file.schemaVersion == schemaVersion
            && file.status == .ready
            && file.adapter == hybridAdapter
            && file.algorithmVersion == hybridVersion
    }

    static func isCurrent(
        _ file: TopicsFile,
        granularity: TopicGranularity,
        sourceSignature: String
    ) -> Bool {
        guard recognizes(file),
              file.granularity == granularity,
              !sourceSignature.isEmpty,
              file.sourceSignature == sourceSignature else { return false }
        return file.status == .ready
    }
}

enum TopicsFileStatus: String, Codable {
    case ready
    case draft
}

struct TopicSegment: Codable, Identifiable {
    var id: String
    var title: String
    var start: TimeInterval
    var end: TimeInterval
    var duration: TimeInterval
    var summary: String
    var keywords: [String]
    var confidence: Double
    var boundaryReason: String
    var sourceCueStart: Int
    var sourceCueEnd: Int
    var cueIds: [Int]

    init(
        id: String,
        title: String,
        start: TimeInterval,
        end: TimeInterval,
        duration: TimeInterval? = nil,
        summary: String = "",
        keywords: [String],
        confidence: Double = 0,
        boundaryReason: String = "",
        sourceCueStart: Int? = nil,
        sourceCueEnd: Int? = nil,
        cueIds: [Int]
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.duration = duration ?? max(0, end - start)
        self.summary = summary
        self.keywords = keywords
        self.confidence = confidence
        self.boundaryReason = boundaryReason
        self.sourceCueStart = sourceCueStart ?? cueIds.min() ?? 0
        self.sourceCueEnd = sourceCueEnd ?? cueIds.max() ?? 0
        self.cueIds = cueIds
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, start, end, duration, summary, keywords, confidence, boundaryReason
        case sourceCueStart, sourceCueEnd, cueIds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        start = try values.decode(TimeInterval.self, forKey: .start)
        end = try values.decode(TimeInterval.self, forKey: .end)
        duration = try values.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? max(0, end - start)
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        keywords = try values.decodeIfPresent([String].self, forKey: .keywords) ?? []
        confidence = try values.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        boundaryReason = try values.decodeIfPresent(String.self, forKey: .boundaryReason) ?? ""
        cueIds = try values.decodeIfPresent([Int].self, forKey: .cueIds) ?? []
        sourceCueStart = try values.decodeIfPresent(Int.self, forKey: .sourceCueStart) ?? cueIds.min() ?? 0
        sourceCueEnd = try values.decodeIfPresent(Int.self, forKey: .sourceCueEnd) ?? cueIds.max() ?? 0
    }
}

struct TopicsFile: Codable {
    var schemaVersion: Int
    var algorithmVersion: String
    var adapter: String
    var createdAt: Date
    var sourceSRT: String
    var sourceSignature: String
    var status: TopicsFileStatus
    var granularity: TopicGranularity
    var embeddingModel: String?
    var languageModel: String?
    var topics: [TopicSegment]

    init(
        schemaVersion: Int = TopicAlgorithmIdentity.schemaVersion,
        algorithmVersion: String = TopicAlgorithmIdentity.hybridVersion,
        adapter: String,
        createdAt: Date,
        sourceSRT: String,
        sourceSignature: String = "",
        status: TopicsFileStatus = .ready,
        granularity: TopicGranularity = .normal,
        embeddingModel: String? = nil,
        languageModel: String? = nil,
        topics: [TopicSegment]
    ) {
        self.schemaVersion = schemaVersion
        self.algorithmVersion = algorithmVersion
        self.adapter = adapter
        self.createdAt = createdAt
        self.sourceSRT = sourceSRT
        self.sourceSignature = sourceSignature
        self.status = status
        self.granularity = granularity
        self.embeddingModel = embeddingModel
        self.languageModel = languageModel
        self.topics = topics
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, algorithmVersion, adapter, createdAt, sourceSRT, sourceSignature
        case status, granularity, embeddingModel, languageModel, topics
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        algorithmVersion = try values.decodeIfPresent(String.self, forKey: .algorithmVersion) ?? "legacy"
        adapter = try values.decode(String.self, forKey: .adapter)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        sourceSRT = try values.decode(String.self, forKey: .sourceSRT)
        sourceSignature = try values.decodeIfPresent(String.self, forKey: .sourceSignature) ?? ""
        status = try values.decodeIfPresent(TopicsFileStatus.self, forKey: .status) ?? .draft
        granularity = try values.decodeIfPresent(TopicGranularity.self, forKey: .granularity) ?? .normal
        embeddingModel = try values.decodeIfPresent(String.self, forKey: .embeddingModel)
        languageModel = try values.decodeIfPresent(String.self, forKey: .languageModel)
        topics = try values.decode([TopicSegment].self, forKey: .topics)
    }
}

struct WorkflowSettings {
    var mediaURL: URL?
    var projectURL: URL?
    var selectedOperations: Set<WorkflowOperation>
    var mode: ProjectRunMode
    var rangeStart: TimeInterval
    var rangeEnd: TimeInterval
    var fragmentName: String
    var burnFragmentSubtitles: Bool
    var subtitleStyle: SubtitleStyleSettings
    var selectedTopicID: String?
    var whisperModelPath: String
    var whisperLanguage: String
    var transcriptionContext: String? = nil
    var topicGranularity: TopicGranularity = .normal
    var artifactLanguage: ArtifactLanguage? = nil
    var subtitleSource: SubtitleSourceSelection = .source
    var quoteStart: String? = nil
    var quoteEnd: String? = nil
    var speedFactor: Double = 1
    var speedSource: SpeedSourceKind = .fullVideo
    var blurSource: SpeedSourceKind = .fullVideo
    var blurRegion: NormalizedVideoRect = NormalizedVideoRect(x: 0.65, y: 0.05, width: 0.3, height: 0.2)
    var blurIntensity: Double = 12
    var blurStart: TimeInterval? = nil
    var blurEnd: TimeInterval? = nil
    var watermarkImageURL: URL? = nil
    var watermarkSource: SpeedSourceKind = .fullVideo
    var watermarkPosition: WatermarkPosition = .bottomRight
    var watermarkManualX: Double = 0.75
    var watermarkManualY: Double = 0.75
    var watermarkRelativeWidth: Double = 0.18
    var watermarkMargin: Double = 0.03
    var watermarkOpacity: Double = 0.85
    var watermarkStart: TimeInterval? = nil
    var watermarkEnd: TimeInterval? = nil
    var watermarkIncludesBlur: Bool = false
    var watermarkBurnSubtitles: Bool = false
    var fillerMode: FillerProcessingMode = .muteAll
    var selectedFillerCandidateIDs: Set<String> = []
    var audioEnhancementProfile: AudioEnhancementProfile = .normal
    var dubbingLanguage: ArtifactLanguage = .ru
    var dubbingMixMode: DubbingMixMode = .replace
    var sourceHumanReviewEnabled: Bool = true
    var translationHumanReviewEnabled: Bool = false
    var fillerAnalysisBeforeReview: Bool = true
    var topicHumanReviewEnabled: Bool = false
    var fragmentMuteFillerWords: Bool = false
    var fragmentAdjustSpeed: Bool = false
    var fragmentApplyBlur: Bool = false
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

enum WorkflowError: LocalizedError {
    case missingMedia
    case missingProjectFolder
    case missingProjectManifest
    case multipleProjectsFound(Int)
    case missingTool(String)
    case missingFullSRT
    case missingTopics
    case invalidRange
    case invalidTimecode(String)
    case noSubtitlesInRange
    case invalidSRT(String)
    case sourceMismatch
    case cannotCreateProject(String)
    case insufficientDiskSpace
    case cannotOpenProjectFolder
    case cannotOpenResult
    case processFailed(String)
    case topicServiceUnavailable(String)
    case invalidTopics(String)
    case unsupportedProjectSchema(Int)

    var errorDescription: String? {
        switch self {
        case .missingMedia: return "Сначала выберите видео- или аудиофайл."
        case .missingProjectFolder: return "Сначала выберите папку проекта."
        case .missingProjectManifest: return "Проект videotext не найден. Выберите папку «Обработка видео …», её Support files, файл manifest.json или родительскую папку с одним проектом."
        case .multipleProjectsFound(let count): return "В выбранной папке найдено несколько проектов videotext (\(count)). Выберите конкретную папку «Обработка видео …»."
        case .missingTool(let name): return "Не найден обязательный инструмент: \(name)."
        case .missingFullSRT: return "Файл full.srt не найден. Сначала выполните расшифровку."
        case .missingTopics: return "Файл topics.json не найден. Сначала выполните тематический таймкодинг."
        case .invalidRange: return "Выбран некорректный временной диапазон."
        case .invalidTimecode(let value): return "Не удалось распознать таймкод \"\(value)\". Используйте секунды или ЧЧ:ММ:СС.ммм."
        case .noSubtitlesInRange: return "В выбранном диапазоне нет субтитров."
        case .invalidSRT(let message): return "Ошибка формата SRT: \(message)"
        case .sourceMismatch: return "Исходный медиафайл не соответствует выбранному проекту."
        case .cannotCreateProject(let path): return "Не удалось создать папку проекта: \(path)."
        case .insufficientDiskSpace: return "Недостаточно свободного места для обработки выбранного файла."
        case .cannotOpenProjectFolder: return "Не удалось открыть папку проекта в Finder."
        case .cannotOpenResult: return "Не удалось открыть выбранный результат. Возможно, файл был перемещён или удалён."
        case .processFailed(let message): return message
        case .topicServiceUnavailable(let message): return "Качественный тематический анализ недоступен: \(message)"
        case .invalidTopics(let message): return "Тематический таймкодинг не прошёл проверку: \(message)"
        case .unsupportedProjectSchema(let version): return "Версия проекта \(version) новее поддерживаемой схемы \(ProjectSchema.currentVersion). Обновите videotext и не изменяйте этот проект старой версией приложения."
        }
    }
}
