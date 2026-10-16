import Foundation

enum ProjectArtifactAvailability: Equatable {
    case ready
    case partial
    case missing
    case invalid

    var title: String {
        switch self {
        case .ready: return "Готово"
        case .partial: return "Частично"
        case .missing: return "Отсутствует"
        case .invalid: return "Ошибка"
        }
    }
}

enum ProjectArtifactKind: String, CaseIterable, Identifiable {
    case transcription
    case timeline
    case topics
    case subtitles
    case subtitledVideo
    case fragments
    case diagnostics
    case manifest
    case ffprobe
    case discovery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcription: return "Расшифровка"
        case .timeline: return "Проверка временной шкалы"
        case .topics: return "Тематический таймкодинг"
        case .subtitles: return "Субтитры SRT"
        case .subtitledVideo: return "Видео с субтитрами"
        case .fragments: return "Фрагменты"
        case .diagnostics: return "Диагностика"
        case .manifest: return "Манифест проекта"
        case .ffprobe: return "Проверка ffprobe"
        case .discovery: return "Обнаружение результатов"
        }
    }

    var isAdditionalService: Bool {
        switch self {
        case .diagnostics, .manifest, .ffprobe, .discovery: return true
        default: return false
        }
    }
}

struct ProjectArtifactSummary: Identifiable, Equatable {
    var id: ProjectArtifactKind { kind }
    var kind: ProjectArtifactKind
    var availability: ProjectArtifactAvailability
    var detail: String
}

struct ProjectResultSummary: Equatable {
    var artifacts: [ProjectArtifactSummary]
    var lastRunStatus: ProjectStatus?
    var lastError: String?

    static let empty = ProjectResultSummary(
        artifacts: ProjectArtifactKind.allCases.map {
            ProjectArtifactSummary(kind: $0, availability: .missing, detail: "Проект не открыт")
        },
        lastRunStatus: nil,
        lastError: nil
    )

    func artifact(_ kind: ProjectArtifactKind) -> ProjectArtifactSummary? {
        artifacts.first { $0.kind == kind }
    }
}

struct ProjectResultSummaryService {
    private let fileManager = FileManager.default
    private let srt = SRTService()
    private let detector = ResultsDetector()

    func summarize(projectURL: URL) -> ProjectResultSummary {
        let layout = ProjectLayout(root: projectURL)
        let parsedSRT: Result<SRTParseResult, Error>? = nonemptyFile(layout.fullSRTURL)
            ? Result { try srt.loadWithReport(from: layout.fullSRTURL) }
            : nil
        let outputs = detector.discover(in: projectURL)
        let manifest = try? ProjectStore().load(from: projectURL)

        return ProjectResultSummary(
            artifacts: [
                transcriptionSummary(layout: layout, parsedSRT: parsedSRT),
                timelineSummary(layout: layout),
                topicsSummary(layout: layout),
                subtitlesSummary(parsedSRT: parsedSRT),
                fileSummary(kind: .subtitledVideo, url: layout.subtitledVideoURL, readyDetail: "subtitled.mp4"),
                fragmentsSummary(outputs: outputs),
                diagnosticsSummary(layout: layout),
                manifestSummary(layout: layout, manifest: manifest),
                ffprobeSummary(outputs: outputs),
                summary(.discovery, .ready, "Найдено файлов: \(outputs.count)")
            ],
            lastRunStatus: manifest?.workflow?.status,
            lastError: manifest?.workflow?.lastError
        )
    }

    private func transcriptionSummary(
        layout: ProjectLayout,
        parsedSRT: Result<SRTParseResult, Error>?
    ) -> ProjectArtifactSummary {
        guard let parsedSRT else {
            return summary(.transcription, .missing, "Расшифровка ещё не выполнена")
        }
        switch parsedSRT {
        case .success(let result):
            let cueText = cueDescription(result.cues.count)
            if nonemptyFile(layout.transcriptURL) {
                return summary(.transcription, .ready, "\(cueText), SRT и TXT")
            }
            return summary(.transcription, .partial, "\(cueText); обычный TXT отсутствует")
        case .failure(let error):
            return summary(.transcription, .invalid, error.localizedDescription)
        }
    }

    private func timelineSummary(layout: ProjectLayout) -> ProjectArtifactSummary {
        guard nonemptyFile(layout.timelineValidationURL) else {
            return summary(.timeline, .missing, "Проверка ещё не выполнена")
        }
        let report = (try? String(contentsOf: layout.timelineValidationURL, encoding: .utf8)) ?? ""
        guard report.contains("Временная шкала корректна") else {
            let detail = report.split(separator: "\n").first.map(String.init) ?? "Отчёт проверки некорректен"
            return summary(.timeline, .invalid, detail)
        }
        if nonemptyFile(layout.fullSRTURL), !isAtLeastAsNew(layout.timelineValidationURL, as: layout.fullSRTURL) {
            return summary(.timeline, .partial, "Нужно повторить после изменения SRT")
        }
        return summary(.timeline, .ready, "Интервалы проверены")
    }

    private func topicsSummary(layout: ProjectLayout) -> ProjectArtifactSummary {
        guard nonemptyFile(layout.topicsURL) else {
            return summary(.topics, .missing, "topics.json ещё не создан")
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(TopicsFile.self, from: Data(contentsOf: layout.topicsURL))
            let topics = file.topics
            guard !topics.isEmpty else { return summary(.topics, .invalid, "В topics.json нет тем") }
            guard TopicAlgorithmIdentity.recognizes(file) else {
                return summary(.topics, .partial, "Устаревший алгоритм \(file.adapter); выполните таймкодинг повторно")
            }
            let sourceCandidates = [layout.fullSRTURL] + ArtifactLanguage.allCases.map {
                layout.subtitlesURL(language: $0)
            }
            let matchingSource = sourceCandidates.first { sourceURL in
                guard nonemptyFile(sourceURL),
                      let source = try? String(contentsOf: sourceURL, encoding: .utf8) else { return false }
                return file.sourceSignature == StableTopicHash.string(source)
            }
            guard matchingSource != nil else {
                return summary(.topics, .partial, "\(topicDescription(topics.count)); содержимое SRT изменилось")
            }
            if file.status == .draft {
                return summary(.topics, .partial, "\(topicDescription(topics.count)); черновой режим")
            }
            return summary(.topics, .ready, topicDescription(topics.count))
        } catch {
            return summary(.topics, .invalid, "topics.json не читается")
        }
    }

    private func subtitlesSummary(parsedSRT: Result<SRTParseResult, Error>?) -> ProjectArtifactSummary {
        guard let parsedSRT else { return summary(.subtitles, .missing, "full.srt отсутствует") }
        switch parsedSRT {
        case .success(let result):
            var detail = "full.srt, \(cueDescription(result.cues.count))"
            if result.skippedZeroDurationCount > 0 {
                detail += "; пропущено служебных: \(result.skippedZeroDurationCount)"
            }
            return summary(.subtitles, .ready, detail)
        case .failure(let error):
            return summary(.subtitles, .invalid, error.localizedDescription)
        }
    }

    private func fileSummary(
        kind: ProjectArtifactKind,
        url: URL,
        readyDetail: String
    ) -> ProjectArtifactSummary {
        nonemptyFile(url)
            ? summary(kind, .ready, readyDetail)
            : summary(kind, .missing, "Готового файла нет")
    }

    private func fragmentsSummary(outputs: [ProjectOutput]) -> ProjectArtifactSummary {
        let videos = outputs.filter {
            $0.kind == "fragment-video" || $0.kind == "processed-fragment-video"
        }.count
        let processed = outputs.filter { $0.kind == "processed-fragment-video" }.count
        guard videos > 0 else { return summary(.fragments, .missing, "Фрагментов: 0") }
        return summary(.fragments, .ready, "Фрагментов: \(videos), обработанных вариантов: \(processed)")
    }

    private func diagnosticsSummary(layout: ProjectLayout) -> ProjectArtifactSummary {
        guard nonemptyFile(layout.diagnosticsURL) else {
            return summary(.diagnostics, .missing, "Проверка инструментов ещё не выполнена")
        }
        do {
            let report = try JSONDecoder().decode(DiagnosticsReport.self, from: Data(contentsOf: layout.diagnosticsURL))
            let missing = report.tools.filter { !$0.isAvailable }.map(\.name)
            if !missing.isEmpty {
                return summary(.diagnostics, .invalid, "Не найдены: \(missing.joined(separator: ", "))")
            }
            return summary(.diagnostics, .ready, "Инструментов доступно: \(report.tools.count)")
        } catch {
            return summary(.diagnostics, .invalid, "diagnostics.json не читается")
        }
    }

    private func manifestSummary(layout: ProjectLayout, manifest: ProjectManifest?) -> ProjectArtifactSummary {
        guard nonemptyFile(layout.manifestURL) else {
            return summary(.manifest, .missing, "manifest.json отсутствует")
        }
        guard let manifest else {
            return summary(.manifest, .invalid, "manifest.json не читается")
        }
        return summary(.manifest, .ready, "Схема: \(manifest.schemaVersion ?? 1), версия: \(manifest.appVersion)")
    }

    private func ffprobeSummary(outputs: [ProjectOutput]) -> ProjectArtifactSummary {
        let hasFullVideo = outputs.contains { $0.kind == "subtitled-video" || $0.kind.hasPrefix("subtitled-video-") }
        let fragmentFolders = Set(outputs.compactMap { output -> String? in
            guard output.kind == "fragment-video" || output.kind == "fragment-subtitled-video" || output.kind.hasPrefix("fragment-subtitled-video-") else { return nil }
            return URL(fileURLWithPath: output.path).deletingLastPathComponent().path
        })
        let expectedReports = (hasFullVideo ? 1 : 0) + fragmentFolders.count
        guard expectedReports > 0 else {
            return summary(.ffprobe, .missing, "Созданных видео для проверки нет")
        }
        let reports = outputs.filter { $0.kind == "ffprobe" || $0.kind == "fragment-ffprobe" }.count
        guard reports >= expectedReports else {
            return summary(.ffprobe, .partial, "Проверено: \(reports) из \(expectedReports)")
        }
        return summary(.ffprobe, .ready, "Отчётов: \(reports)")
    }

    private func summary(
        _ kind: ProjectArtifactKind,
        _ availability: ProjectArtifactAvailability,
        _ detail: String
    ) -> ProjectArtifactSummary {
        ProjectArtifactSummary(kind: kind, availability: availability, detail: detail)
    }

    private func nonemptyFile(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.intValue > 0
    }

    private func isAtLeastAsNew(_ candidate: URL, as source: URL) -> Bool {
        guard let candidateDate = modificationDate(candidate), let sourceDate = modificationDate(source) else { return false }
        return candidateDate >= sourceDate
    }

    private func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func cueDescription(_ count: Int) -> String {
        "реплик: \(count)"
    }

    private func topicDescription(_ count: Int) -> String {
        "тем: \(count)"
    }
}
