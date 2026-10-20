import Foundation
import CryptoKit
import ImageIO

/// A preset describes an outcome. The engine remains the only executor of media operations.
enum ProcessingPresetGoal: String, CaseIterable, Codable, Identifiable {
    case transcription, topics, sourceSubtitles, translation, translatedSubtitles
    case processing, fullOriginal, fullTranslated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcription: return "Расшифровка"
        case .topics: return "Расшифровка и темы"
        case .sourceSubtitles: return "Видео с исходными субтитрами"
        case .translation: return "Перевод текста"
        case .translatedSubtitles: return "Видео с переводными субтитрами"
        case .processing: return "Обработка видео"
        case .fullOriginal: return "Полная обработка оригинала"
        case .fullTranslated: return "Полная обработка с переводом"
        }
    }

    var needsTranscript: Bool { self != .processing }
    var needsTranslation: Bool { self == .translation || self == .translatedSubtitles || self == .fullTranslated }
    var needsVideo: Bool { self == .sourceSubtitles || self == .translatedSubtitles || self == .processing || self == .fullOriginal || self == .fullTranslated }
}

enum ProcessingPresetScope: String, CaseIterable, Codable, Identifiable {
    case fullVideo, timeFragment, approvedTopic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fullVideo: return "Полное видео"
        case .timeFragment: return "Фрагмент по времени"
        case .approvedTopic: return "Фрагмент по утверждённой теме"
        }
    }
}

enum ProcessingPresetEffect: String, CaseIterable, Codable, Identifiable {
    case none, speed, blur, watermark, audioEnhancement
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Без эффекта"
        case .speed: return "Изменить скорость"
        case .blur: return "Статический blur"
        case .watermark: return "Watermark"
        case .audioEnhancement: return "Улучшить звук"
        }
    }
}

struct ProcessingPresetConfiguration: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var goal: ProcessingPresetGoal = .transcription
    var sourceLanguage = "auto"
    var targetLanguage: ArtifactLanguage = .en
    var topicGranularity: TopicGranularity = .normal
    var topicID: String? = nil
    var scope: ProcessingPresetScope = .fullVideo
    var effect: ProcessingPresetEffect = .none
    var speedFactor: Double = 1.25
    var blurRegion = NormalizedVideoRect(x: 0.65, y: 0.05, width: 0.3, height: 0.2)
    var blurIntensity: Double = 12
    var watermarkImagePath: String? = nil
    var watermarkPosition: WatermarkPosition = .bottomRight
    var watermarkOpacity: Double = 0.85
    var audioEnhancementProfile: AudioEnhancementProfile = .normal
    var combineBlur = false
    var muteFillers = false
    var fragmentStart: TimeInterval = 0
    var fragmentEnd: TimeInterval = 10
    var subtitleStyle = SubtitleStyleSettings.standard

    var needsSourceSubtitles: Bool { goal == .sourceSubtitles || goal == .fullOriginal }
    var needsTranslatedSubtitles: Bool { goal == .translatedSubtitles || goal == .fullTranslated }

    func sameOutcome(as other: Self) -> Bool {
        var lhs = self
        var rhs = other
        lhs.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        rhs.id = lhs.id
        lhs.name = ""
        rhs.name = ""
        return lhs == rhs
    }

    func portableForSaving() -> Self {
        var value = self
        if value.scope == .approvedTopic { value.topicID = nil }
        return value
    }

    func clearingHiddenOptions() -> Self {
        var value = self
        if value.effect != .watermark { value.combineBlur = false }
        if value.scope != .timeFragment { value.muteFillers = false }
        if value.scope != .approvedTopic { value.topicID = nil }
        return value
    }
}

enum ProcessingPresetStage: String, Codable, CaseIterable {
    case transcription, topics, translation, render
    var title: String {
        switch self {
        case .transcription: return "Расшифровка и проверка"
        case .topics: return "Темы и проверка"
        case .translation: return "Перевод и проверка"
        case .render: return "Создание результата"
        }
    }
}

struct ProcessingPresetPlan: Equatable {
    var stages: [ProcessingPresetStage]
    var reused: [String]
    var result: String
    var blocker: String? = nil
    var canCreate: Bool { blocker == nil }
}

/// Pure compatibility and ordering contract. Readiness booleans must come from
/// validated project-local immutable revisions, never from file presence alone.
struct ProcessingPresetPlanner {
    /// Validate a saved template independently of any one project's language.
    /// Runtime planning still resolves Auto against the opened project and
    /// rejects a target that is not opposite to that project's source.
    func validatePortable(_ configuration: ProcessingPresetConfiguration) -> ProcessingPresetPlan {
        var sample = configuration.portableForSaving()
        if sample.scope == .approvedTopic { sample.topicID = "portable-topic-selection" }
        let sampleLanguage: ArtifactLanguage? = sample.goal.needsTranslation && sample.sourceLanguage == "auto"
            ? sample.targetLanguage.translationTarget : nil
        return make(
            sample, projectAvailable: true, effectiveLanguage: sampleLanguage,
            approvedSource: false, approvedTopics: sample.scope == .approvedTopic,
            approvedTranslation: false
        )
    }

    private func resultDescription(_ config: ProcessingPresetConfiguration, language: ArtifactLanguage?) -> String {
        let source = language?.rawValue.uppercased() ?? config.sourceLanguage.uppercased()
        switch config.goal {
        case .transcription: return "TXT и SRT · \(source)"
        case .topics: return "TXT и темы · \(source) · \(config.topicGranularity.title)"
        case .translation: return "TXT и SRT · \(config.targetLanguage.rawValue.uppercased())"
        case .sourceSubtitles, .translatedSubtitles, .processing, .fullOriginal, .fullTranslated:
            let subtitleLanguage = config.needsTranslatedSubtitles ? config.targetLanguage.rawValue.uppercased() : source
            let subtitleLabel = config.needsSourceSubtitles || config.needsTranslatedSubtitles
                ? " · субтитры \(subtitleLanguage)" : ""
            let effectLabel = config.effect == .none ? "" : " · \(config.effect.title)"
            let blurLabel = config.combineBlur ? " + blur" : ""
            let muteLabel = config.muteFillers ? " · mute слов-паразитов" : ""
            return "MP4 · \(config.scope.title)\(subtitleLabel)\(effectLabel)\(blurLabel)\(muteLabel)"
        }
    }

    func make(
        _ config: ProcessingPresetConfiguration,
        projectAvailable: Bool,
        effectiveLanguage: ArtifactLanguage?,
        approvedSource: Bool,
        approvedTopics: Bool,
        approvedTranslation: Bool
    ) -> ProcessingPresetPlan {
        var plan = ProcessingPresetPlan(
            stages: [], reused: [], result: resultDescription(config, language: effectiveLanguage)
        )
        func block(_ message: String) -> ProcessingPresetPlan {
            plan.blocker = message
            return plan
        }
        guard projectAvailable else { return block("Выберите исходное видео или откройте проект.") }
        guard ["auto", "ru", "en"].contains(config.sourceLanguage) else {
            return block("Язык распознавания: только Авто, RU или EN.")
        }
        if let effectiveLanguage, config.sourceLanguage != "auto", config.sourceLanguage != effectiveLanguage.rawValue {
            return block("Выбранный язык не совпадает с языком существующего проекта.")
        }
        if config.goal.needsTranslation && effectiveLanguage == nil && config.sourceLanguage == "auto" {
            return block("Для пакета с переводом выберите язык исходника RU или EN до запуска.")
        }
        if config.goal.needsTranslation,
           let source = effectiveLanguage ?? ArtifactLanguage(rawValue: config.sourceLanguage),
           config.targetLanguage != source.translationTarget {
            return block("Перевод доступен только RU↔EN в противоположный исходному язык.")
        }
        if !config.goal.needsVideo && config.scope == .timeFragment {
            return block("Этот результат создаётся для всего текста, не для фрагмента видео.")
        }
        if config.scope == .timeFragment {
            guard config.fragmentStart.isFinite, config.fragmentEnd.isFinite,
                  config.fragmentStart >= 0, config.fragmentEnd > config.fragmentStart else {
                return block("Задайте правильные начало и конец фрагмента.")
            }
            if config.effect == .watermark || config.effect == .audioEnhancement {
                return block("Watermark и улучшение звука недоступны в обработанном фрагменте.")
            }
        } else if config.muteFillers {
            return block("Mute слов-паразитов поддерживается только в обработанном фрагменте.")
        }
        if config.scope == .approvedTopic {
            guard config.goal == .sourceSubtitles || config.goal == .translatedSubtitles else {
                return block("Пакетная обработка фрагмента по теме не имеет безопасного контракта для последовательных эффектов. Выберите фрагмент по времени.")
            }
            guard approvedTopics else {
                return block("Для фрагмента по теме нужны утверждённые обычные темы. Сначала создайте и проверьте их.")
            }
            guard config.topicID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return block("Выберите утверждённую тему.")
            }
        }
        if config.effect == .speed && (!config.speedFactor.isFinite || !(0.5...2).contains(config.speedFactor)) {
            return block("Скорость должна быть от 0.5 до 2.0.")
        }
        if config.effect == .blur || config.combineBlur {
            guard (try? config.blurRegion.validated()) != nil,
                  config.blurIntensity.isFinite, config.blurIntensity > 0 else {
                return block("Укажите допустимую область и интенсивность blur.")
            }
        }
        if config.combineBlur && config.effect != .watermark {
            return block("Совместный blur поддерживается только операцией watermark.")
        }
        if config.effect == .watermark {
            guard config.watermarkPosition != .manual else {
                return block("Ручное положение watermark задаётся в расширенном режиме; для пакета выберите готовую позицию.")
            }
            guard let path = config.watermarkImagePath, !path.isEmpty else {
                return block("Выберите доступный PNG, JPEG или WebP watermark и прозрачность от 0 до 1.")
            }
            let imageURL = URL(fileURLWithPath: path)
            guard ["png", "jpg", "jpeg", "webp"].contains(imageURL.pathExtension.lowercased()),
                  FileManager.default.isReadableFile(atPath: path),
                  let image = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                  CGImageSourceCreateImageAtIndex(image, 0, nil) != nil,
                  config.watermarkOpacity.isFinite, (0...1).contains(config.watermarkOpacity) else {
                return block("Выберите доступный PNG, JPEG или WebP watermark и прозрачность от 0 до 1.")
            }
        }
        if config.goal == .fullOriginal || config.goal == .fullTranslated {
            if config.scope == .fullVideo && config.effect != .watermark {
                return block("Совместные субтитры и эффект на полном видео поддерживаются только через watermark. Для фрагмента доступны скорость и blur.")
            }
        }
        if config.goal == .processing && config.effect == .none && !config.muteFillers {
            return block("Выберите поддерживаемую обработку.")
        }
        if config.goal != .processing && config.goal != .fullOriginal && config.goal != .fullTranslated && config.effect != .none {
            return block("Для выбранного результата эффект не применяется. Выберите пакет обработки.")
        }
        if config.goal.needsTranscript || config.scope != .fullVideo || config.effect == .speed {
            if approvedSource { plan.reused.append("Утверждённая расшифровка") }
            else { plan.stages.append(.transcription) }
        }
        if config.goal == .topics {
            if approvedTopics { plan.reused.append("Утверждённые темы выбранной детализации") }
            else { plan.stages.append(.topics) }
        }
        if config.goal.needsTranslation {
            if approvedTranslation { plan.reused.append("Утверждённый перевод") }
            else { plan.stages.append(.translation) }
        }
        if config.goal.needsVideo { plan.stages.append(.render) }
        return plan
    }
}

enum ProcessingPresetExecutionStatus: String, Codable {
    case running, awaitingReview, stopped, failed, complete
}

struct ProcessingPresetExecution: Codable {
    var projectPath: String
    var configuration: ProcessingPresetConfiguration
    var stages: [ProcessingPresetStage]
    var currentStage = 0
    var status: ProcessingPresetExecutionStatus = .running
    var resultPath: String? = nil
    /// Captured only after the workflow's ffprobe validation succeeds.
    var resultSHA256: String? = nil
    var lastError: String? = nil
    var stageStartedAt: Date? = nil
    var reviewIdentity: String? = nil
    var sourceRevisionID: String? = nil
    var translationRevisionID: String? = nil
    var topicRevisionID: String? = nil
    /// Input bytes used for the selected watermark operation. Path alone is
    /// insufficient because a custom preset can point to a replaced image.
    var watermarkSHA256: String? = nil
}

enum ProcessingPresetInputIdentity {
    static func sourceMatches(manifest: ProjectManifest, mediaURL: URL, store: ProjectStore) -> Bool {
        guard let expected = manifest.sourceFingerprint,
              let current = try? store.sourceFingerprint(for: mediaURL) else { return false }
        return expected.standardizedPath == current.standardizedPath && store.sameSource(expected, current)
    }

    static func watermarkDigest(_ configuration: ProcessingPresetConfiguration) throws -> String? {
        guard configuration.effect == .watermark else { return nil }
        guard let path = configuration.watermarkImagePath else {
            throw WorkflowError.processFailed("Watermark image не выбран.")
        }
        return try ProcessingPresetResultIntegrity.digest(URL(fileURLWithPath: path))
    }

    static func watermarkMatches(_ execution: ProcessingPresetExecution) -> Bool {
        guard execution.configuration.effect == .watermark else { return true }
        guard let expected = execution.watermarkSHA256, expected.count == 64 else { return false }
        return (try? watermarkDigest(execution.configuration)) == expected
    }
}

enum ProcessingPresetReviewIdentity {
    static func matchesSaved(_ saved: String?, current: String?) -> Bool {
        guard let saved, !saved.isEmpty, let current else { return false }
        return saved == current
    }
}

enum ProcessingPresetTextResult {
    static func reusedOutputBlocker(
        configuration: ProcessingPresetConfiguration, manifest: ProjectManifest,
        projectURL: URL, approvedSource: Bool, approvedTopics: Bool
    ) -> String? {
        switch configuration.goal {
        case .transcription where approvedSource:
            guard validatedURL(configuration: configuration, manifest: manifest, projectURL: projectURL) != nil else {
                return "Утверждённая расшифровка есть, но её TXT отсутствует или не совпадает с утверждённой ревизией. Восстановите TXT проекта без повторного ASR."
            }
        case .topics where approvedTopics:
            guard validatedURL(configuration: configuration, manifest: manifest, projectURL: projectURL) != nil else {
                return "Утверждённые темы есть, но TXT выбранной детализации отсутствует или не совпадает со снимком. Восстановите TXT проекта."
            }
        default: break
        }
        return nil
    }

    static func targetURL(
        configuration: ProcessingPresetConfiguration, language: ArtifactLanguage, layout: ProjectLayout
    ) -> URL? {
        switch configuration.goal {
        case .transcription: return layout.transcriptURL(language: language)
        case .translation: return layout.transcriptURL(language: language.translationTarget)
        case .topics: return layout.topicsTextURL(language: language, granularity: configuration.topicGranularity)
        default: return nil
        }
    }

    static func validatedURL(
        execution: ProcessingPresetExecution, manifest: ProjectManifest, projectURL: URL
    ) -> URL? {
        validatedURL(configuration: execution.configuration, manifest: manifest, projectURL: projectURL)
    }

    static func validatedURL(
        configuration: ProcessingPresetConfiguration, manifest: ProjectManifest, projectURL: URL
    ) -> URL? {
        guard let language = manifest.languageProfile?.effective else { return nil }
        let layout = ProjectLayout(root: projectURL)
        guard let target = targetURL(configuration: configuration, language: language, layout: layout),
              let data = try? Data(contentsOf: target), !data.isEmpty,
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        switch configuration.goal {
        case .transcription, .translation:
            let targetLanguage = configuration.goal == .translation ? language.translationTarget : language
            guard let revision = manifest.activeTranscriptRevision(for: targetLanguage),
                  revision.reviewStatus == .approved,
                  let immutable = try? Data(contentsOf: layout.transcriptRevisionURL(
                    id: revision.id, language: targetLanguage
                  )), immutable == data else { return nil }
        case .topics:
            let granularity = configuration.topicGranularity
            guard let snapshot = try? WorkflowEngine.approvedTopicSnapshot(
                manifest: manifest, projectURL: projectURL, language: language, granularity: granularity
            ), snapshot.file.status == .ready,
            text == TopicFileService().textRepresentation(snapshot.file) else { return nil }
        default: return nil
        }
        return target
    }
}

enum ProcessingPresetResultIntegrity {
    static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        var bytesRead = 0
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            hash.update(data: chunk)
            bytesRead += chunk.count
        }
        guard bytesRead > 0 else { throw WorkflowError.processFailed("Результат пакета пуст.") }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func matches(_ execution: ProcessingPresetExecution, projectURL: URL) -> Bool {
        guard let path = execution.resultPath, let expected = execution.resultSHA256,
              expected.count == 64 else { return false }
        let root = projectURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root) else { return false }
        return (try? digest(file)) == expected
    }
}

enum ProcessingPresetOutputSelection {
    static func select(_ execution: ProcessingPresetExecution, manifest: ProjectManifest) -> ProjectOutput? {
        let config = execution.configuration
        let kind: String
        if config.scope == .timeFragment { kind = "processed-fragment-video" }
        else if config.scope == .approvedTopic {
            let language = config.needsTranslatedSubtitles
                ? config.targetLanguage.rawValue : (manifest.languageProfile?.effective?.rawValue ?? "")
            kind = "fragment-subtitled-video-\(language)"
        } else if config.effect == .watermark { kind = "watermarked-video" }
        else if config.goal == .sourceSubtitles { kind = "subtitled-video" }
        else if config.goal == .translatedSubtitles {
            kind = "subtitled-video-\(config.targetLanguage.rawValue)"
        } else {
            switch config.effect {
            case .speed: kind = "speed-adjusted-video"
            case .blur: kind = "blurred-video"
            case .audioEnhancement: kind = "enhanced-video"
            case .none, .watermark: return nil
            }
        }
        guard let started = execution.stageStartedAt else { return nil }
        return manifest.outputs.filter { $0.kind == kind && $0.createdAt >= started }
            .sorted { $0.createdAt > $1.createdAt }.first
    }
}

/// The accepted target revision alone cannot establish translation provenance:
/// a later approved source edit can leave the old target marked approved.
enum ProcessingPresetTranslationEligibility {
    static func ready(
        manifest: ProjectManifest, projectURL: URL, approvedSource: TranscriptRevision
    ) -> Bool {
        guard let source = manifest.languageProfile?.effective,
              approvedSource.id == manifest.activeTranscriptRevision(for: source)?.id,
              approvedSource.reviewStatus == .approved,
              let target = manifest.activeTranscriptRevision(for: source.translationTarget),
              target.reviewStatus == .approved,
              manifest.humanReviewState?.pendingCheckpoint == nil else { return false }
        let layout = ProjectLayout(root: projectURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let reportData = try? Data(contentsOf: layout.translationReportURL(
            source: source, target: source.translationTarget
        )), let report = try? decoder.decode(TranslationReport.self, from: reportData),
              report.sourceLanguage == source,
              report.targetLanguage == source.translationTarget,
              report.sourceRevisionID == approvedSource.id,
              (target.origin == .userEdited || report.targetRevisionID == target.id),
              (report.status == .ready && report.reviewTaskIDs.isEmpty) || target.origin == .userEdited,
              TranslationResumeValidator.outputsMatch(report: report, manifest: manifest, layout: layout),
              (try? SubtitleSourceResolver.resolve(
                .approvedTranslation(source.translationTarget), manifest: manifest, projectURL: projectURL
              )) != nil else { return false }
        let related = (manifest.artifacts ?? []).filter {
            $0.id == target.transcriptArtifactID || $0.id == target.subtitleArtifactID
        }
        return related.allSatisfy { $0.validationStatus == .ready }
            && ((try? layout.transcriptURL(language: source.translationTarget)
                .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }
}

enum ProcessingPresetRunContract {
    static func muteFillers(_ configuration: ProcessingPresetConfiguration?, advanced: Bool) -> Bool {
        configuration?.muteFillers ?? advanced
    }

    static func source(_ configuration: ProcessingPresetConfiguration?, advanced: SpeedSourceKind) -> SpeedSourceKind {
        configuration == nil ? advanced : .fullVideo
    }

    static func ownsCompletion(
        token: UUID?, activeToken: UUID?, execution: ProcessingPresetExecution?
    ) -> Bool {
        guard let token, token == activeToken else { return false }
        return execution?.status == .running
    }
}

struct ProcessingPresetExecutionStore {
    func url(for projectURL: URL) -> URL {
        projectURL.appendingPathComponent("Support/Preset/execution.json")
    }

    func load(from projectURL: URL) throws -> ProcessingPresetExecution? {
        let location = url(for: projectURL)
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        let value = try JSONDecoder().decode(ProcessingPresetExecution.self, from: Data(contentsOf: location))
        guard value.projectPath == projectURL.standardizedFileURL.path else { return nil }
        let order: [ProcessingPresetStage] = [.transcription, .topics, .translation, .render]
        guard value.currentStage >= 0, value.currentStage <= value.stages.count,
              value.stages == order.filter({ value.stages.contains($0) }),
              (value.status != .complete || value.currentStage == value.stages.count),
              (!value.stages.contains(.topics) || value.configuration.goal == .topics),
              (!value.stages.contains(.translation) || value.configuration.goal.needsTranslation),
              (!value.stages.contains(.render) || value.configuration.goal.needsVideo) else {
            throw WorkflowError.processFailed("Сохранённый план пакета имеет недопустимые этапы.")
        }
        return value
    }

    func save(_ value: ProcessingPresetExecution, to projectURL: URL) throws {
        let location = url(for: projectURL)
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: location, options: .atomic)
    }
}

struct CustomProcessingPresetStore {
    var fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL { self.fileURL = fileURL; return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.fileURL = base.appendingPathComponent("VideoText/processing-presets.json")
    }

    func load() throws -> [ProcessingPresetConfiguration] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([ProcessingPresetConfiguration].self, from: Data(contentsOf: fileURL))
    }

    func save(_ presets: [ProcessingPresetConfiguration]) throws {
        // A corrupt existing library is retained for recovery, never silently
        // replaced by the empty in-memory fallback from a failed load.
        if FileManager.default.fileExists(atPath: fileURL.path) { _ = try load() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(presets).write(to: fileURL, options: .atomic)
    }
}
