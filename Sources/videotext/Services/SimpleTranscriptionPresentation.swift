import Foundation

/// Presentation intent for one explicitly started Simple transcription.
/// It never creates or replaces a persisted review checkpoint.
struct SimpleTranscriptionPresentation {
    private struct Intent {
        var language: ArtifactLanguage?
        var startedAt: Date
        var sawRunning = false
        var sawCompletion = false
    }

    private var intent: Intent?
    private var presentedCheckpoint: HumanReviewCheckpoint?
    private(set) var projectPath: String?

    mutating func begin(projectURL: URL, language: String, now: Date = Date()) {
        let path = projectURL.standardizedFileURL.path
        projectPath = path
        presentedCheckpoint = nil
        intent = Intent(
            language: ArtifactLanguage(rawValue: language),
            // Persisted checkpoint dates may have whole-second precision.
            startedAt: Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        )
    }

    mutating func cancelPendingReview() {
        intent = nil
    }

    mutating func reset() {
        intent = nil
        presentedCheckpoint = nil
        projectPath = nil
    }

    func belongsTo(_ projectURL: URL?) -> Bool {
        guard let projectURL else { return false }
        return projectPath == projectURL.standardizedFileURL.path
    }

    func sourceRunAlert(_ alert: AppAlert, projectURL: URL?) -> AppAlert {
        guard belongsTo(projectURL), presentedCheckpoint == nil else { return alert }
        var display = alert
        if alert.title == "Обработка остановлена" {
            display.message = "Расшифровка не завершена. Её можно продолжить в этом проекте."
        } else if alert.title == "Ошибка" || alert.title == "Ошибка обработки" {
            display.title = "Не удалось создать расшифровку"
            display.message = Self.displayMessage(for: alert.message)
        }
        return display
    }

    private static func displayMessage(for workflowMessage: String) -> String {
        let reason = redactPaths(in: workflowMessage)
        let normalized = workflowMessage.lowercased()
        if isSourceUnavailable(normalized) {
            return "Причина: \(reason)\n\nПроверьте, что исходный файл доступен, и повторите попытку."
        }
        if isMissingPackagedComponent(normalized) {
            return "Причина: \(reason)\n\nПроверьте установку VideoText и повторите попытку."
        }
        return "Причина: \(reason)\n\nОткройте папку проекта, чтобы посмотреть журнал, затем повторите попытку."
    }

    private static func isSourceUnavailable(_ message: String) -> Bool {
        if message.contains("сначала выберите видео- или аудиофайл") { return true }
        let refersToSource = message.contains("исходн") || message.contains("медиафайл")
        let isUnavailable = message.contains("недоступ") || message.contains("не найден") || message.contains("не уда")
        return refersToSource && isUnavailable
    }

    private static func isMissingPackagedComponent(_ message: String) -> Bool {
        message.contains("не найден обязательный инструмент")
            || message.contains("не найден совместимый компонент seminartext")
            || (message.contains("ffmpeg") && (message.contains("не установ") || message.contains("не найден")))
    }

    /// A workflow error can contain an implementation path. The cause remains
    /// actionable, but the Simple surface should not expose unrelated folders.
    private static func redactPaths(in message: String) -> String {
        let pattern = #"(?:file://)?/(?:[^\s:]+/)*[^\s:]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return message }
        let range = NSRange(message.startIndex..., in: message)
        return expression.stringByReplacingMatches(in: message, range: range, withTemplate: "<путь скрыт>")
    }

    private func matches(_ checkpoint: HumanReviewCheckpoint, projectURL: URL?) -> Bool {
        guard let intent, belongsTo(projectURL), checkpoint.kind == .sourceTranscript,
              checkpoint.createdAt >= intent.startedAt else { return false }
        return intent.language == nil || intent.language == checkpoint.language
    }

    func suppressesReviewAlert(title: String, projectURL: URL?, checkpoint: HumanReviewCheckpoint?) -> Bool {
        guard title == "Требуется Human Review", belongsTo(projectURL),
              let checkpoint, checkpoint.kind == .sourceTranscript else { return false }
        if matches(checkpoint, projectURL: projectURL) { return true }
        return presentedCheckpoint?.revisionID == checkpoint.revisionID
            && presentedCheckpoint?.language == checkpoint.language
    }

    mutating func observe(
        projectURL: URL?,
        mode: ProjectPresentationMode,
        isRunning: Bool,
        checkpoint: HumanReviewCheckpoint?,
        failedOrStopped: Bool = false
    ) -> HumanReviewCheckpoint? {
        guard mode == .simple, belongsTo(projectURL) else {
            reset()
            return nil
        }
        guard !failedOrStopped else {
            cancelPendingReview()
            return nil
        }
        guard var current = intent else { return nil }
        if isRunning {
            // An unrelated later run cannot satisfy an earlier launch intent.
            guard !current.sawCompletion else {
                cancelPendingReview()
                return nil
            }
            current.sawRunning = true
            intent = current
            return nil
        }
        guard current.sawRunning else { return nil }
        current.sawCompletion = true
        intent = current
        guard let checkpoint, matches(checkpoint, projectURL: projectURL) else { return nil }
        presentedCheckpoint = checkpoint
        intent = nil
        return checkpoint
    }

    static func stage(operation: WorkflowOperation?, isStopping: Bool) -> String {
        if isStopping { return "Останавливаем обработку" }
        switch operation {
        case .diagnostics, .createManifest, .ffprobeValidate: return "Проверяем исходный файл"
        case .detectLanguage: return "Определяем язык"
        case .transcribe: return "Создаём расшифровку"
        case .assessTranscriptionQuality, .validateTimeline: return "Проверяем расшифровку"
        case .topicTimecoding: return "Создаём темы"
        case .detectFillerWords: return "Проверяем речь"
        case .discoverResults: return "Подготавливаем результаты"
        default: return "Обработка выполняется"
        }
    }

    static func fraction(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}
