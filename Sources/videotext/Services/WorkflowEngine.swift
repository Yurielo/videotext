import Foundation
import AVFoundation
import AppKit

@MainActor
final class WorkflowViewModel: ObservableObject {
    @Published var mediaURL: URL?
    @Published var projectURL: URL?
    @Published var selectedOperations: Set<WorkflowOperation> = [.transcribe, .topicTimecoding]
    @Published var rangeStartText = "00:00:00.000"
    @Published var rangeEndText = "00:01:00.000"
    @Published var fragmentName = ""
    @Published var burnFragmentSubtitles = true
    @Published var fragmentMuteFillerWords = false
    @Published var fragmentAdjustSpeed = false
    @Published var fragmentApplyBlur = false
    @Published var subtitleStyle = SubtitleStyleSettings.standard
    @Published var whisperModelPath = ""
    @Published var whisperLanguage = "ru"
    @Published var topicGranularity = TopicGranularity.normal
    @Published var artifactLanguage = ArtifactLanguage.ru
    @Published var topicAnalysisMode = TopicAnalysisMode.hybrid
    @Published var selectedTopicID = ""
    @Published var quoteStartText = ""
    @Published var quoteEndText = ""
    @Published var quoteLeadPadding: Double = 0.2
    @Published var quoteTrailingPadding: Double = 0.2
    @Published var speedFactor: Double = 1
    @Published var speedSource = SpeedSourceKind.fullVideo
    @Published var blurEnabled = false
    @Published var blurSource = SpeedSourceKind.fullVideo
    @Published var blurRegion = NormalizedVideoRect(x: 0.65, y: 0.05, width: 0.3, height: 0.2)
    @Published var blurIntensity: Double = 12
    @Published var blurUsesTimeRange = false
    @Published var blurStartText = "00:00:00.000"
    @Published var blurEndText = "00:00:10.000"
    @Published var watermarkImageURL: URL?
    @Published var watermarkSource = SpeedSourceKind.fullVideo
    @Published var watermarkPosition = WatermarkPosition.bottomRight
    @Published var watermarkManualX: Double = 0.75
    @Published var watermarkManualY: Double = 0.75
    @Published var watermarkRelativeWidth: Double = 0.18
    @Published var watermarkMargin: Double = 0.03
    @Published var watermarkOpacity: Double = 0.85
    @Published var watermarkUsesTimeRange = false
    @Published var watermarkStartText = "00:00:00.000"
    @Published var watermarkEndText = "00:00:10.000"
    @Published var watermarkIncludesBlur = false
    @Published var watermarkBurnSubtitles = false
    @Published var fillerMode = FillerProcessingMode.muteAll
    @Published var fillerCandidates: [FillerWordCandidate] = []
    @Published var selectedFillerCandidateIDs = Set<String>()
    @Published var fillerSearch = ""
    @Published var audioEnhancementProfile = AudioEnhancementProfile.normal
    @Published var dubbingLanguage = ArtifactLanguage.ru
    @Published var dubbingMixMode = DubbingMixMode.replace
    @Published var sourceHumanReviewEnabled = true
    @Published var translationHumanReviewEnabled = false
    @Published var fillerAnalysisBeforeReview = true
    @Published var humanReviewCheckpoint: HumanReviewCheckpoint?
    @Published var topicHumanReviewEnabled = true
    @Published var topicReviewCheckpoint: TopicReviewCheckpoint?
    @Published var quoteCandidates: [QuoteRangeCandidate] = []
    @Published var selectedQuoteCandidateID = ""
    @Published var topics: [TopicSegment] = []
    @Published var topicsFileStatus: TopicsFileStatus?
    @Published var topicsEmbeddingModel = ""
    @Published var topicsLanguageModel = ""
    @Published var topicsAlgorithmVersion = ""
    @Published var outputs: [ProjectOutput] = []
    @Published var reviewTasks: [ReviewTask] = []
    @Published var reviewCues: [SubtitleCue] = []
    @Published var resultSummary = ProjectResultSummary.empty
    @Published var history: [ProjectHistoryEntry] = []
    @Published var selectedHistoryID: String?
    @Published var isRunning = false
    @Published var isStopping = false
    @Published var status = "Готово"
    @Published var progress = WorkflowProgress.idle
    @Published var alert: AppAlert?
    @Published var log = AppLog()

    private let engine = WorkflowEngine()
    private let store = ProjectStore()
    private let historyStore = ProjectHistoryStore()
    private let notifications = NotificationService()
    private let finder = FinderService()
    private let resultsDetector = ResultsDetector()
    private let resultSummaryService = ProjectResultSummaryService()
    private let reviewTaskService = ReviewTaskService()
    private let humanReviewService = HumanReviewService()
    private let topicReviewService = TopicReviewService()
    private var clockTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var runStartedAt: Date?
    private var runMode: ProjectRunMode = .newProject
    private var notificationPermissionRequested = false
    private var useQuoteProvenance = false
    private var fillerPreviewPlayer: AVPlayer?
    private var fillerPreviewStopTask: Task<Void, Never>?

    init() {
        whisperModelPath = WhisperModelLocator().bestModelPath() ?? ""
        reloadHistory()
    }

    var rangeDurationText: String {
        guard let start = try? TimecodeParser.parse(rangeStartText),
              let end = try? TimecodeParser.parse(rangeEndText), end > start else { return "Некорректный диапазон" }
        return TimecodeParser.display(end - start)
    }

    var isRangeValid: Bool {
        guard let start = try? TimecodeParser.parse(rangeStartText),
              let end = try? TimecodeParser.parse(rangeEndText) else { return false }
        return end > start
    }

    func selectMedia(_ url: URL) {
        guard !isRunning else { return }
        status = "Подготовка проекта"
        do {
            let automaticProject = try store.createAutomaticProject(for: url)
            mediaURL = url
            projectURL = automaticProject
            runMode = .newProject
            refreshProjectResults(automaticProject)
            topics = []
            topicsFileStatus = nil
            clearTopicMetadata()
            subtitleStyle = .standard
            whisperLanguage = "ru"
            blurEnabled = false
            fragmentMuteFillerWords = false
            fragmentAdjustSpeed = false
            fragmentApplyBlur = false
            fillerMode = .muteAll
            sourceHumanReviewEnabled = true
            translationHumanReviewEnabled = false
            fillerAnalysisBeforeReview = true
            humanReviewCheckpoint = nil
            topicHumanReviewEnabled = true
            topicReviewCheckpoint = nil
            progress = .idle
            log.append("Создан новый проект: \(automaticProject.path)")
            status = "Готово"
            reloadHistory()
        } catch {
            reportPreparationError(error)
        }
    }

    func openProject(_ url: URL) {
        guard !isRunning else { return }
        do {
            let projectRoot = try ProjectLocator().resolve(url)
            let (manifest, sourceURL) = try store.openProject(at: projectRoot)
            mediaURL = sourceURL
            projectURL = projectRoot
            runMode = manifest.workflow?.status == .failed ? .retryFailedOperations : .resumeProject
            refreshProjectResults(projectRoot)
            if let topicsFile = try? WorkflowEngine.loadTopics(projectURL: projectRoot) {
                artifactLanguage = manifest.languageProfile?.effective ?? .ru
                if !loadTopicVariant(language: artifactLanguage, granularity: topicsFile.granularity) {
                    applyTopicFile(topicsFile)
                }
            } else {
                topics = []
                topicsFileStatus = nil
                clearTopicMetadata()
            }
            subtitleStyle = manifest.subtitleStyle ?? .standard
            blurEnabled = false
            fragmentMuteFillerWords = false
            fragmentAdjustSpeed = false
            fragmentApplyBlur = false
            fillerMode = .muteAll
            sourceHumanReviewEnabled = manifest.humanReviewState?.sourceReviewEnabled ?? true
            translationHumanReviewEnabled = manifest.humanReviewState?.translationReviewEnabled ?? false
            fillerAnalysisBeforeReview = manifest.humanReviewState?.fillerAnalysisBeforeReview ?? true
            humanReviewCheckpoint = manifest.humanReviewState?.pendingCheckpoint
            topicHumanReviewEnabled = manifest.topicReviewState?.enabled ?? true
            topicReviewCheckpoint = manifest.topicReviewState?.pendingCheckpoint
            progress = .idle
            status = manifest.workflow?.status.title ?? "Готово"
            selectedHistoryID = projectRoot.path
            log.append("Открыт существующий проект: \(projectRoot.path)")
            log.append("Исходный файл: \(sourceURL.path)")
            reloadHistory()
        } catch {
            reportPreparationError(error)
        }
    }

    func openHistoryEntry(_ entry: ProjectHistoryEntry) {
        openProject(URL(fileURLWithPath: entry.projectPath, isDirectory: true))
    }

    func run() {
        if humanReviewCheckpoint != nil || topicReviewCheckpoint != nil {
            status = "Ожидает проверки"
            alert = AppAlert(title: "Требуется Human Review", message: "Завершите текущую проверку перед продолжением операций.")
            return
        }
        startRun(operations: selectedOperations)
    }

    func createFragment() {
        useQuoteProvenance = false
        var operations: Set<WorkflowOperation> = [.cutRange]
        if burnFragmentSubtitles { operations.insert(.burnFragmentSubtitles) }
        startRun(operations: operations)
    }

    func createTopicFragment() {
        useQuoteProvenance = false
        startRun(operations: [.cutTopic])
    }

    func createProcessedFragment(selectionMode: FragmentSelectionMode) {
        useQuoteProvenance = false
        switch selectionMode {
        case .timecode:
            guard isRangeValid else {
                reportPreparationError(WorkflowError.invalidRange)
                return
            }
        case .topic:
            guard let topic = selectedTopic else {
                reportPreparationError(WorkflowError.missingTopics)
                return
            }
            rangeStartText = TimecodeParser.display(topic.start)
            rangeEndText = TimecodeParser.display(topic.end)
            selectedTopicID = topic.id
        case .quote:
            guard let candidate = selectedQuoteCandidate else {
                reportPreparationError(WorkflowError.processFailed("Выберите найденный диапазон цитат."))
                return
            }
            rangeStartText = TimecodeParser.display(candidate.start)
            rangeEndText = TimecodeParser.display(candidate.end)
            useQuoteProvenance = true
        }
        startRun(operations: [.renderFragment])
    }

    func createSpeedAdjustedVideo() {
        startRun(operations: [.adjustSpeed])
    }

    func createBlurredVideo() {
        guard blurEnabled else { return }
        startRun(operations: [.applyBlur])
    }

    func createWatermarkedVideo() {
        startRun(operations: [.applyWatermark])
    }

    func analyzeFillerWords() {
        startRun(operations: [.detectFillerWords])
    }

    func muteFillerWords() {
        startRun(operations: [.muteFillerWords])
    }

    func analyzeAudio() {
        startRun(operations: [.analyzeAudio])
    }

    func enhanceAudio() {
        startRun(operations: [.enhanceAudio])
    }

    func createDubbing() {
        startRun(operations: [.createDubbing])
    }

    func selectHighConfidenceFillers() {
        for candidate in fillerCandidates where candidate.highConfidence {
            setFillerCandidate(candidate.id, selected: true)
        }
    }

    func selectAllFillers() {
        for candidate in fillerCandidates {
            setFillerCandidate(candidate.id, selected: true)
        }
    }

    func setFillerCandidate(_ id: String, selected: Bool) {
        updateFillerDecision(id: id, decision: selected ? .selectedForMute : .pending)
    }

    func keepFillerCandidate(_ id: String) {
        updateFillerDecision(id: id, decision: .keep)
    }

    func previewFiller(_ candidate: FillerWordCandidate, afterMute: Bool) {
        let sourceURL: URL?
        if afterMute {
            sourceURL = outputs
                .filter { $0.kind == "filler-muted-video" }
                .sorted { $0.createdAt > $1.createdAt }
                .first
                .map { URL(fileURLWithPath: $0.path) }
        } else {
            sourceURL = mediaURL
        }
        guard let sourceURL else { return }
        fillerPreviewStopTask?.cancel()
        let player = AVPlayer(url: sourceURL)
        fillerPreviewPlayer = player
        let start = max(0, candidate.start - 1)
        let duration = max(0.5, candidate.end - candidate.start + 2)
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        fillerPreviewStopTask = Task { [weak player] in
            try? await Task.sleep(nanoseconds: UInt64(min(duration, 30) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { player?.pause() }
        }
    }

    func previewAudioEnhancement(after: Bool) {
        let sourceURL: URL?
        if after {
            sourceURL = outputs
                .filter { $0.kind == "enhanced-video" }
                .sorted { $0.createdAt > $1.createdAt }
                .first
                .map { URL(fileURLWithPath: $0.path) }
        } else {
            sourceURL = mediaURL
        }
        guard let sourceURL else { return }
        fillerPreviewStopTask?.cancel()
        let player = AVPlayer(url: sourceURL)
        fillerPreviewPlayer = player
        player.play()
        fillerPreviewStopTask = Task { [weak player] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { player?.pause() }
        }
    }

    var filteredFillerCandidates: [FillerWordCandidate] {
        let query = fillerSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return fillerCandidates }
        return fillerCandidates.filter {
            $0.text.lowercased().contains(query) || $0.context.lowercased().contains(query)
        }
    }

    private func updateFillerDecision(id: String, decision: FillerCandidateDecision) {
        guard let projectURL else { return }
        let url = ProjectLayout(root: projectURL).fillerWordsURL
        guard var report = try? FillerWordService().load(from: url),
              let index = report.candidates.firstIndex(where: { $0.id == id }) else { return }
        report.candidates[index].decision = decision
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard (try? encoder.encode(report).write(to: url, options: .atomic)) != nil else { return }
        fillerCandidates = report.candidates
        if decision == .selectedForMute { selectedFillerCandidateIDs.insert(id) }
        else { selectedFillerCandidateIDs.remove(id) }
    }

    func findQuoteCandidates() {
        guard let projectURL else { return }
        do {
            let srtURL = ProjectLayout(root: projectURL).subtitlesURL(language: artifactLanguage)
            let cues = try SRTService().load(from: srtURL)
            quoteCandidates = QuoteRangeMatcher().candidates(
                cues: cues,
                startQuote: quoteStartText,
                endQuote: quoteEndText,
                leadPadding: quoteLeadPadding,
                trailingPadding: quoteTrailingPadding
            )
            selectedQuoteCandidateID = quoteCandidates.count == 1 ? quoteCandidates[0].id : ""
            if quoteCandidates.isEmpty {
                throw WorkflowError.processFailed("Цитаты не найдены в расшифровке выбранного языка.")
            }
            if quoteCandidates.count > 1 {
                log.append("Найдено вариантов диапазона по цитатам: \(quoteCandidates.count). Требуется выбрать один.")
            }
        } catch {
            quoteCandidates = []
            selectedQuoteCandidateID = ""
            reportPreparationError(error)
        }
    }

    func clearQuoteCandidates() {
        quoteCandidates = []
        selectedQuoteCandidateID = ""
    }

    var selectedQuoteCandidate: QuoteRangeCandidate? {
        quoteCandidates.first { $0.id == selectedQuoteCandidateID }
    }

    func createQuoteFragment() {
        guard let candidate = selectedQuoteCandidate else {
            reportPreparationError(WorkflowError.processFailed("Выберите найденный диапазон цитат."))
            return
        }
        rangeStartText = TimecodeParser.display(candidate.start)
        rangeEndText = TimecodeParser.display(candidate.end)
        useQuoteProvenance = true
        var operations: Set<WorkflowOperation> = [.cutRange]
        if burnFragmentSubtitles { operations.insert(.burnFragmentSubtitles) }
        startRun(operations: operations)
    }

    func runDiagnostics() {
        startRun(operations: [.diagnostics])
    }

    func stop() {
        guard isRunning, !isStopping else { return }
        isStopping = true
        status = "Остановка..."
        log.append("Запрошена остановка текущего процесса.")
        runTask?.cancel()
    }

    func cancelForApplicationTermination() {
        runTask?.cancel()
        clockTask?.cancel()
        fillerPreviewStopTask?.cancel()
        fillerPreviewPlayer?.pause()
        engine.cancel()
    }

    func prepareForApplicationTermination() async {
        cancelForApplicationTermination()
        try? await Task.sleep(nanoseconds: 200_000_000)
        _ = await engine.shutdownServices()
    }

    func loadDetectedResults() {
        guard let projectURL else { return }
        refreshProjectResults(projectURL)
        if loadTopicVariant(language: artifactLanguage, granularity: topicGranularity) {
            // Selected matrix variant loaded.
        } else if let topicsFile = try? WorkflowEngine.loadTopics(projectURL: projectURL) {
            applyTopicFile(topicsFile)
        } else {
            topics = []
            topicsFileStatus = nil
            clearTopicMetadata()
        }
        reloadHistory()
    }

    func reloadHistory() {
        history = historyStore.entries()
    }

    var selectedTopic: TopicSegment? {
        selectedTopicID.isEmpty ? topics.first : topics.first { $0.id == selectedTopicID }
    }

    var availableArtifactLanguages: [ArtifactLanguage] {
        guard let projectURL else { return [.ru, .en] }
        let layout = ProjectLayout(root: projectURL)
        let available = ArtifactLanguage.allCases.filter { language in
            TopicGranularity.allCases.contains { FileManager.default.fileExists(atPath: layout.topicsURL(language: language, granularity: $0).path) }
                || FileManager.default.fileExists(atPath: layout.subtitlesURL(language: language).path)
        }
        return available.isEmpty ? [.ru, .en] : available
    }

    func selectTopicVariant(language: ArtifactLanguage, granularity: TopicGranularity) {
        artifactLanguage = language
        topicGranularity = granularity
        guard loadTopicVariant(language: language, granularity: granularity) else {
            topics = []
            topicsFileStatus = nil
            selectedTopicID = ""
            clearTopicMetadata()
            return
        }
    }

    @discardableResult
    func saveTopicEdits(title: String, summary: String, startText: String, endText: String) -> Bool {
        guard let projectURL, let topic = selectedTopic else { return false }
        do {
            let start = try TimecodeParser.parse(startText)
            let end = try TimecodeParser.parse(endText)
            let file = try TopicFileService().update(
                projectURL: projectURL,
                id: topic.id,
                title: title,
                summary: summary,
                start: start,
                end: end,
                language: artifactLanguage,
                granularity: topicGranularity
            )
            applyEditedTopics(file, preferredID: topic.id, logMessage: "Тема отредактирована: \(title).")
            return true
        } catch {
            reportPreparationError(error)
            return false
        }
    }

    func splitSelectedTopic() {
        editTopics("Тема разделена.") { service, projectURL, topic in
            try service.split(
                projectURL: projectURL,
                id: topic.id,
                language: artifactLanguage,
                granularity: topicGranularity
            )
        }
    }

    func mergeSelectedTopicWithNext() {
        editTopics("Тема объединена со следующей.") { service, projectURL, topic in
            try service.mergeWithNext(
                projectURL: projectURL,
                id: topic.id,
                language: artifactLanguage,
                granularity: topicGranularity
            )
        }
    }

    func removeSelectedTopicBoundary() {
        editTopics("Граница темы удалена; её реплики присоединены к соседней теме.") { service, projectURL, topic in
            try service.removeBoundary(
                projectURL: projectURL,
                id: topic.id,
                language: artifactLanguage,
                granularity: topicGranularity
            )
        }
    }

    private func refreshProjectResults(_ projectURL: URL) {
        outputs = resultsDetector.discover(in: projectURL)
        resultSummary = resultSummaryService.summarize(projectURL: projectURL)
        let manifest = try? store.load(from: projectURL)
        reviewTasks = manifest?.reviewTasks ?? []
        humanReviewCheckpoint = manifest?.humanReviewState?.pendingCheckpoint
        topicReviewCheckpoint = manifest?.topicReviewState?.pendingCheckpoint
        let layout = ProjectLayout(root: projectURL)
        let reviewURL: URL
        if let language = humanReviewCheckpoint?.language,
           manifest?.languageProfile?.effective != language {
            reviewURL = layout.subtitlesURL(language: language)
        } else {
            reviewURL = layout.fullSRTURL
        }
        reviewCues = (try? SRTService().load(from: reviewURL)) ?? []
        fillerCandidates = (try? FillerWordService().load(from: ProjectLayout(root: projectURL).fillerWordsURL).candidates) ?? []
        selectedFillerCandidateIDs = selectedFillerCandidateIDs.intersection(Set(fillerCandidates.map(\.id)))
    }

    var unresolvedReviewTasks: [ReviewTask] {
        reviewTasks.filter { $0.status == .needsReview }.sorted { $0.start < $1.start }
    }

    var canBeginHumanReview: Bool {
        !isRunning && projectURL != nil && humanReviewCheckpoint == nil && !reviewCues.isEmpty
    }

    func beginHumanReview() {
        guard let projectURL else { return }
        do {
            let manifest = try store.load(from: projectURL)
            let language = manifest.languageProfile?.effective ?? artifactLanguage
            humanReviewCheckpoint = try humanReviewService.beginReview(
                projectURL: projectURL,
                language: language
            )
            sourceHumanReviewEnabled = true
            status = "Ожидает проверки"
            refreshProjectResults(projectURL)
            log.append("Human Review исходной расшифровки открыт вручную.")
        } catch {
            reportPreparationError(error)
        }
    }

    func resolveReviewTask(_ task: ReviewTask, replacementText: String) -> Bool {
        guard !isRunning, let projectURL else { return false }
        do {
            let resolution = try reviewTaskService.resolve(
                projectURL: projectURL,
                taskID: task.id,
                replacementText: replacementText
            )
            reviewTasks = resolution.tasks
            reviewCues = resolution.cues
            refreshProjectResults(projectURL)
            log.append("Фрагмент ручной проверки исправлен: \(TimecodeParser.display(task.start))-\(TimecodeParser.display(task.end)).")
            return true
        } catch {
            reportPreparationError(error)
            return false
        }
    }

    func saveHumanReviewCue(_ cue: SubtitleCue, replacementText: String) -> Bool {
        guard !isRunning, let projectURL, let checkpoint = humanReviewCheckpoint else { return false }
        do {
            reviewCues = try humanReviewService.saveDraftCue(
                projectURL: projectURL,
                language: checkpoint.language,
                cueID: cue.id,
                replacementText: replacementText
            )
            refreshProjectResults(projectURL)
            log.append("Human Review: сохранён текст cue \(cue.id), таймкод не изменён.")
            return true
        } catch {
            reportPreparationError(error)
            return false
        }
    }

    func approveHumanReview() {
        guard !isRunning, let projectURL else { return }
        do {
            let approval = try humanReviewService.approve(projectURL: projectURL)
            humanReviewCheckpoint = nil
            reviewCues = approval.cues
            runMode = .resumeProject
            refreshProjectResults(projectURL)
            log.append("Human Review завершён: утверждена ревизия \(approval.revision.id).")
            if approval.pendingOperations.isEmpty {
                status = "Завершено"
            } else {
                startRun(operations: Set(approval.pendingOperations))
            }
        } catch {
            reportPreparationError(error)
        }
    }

    func beginTopicReview() {
        guard !isRunning, let projectURL else { return }
        do {
            topicReviewCheckpoint = try topicReviewService.beginReview(
                projectURL: projectURL,
                enabled: true,
                force: true
            )
            topicHumanReviewEnabled = true
            status = "Ожидает проверки тем"
            log.append("Human Review тематического таймкодинга открыт вручную.")
        } catch {
            reportPreparationError(error)
        }
    }

    func approveTopicReview() {
        guard !isRunning, let projectURL else { return }
        do {
            let approval = try topicReviewService.approve(projectURL: projectURL)
            topicReviewCheckpoint = nil
            refreshProjectResults(projectURL)
            log.append("Human Review тематического таймкодинга завершён: утверждено вариантов \(approval.revisions.count).")
            if approval.pendingOperations.isEmpty {
                status = "Завершено"
            } else {
                startRun(operations: Set(approval.pendingOperations))
            }
        } catch {
            reportPreparationError(error)
        }
    }

    private func editTopics(
        _ message: String,
        operation: (TopicFileService, URL, TopicSegment) throws -> TopicsFile
    ) {
        guard !isRunning, let projectURL, let topic = selectedTopic else { return }
        do {
            let file = try operation(TopicFileService(), projectURL, topic)
            let candidateIndex = min(topicIndex(topic), max(file.topics.count - 1, 0))
            let preferredID = file.topics.indices.contains(candidateIndex)
                ? file.topics[candidateIndex].id
                : file.topics.first?.id
            applyEditedTopics(file, preferredID: preferredID, logMessage: message)
        } catch {
            reportPreparationError(error)
        }
    }

    private func topicIndex(_ topic: TopicSegment) -> Int {
        topics.firstIndex(where: { $0.id == topic.id }) ?? 0
    }

    private func applyEditedTopics(_ file: TopicsFile, preferredID: String?, logMessage: String) {
        if let projectURL {
            try? TopicFileService().save(
                file,
                projectURL: projectURL,
                language: artifactLanguage,
                granularity: topicGranularity,
                updateLegacyFiles: true
            )
        }
        applyTopicFile(file)
        if let preferredID, topics.contains(where: { $0.id == preferredID }) {
            selectedTopicID = preferredID
        } else {
            selectedTopicID = topics.first?.id ?? ""
        }
        if let projectURL { refreshProjectResults(projectURL) }
        log.append(logMessage)
    }

    private func applyTopicFile(_ file: TopicsFile) {
        topicGranularity = file.granularity
        guard TopicAlgorithmIdentity.recognizes(file) else {
            topics = []
            topicsFileStatus = nil
            selectedTopicID = ""
            topicAnalysisMode = .hybrid
            clearTopicMetadata()
            return
        }
        topics = file.topics
        topicsFileStatus = file.status
        topicAnalysisMode = file.status == .ready ? .hybrid : .draft
        topicsEmbeddingModel = file.embeddingModel ?? ""
        topicsLanguageModel = file.languageModel ?? ""
        topicsAlgorithmVersion = file.algorithmVersion
    }

    @discardableResult
    private func loadTopicVariant(language: ArtifactLanguage, granularity: TopicGranularity) -> Bool {
        guard let projectURL,
              let file = try? WorkflowEngine.loadTopics(
                projectURL: projectURL,
                language: language,
                granularity: granularity
              ) else { return false }
        artifactLanguage = language
        applyTopicFile(file)
        try? TopicFileService().save(
            file,
            projectURL: projectURL,
            language: language,
            granularity: granularity,
            updateLegacyFiles: true
        )
        selectedTopicID = file.topics.first?.id ?? ""
        return true
    }

    private func clearTopicMetadata() {
        topicsEmbeddingModel = ""
        topicsLanguageModel = ""
        topicsAlgorithmVersion = ""
    }

    func openProjectFolder() {
        guard let projectURL else { return }
        do {
            let preferred = outputs
                .filter {
                    $0.kind == "processed-fragment-video"
                        || $0.kind == "fragment-subtitled-video"
                        || $0.kind == "subtitled-video"
                        || $0.kind == "fragment-video"
                }
                .sorted { $0.createdAt > $1.createdAt }
                .first
                .map { URL(fileURLWithPath: $0.path) }
            try finder.openProject(projectURL, preferredOutput: preferred)
        } catch {
            status = "Ошибка"
            log.append(error.localizedDescription)
        }
    }

    private func startRun(operations requestedOperations: Set<WorkflowOperation>) {
        var operations = requestedOperations
        if operations.contains(.renderFragment), fragmentMuteFillerWords {
            operations.insert(.detectFillerWords)
        }
        guard !isRunning else { return }
        guard humanReviewCheckpoint == nil, topicReviewCheckpoint == nil else {
            status = "Ожидает проверки"
            alert = AppAlert(title: "Требуется Human Review", message: "Завершите текущую проверку перед созданием производных файлов.")
            return
        }
        guard let mediaURL else {
            reportPreparationError(WorkflowError.missingMedia)
            return
        }
        guard let projectURL else {
            reportPreparationError(WorkflowError.missingProjectFolder)
            return
        }

        var start: TimeInterval = 0
        var end: TimeInterval = 1
        if operations.contains(.cutRange) || operations.contains(.burnFragmentSubtitles) || operations.contains(.renderFragment) {
            do {
                start = try TimecodeParser.parse(rangeStartText)
                end = try TimecodeParser.parse(rangeEndText)
                guard end > start else { throw WorkflowError.invalidRange }
            } catch {
                reportPreparationError(error)
                return
            }
        }

        isRunning = true
        isStopping = false
        status = "Выполняется"
        requestNotificationAuthorizationIfNeeded()
        progress = .idle
        runStartedAt = Date()
        startClock()

        let quoteProvenance = useQuoteProvenance
        useQuoteProvenance = false
        let blurStart: TimeInterval?
        let blurEnd: TimeInterval?
        if (operations.contains(.applyBlur) || (operations.contains(.renderFragment) && fragmentApplyBlur)), blurUsesTimeRange {
            do {
                blurStart = try TimecodeParser.parse(blurStartText)
                blurEnd = try TimecodeParser.parse(blurEndText)
                guard let blurStart, let blurEnd, blurEnd > blurStart else { throw WorkflowError.invalidRange }
            } catch {
                reportPreparationError(error)
                isRunning = false
                clockTask?.cancel()
                clockTask = nil
                return
            }
        } else {
            blurStart = nil
            blurEnd = nil
        }
        let watermarkStart: TimeInterval?
        let watermarkEnd: TimeInterval?
        if operations.contains(.applyWatermark), watermarkUsesTimeRange {
            do {
                watermarkStart = try TimecodeParser.parse(watermarkStartText)
                watermarkEnd = try TimecodeParser.parse(watermarkEndText)
                guard let watermarkStart, let watermarkEnd, watermarkEnd > watermarkStart else { throw WorkflowError.invalidRange }
            } catch {
                reportPreparationError(error)
                isRunning = false
                clockTask?.cancel()
                clockTask = nil
                return
            }
        } else {
            watermarkStart = nil
            watermarkEnd = nil
        }
        let settings = WorkflowSettings(
            mediaURL: mediaURL,
            projectURL: projectURL,
            selectedOperations: operations,
            mode: runMode,
            rangeStart: start,
            rangeEnd: end,
            fragmentName: fragmentName,
            burnFragmentSubtitles: burnFragmentSubtitles,
            subtitleStyle: subtitleStyle,
            selectedTopicID: selectedTopicID.isEmpty ? nil : selectedTopicID,
            whisperModelPath: whisperModelPath,
            whisperLanguage: whisperLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "auto" : whisperLanguage,
            topicGranularity: topicGranularity,
            topicAnalysisMode: topicAnalysisMode,
            artifactLanguage: artifactLanguage,
            quoteStart: quoteProvenance ? quoteStartText : nil,
            quoteEnd: quoteProvenance ? quoteEndText : nil,
            speedFactor: speedFactor,
            speedSource: speedSource,
            blurSource: blurSource,
            blurRegion: blurRegion,
            blurIntensity: blurIntensity,
            blurStart: blurStart,
            blurEnd: blurEnd,
            watermarkImageURL: watermarkImageURL,
            watermarkSource: watermarkSource,
            watermarkPosition: watermarkPosition,
            watermarkManualX: watermarkManualX,
            watermarkManualY: watermarkManualY,
            watermarkRelativeWidth: watermarkRelativeWidth,
            watermarkMargin: watermarkMargin,
            watermarkOpacity: watermarkOpacity,
            watermarkStart: watermarkStart,
            watermarkEnd: watermarkEnd,
            watermarkIncludesBlur: watermarkIncludesBlur,
            watermarkBurnSubtitles: watermarkBurnSubtitles,
            fillerMode: fillerMode,
            selectedFillerCandidateIDs: selectedFillerCandidateIDs,
            audioEnhancementProfile: audioEnhancementProfile,
            dubbingLanguage: dubbingLanguage,
            dubbingMixMode: dubbingMixMode,
            sourceHumanReviewEnabled: sourceHumanReviewEnabled,
            translationHumanReviewEnabled: translationHumanReviewEnabled,
            fillerAnalysisBeforeReview: fillerAnalysisBeforeReview,
            topicHumanReviewEnabled: topicHumanReviewEnabled,
            fragmentMuteFillerWords: fragmentMuteFillerWords,
            fragmentAdjustSpeed: fragmentAdjustSpeed,
            fragmentApplyBlur: fragmentApplyBlur
        )

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await engine.run(
                    settings: settings,
                    onLog: { [weak self] message in
                        Task { @MainActor in self?.log.append(message) }
                    },
                    onProgress: { [weak self] snapshot in
                        Task { @MainActor in
                            guard let self, snapshot.overallFraction >= self.progress.overallFraction else { return }
                            self.progress = snapshot
                        }
                    }
                )
                self.projectURL = result.projectURL
                self.outputs = result.outputs
                if self.loadTopicVariant(language: self.artifactLanguage, granularity: self.topicGranularity) {
                    // Selected matrix variant loaded.
                } else if let topicFile = try? WorkflowEngine.loadTopics(projectURL: result.projectURL) {
                    self.applyTopicFile(topicFile)
                } else {
                    self.topics = result.topics
                    self.topicsFileStatus = nil
                    self.clearTopicMetadata()
                }
                self.humanReviewCheckpoint = result.checkpoint
                self.topicReviewCheckpoint = result.topicReviewCheckpoint
                self.status = result.checkpoint == nil && result.topicReviewCheckpoint == nil ? "Завершено" : "Ожидает проверки"
                self.runMode = .resumeProject
                self.progress.elapsed = result.elapsed
                self.progress.estimatedTotal = result.elapsed
                self.progress.remaining = 0
                if let checkpoint = result.checkpoint {
                    NSSound.beep()
                    self.alert = AppAlert(
                        title: "Требуется Human Review",
                        message: "Проверьте расшифровку \(checkpoint.language.rawValue.uppercased()). После утверждения обработка продолжится автоматически."
                    )
                } else if result.topicReviewCheckpoint != nil {
                    NSSound.beep()
                    self.alert = AppAlert(
                        title: "Требуется Human Review тем",
                        message: "Проверьте подробный, обычный и крупный таймкодинг. После утверждения обработка продолжится автоматически."
                    )
                } else {
                    await self.notifications.notifySuccess(
                        mediaName: mediaURL.lastPathComponent,
                        elapsed: result.elapsed,
                        projectURL: result.projectURL
                    )
                    self.alert = AppAlert(
                        title: "Обработка завершена",
                        message: "\(mediaURL.lastPathComponent) готово за \(TimeTextFormatter.string(result.elapsed))."
                    )
                }
            } catch is CancellationError {
                self.status = "Остановлено"
                self.alert = AppAlert(title: "Обработка остановлена", message: "Задание можно продолжить из истории проектов.")
            } catch {
                self.status = "Ошибка"
                self.log.append(error.localizedDescription)
                await self.notifications.notifyFailure(message: error.localizedDescription, projectURL: self.projectURL)
                self.alert = AppAlert(title: "Ошибка обработки", message: error.localizedDescription)
            }
            self.clockTask?.cancel()
            self.clockTask = nil
            self.runTask = nil
            self.isRunning = false
            self.isStopping = false
            self.loadDetectedResults()
        }
    }

    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isRunning, let startedAt = self.runStartedAt else { continue }
                self.progress.elapsed = Date().timeIntervalSince(startedAt)
                if let estimatedTotal = self.progress.estimatedTotal {
                    self.progress.remaining = max(1, estimatedTotal - self.progress.elapsed)
                }
            }
        }
    }

    private func requestNotificationAuthorizationIfNeeded() {
        guard !notificationPermissionRequested else { return }
        notificationPermissionRequested = true
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.notifications.requestAuthorization()
            if !granted {
                self.log.append("Системные уведомления отключены. По завершении будет использован звуковой сигнал приложения.")
            }
        }
    }

    private func reportPreparationError(_ error: Error) {
        status = "Ошибка"
        log.append(error.localizedDescription)
        alert = AppAlert(title: "Ошибка", message: error.localizedDescription)
    }
}

extension WorkflowViewModel: ApplicationTerminationHandling {}

struct WorkflowResult {
    var projectURL: URL
    var outputs: [ProjectOutput]
    var topics: [TopicSegment]
    var elapsed: TimeInterval
    var checkpoint: HumanReviewCheckpoint? = nil
    var topicReviewCheckpoint: TopicReviewCheckpoint? = nil
}

final class WorkflowEngine: @unchecked Sendable {
    let controller: ProcessController
    let runner: ToolRunner
    let diagnostics: DiagnosticsService
    let languageDetection: LanguageDetectionService
    let store: ProjectStore
    let srt = SRTService()
    let transcriber: WhisperCLITranscriber
    let ffmpeg: FFmpegAdapter
    let hybridTopicAdapter: TopicAdapter
    let draftTopicAdapter: TopicAdapter
    let detector = ResultsDetector()
    let ollamaMemory = OllamaMemoryManager()
    let transcriptionQuality = TranscriptionQualityService()
    let humanReview: HumanReviewService
    let topicReview: TopicReviewService
    let translationAdapter: TranslationAdapter
    let localWhisperRetry: LocalWhisperRetryService
    let fillerWords = FillerWordService()
    let audioEnhancement: AudioEnhancementAdapter
    let speechSynthesis: SpeechSynthesisAdapter

    init(
        store: ProjectStore = ProjectStore(),
        controller: ProcessController = ProcessController(),
        hybridTopicAdapter: TopicAdapter = HybridTopicAdapter(),
        draftTopicAdapter: TopicAdapter = DraftTopicAdapter(),
        translationAdapter: TranslationAdapter = TranslationAdapter()
    ) {
        self.store = store
        self.controller = controller
        self.hybridTopicAdapter = hybridTopicAdapter
        self.draftTopicAdapter = draftTopicAdapter
        self.translationAdapter = translationAdapter
        runner = ToolRunner(controller: controller)
        diagnostics = DiagnosticsService(runner: runner)
        languageDetection = LanguageDetectionService(runner: runner)
        transcriber = WhisperCLITranscriber(runner: runner)
        ffmpeg = FFmpegAdapter(runner: runner)
        audioEnhancement = AudioEnhancementAdapter(runner: runner)
        speechSynthesis = SpeechSynthesisAdapter(runner: runner)
        localWhisperRetry = LocalWhisperRetryService(runner: runner)
        humanReview = HumanReviewService(store: store)
        topicReview = TopicReviewService(store: store)
    }

    func cancel() {
        controller.cancelCurrentProcess()
    }

    func shutdownServices() async -> [String] {
        controller.cancelCurrentProcess(gracePeriod: 1)
        return await ollamaMemory.unloadVideoTextModels()
    }

    func run(
        settings: WorkflowSettings,
        onLog: @escaping (String) -> Void,
        onProgress: @escaping (WorkflowProgress) -> Void = { _ in }
    ) async throws -> WorkflowResult {
        guard let mediaURL = settings.mediaURL else { throw WorkflowError.missingMedia }
        let projectURL = try settings.projectURL ?? store.createAutomaticProject(for: mediaURL)
        let layout = ProjectLayout(root: projectURL)
        let operations = expanded(
            settings.selectedOperations,
            includeFillerAnalysisBeforeReview: settings.fillerAnalysisBeforeReview
        )
        let existingDuration = (try? store.load(from: projectURL).durationSeconds) ?? nil
        let etaContext = ETAContext(
            mediaDuration: existingDuration,
            model: URL(fileURLWithPath: settings.whisperModelPath).lastPathComponent,
            language: settings.whisperLanguage,
            codec: mediaURL.pathExtension.lowercased(),
            hardware: "\(ProcessInfo.processInfo.hostName)-\(ProcessInfo.processInfo.activeProcessorCount)"
        )
        let tracker = WorkflowProgressTracker(operations: operations, context: etaContext, onProgress: onProgress)
        let startedAt = Date()
        let fileLog = FileLog(projectURL: projectURL)
        var currentOperation: WorkflowOperation?
        var activeFragment: FragmentRecord?

        func log(_ message: String) {
            onLog(message)
            fileLog.append(message)
        }

        log("videotext \(BuildInfo.version) (\(BuildInfo.build))")
        log("Режим: \(settings.mode.rawValue)")
        log("Исходный файл: \(mediaURL.path)")
        log("Папка проекта: \(projectURL.path)")
        var manifest = try store.ensureProject(at: projectURL, mediaURL: mediaURL, mode: settings.mode)
        if let checkpoint = manifest.humanReviewState?.pendingCheckpoint {
            let discovered = detector.discover(in: projectURL)
            log("Операции не запущены: ожидается Human Review \(checkpoint.language.rawValue.uppercased()).")
            return WorkflowResult(
                projectURL: projectURL,
                outputs: discovered,
                topics: (try? Self.loadTopics(projectURL: projectURL).topics) ?? [],
                elapsed: 0,
                checkpoint: checkpoint
            )
        }
        if let checkpoint = manifest.topicReviewState?.pendingCheckpoint {
            let discovered = detector.discover(in: projectURL)
            log("Операции не запущены: ожидается Human Review тематического таймкодинга.")
            return WorkflowResult(
                projectURL: projectURL,
                outputs: discovered,
                topics: (try? Self.loadTopics(projectURL: projectURL).topics) ?? [],
                elapsed: 0,
                topicReviewCheckpoint: checkpoint
            )
        }
        try store.mutate(projectURL) { manifest in
            var state = manifest.humanReviewState ?? .newProjectDefault
            state.sourceReviewEnabled = settings.sourceHumanReviewEnabled
            state.translationReviewEnabled = settings.translationHumanReviewEnabled
            state.fillerAnalysisBeforeReview = settings.fillerAnalysisBeforeReview
            manifest.humanReviewState = state
            var topicState = manifest.topicReviewState ?? .newProjectDefault
            topicState.enabled = settings.topicHumanReviewEnabled
            manifest.topicReviewState = topicState
        }
        try updateWorkflow(projectURL, status: .running, progress: 0, mode: settings.mode, error: nil)

        do {
            for (index, operation) in operations.enumerated() {
                try Task.checkCancellation()
                currentOperation = operation
                tracker.begin(operation)

                manifest = try store.load(from: projectURL)
                if try await shouldSkip(
                    operation,
                    settings: settings,
                    manifest: manifest,
                    projectURL: projectURL,
                    mediaURL: mediaURL,
                    log: log
                ) {
                    log("Пропуск: \(operation.title) — готовый результат прошёл проверку.")
                    try markOperation(operation, status: .skipped, projectURL: projectURL, error: nil)
                    tracker.finish(operation, recordActual: false)
                    try updateWorkflow(projectURL, status: .running, progress: Double(index + 1) / Double(max(operations.count, 1)), mode: settings.mode, error: nil)
                    try refreshDetectedResults(in: projectURL)
                    if let checkpoint = try checkpointAfter(
                        operation,
                        settings: settings,
                        projectURL: projectURL,
                        pendingOperations: Array(operations.dropFirst(index + 1))
                    ) {
                        let progress = Double(index + 1) / Double(max(operations.count, 1))
                        try updateWorkflow(projectURL, status: .awaitingReview, progress: progress, mode: .resumeProject, error: nil)
                        let elapsed = Date().timeIntervalSince(startedAt)
                        let discovered = detector.discover(in: projectURL)
                        log("Восстановлена приостановка для Human Review \(checkpoint.language.rawValue.uppercased()).")
                        return WorkflowResult(
                            projectURL: projectURL,
                            outputs: discovered,
                            topics: (try? Self.loadTopics(projectURL: projectURL).topics) ?? [],
                            elapsed: elapsed,
                            checkpoint: checkpoint
                        )
                    }
                    if let topicCheckpoint = try topicCheckpointAfter(
                        operation,
                        settings: settings,
                        projectURL: projectURL,
                        pendingOperations: Array(operations.dropFirst(index + 1))
                    ) {
                        let progress = Double(index + 1) / Double(max(operations.count, 1))
                        try updateWorkflow(projectURL, status: .awaitingReview, progress: progress, mode: .resumeProject, error: nil)
                        let elapsed = Date().timeIntervalSince(startedAt)
                        log("Восстановлена приостановка для Human Review тематического таймкодинга.")
                        return WorkflowResult(
                            projectURL: projectURL,
                            outputs: detector.discover(in: projectURL),
                            topics: (try? Self.loadTopics(projectURL: projectURL).topics) ?? [],
                            elapsed: elapsed,
                            topicReviewCheckpoint: topicCheckpoint
                        )
                    }
                    continue
                }

                log("Запуск: \(operation.title)")
                try markOperation(operation, status: .running, projectURL: projectURL, error: nil)

                switch operation {
                case .diagnostics:
                    let report = await diagnostics.collect()
                    try store.mutate(projectURL) { manifest in manifest.diagnostics = report }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(report).write(to: layout.diagnosticsURL, options: .atomic)
                    try store.registerOutput(kind: "diagnostics", url: layout.diagnosticsURL, in: projectURL)
                    for tool in report.tools { log("\(tool.name): \(tool.path ?? "не найден")") }

                case .createManifest:
                    manifest = try store.ensureProject(at: projectURL, mediaURL: mediaURL, mode: settings.mode)
                    if manifest.durationSeconds == nil || manifest.durationSeconds == 0 {
                        manifest.durationSeconds = try await ffmpeg.duration(of: mediaURL)
                    }
                    manifest.subtitleStyle = settings.subtitleStyle
                    try store.save(manifest, to: projectURL)
                    log("Манифест сохранён.")

                case .detectLanguage:
                    let modelPath = try WhisperModelLocator().resolvedModelPath(settings.whisperModelPath)
                    let profile = try await languageDetection.detect(
                        mediaURL: mediaURL,
                        projectURL: projectURL,
                        mediaDuration: try await requiredDuration(of: mediaURL, manifest: manifest),
                        modelPath: modelPath,
                        requestedLanguage: settings.whisperLanguage,
                        onProgress: { tracker.update(operation, fraction: $0) },
                        onLog: log
                    )
                    try store.mutate(projectURL) { $0.languageProfile = profile }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    try encoder.encode(profile).write(to: layout.languageDetectionURL, options: .atomic)
                    try store.registerOutput(kind: "language-detection", url: layout.languageDetectionURL, in: projectURL)
                    let effective = profile.effective?.rawValue ?? "auto"
                    log("Язык видео: \(profile.detected.rawValue); язык обработки: \(effective).")

                case .transcribe:
                    let modelPath = try WhisperModelLocator().resolvedModelPath(settings.whisperModelPath)
                    let mediaDuration = try await requiredDuration(of: mediaURL, manifest: manifest)
                    let unloadedModels = await ollamaMemory.unloadTopicModels()
                    try Task.checkCancellation()
                    if !unloadedModels.isEmpty {
                        log("Освобождена память Ollama перед Whisper: \(unloadedModels.joined(separator: ", ")).")
                    }
                    log("Модель Whisper: \(modelPath)")
                    log("Подготовка звуковой дорожки: PCM WAV, 16 кГц, моно.")
                    let detectedLanguage = try store.load(from: projectURL).languageProfile?.effective?.rawValue
                    let transcriptionLanguage = settings.whisperLanguage.lowercased() == "auto"
                        ? (detectedLanguage ?? "auto")
                        : settings.whisperLanguage
                    let transcription = try await transcriber.transcribe(
                        mediaURL: mediaURL,
                        projectURL: projectURL,
                        mediaDuration: mediaDuration,
                        modelPath: modelPath,
                        language: transcriptionLanguage,
                        onProgress: { fraction in
                        tracker.update(operation, fraction: fraction)
                    }, onLog: log)
                    try store.registerOutput(kind: "full-srt", url: transcription.srtURL, in: projectURL)
                    try store.registerOutput(kind: "whisper-json", url: transcription.jsonURL, in: projectURL)
                    let cues = try srt.load(from: transcription.srtURL)
                    try writeTranscript(from: cues, to: layout.transcriptURL)
                    try store.registerOutput(kind: "transcript", url: layout.transcriptURL, in: projectURL)
                    _ = try registerTranscriptRevision(
                        cues: cues,
                        language: transcriptionQuality.inferLanguage(cues: cues, whisperJSONURL: transcription.jsonURL),
                        projectURL: projectURL,
                        layout: layout,
                        sourceSRT: transcription.srtURL,
                        sourceTranscript: layout.transcriptURL,
                        modelPath: modelPath
                    )
                    log("Созданы full.srt и transcript.txt.")

                case .assessTranscriptionQuality:
                    let parsed = try srt.loadWithReport(from: layout.fullSRTURL)
                    let manifest = try store.load(from: projectURL)
                    let language = manifest.languageProfile?.effective
                        ?? transcriptionQuality.inferLanguage(
                            cues: parsed.cues,
                            whisperJSONURL: nonemptyFile(layout.whisperJSONURL) ? layout.whisperJSONURL : nil
                        )
                    let revision = try ensureTranscriptRevision(
                        cues: parsed.cues,
                        language: language,
                        projectURL: projectURL,
                        layout: layout
                    )
                    var assessment = transcriptionQuality.assess(
                        cues: parsed.cues,
                        skippedZeroDurationCount: parsed.skippedZeroDurationCount,
                        whisperJSONURL: nonemptyFile(layout.whisperJSONURL) ? layout.whisperJSONURL : nil,
                        language: language,
                        transcriptRevisionID: revision.id,
                        mediaDuration: try await requiredDuration(of: mediaURL, manifest: manifest)
                    )
                    if assessment.recoveryIssue == nil, !assessment.tasks.isEmpty {
                        let modelPath = try WhisperModelLocator().resolvedModelPath(settings.whisperModelPath)
                        assessment.tasks = try await localWhisperRetry.addSuggestions(
                            to: assessment.tasks,
                            mediaURL: mediaURL,
                            projectURL: projectURL,
                            modelPath: modelPath,
                            language: language,
                            onLog: log
                        )
                        assessment.html = transcriptionQuality.renderHTML(
                            cues: parsed.cues,
                            tasks: assessment.tasks,
                            language: language
                        )
                    }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    try encoder.encode(assessment.report).write(to: layout.transcriptionQualityURL, options: .atomic)
                    try encoder.encode(assessment.tasks).write(to: layout.reviewTasksURL, options: .atomic)
                    try assessment.html.write(to: layout.transcriptReviewHTMLURL, atomically: true, encoding: .utf8)
                    try store.mutate(projectURL) { manifest in
                        let retained = (manifest.reviewTasks ?? []).filter { $0.transcriptRevisionID != revision.id }
                        manifest.reviewTasks = retained + assessment.tasks
                    }
                    try store.registerOutput(kind: "transcription-quality", url: layout.transcriptionQualityURL, in: projectURL)
                    try store.registerOutput(kind: "review-tasks", url: layout.reviewTasksURL, in: projectURL)
                    try store.registerOutput(kind: "transcript-review", url: layout.transcriptReviewHTMLURL, in: projectURL)
                    if let issue = assessment.recoveryIssue {
                        log("Качество расшифровки: обнаружена \(issue.message). Тематический анализ заблокирован до автоматической повторной расшифровки.")
                        throw WorkflowError.processFailed("Расшифровка повреждена: \(issue.message). Повторите расшифровку с автоматическим восстановлением сегментов.")
                    } else {
                        log(assessment.tasks.isEmpty
                            ? "Качество расшифровки: замечаний не найдено."
                            : "Качество расшифровки: создано заданий ручной проверки — \(assessment.tasks.count). Pipeline продолжен.")
                    }

                case .translateTranscript:
                    let current = try store.load(from: projectURL)
                    guard let sourceLanguage = current.languageProfile?.effective else {
                        throw WorkflowError.processFailed("Не определён исходный язык для перевода.")
                    }
                    let targetLanguage: ArtifactLanguage = sourceLanguage == .ru ? .en : .ru
                    let sourceRevision = try ensureTranscriptRevision(
                        cues: try srt.load(from: layout.fullSRTURL),
                        language: sourceLanguage,
                        projectURL: projectURL,
                        layout: layout
                    )
                    let sourceSRT = layout.subtitlesURL(language: sourceLanguage)
                    let sourceCues = try srt.load(from: sourceSRT)
                    let result = try await translationAdapter.translate(
                        cues: sourceCues,
                        source: sourceLanguage,
                        target: targetLanguage,
                        onProgress: { tracker.update(operation, fraction: $0) },
                        onLog: log
                    )
                    let report = try registerTranslation(
                        result,
                        sourceRevision: sourceRevision,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage,
                        projectURL: projectURL,
                        layout: layout
                    )
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    try encoder.encode(report).write(
                        to: layout.translationReportURL(source: sourceLanguage, target: targetLanguage),
                        options: .atomic
                    )
                    try store.registerOutput(
                        kind: "translation-\(sourceLanguage.rawValue)-\(targetLanguage.rawValue)",
                        url: layout.translationReportURL(source: sourceLanguage, target: targetLanguage),
                        in: projectURL
                    )
                    log(report.reviewTaskIDs.isEmpty
                        ? "Перевод \(sourceLanguage.rawValue) → \(targetLanguage.rawValue) готов: \(report.cueCount) cue."
                        : "Перевод сохранён с заданиями ручной проверки: \(report.reviewTaskIDs.count). Pipeline продолжен.")

                case .validateTimeline:
                    try await validateTimeline(mediaURL: mediaURL, layout: layout, projectURL: projectURL, log: log)

                case .topicTimecoding:
                    if nonemptyFile(layout.transcriptionQualityURL),
                       let report = try? store.decoder.decode(
                        TranscriptionQualityReport.self,
                        from: Data(contentsOf: layout.transcriptionQualityURL)
                       ), report.status == .invalid {
                        throw WorkflowError.processFailed(
                            "Тематический таймкодинг не запущен: расшифровка имеет критический статус invalid. " +
                            "Повторно запустите расшифровку; VideoText автоматически обработает длинное видео сегментами."
                        )
                    }
                    let adapter = settings.topicAnalysisMode == .hybrid ? hybridTopicAdapter : draftTopicAdapter
                    let currentManifest = try store.load(from: projectURL)
                    let languages = availableTopicLanguages(manifest: currentManifest, layout: layout)
                    let combinations = languages.flatMap { language in
                        TopicGranularity.allCases.map { (language, $0) }
                    }
                    let mediaDuration = try await requiredDuration(of: mediaURL, manifest: currentManifest)
                    for (combinationIndex, combination) in combinations.enumerated() {
                        let (language, granularity) = combination
                        let srtURL = layout.subtitlesURL(language: language)
                        guard nonemptyFile(srtURL) else { throw WorkflowError.missingFullSRT }
                        log("Тематический набор: \(language.rawValue.uppercased()), \(granularity.title.lowercased()).")
                        let cues = try srt.load(from: srtURL)
                        let context = TopicBuildContext(
                            projectURL: projectURL,
                            mediaDuration: mediaDuration,
                            granularity: granularity,
                            language: language
                        )
                        let progress: (Double) -> Void = { localFraction in
                            let overall = (Double(combinationIndex) + localFraction) / Double(max(combinations.count, 1))
                            tracker.update(operation, fraction: overall)
                        }
                        let topics: TopicsFile
                        do {
                            topics = try await adapter.buildTopics(
                                from: cues,
                                sourceSRT: srtURL,
                                context: context,
                                onProgress: progress,
                                onLog: log
                            )
                        } catch WorkflowError.invalidTopics(let reason) where settings.topicAnalysisMode == .hybrid {
                            log("Качественное описание не прошло строгую проверку: \(reason) Сохраняется проверяемый черновик с исходными cueId.")
                            topics = try await draftTopicAdapter.buildTopics(
                                from: cues,
                                sourceSRT: srtURL,
                                context: context,
                                onProgress: progress,
                                onLog: log
                            )
                        }
                        let activeLanguage = settings.artifactLanguage
                            ?? currentManifest.languageProfile?.effective
                            ?? language
                        let updateLegacy = language == activeLanguage
                            && granularity == settings.topicGranularity
                        try TopicFileService().save(
                            topics,
                            projectURL: projectURL,
                            language: language,
                            granularity: granularity,
                            updateLegacyFiles: updateLegacy
                        )
                        try registerTopicArtifact(
                            topics,
                            language: language,
                            granularity: granularity,
                            sourceLanguage: currentManifest.languageProfile?.effective ?? language,
                            projectURL: projectURL,
                            layout: layout
                        )
                        try store.registerOutput(
                            kind: "topics-\(language.rawValue)-\(granularity.rawValue)",
                            url: layout.topicsURL(language: language, granularity: granularity),
                            in: projectURL
                        )
                        try store.registerOutput(
                            kind: "topics-text-\(language.rawValue)-\(granularity.rawValue)",
                            url: layout.topicsTextURL(language: language, granularity: granularity),
                            in: projectURL
                        )
                        let status = topics.status == .ready ? "готов" : "черновой"
                        log("Набор сохранён. Тем: \(topics.topics.count), статус: \(status).")
                    }

                case .discoverResults:
                    let discovered = detector.discover(in: projectURL)
                    try store.mutate(projectURL) { manifest in manifest.outputs = discovered }
                    log("Найдено файлов результатов проекта: \(discovered.count).")

                case .cutRange:
                    let subtitleLanguage = settings.artifactLanguage
                        ?? manifest.languageProfile?.effective
                        ?? .ru
                    activeFragment = try await createFragment(
                        mediaURL: mediaURL,
                        projectURL: projectURL,
                        start: settings.rangeStart,
                        end: settings.rangeEnd,
                        name: settings.fragmentName,
                        style: settings.subtitleStyle,
                        subtitleLanguage: subtitleLanguage,
                        topicGranularity: nil,
                        topicID: nil,
                        quoteStart: settings.quoteStart,
                        quoteEnd: settings.quoteEnd,
                        onProgress: { tracker.update(operation, fraction: $0) },
                        log: log
                    )

                case .burnFragmentSubtitles:
                    guard var fragment = activeFragment else {
                        throw WorkflowError.processFailed("Не найден созданный в текущем запуске фрагмент.")
                    }
                    fragment = try await burnSubtitlesIntoFragment(
                        fragment,
                        projectURL: projectURL,
                        onProgress: { tracker.update(operation, fraction: $0) },
                        log: log
                    )
                    activeFragment = fragment

                case .cutTopic:
                    let topicLanguage = settings.artifactLanguage
                        ?? manifest.languageProfile?.effective
                        ?? .ru
                    let topic = try Self.selectTopic(
                        projectURL: projectURL,
                        id: settings.selectedTopicID,
                        language: topicLanguage,
                        granularity: settings.topicGranularity
                    )
                    activeFragment = try await createFragment(
                        mediaURL: mediaURL,
                        projectURL: projectURL,
                        start: topic.start,
                        end: topic.end,
                        name: topic.title,
                        style: settings.subtitleStyle,
                        subtitleLanguage: topicLanguage,
                        topicGranularity: settings.topicGranularity,
                        topicID: topic.id,
                        quoteStart: nil,
                        quoteEnd: nil,
                        onProgress: {
                            tracker.update(operation, fraction: settings.burnFragmentSubtitles ? $0 * 0.55 : $0)
                        },
                        log: log
                    )
                    if settings.burnFragmentSubtitles, var fragment = activeFragment {
                        fragment = try await burnSubtitlesIntoFragment(
                            fragment,
                            projectURL: projectURL,
                            onProgress: { tracker.update(operation, fraction: 0.55 + $0 * 0.45) },
                            log: log
                        )
                        activeFragment = fragment
                    }

                case .renderFragment:
                    let language = settings.artifactLanguage
                        ?? manifest.languageProfile?.effective
                        ?? .ru
                    let topic = settings.selectedTopicID.flatMap { id in
                        try? Self.selectTopic(
                            projectURL: projectURL,
                            id: id,
                            language: language,
                            granularity: settings.topicGranularity
                        )
                    }
                    var fragment = try await createFragment(
                        mediaURL: mediaURL,
                        projectURL: projectURL,
                        start: settings.rangeStart,
                        end: settings.rangeEnd,
                        name: settings.fragmentName.isEmpty ? (topic?.title ?? "Фрагмент") : settings.fragmentName,
                        style: settings.subtitleStyle,
                        subtitleLanguage: language,
                        topicGranularity: topic == nil ? nil : settings.topicGranularity,
                        topicID: topic?.id,
                        quoteStart: settings.quoteStart,
                        quoteEnd: settings.quoteEnd,
                        onProgress: { tracker.update(operation, fraction: $0 * 0.2) },
                        log: log
                    )
                    fragment = try await renderProcessedFragment(
                        fragment,
                        projectURL: projectURL,
                        settings: settings,
                        removeSourceAfterSuccess: true,
                        onProgress: { tracker.update(operation, fraction: 0.2 + $0 * 0.8) },
                        log: log
                    )
                    activeFragment = fragment

                case .burnSubtitles:
                    let subtitleLanguage = settings.artifactLanguage
                        ?? manifest.languageProfile?.effective
                        ?? .ru
                    let selectedSRT = layout.subtitlesURL(language: subtitleLanguage)
                    guard FileManager.default.fileExists(atPath: selectedSRT.path) else { throw WorkflowError.missingFullSRT }
                    let sourceLanguage = manifest.languageProfile?.effective ?? subtitleLanguage
                    let outputURL = subtitleLanguage == sourceLanguage
                        ? layout.subtitledVideoURL
                        : layout.subtitledVideoURL(language: subtitleLanguage)
                    let mediaDuration = try await requiredDuration(of: mediaURL, manifest: manifest)
                    let ffmpegPath = try await ffmpeg.burnSubtitles(
                        mediaURL: mediaURL,
                        srtURL: selectedSRT,
                        outputURL: outputURL,
                        mediaDuration: mediaDuration,
                        style: settings.subtitleStyle
                    ) { fraction in tracker.update(operation, fraction: fraction) }
                    try store.registerOutput(kind: "subtitled-video", url: outputURL, in: projectURL)
                    log("Создано полное видео с субтитрами через \(ffmpegPath).")

                case .adjustSpeed:
                    try await createSpeedAdjustedVideo(
                        originalMediaURL: mediaURL,
                        projectURL: projectURL,
                        manifest: manifest,
                        settings: settings,
                        operation: operation,
                        tracker: tracker,
                        log: log
                    )

                case .applyBlur:
                    try await createBlurredVideo(
                        originalMediaURL: mediaURL,
                        projectURL: projectURL,
                        manifest: manifest,
                        settings: settings,
                        operation: operation,
                        tracker: tracker,
                        log: log
                    )

                case .applyWatermark:
                    try await createWatermarkedVideo(
                        originalMediaURL: mediaURL,
                        projectURL: projectURL,
                        manifest: manifest,
                        settings: settings,
                        operation: operation,
                        tracker: tracker,
                        log: log
                    )

                case .detectFillerWords:
                    let current = try store.load(from: projectURL)
                    guard let language = current.languageProfile?.effective,
                          let revision = current.activeTranscriptRevision(for: language) else {
                        throw WorkflowError.processFailed("Не найдена актуальная ревизия расшифровки для анализа слов-паразитов.")
                    }
                    let report = try fillerWords.analyze(
                        whisperJSONURL: layout.whisperJSONURL,
                        cues: try srt.load(from: layout.subtitlesURL(language: language)),
                        language: language,
                        transcriptRevisionID: revision.id
                    )
                    try encoderForDerivedTimeline().encode(report).write(to: layout.fillerWordsURL, options: .atomic)
                    let reviewTasks = report.candidates.filter { !$0.highConfidence }.map { candidate in
                        ReviewTask(
                            id: "review-\(candidate.id)",
                            transcriptRevisionID: revision.id,
                            status: .needsReview,
                            language: language,
                            start: candidate.start,
                            end: candidate.end,
                            cueIDs: [candidate.cueID],
                            reasonCodes: ["filler-candidate-needs-decision"] + candidate.reasonCodes,
                            confidence: candidate.confidence,
                            originalText: candidate.context,
                            suggestedText: candidate.text,
                            createdAt: Date(),
                            resolvedAt: nil,
                            dependentArtifactIDs: ["artifact-filler-\(revision.id)"]
                        )
                    }
                    try store.mutate(projectURL) { manifest in
                        var tasks = manifest.reviewTasks ?? []
                        tasks.removeAll { $0.reasonCodes.contains("filler-candidate-needs-decision") && $0.transcriptRevisionID == revision.id }
                        tasks.append(contentsOf: reviewTasks)
                        manifest.reviewTasks = tasks
                    }
                    try store.registerOutput(kind: "filler-analysis", url: layout.fillerWordsURL, in: projectURL)
                    try store.registerArtifact(ProjectArtifactRecord(
                        id: "artifact-filler-\(revision.id)",
                        kind: .fillerAnalysis,
                        path: layout.fillerWordsURL.path,
                        language: language,
                        origin: .source,
                        granularity: nil,
                        sourceArtifactID: revision.transcriptArtifactID,
                        sourceRevision: revision.id,
                        dependencyIDs: [revision.id],
                        contentHash: StableTopicHash.string(try String(contentsOf: layout.fillerWordsURL, encoding: .utf8)),
                        createdAt: Date(),
                        generator: BuildInfo.name,
                        generatorVersion: BuildInfo.version,
                        model: "whisper-token-timeline",
                        validationStatus: reviewTasks.isEmpty ? .ready : .needsReview,
                        qualityStatus: reviewTasks.isEmpty ? .ready : .needsReview,
                        reviewTaskCount: reviewTasks.count
                    ), in: projectURL)
                    log("Найдено кандидатов слов-паразитов: \(report.candidates.count); уверенных: \(report.candidates.filter(\.highConfidence).count).")

                case .muteFillerWords:
                    var report = try fillerWords.load(from: layout.fillerWordsURL)
                    let selectedIDs: Set<String>
                    switch settings.fillerMode {
                    case .detectOnly:
                        throw WorkflowError.processFailed("Для mute выберите всех, выбранных или уверенных кандидатов.")
                    case .muteAll:
                        selectedIDs = Set(report.candidates.map(\.id))
                    case .muteSelected:
                        selectedIDs = settings.selectedFillerCandidateIDs
                    case .muteHighConfidence:
                        selectedIDs = Set(report.candidates.filter(\.highConfidence).map(\.id))
                    }
                    let selected = report.candidates.filter { selectedIDs.contains($0.id) }
                    guard !selected.isEmpty else {
                        throw WorkflowError.processFailed("Нет выбранных слов-паразитов для mute.")
                    }
                    let current = try store.load(from: projectURL)
                    let duration = try await requiredDuration(of: mediaURL, manifest: current)
                    let id = "filler-mute-\(UUID().uuidString.lowercased())"
                    let outputAudio = layout.fillerMutedAudioURL(id: id)
                    let outputVideo = layout.fillerMutedVideoURL(id: id)
                    let intervals = selected.map { ClosedRangeRecord(start: $0.start, end: $0.end) }
                    let graph = try await ffmpeg.muteAudioIntervals(
                        mediaURL: mediaURL,
                        outputAudioURL: outputAudio,
                        outputVideoURL: outputVideo,
                        intervals: intervals,
                        mediaDuration: duration,
                        onProgress: { tracker.update(operation, fraction: $0) }
                    )
                    for index in report.candidates.indices where selectedIDs.contains(report.candidates[index].id) {
                        report.candidates[index].decision = .muted
                    }
                    try encoderForDerivedTimeline().encode(report).write(to: layout.fillerWordsURL, options: .atomic)
                    let record = FillerMuteRecord(
                        id: id,
                        sourceMediaPath: mediaURL.path,
                        outputAudioPath: outputAudio.path,
                        outputVideoPath: outputVideo.path,
                        transcriptRevisionID: report.transcriptRevisionID,
                        candidateIDs: selected.map(\.id),
                        intervals: intervals,
                        fadeDuration: 0.025,
                        filterGraph: graph,
                        createdAt: Date()
                    )
                    let muteReportURL = layout.fillerMuteReportURL(id: id)
                    try encoderForDerivedTimeline().encode(record).write(to: muteReportURL, options: .atomic)
                    try store.mutate(projectURL) { manifest in
                        var records = manifest.fillerMuteRecords ?? []
                        records.append(record)
                        manifest.fillerMuteRecords = records
                    }
                    try store.registerOutput(kind: "filler-muted-audio", url: outputAudio, in: projectURL)
                    try store.registerOutput(kind: "filler-muted-video", url: outputVideo, in: projectURL)
                    try store.registerOutput(kind: "filler-mute-report", url: muteReportURL, in: projectURL)
                    try store.registerArtifact(ProjectArtifactRecord(
                        id: "artifact-\(id)-audio",
                        kind: .mutedAudio,
                        path: outputAudio.path,
                        language: report.language,
                        origin: .source,
                        granularity: nil,
                        sourceArtifactID: "artifact-filler-\(report.transcriptRevisionID)",
                        sourceRevision: report.transcriptRevisionID,
                        dependencyIDs: selected.map(\.id),
                        contentHash: nil,
                        createdAt: Date(),
                        generator: BuildInfo.name,
                        generatorVersion: BuildInfo.version,
                        model: nil,
                        validationStatus: .ready,
                        qualityStatus: .ready,
                        reviewTaskCount: 0
                    ), in: projectURL)
                    try store.registerArtifact(ProjectArtifactRecord(
                        id: "artifact-\(id)-video",
                        kind: .mutedVideo,
                        path: outputVideo.path,
                        language: report.language,
                        origin: .source,
                        granularity: nil,
                        sourceArtifactID: "artifact-\(id)-audio",
                        sourceRevision: report.transcriptRevisionID,
                        dependencyIDs: ["artifact-\(id)-audio"],
                        contentHash: nil,
                        createdAt: Date(),
                        generator: BuildInfo.name,
                        generatorVersion: BuildInfo.version,
                        model: nil,
                        validationStatus: .ready,
                        qualityStatus: .ready,
                        reviewTaskCount: 0
                    ), in: projectURL)
                    log("Mute применён к кандидатам: \(selected.count). Созданы отдельные аудио и видео; transcript/SRT не изменены.")

                case .analyzeAudio:
                    let report = try await audioEnhancement.analyze(mediaURL: mediaURL)
                    try encoderForDerivedTimeline().encode(report).write(to: layout.audioAnalysisURL, options: .atomic)
                    try store.registerOutput(kind: "audio-analysis", url: layout.audioAnalysisURL, in: projectURL)
                    log("Анализ звука сохранён: mean \(report.meanVolumeDB.map { String(format: "%.1f dB", $0) } ?? "n/a"), peak \(report.maxVolumeDB.map { String(format: "%.1f dB", $0) } ?? "n/a").")

                case .enhanceAudio:
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let before = try decoder.decode(AudioAnalysisReport.self, from: Data(contentsOf: layout.audioAnalysisURL))
                    let sourceLanguage = try store.load(from: projectURL).languageProfile?.effective
                    let id = "audio-enhancement-\(settings.audioEnhancementProfile.rawValue)-\(UUID().uuidString.lowercased())"
                    let outputAudio = layout.enhancedAudioURL(id: id)
                    let outputVideo = layout.enhancedVideoURL(id: id)
                    let result = try await audioEnhancement.enhance(
                        mediaURL: mediaURL,
                        outputAudioURL: outputAudio,
                        outputVideoURL: outputVideo,
                        profile: settings.audioEnhancementProfile,
                        sourceLanguage: sourceLanguage,
                        before: before,
                        onProgress: { tracker.update(operation, fraction: $0) }
                    )
                    let record = AudioEnhancementRecord(
                        id: id,
                        sourceMediaPath: mediaURL.path,
                        outputAudioPath: outputAudio.path,
                        outputVideoPath: outputVideo.path,
                        profile: settings.audioEnhancementProfile,
                        backendModel: result.backendModel,
                        filterGraph: result.filterGraph,
                        before: result.before,
                        after: result.after,
                        createdAt: Date()
                    )
                    let reportURL = layout.audioEnhancementReportURL(id: id)
                    try encoderForDerivedTimeline().encode(record).write(to: reportURL, options: .atomic)
                    try store.mutate(projectURL) { manifest in
                        var records = manifest.audioEnhancements ?? []
                        records.append(record)
                        manifest.audioEnhancements = records
                    }
                    try store.registerOutput(kind: "enhanced-audio", url: outputAudio, in: projectURL)
                    try store.registerOutput(kind: "enhanced-video", url: outputVideo, in: projectURL)
                    try store.registerOutput(kind: "audio-enhancement-report", url: reportURL, in: projectURL)
                    try store.registerArtifact(ProjectArtifactRecord(
                        id: "artifact-\(id)-audio",
                        kind: .enhancedAudio,
                        path: outputAudio.path,
                        language: nil,
                        origin: .source,
                        granularity: nil,
                        sourceArtifactID: nil,
                        sourceRevision: nil,
                        dependencyIDs: [],
                        contentHash: nil,
                        createdAt: Date(),
                        generator: BuildInfo.name,
                        generatorVersion: BuildInfo.version,
                        model: result.backendModel,
                        validationStatus: .ready,
                        qualityStatus: .ready,
                        reviewTaskCount: 0
                    ), in: projectURL)
                    log("Созданы отдельные улучшенная аудиодорожка и видео, профиль: \(settings.audioEnhancementProfile.title), UVR: \(result.backendModel).")

                case .createDubbing:
                    let current = try store.load(from: projectURL)
                    guard let sourceLanguage = current.languageProfile?.effective,
                          settings.dubbingLanguage != sourceLanguage else {
                        throw WorkflowError.processFailed("Для дубляжа выберите язык перевода, отличный от языка исходного видео.")
                    }
                    guard let revision = current.activeTranscriptRevision(for: settings.dubbingLanguage) else {
                        throw WorkflowError.processFailed("Не найдена переведённая ревизия для дубляжа.")
                    }
                    let targetSRT = layout.subtitlesURL(language: settings.dubbingLanguage)
                    let duration = try await requiredDuration(of: mediaURL, manifest: current)
                    let id = "dubbing-\(settings.dubbingLanguage.rawValue)-\(UUID().uuidString.lowercased())"
                    let outputAudio = layout.dubbedAudioURL(id: id)
                    let outputVideo = layout.dubbedVideoURL(id: id)
                    let result = try await speechSynthesis.synthesize(
                        cues: try srt.load(from: targetSRT),
                        language: settings.dubbingLanguage,
                        transcriptRevisionID: revision.id,
                        mediaURL: mediaURL,
                        mediaDuration: duration,
                        outputAudioURL: outputAudio,
                        outputVideoURL: outputVideo,
                        mixMode: settings.dubbingMixMode,
                        onProgress: { tracker.update(operation, fraction: $0) }
                    )
                    let record = DubbingRecord(
                        id: id,
                        sourceMediaPath: mediaURL.path,
                        sourceSubtitlePath: targetSRT.path,
                        outputAudioPath: outputAudio.path,
                        outputVideoPath: outputVideo.path,
                        language: settings.dubbingLanguage,
                        voiceIdentifier: result.voiceIdentifier,
                        voiceProviderVersion: result.voiceProviderVersion,
                        mixMode: settings.dubbingMixMode,
                        cues: result.cues,
                        reviewTaskIDs: result.reviewTasks.map(\.id),
                        createdAt: Date()
                    )
                    let reportURL = layout.dubbingReportURL(id: id)
                    try encoderForDerivedTimeline().encode(record).write(to: reportURL, options: .atomic)
                    try store.mutate(projectURL) { manifest in
                        var records = manifest.dubbingRecords ?? []
                        records.append(record)
                        manifest.dubbingRecords = records
                        var tasks = manifest.reviewTasks ?? []
                        tasks.removeAll { result.reviewTasks.map(\.id).contains($0.id) }
                        tasks.append(contentsOf: result.reviewTasks)
                        manifest.reviewTasks = tasks
                    }
                    try store.registerOutput(kind: "dubbed-audio", url: outputAudio, in: projectURL)
                    try store.registerOutput(kind: "dubbed-video", url: outputVideo, in: projectURL)
                    try store.registerOutput(kind: "dubbing-report", url: reportURL, in: projectURL)
                    try store.registerArtifact(ProjectArtifactRecord(
                        id: "artifact-\(id)-audio",
                        kind: .dubbedAudio,
                        path: outputAudio.path,
                        language: settings.dubbingLanguage,
                        origin: .translated,
                        granularity: nil,
                        sourceArtifactID: revision.transcriptArtifactID,
                        sourceRevision: revision.id,
                        dependencyIDs: [revision.id],
                        contentHash: nil,
                        createdAt: Date(),
                        generator: BuildInfo.name,
                        generatorVersion: BuildInfo.version,
                        model: result.voiceIdentifier,
                        validationStatus: result.reviewTasks.isEmpty ? .ready : .needsReview,
                        qualityStatus: result.reviewTasks.isEmpty ? .ready : .needsReview,
                        reviewTaskCount: result.reviewTasks.count
                    ), in: projectURL)
                    log("Нейтральный дубляж \(settings.dubbingLanguage.rawValue.uppercased()) создан голосом \(result.voiceIdentifier); заданий проверки темпа: \(result.reviewTasks.count).")

                case .ffprobeValidate:
                    try await validateAllVideos(projectURL: projectURL, operation: operation, tracker: tracker, log: log)
                }

                try markOperation(operation, status: .completed, projectURL: projectURL, error: nil)
                tracker.finish(operation)
                try updateWorkflow(projectURL, status: .running, progress: Double(index + 1) / Double(max(operations.count, 1)), mode: settings.mode, error: nil)
                try refreshDetectedResults(in: projectURL)
                if let checkpoint = try checkpointAfter(
                    operation,
                    settings: settings,
                    projectURL: projectURL,
                    pendingOperations: Array(operations.dropFirst(index + 1))
                ) {
                    let progress = Double(index + 1) / Double(max(operations.count, 1))
                    try updateWorkflow(projectURL, status: .awaitingReview, progress: progress, mode: .resumeProject, error: nil)
                    let elapsed = Date().timeIntervalSince(startedAt)
                    let discovered = detector.discover(in: projectURL)
                    log("Обработка приостановлена для Human Review \(checkpoint.language.rawValue.uppercased()).")
                    return WorkflowResult(
                        projectURL: projectURL,
                        outputs: discovered,
                        topics: (try? Self.loadTopics(projectURL: projectURL).topics) ?? [],
                        elapsed: elapsed,
                        checkpoint: checkpoint
                    )
                }
                if let topicCheckpoint = try topicCheckpointAfter(
                    operation,
                    settings: settings,
                    projectURL: projectURL,
                    pendingOperations: Array(operations.dropFirst(index + 1))
                ) {
                    let progress = Double(index + 1) / Double(max(operations.count, 1))
                    try updateWorkflow(projectURL, status: .awaitingReview, progress: progress, mode: .resumeProject, error: nil)
                    let elapsed = Date().timeIntervalSince(startedAt)
                    log("Обработка приостановлена для Human Review тематического таймкодинга.")
                    return WorkflowResult(
                        projectURL: projectURL,
                        outputs: detector.discover(in: projectURL),
                        topics: (try? Self.loadTopics(projectURL: projectURL).topics) ?? [],
                        elapsed: elapsed,
                        topicReviewCheckpoint: topicCheckpoint
                    )
                }
            }
        } catch is CancellationError {
            cleanupPartialFiles(in: projectURL)
            if let currentOperation {
                try? markOperation(currentOperation, status: .stopped, projectURL: projectURL, error: "Остановлено пользователем")
            }
            try? updateWorkflow(projectURL, status: .stopped, progress: currentProgress(projectURL), mode: settings.mode, error: nil)
            try? refreshDetectedResults(in: projectURL)
            log("Задание остановлено пользователем. Незавершённые файлы удалены.")
            throw CancellationError()
        } catch {
            cleanupPartialFiles(in: projectURL)
            if let currentOperation {
                try? markOperation(currentOperation, status: .failed, projectURL: projectURL, error: error.localizedDescription)
            }
            try? updateWorkflow(projectURL, status: .failed, progress: currentProgress(projectURL), mode: settings.mode, error: error.localizedDescription)
            try? refreshDetectedResults(in: projectURL)
            log("Ошибка: \(error.localizedDescription)")
            throw error
        }

        tracker.complete()
        let elapsed = Date().timeIntervalSince(startedAt)
        let discovered = detector.discover(in: projectURL)
        try store.mutate(projectURL) { manifest in
            manifest.outputs = discovered
            manifest.subtitleStyle = settings.subtitleStyle
            manifest.workflow?.status = .completed
            manifest.workflow?.progress = 1
            manifest.workflow?.lastError = nil
        }
        log("Задание завершено за \(TimeTextFormatter.string(elapsed)).")
        return WorkflowResult(
            projectURL: projectURL,
            outputs: discovered,
            topics: (try? Self.loadTopics(projectURL: projectURL).topics) ?? [],
            elapsed: elapsed,
            checkpoint: nil
        )
    }

    private func checkpointAfter(
        _ operation: WorkflowOperation,
        settings: WorkflowSettings,
        projectURL: URL,
        pendingOperations: [WorkflowOperation]
    ) throws -> HumanReviewCheckpoint? {
        let manifest = try store.load(from: projectURL)
        let kind: HumanReviewCheckpointKind
        let language: ArtifactLanguage
        let revision: TranscriptRevision
        switch operation {
        case .assessTranscriptionQuality:
            guard !settings.fillerAnalysisBeforeReview else { return nil }
            guard let sourceLanguage = manifest.languageProfile?.effective,
                  let sourceRevision = revisionMatchingWorkingSubtitle(
                    manifest: manifest,
                    language: sourceLanguage,
                    projectURL: projectURL
                  ) else {
                throw WorkflowError.processFailed("Не найдена исходная ревизия для Human Review.")
            }
            kind = .sourceTranscript
            language = sourceLanguage
            revision = sourceRevision
        case .detectFillerWords:
            guard settings.fillerAnalysisBeforeReview,
                  let sourceLanguage = manifest.languageProfile?.effective,
                  let sourceRevision = revisionMatchingWorkingSubtitle(
                    manifest: manifest,
                    language: sourceLanguage,
                    projectURL: projectURL
                  ) else {
                return nil
            }
            kind = .sourceTranscript
            language = sourceLanguage
            revision = sourceRevision
        case .translateTranscript:
            guard let sourceLanguage = manifest.languageProfile?.effective else {
                throw WorkflowError.processFailed("Не определён исходный язык Human Review перевода.")
            }
            let targetLanguage: ArtifactLanguage = sourceLanguage == .ru ? .en : .ru
            guard let translatedRevision = manifest.transcriptRevisions?.last(where: {
                $0.language == targetLanguage && $0.origin == .translated
            }) else {
                throw WorkflowError.processFailed("Не найдена переведённая ревизия для Human Review.")
            }
            kind = .translatedTranscript
            language = targetLanguage
            revision = translatedRevision
        default:
            return nil
        }
        return try humanReview.transitionAfterGeneration(
            projectURL: projectURL,
            kind: kind,
            language: language,
            revisionID: revision.id,
            pendingOperations: pendingOperations,
            sourceReviewEnabled: settings.sourceHumanReviewEnabled,
            translationReviewEnabled: settings.translationHumanReviewEnabled
        )
    }

    private func topicCheckpointAfter(
        _ operation: WorkflowOperation,
        settings: WorkflowSettings,
        projectURL: URL,
        pendingOperations: [WorkflowOperation]
    ) throws -> TopicReviewCheckpoint? {
        guard operation == .topicTimecoding else { return nil }
        return try topicReview.beginReview(
            projectURL: projectURL,
            pendingOperations: pendingOperations,
            enabled: settings.topicHumanReviewEnabled
        )
    }

    private func revisionMatchingWorkingSubtitle(
        manifest: ProjectManifest,
        language: ArtifactLanguage,
        projectURL: URL
    ) -> TranscriptRevision? {
        let layout = ProjectLayout(root: projectURL)
        let subtitleURL = manifest.languageProfile?.effective == language
            ? layout.fullSRTURL
            : layout.subtitlesURL(language: language)
        if let text = try? String(contentsOf: subtitleURL, encoding: .utf8) {
            let hash = StableTopicHash.string(text)
            if let revision = manifest.transcriptRevisions?.last(where: {
                $0.language == language && $0.contentHash == hash
            }) {
                return revision
            }
        }
        return manifest.activeTranscriptRevision(for: language)
    }

    private func createFragment(
        mediaURL: URL,
        projectURL: URL,
        start: TimeInterval,
        end: TimeInterval,
        name: String,
        style: SubtitleStyleSettings,
        subtitleLanguage: ArtifactLanguage,
        topicGranularity: TopicGranularity?,
        topicID: String?,
        quoteStart: String?,
        quoteEnd: String?,
        onProgress: @escaping (Double) -> Void,
        log: (String) -> Void
    ) async throws -> FragmentRecord {
        guard end > start else { throw WorkflowError.invalidRange }
        guard let mediaDuration = try await ffmpeg.duration(of: mediaURL), end <= mediaDuration + 0.001 else {
            throw WorkflowError.invalidRange
        }
        let layout = ProjectLayout(root: projectURL)
        let selectedSRT = layout.subtitlesURL(language: subtitleLanguage)
        guard FileManager.default.fileExists(atPath: selectedSRT.path) else { throw WorkflowError.missingFullSRT }
        let cues = try srt.cues(in: srt.load(from: selectedSRT), start: start, end: end, rebased: true)
        guard !cues.isEmpty else { throw WorkflowError.noSubtitlesInRange }

        let identifier = uniqueFragmentIdentifier(projectURL: projectURL, start: start, end: end, name: name)
        let videoURL = layout.fragmentVideoURL(kind: identifier)
        let subtitleURL = layout.fragmentSRTURL(kind: identifier)
        let reportURL = layout.fragmentFFprobeURL(kind: identifier)
        try FileManager.default.createDirectory(at: subtitleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try srt.write(cues, to: subtitleURL)
        try await ffmpeg.cutAccurate(mediaURL: mediaURL, start: start, end: end, outputURL: videoURL, onProgress: onProgress)
        let report = try await ffmpeg.strictValidationReport(mediaURL: videoURL, expectedDuration: end - start)
        try report.write(to: reportURL, atomically: true, encoding: .utf8)

        try store.registerOutput(kind: "fragment-video", url: videoURL, in: projectURL)
        try store.registerOutput(kind: "fragment-srt", url: subtitleURL, in: projectURL)
        try store.registerOutput(kind: "fragment-ffprobe", url: reportURL, in: projectURL)
        let record = FragmentRecord(
            id: identifier,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Фрагмент" : name,
            start: start,
            end: end,
            createdAt: Date(),
            videoPath: videoURL.path,
            subtitlePath: subtitleURL.path,
            subtitledVideoPath: nil,
            ffprobeReportPath: reportURL.path,
            style: style,
            language: subtitleLanguage,
            topicGranularity: topicGranularity,
            topicID: topicID,
            quoteStart: quoteStart,
            quoteEnd: quoteEnd
        )
        try store.registerFragment(record, in: projectURL)
        log("Создан точный фрагмент \(identifier) и синхронизированный fragment.srt.")
        return record
    }

    private func burnSubtitlesIntoFragment(
        _ fragment: FragmentRecord,
        projectURL: URL,
        onProgress: @escaping (Double) -> Void,
        log: (String) -> Void
    ) async throws -> FragmentRecord {
        var updated = fragment
        let layout = ProjectLayout(root: projectURL)
        let videoURL = URL(fileURLWithPath: fragment.videoPath)
        let subtitleURL = URL(fileURLWithPath: fragment.subtitlePath)
        let outputURL = layout.fragmentSubtitledVideoURL(kind: fragment.id)
        let duration = fragment.end - fragment.start
        _ = try await ffmpeg.burnSubtitles(
            mediaURL: videoURL,
            srtURL: subtitleURL,
            outputURL: outputURL,
            mediaDuration: duration,
            style: fragment.style
        ) { onProgress($0) }
        let report = try await ffmpeg.strictValidationReport(mediaURL: outputURL, expectedDuration: duration)
        let reportURL = layout.fragmentFFprobeURL(kind: fragment.id)
        let existing = (try? String(contentsOf: reportURL, encoding: .utf8)) ?? ""
        try (existing + "\n## fragment_subtitled.mp4\n" + report).write(to: reportURL, atomically: true, encoding: .utf8)
        updated.subtitledVideoPath = outputURL.path
        updated.ffprobeReportPath = reportURL.path
        try store.registerOutput(kind: "fragment-subtitled-video", url: outputURL, in: projectURL)
        try store.registerFragment(updated, in: projectURL)
        log("Субтитры вшиты во фрагмент \(fragment.id).")
        return updated
    }

    func renderProcessedFragment(
        _ fragment: FragmentRecord,
        projectURL: URL,
        settings: WorkflowSettings,
        removeSourceAfterSuccess: Bool = false,
        onProgress: @escaping (Double) -> Void,
        log: (String) -> Void
    ) async throws -> FragmentRecord {
        let layout = ProjectLayout(root: projectURL)
        let fileManager = FileManager.default
        let outputURL = layout.processedFragmentVideoURL(kind: fragment.id)
        let outputSRT = layout.processedFragmentSRTURL(kind: fragment.id)
        let recipeURL = layout.processedFragmentRecipeURL(kind: fragment.id)
        let stageDirectory = layout.supportFragmentsDirectory
            .appendingPathComponent(fragment.id, isDirectory: true)
            .appendingPathComponent("Processing", isDirectory: true)
        try fileManager.createDirectory(at: stageDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stageDirectory) }

        var currentMedia = URL(fileURLWithPath: fragment.videoPath)
        var currentDuration = fragment.end - fragment.start
        var cues = try srt.load(from: URL(fileURLWithPath: fragment.subtitlePath))
        var filterGraphs: [String] = []
        var mutedCandidateIDs: [String] = []
        let enabledStages = 1
            + (settings.fragmentMuteFillerWords ? 1 : 0)
            + (settings.fragmentAdjustSpeed ? 1 : 0)
            + (settings.fragmentApplyBlur ? 1 : 0)
            + (settings.burnFragmentSubtitles ? 1 : 0)
        var completedStages = 0

        func stageProgress(_ fraction: Double) {
            onProgress((Double(completedStages) + fraction) / Double(enabledStages))
        }

        if settings.fragmentMuteFillerWords {
            let report = try fillerWords.load(from: layout.fillerWordsURL)
            let selectedIDs: Set<String>
            switch settings.fillerMode {
            case .detectOnly:
                throw WorkflowError.processFailed("Для mute выберите режим «Все», «Выбранные» или «Уверенные».")
            case .muteAll:
                selectedIDs = Set(report.candidates.map(\.id))
            case .muteSelected:
                selectedIDs = settings.selectedFillerCandidateIDs
            case .muteHighConfidence:
                selectedIDs = Set(report.candidates.filter(\.highConfidence).map(\.id))
            }
            let selected = report.candidates.filter {
                selectedIDs.contains($0.id) && $0.end > fragment.start && $0.start < fragment.end
            }
            guard !selected.isEmpty else {
                throw WorkflowError.processFailed("В выбранном фрагменте нет слов-паразитов для mute.")
            }
            let intervals = selected.map {
                ClosedRangeRecord(
                    start: max($0.start, fragment.start) - fragment.start,
                    end: min($0.end, fragment.end) - fragment.start
                )
            }
            let mutedAudio = stageDirectory.appendingPathComponent("muted.m4a")
            let mutedVideo = stageDirectory.appendingPathComponent("muted.mp4")
            let graph = try await ffmpeg.muteAudioIntervals(
                mediaURL: currentMedia,
                outputAudioURL: mutedAudio,
                outputVideoURL: mutedVideo,
                intervals: intervals,
                mediaDuration: currentDuration,
                onProgress: stageProgress
            )
            filterGraphs.append("mute: \(graph)")
            mutedCandidateIDs = selected.map(\.id)
            currentMedia = mutedVideo
            completedStages += 1
        }

        if settings.fragmentAdjustSpeed {
            guard settings.speedFactor >= 0.5, settings.speedFactor <= 2 else {
                throw WorkflowError.processFailed("Коэффициент скорости должен быть от 0.5 до 2.0.")
            }
            let speedVideo = stageDirectory.appendingPathComponent("speed.mp4")
            let graph = try await ffmpeg.adjustSpeed(
                mediaURL: currentMedia,
                outputURL: speedVideo,
                speedFactor: settings.speedFactor,
                mediaDuration: currentDuration,
                onProgress: stageProgress
            )
            filterGraphs.append("speed: \(graph)")
            cues = try srt.cues(cues, adjustedForSpeed: settings.speedFactor)
            currentDuration /= settings.speedFactor
            currentMedia = speedVideo
            completedStages += 1
        }

        var appliedBlurStart: TimeInterval?
        var appliedBlurEnd: TimeInterval?
        if settings.fragmentApplyBlur {
            if let sourceStart = settings.blurStart, let sourceEnd = settings.blurEnd {
                let clippedStart = max(sourceStart, fragment.start)
                let clippedEnd = min(sourceEnd, fragment.end)
                guard clippedEnd > clippedStart else {
                    throw WorkflowError.processFailed("Диапазон blur не пересекается с выбранным фрагментом.")
                }
                let speed = settings.fragmentAdjustSpeed ? settings.speedFactor : 1
                appliedBlurStart = (clippedStart - fragment.start) / speed
                appliedBlurEnd = (clippedEnd - fragment.start) / speed
            }
            let blurVideo = stageDirectory.appendingPathComponent("blur.mp4")
            let graph = try await ffmpeg.applyStaticBlur(
                mediaURL: currentMedia,
                outputURL: blurVideo,
                region: settings.blurRegion,
                intensity: settings.blurIntensity,
                start: appliedBlurStart,
                end: appliedBlurEnd,
                mediaDuration: currentDuration,
                onProgress: stageProgress
            )
            filterGraphs.append("blur: \(graph)")
            currentMedia = blurVideo
            completedStages += 1
        }

        try fileManager.createDirectory(at: outputSRT.deletingLastPathComponent(), withIntermediateDirectories: true)
        try srt.write(cues, to: outputSRT)
        if settings.burnFragmentSubtitles {
            _ = try await ffmpeg.burnSubtitles(
                mediaURL: currentMedia,
                srtURL: outputSRT,
                outputURL: outputURL,
                mediaDuration: currentDuration,
                style: settings.subtitleStyle,
                onProgress: stageProgress
            )
            completedStages += 1
        } else {
            try? fileManager.removeItem(at: outputURL)
            try fileManager.copyItem(at: currentMedia, to: outputURL)
        }

        let validation = try await ffmpeg.strictValidationReport(
            mediaURL: outputURL,
            expectedDuration: currentDuration
        )
        let reportURL = layout.fragmentFFprobeURL(kind: fragment.id)
        let existing = (try? String(contentsOf: reportURL, encoding: .utf8)) ?? ""
        try (existing + "\n## fragment_processed.mp4\n" + validation)
            .write(to: reportURL, atomically: true, encoding: .utf8)
        completedStages += 1
        stageProgress(0)

        let recipe = FragmentProcessingRecipe(
            burnSubtitles: settings.burnFragmentSubtitles,
            muteFillerWords: settings.fragmentMuteFillerWords,
            fillerMode: settings.fillerMode,
            fillerCandidateIDs: mutedCandidateIDs,
            adjustSpeed: settings.fragmentAdjustSpeed,
            speedFactor: settings.fragmentAdjustSpeed ? settings.speedFactor : 1,
            applyBlur: settings.fragmentApplyBlur,
            blurRegion: settings.blurRegion,
            blurIntensity: settings.blurIntensity,
            blurStart: appliedBlurStart,
            blurEnd: appliedBlurEnd,
            filterGraphs: filterGraphs
        )
        try encoderForDerivedTimeline().encode(recipe).write(to: recipeURL, options: .atomic)
        var updated = fragment
        if removeSourceAfterSuccess {
            try? fileManager.removeItem(at: URL(fileURLWithPath: fragment.videoPath))
            try? fileManager.removeItem(at: URL(fileURLWithPath: fragment.subtitlePath))
            try store.mutate(projectURL) { manifest in
                manifest.outputs.removeAll { output in
                    output.path == fragment.videoPath || output.path == fragment.subtitlePath
                }
            }
        }
        updated.videoPath = outputURL.path
        updated.processedVideoPath = outputURL.path
        updated.processingRecipe = recipe
        updated.subtitlePath = outputSRT.path
        updated.ffprobeReportPath = reportURL.path
        try store.registerOutput(kind: "processed-fragment-video", url: outputURL, in: projectURL)
        try store.registerOutput(kind: "processed-fragment-srt", url: outputSRT, in: projectURL)
        try store.registerOutput(kind: "processed-fragment-recipe", url: recipeURL, in: projectURL)
        try store.registerFragment(updated, in: projectURL)
        onProgress(1)
        var appliedStages = ["вырезка"]
        if recipe.muteFillerWords { appliedStages.append("mute") }
        if recipe.adjustSpeed { appliedStages.append("скорость") }
        if recipe.applyBlur { appliedStages.append("blur") }
        if recipe.burnSubtitles { appliedStages.append("субтитры") }
        log("Создан обработанный фрагмент \(fragment.id): \(appliedStages.joined(separator: " → ")).")
        return updated
    }

    private func validateTimeline(mediaURL: URL, layout: ProjectLayout, projectURL: URL, log: (String) -> Void) async throws {
        guard FileManager.default.fileExists(atPath: layout.fullSRTURL.path) else { throw WorkflowError.missingFullSRT }
        let parsed = try srt.loadWithReport(from: layout.fullSRTURL)
        let warnings = srt.validateTimeline(parsed.cues, mediaDuration: try await ffmpeg.duration(of: mediaURL))
        var lines = warnings.isEmpty
            ? ["Временная шкала корректна. Субтитров: \(parsed.cues.count)."]
            : warnings
        if parsed.skippedZeroDurationCount > 0 {
            lines.append("Пропущено служебных реплик нулевой длительности: \(parsed.skippedZeroDurationCount).")
        }
        let body = lines.joined(separator: "\n") + "\n"
        try body.write(to: layout.timelineValidationURL, atomically: true, encoding: .utf8)
        try store.registerOutput(kind: "timeline-validation", url: layout.timelineValidationURL, in: projectURL)
        log(body.trimmingCharacters(in: .whitespacesAndNewlines))
        if !warnings.isEmpty { throw WorkflowError.invalidSRT(warnings.joined(separator: " ")) }
    }

    private func validateAllVideos(
        projectURL: URL,
        operation: WorkflowOperation,
        tracker: WorkflowProgressTracker,
        log: (String) -> Void
    ) async throws {
        let outputs = detector.discover(in: projectURL).filter {
            ["mp4", "mov", "m4v"].contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased())
        }
        let manifest = try store.load(from: projectURL)
        var report = ""
        for (index, output) in outputs.enumerated() {
            try Task.checkCancellation()
            report += "## \(output.path)\n"
            let outputURL = URL(fileURLWithPath: output.path)
            if let expectedDuration = expectedDuration(for: output, manifest: manifest) {
                report += try await ffmpeg.strictValidationReport(mediaURL: outputURL, expectedDuration: expectedDuration)
            } else {
                report += try await ffmpeg.validate(mediaURL: outputURL)
            }
            report += "\n\n"
            tracker.update(operation, fraction: Double(index + 1) / Double(max(outputs.count, 1)))
        }
        let reportURL = ProjectLayout(root: projectURL).ffprobeReportURL
        try report.write(to: reportURL, atomically: true, encoding: .utf8)
        try store.registerOutput(kind: "ffprobe", url: reportURL, in: projectURL)
        log("Проверка ffprobe сохранена.")
    }

    private func shouldSkip(
        _ operation: WorkflowOperation,
        settings: WorkflowSettings,
        manifest: ProjectManifest,
        projectURL: URL,
        mediaURL: URL,
        log: (String) -> Void
    ) async throws -> Bool {
        let layout = ProjectLayout(root: projectURL)
        switch operation {
        case .diagnostics:
            return false
        case .createManifest:
            return false
        case .detectLanguage:
            guard settings.mode != .newProject,
                  nonemptyFile(layout.languageDetectionURL),
                  manifest.languageProfile != nil else { return false }
            return true
        case .transcribe:
            guard nonemptyFile(layout.fullSRTURL) else { return false }
            let parsed: SRTParseResult
            do {
                parsed = try srt.loadWithReport(from: layout.fullSRTURL)
            } catch {
                log("Существующий full.srt не читается; потребуется новая расшифровка: \(error.localizedDescription)")
                return false
            }
            let warnings = srt.validateTimeline(parsed.cues, mediaDuration: try await ffmpeg.duration(of: mediaURL))
            guard warnings.isEmpty else {
                log("Существующий full.srt не прошёл проверку; потребуется новая расшифровка.")
                return false
            }
            if let issue = transcriptionQuality.recoveryIssue(cues: parsed.cues) {
                log("Существующий full.srt содержит \(issue.message). Будет выполнена автоматическая сегментированная расшифровка.")
                return false
            }
            try store.registerOutput(kind: "full-srt", url: layout.fullSRTURL, in: projectURL)
            if !nonemptyFile(layout.transcriptURL) || !isAtLeastAsNew(layout.transcriptURL, as: layout.fullSRTURL) {
                try writeTranscript(from: parsed.cues, to: layout.transcriptURL)
                try store.registerOutput(kind: "transcript", url: layout.transcriptURL, in: projectURL)
                log("Восстановлен transcript.txt из существующего full.srt без запуска Whisper.")
            } else {
                try store.registerOutput(kind: "transcript", url: layout.transcriptURL, in: projectURL)
            }
            return true
        case .assessTranscriptionQuality:
            guard settings.mode != .newProject,
                  isAtLeastAsNew(layout.transcriptionQualityURL, as: layout.fullSRTURL),
                  nonemptyFile(layout.reviewTasksURL),
                  nonemptyFile(layout.transcriptReviewHTMLURL) else { return false }
            return true
        case .translateTranscript:
            guard settings.mode != .newProject,
                  let sourceLanguage = manifest.languageProfile?.effective,
                  let sourceRevision = manifest.activeTranscriptRevision(for: sourceLanguage) else {
                return false
            }
            let targetLanguage: ArtifactLanguage = sourceLanguage == .ru ? .en : .ru
            let reportURL = layout.translationReportURL(source: sourceLanguage, target: targetLanguage)
            guard nonemptyFile(reportURL),
                  nonemptyFile(layout.transcriptURL(language: targetLanguage)),
                  nonemptyFile(layout.subtitlesURL(language: targetLanguage)),
                  let report = try? store.decoder.decode(TranslationReport.self, from: Data(contentsOf: reportURL)) else {
                return false
            }
            return report.sourceRevisionID == sourceRevision.id
        case .validateTimeline:
            guard settings.mode != .newProject else { return false }
            guard isAtLeastAsNew(layout.timelineValidationURL, as: layout.fullSRTURL),
                  let report = try? String(contentsOf: layout.timelineValidationURL, encoding: .utf8) else { return false }
            return report.contains("Временная шкала корректна")
        case .topicTimecoding:
            guard settings.mode != .newProject else { return false }
            let languages = availableTopicLanguages(manifest: manifest, layout: layout)
            for language in languages {
                let sourceSRT = layout.subtitlesURL(language: language)
                guard nonemptyFile(sourceSRT) else { return false }
                let sourceSignature = StableTopicHash.string(try String(contentsOf: sourceSRT, encoding: .utf8))
                for granularity in TopicGranularity.allCases {
                    let jsonURL = layout.topicsURL(language: language, granularity: granularity)
                    let textURL = layout.topicsTextURL(language: language, granularity: granularity)
                    guard isAtLeastAsNew(jsonURL, as: sourceSRT),
                          isAtLeastAsNew(textURL, as: sourceSRT),
                          let topics = try? Self.loadTopics(
                            projectURL: projectURL,
                            language: language,
                            granularity: granularity
                          ),
                          !topics.topics.isEmpty,
                          TopicAlgorithmIdentity.isCurrent(
                            topics,
                            mode: settings.topicAnalysisMode,
                            granularity: granularity,
                            sourceSignature: sourceSignature
                          ) else {
                        log("Набор тем \(language.rawValue)/\(granularity.rawValue) отсутствует или устарел; анализ будет пересчитан.")
                        return false
                    }
                }
            }
            return nonemptyFile(layout.topicsURL) && nonemptyFile(layout.topicsTextURL)
        case .detectFillerWords:
            guard settings.mode != .newProject,
                  nonemptyFile(layout.fillerWordsURL),
                  let language = manifest.languageProfile?.effective,
                  let revision = manifest.activeTranscriptRevision(for: language),
                  let report = try? fillerWords.load(from: layout.fillerWordsURL) else { return false }
            return report.transcriptRevisionID == revision.id
        case .analyzeAudio:
            return settings.mode != .newProject && isAtLeastAsNew(layout.audioAnalysisURL, as: mediaURL)
        case .discoverResults, .cutRange, .burnFragmentSubtitles, .cutTopic, .renderFragment, .burnSubtitles, .adjustSpeed, .applyBlur, .applyWatermark, .muteFillerWords, .enhanceAudio, .createDubbing, .ffprobeValidate:
            return false
        }
    }

    private func markOperation(
        _ operation: WorkflowOperation,
        status: ProjectOperationStatus,
        projectURL: URL,
        error: String?
    ) throws {
        let outputPaths = operationOutputPaths(operation, projectURL: projectURL)
        try store.mutate(projectURL) { manifest in
            var workflow = manifest.workflow ?? ProjectWorkflowState(status: .ready, progress: 0, mode: .resumeProject, operations: [:], lastError: nil)
            var record = workflow.operations[operation.rawValue] ?? ProjectOperationRecord(
                status: .pending,
                startedAt: nil,
                finishedAt: nil,
                inputSignature: manifest.sourceFingerprint.map { "\($0.fileSize):\($0.modificationTime)" },
                outputPaths: [],
                errorMessage: nil
            )
            record.status = status
            if status == .running { record.startedAt = Date(); record.finishedAt = nil }
            if status == .completed || status == .skipped || status == .stopped || status == .failed { record.finishedAt = Date() }
            if status == .completed || status == .skipped { record.outputPaths = outputPaths }
            record.errorMessage = error
            workflow.operations[operation.rawValue] = record
            manifest.workflow = workflow
        }
    }

    private func operationOutputPaths(_ operation: WorkflowOperation, projectURL: URL) -> [String] {
        let layout = ProjectLayout(root: projectURL)
        let manifest = try? store.load(from: projectURL)
        switch operation {
        case .diagnostics: return [layout.diagnosticsURL.path]
        case .createManifest: return [layout.manifestURL.path]
        case .detectLanguage: return [layout.languageDetectionURL.path]
        case .transcribe:
            return [layout.fullSRTURL, layout.transcriptURL, layout.whisperJSONURL, layout.sourceAudioURL]
                .filter { nonemptyFile($0) }
                .map(\.path)
        case .assessTranscriptionQuality:
            return [layout.transcriptionQualityURL, layout.reviewTasksURL, layout.transcriptReviewHTMLURL]
                .filter { nonemptyFile($0) }
                .map(\.path)
        case .translateTranscript:
            guard let source = manifest?.languageProfile?.effective else { return [] }
            let target: ArtifactLanguage = source == .ru ? .en : .ru
            return [
                layout.transcriptURL(language: target),
                layout.subtitlesURL(language: target),
                layout.translationReportURL(source: source, target: target)
            ].filter { nonemptyFile($0) }.map(\.path)
        case .validateTimeline: return [layout.timelineValidationURL.path]
        case .topicTimecoding:
            let localized = ArtifactLanguage.allCases.flatMap { language in
                TopicGranularity.allCases.flatMap { granularity in
                    [layout.topicsURL(language: language, granularity: granularity),
                     layout.topicsTextURL(language: language, granularity: granularity)]
                }
            }
            return ([layout.topicsURL, layout.topicsTextURL] + localized)
                .filter { nonemptyFile($0) }
                .map(\.path)
        case .discoverResults: return manifest?.outputs.map(\.path) ?? []
        case .cutRange, .cutTopic:
            guard let fragment = manifest?.fragments?.first else { return [] }
            return [fragment.videoPath, fragment.subtitlePath] + [fragment.ffprobeReportPath].compactMap { $0 }
        case .burnFragmentSubtitles:
            return manifest?.fragments?.first?.subtitledVideoPath.map { [$0] } ?? []
        case .renderFragment:
            guard let fragment = manifest?.fragments?.first else { return [] }
            return [fragment.processedVideoPath, fragment.subtitlePath].compactMap { $0 }
        case .burnSubtitles:
            let localized = ArtifactLanguage.allCases.map { layout.subtitledVideoURL(language: $0) }
            return ([layout.subtitledVideoURL] + localized).filter { nonemptyFile($0) }.map(\.path)
        case .adjustSpeed:
            return detector.discover(in: projectURL)
                .filter { $0.kind.hasPrefix("speed-adjusted-") || $0.kind == "speed-adjustment" }
                .map(\.path)
        case .applyBlur:
            return detector.discover(in: projectURL)
                .filter { $0.kind == "blurred-video" || $0.kind == "blur-adjustment" }
                .map(\.path)
        case .applyWatermark:
            return detector.discover(in: projectURL)
                .filter { $0.kind == "watermarked-video" || $0.kind == "watermark-adjustment" || $0.kind == "watermark-image" }
                .map(\.path)
        case .detectFillerWords: return [layout.fillerWordsURL.path]
        case .muteFillerWords:
            return detector.discover(in: projectURL)
                .filter { $0.kind == "filler-muted-audio" || $0.kind == "filler-muted-video" }
                .map(\.path)
        case .analyzeAudio: return [layout.audioAnalysisURL.path]
        case .enhanceAudio:
            return detector.discover(in: projectURL)
                .filter { ["enhanced-audio", "enhanced-video", "audio-enhancement-report"].contains($0.kind) }
                .map(\.path)
        case .createDubbing:
            return detector.discover(in: projectURL)
                .filter { ["dubbed-audio", "dubbed-video", "dubbing-report"].contains($0.kind) }
                .map(\.path)
        case .ffprobeValidate: return [layout.ffprobeReportURL.path]
        }
    }

    private func updateWorkflow(
        _ projectURL: URL,
        status: ProjectStatus,
        progress: Double,
        mode: ProjectRunMode,
        error: String?
    ) throws {
        try store.mutate(projectURL) { manifest in
            var workflow = manifest.workflow ?? ProjectWorkflowState(status: .ready, progress: 0, mode: mode, operations: [:], lastError: nil)
            workflow.status = status
            workflow.progress = min(max(progress, 0), 1)
            workflow.mode = mode
            workflow.lastError = error
            manifest.workflow = workflow
        }
    }

    func expanded(
        _ selected: Set<WorkflowOperation>,
        includeFillerAnalysisBeforeReview: Bool = false
    ) -> [WorkflowOperation] {
        var result = Set<WorkflowOperation>()
        func visit(_ operation: WorkflowOperation) {
            operation.dependencies.forEach(visit)
            result.insert(operation)
        }
        var automatic = selected
        let transcriptConsumers: Set<WorkflowOperation> = [
            .transcribe, .translateTranscript, .validateTimeline, .topicTimecoding,
            .cutRange, .burnFragmentSubtitles, .cutTopic, .burnSubtitles, .createDubbing
        ]
        if includeFillerAnalysisBeforeReview && !selected.isDisjoint(with: transcriptConsumers) {
            automatic.insert(.detectFillerWords)
        }
        let videoOperations: Set<WorkflowOperation> = [.cutRange, .burnFragmentSubtitles, .cutTopic, .renderFragment, .burnSubtitles, .adjustSpeed, .applyBlur, .applyWatermark, .muteFillerWords, .enhanceAudio, .createDubbing]
        if !selected.isDisjoint(with: videoOperations) {
            automatic.insert(.ffprobeValidate)
        }
        if !selected.isEmpty {
            automatic.insert(.discoverResults)
        }
        automatic.forEach(visit)
        return WorkflowOperation.allCases.filter { result.contains($0) }
    }

    private func writeTranscript(from cues: [SubtitleCue], to url: URL) throws {
        let transcript = cues.map(\.text).joined(separator: "\n\n") + "\n"
        try transcript.write(to: url, atomically: true, encoding: .utf8)
    }

    private func createSpeedAdjustedVideo(
        originalMediaURL: URL,
        projectURL: URL,
        manifest: ProjectManifest,
        settings: WorkflowSettings,
        operation: WorkflowOperation,
        tracker: WorkflowProgressTracker,
        log: (String) -> Void
    ) async throws {
        let factor = settings.speedFactor
        guard factor >= 0.5, factor <= 2 else {
            throw WorkflowError.processFailed("Коэффициент скорости должен быть от 0.5 до 2.0.")
        }
        let layout = ProjectLayout(root: projectURL)
        let sourceLanguage = settings.artifactLanguage ?? manifest.languageProfile?.effective ?? .ru
        let sourceMedia: URL
        let sourceSRT: URL
        let language: ArtifactLanguage
        let sourceDuration: TimeInterval
        let sourceFragmentID: String?
        let sourceFragmentRange: ClosedRangeRecord?

        switch settings.speedSource {
        case .fullVideo:
            sourceMedia = originalMediaURL
            sourceSRT = layout.subtitlesURL(language: sourceLanguage)
            language = sourceLanguage
            sourceDuration = try await requiredDuration(of: sourceMedia, manifest: manifest)
            sourceFragmentID = nil
            sourceFragmentRange = nil
        case .latestFragment:
            guard let fragment = manifest.fragments?.first else {
                throw WorkflowError.processFailed("В проекте нет фрагмента для изменения скорости.")
            }
            sourceMedia = URL(fileURLWithPath: fragment.videoPath)
            sourceSRT = URL(fileURLWithPath: fragment.subtitlePath)
            language = fragment.language ?? sourceLanguage
            sourceFragmentID = fragment.id
            sourceFragmentRange = ClosedRangeRecord(start: fragment.start, end: fragment.end)
            guard let duration = try await ffmpeg.duration(of: sourceMedia), duration > 0 else {
                throw WorkflowError.processFailed("Не удалось определить длительность последнего фрагмента.")
            }
            sourceDuration = duration
        }

        guard nonemptyFile(sourceMedia) else {
            throw WorkflowError.processFailed("Исходное видео для изменения скорости не найдено.")
        }
        guard nonemptyFile(sourceSRT) else { throw WorkflowError.missingFullSRT }

        let outputVideo = layout.speedAdjustedVideoURL(source: settings.speedSource, language: language, factor: factor)
        let outputSRT = layout.speedAdjustedSRTURL(source: settings.speedSource, language: language, factor: factor)
        let reportURL = layout.speedAdjustmentReportURL(source: settings.speedSource, language: language, factor: factor)
        try FileManager.default.createDirectory(at: outputSRT.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let adjustedCues = try srt.cues(try srt.load(from: sourceSRT), adjustedForSpeed: factor)
        let audioFilter = try await ffmpeg.adjustSpeed(
            mediaURL: sourceMedia,
            outputURL: outputVideo,
            speedFactor: factor,
            mediaDuration: sourceDuration,
            onProgress: { tracker.update(operation, fraction: $0) }
        )
        try srt.writePreservingIDs(adjustedCues, to: outputSRT)

        var outputTopicPaths: [String] = []
        for granularity in TopicGranularity.allCases {
            let sourceTopicsURL = layout.topicsURL(language: language, granularity: granularity)
            guard nonemptyFile(sourceTopicsURL),
                  let sourceTopics = try? Self.loadTopics(projectURL: projectURL, language: language, granularity: granularity) else { continue }
            var adjustedTopics = try srt.topics(
                sourceTopics,
                adjustedForSpeed: factor,
                sourceRange: sourceFragmentRange
            )
            let outputTopicsURL = layout.speedAdjustedTopicsURL(
                source: settings.speedSource,
                language: language,
                factor: factor,
                granularity: granularity
            )
            try FileManager.default.createDirectory(at: outputTopicsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            adjustedTopics.sourceSRT = outputSRT.path
            try encoderForDerivedTimeline().encode(adjustedTopics).write(to: outputTopicsURL, options: .atomic)
            outputTopicPaths.append(outputTopicsURL.path)
            try store.registerOutput(kind: "speed-adjusted-topics", url: outputTopicsURL, in: projectURL)
        }

        let adjustedReviewTasks = try srt.reviewTasks(
            manifest.reviewTasks ?? [],
            language: language,
            adjustedForSpeed: factor,
            sourceRange: sourceFragmentRange
        )
        let outputReviewTasksURL: URL? = adjustedReviewTasks.isEmpty ? nil : layout.speedAdjustedReviewTasksURL(
            source: settings.speedSource,
            language: language,
            factor: factor
        )
        if let outputReviewTasksURL {
            try encoderForDerivedTimeline().encode(adjustedReviewTasks).write(to: outputReviewTasksURL, options: .atomic)
            try store.registerOutput(kind: "speed-adjusted-review-tasks", url: outputReviewTasksURL, in: projectURL)
        }
        let report = SpeedAdjustmentRecord(
            schemaVersion: 1,
            sourceMediaPath: sourceMedia.path,
            outputMediaPath: outputVideo.path,
            sourceSubtitlePath: sourceSRT.path,
            outputSubtitlePath: outputSRT.path,
            sourceKind: settings.speedSource,
            sourceFragmentID: sourceFragmentID,
            sourceFragmentRange: sourceFragmentRange,
            language: language,
            speedFactor: factor,
            sourceDuration: sourceDuration,
            outputDuration: sourceDuration / factor,
            audioFilter: audioFilter,
            outputTopicPaths: outputTopicPaths,
            outputReviewTasksPath: outputReviewTasksURL?.path,
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: reportURL, options: .atomic)

        try store.registerOutput(kind: "speed-adjusted-video", url: outputVideo, in: projectURL)
        try store.registerOutput(kind: "speed-adjusted-subtitles", url: outputSRT, in: projectURL)
        try store.registerOutput(kind: "speed-adjustment", url: reportURL, in: projectURL)
        try store.registerArtifact(ProjectArtifactRecord(
            id: "speed-\(settings.speedSource.rawValue)-\(language.rawValue)-\(String(format: "%.2f", factor))",
            kind: .speedAdjustedVideo,
            path: outputVideo.path,
            language: language,
            origin: .source,
            granularity: nil,
            sourceArtifactID: nil,
            sourceRevision: nil,
            dependencyIDs: [],
            contentHash: nil,
            createdAt: Date(),
            generator: BuildInfo.name,
            generatorVersion: BuildInfo.version,
            model: nil,
            validationStatus: .ready,
            qualityStatus: .ready,
            reviewTaskCount: adjustedReviewTasks.count
        ), in: projectURL)
        log("Создано видео со скоростью \(String(format: "%.2f", factor))x; субтитры синхронно пересчитаны. Аудиофильтр: \(audioFilter).")
    }

    private func createBlurredVideo(
        originalMediaURL: URL,
        projectURL: URL,
        manifest: ProjectManifest,
        settings: WorkflowSettings,
        operation: WorkflowOperation,
        tracker: WorkflowProgressTracker,
        log: (String) -> Void
    ) async throws {
        let region = try settings.blurRegion.validated()
        let sourceMedia: URL
        let sourceFragmentID: String?
        let duration: TimeInterval
        switch settings.blurSource {
        case .fullVideo:
            sourceMedia = originalMediaURL
            sourceFragmentID = nil
            duration = try await requiredDuration(of: sourceMedia, manifest: manifest)
        case .latestFragment:
            guard let fragment = manifest.fragments?.first else {
                throw WorkflowError.processFailed("В проекте нет фрагмента для применения blur.")
            }
            sourceMedia = URL(fileURLWithPath: fragment.videoPath)
            sourceFragmentID = fragment.id
            guard let sourceDuration = try await ffmpeg.duration(of: sourceMedia), sourceDuration > 0 else {
                throw WorkflowError.processFailed("Не удалось определить длительность последнего фрагмента.")
            }
            duration = sourceDuration
        }
        guard nonemptyFile(sourceMedia) else {
            throw WorkflowError.processFailed("Исходное видео для blur не найдено.")
        }
        let id = "blur-\(UUID().uuidString.lowercased())"
        let layout = ProjectLayout(root: projectURL)
        let outputURL = layout.blurredVideoURL(source: settings.blurSource, id: id)
        let reportURL = layout.blurAdjustmentReportURL(id: id)
        let filterGraph = try await ffmpeg.applyStaticBlur(
            mediaURL: sourceMedia,
            outputURL: outputURL,
            region: region,
            intensity: settings.blurIntensity,
            start: settings.blurStart,
            end: settings.blurEnd,
            mediaDuration: duration,
            onProgress: { tracker.update(operation, fraction: $0) }
        )
        let record = BlurAdjustmentRecord(
            id: id,
            sourceMediaPath: sourceMedia.path,
            outputMediaPath: outputURL.path,
            sourceKind: settings.blurSource,
            sourceFragmentID: sourceFragmentID,
            region: region,
            intensity: settings.blurIntensity,
            start: settings.blurStart,
            end: settings.blurEnd,
            sourceDuration: duration,
            filterGraph: filterGraph,
            createdAt: Date()
        )
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoderForDerivedTimeline().encode(record).write(to: reportURL, options: .atomic)
        try store.mutate(projectURL) { manifest in
            var records = manifest.blurAdjustments ?? []
            records.append(record)
            manifest.blurAdjustments = records
        }
        try store.registerOutput(kind: "blurred-video", url: outputURL, in: projectURL)
        try store.registerOutput(kind: "blur-adjustment", url: reportURL, in: projectURL)
        try store.registerArtifact(ProjectArtifactRecord(
            id: "artifact-\(id)",
            kind: .blurredVideo,
            path: outputURL.path,
            language: nil,
            origin: .source,
            granularity: nil,
            sourceArtifactID: nil,
            sourceRevision: nil,
            dependencyIDs: [],
            contentHash: nil,
            createdAt: Date(),
            generator: BuildInfo.name,
            generatorVersion: BuildInfo.version,
            model: nil,
            validationStatus: .ready,
            qualityStatus: .ready,
            reviewTaskCount: 0
        ), in: projectURL)
        let interval = settings.blurStart.map { start in
            " с \(TimecodeParser.display(start)) до \(TimecodeParser.display(settings.blurEnd ?? duration))"
        } ?? " на всём видео"
        log("Статический blur применён к выбранной области\(interval). Исходный файл не изменён.")
    }

    private func createWatermarkedVideo(
        originalMediaURL: URL,
        projectURL: URL,
        manifest: ProjectManifest,
        settings: WorkflowSettings,
        operation: WorkflowOperation,
        tracker: WorkflowProgressTracker,
        log: (String) -> Void
    ) async throws {
        guard let selectedImage = settings.watermarkImageURL else {
            throw WorkflowError.processFailed("Выберите изображение watermark.")
        }
        let fileExtension = selectedImage.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "webp"].contains(fileExtension),
              nonemptyFile(selectedImage) else {
            throw WorkflowError.processFailed("Watermark должен быть непустым PNG, JPEG/JPG или WebP.")
        }
        let imageData = try Data(contentsOf: selectedImage)
        let imageHash = stableBinaryHash(imageData)
        let layout = ProjectLayout(root: projectURL)
        let storedImage = layout.storedWatermarkImageURL(hash: imageHash, extension: fileExtension)
        if !FileManager.default.fileExists(atPath: storedImage.path) {
            try imageData.write(to: storedImage, options: .atomic)
        }

        let sourceMedia: URL
        let sourceFragmentID: String?
        let duration: TimeInterval
        let sourceSRT: URL?
        switch settings.watermarkSource {
        case .fullVideo:
            sourceMedia = originalMediaURL
            sourceFragmentID = nil
            duration = try await requiredDuration(of: sourceMedia, manifest: manifest)
            let language = settings.artifactLanguage ?? manifest.languageProfile?.effective ?? .ru
            sourceSRT = layout.subtitlesURL(language: language)
        case .latestFragment:
            guard let fragment = manifest.fragments?.first else {
                throw WorkflowError.processFailed("В проекте нет фрагмента для watermark.")
            }
            sourceMedia = URL(fileURLWithPath: fragment.videoPath)
            sourceFragmentID = fragment.id
            sourceSRT = URL(fileURLWithPath: fragment.subtitlePath)
            guard let sourceDuration = try await ffmpeg.duration(of: sourceMedia), sourceDuration > 0 else {
                throw WorkflowError.processFailed("Не удалось определить длительность последнего фрагмента.")
            }
            duration = sourceDuration
        }
        let id = "watermark-\(UUID().uuidString.lowercased())"
        let outputURL = layout.watermarkedVideoURL(source: settings.watermarkSource, id: id)
        let reportURL = layout.watermarkAdjustmentReportURL(id: id)
        let filterGraph = try await ffmpeg.applyWatermark(
            mediaURL: sourceMedia,
            imageURL: storedImage,
            outputURL: outputURL,
            position: settings.watermarkPosition,
            manualX: settings.watermarkManualX,
            manualY: settings.watermarkManualY,
            relativeWidth: settings.watermarkRelativeWidth,
            margin: settings.watermarkMargin,
            opacity: settings.watermarkOpacity,
            start: settings.watermarkStart,
            end: settings.watermarkEnd,
            mediaDuration: duration,
            blurRegion: settings.watermarkIncludesBlur ? settings.blurRegion : nil,
            blurIntensity: settings.blurIntensity,
            blurStart: settings.blurStart,
            blurEnd: settings.blurEnd,
            srtURL: settings.watermarkBurnSubtitles ? sourceSRT : nil,
            subtitleStyle: settings.subtitleStyle,
            onProgress: { tracker.update(operation, fraction: $0) }
        )
        let record = WatermarkAdjustmentRecord(
            id: id,
            sourceMediaPath: sourceMedia.path,
            outputMediaPath: outputURL.path,
            sourceKind: settings.watermarkSource,
            sourceFragmentID: sourceFragmentID,
            sourceImagePath: storedImage.path,
            sourceImageHash: imageHash,
            position: settings.watermarkPosition,
            manualX: settings.watermarkManualX,
            manualY: settings.watermarkManualY,
            relativeWidth: settings.watermarkRelativeWidth,
            margin: settings.watermarkMargin,
            opacity: settings.watermarkOpacity,
            start: settings.watermarkStart,
            end: settings.watermarkEnd,
            sourceDuration: duration,
            filterOrder: (settings.watermarkIncludesBlur ? ["blur"] : [])
                + ["watermark"]
                + (settings.watermarkBurnSubtitles ? ["subtitles"] : []),
            burnedSubtitlePath: settings.watermarkBurnSubtitles ? sourceSRT?.path : nil,
            includedBlurRegion: settings.watermarkIncludesBlur ? settings.blurRegion : nil,
            filterGraph: filterGraph,
            createdAt: Date()
        )
        try encoderForDerivedTimeline().encode(record).write(to: reportURL, options: .atomic)
        try store.mutate(projectURL) { manifest in
            var records = manifest.watermarkAdjustments ?? []
            records.append(record)
            manifest.watermarkAdjustments = records
        }
        try store.registerOutput(kind: "watermark-image", url: storedImage, in: projectURL)
        try store.registerOutput(kind: "watermarked-video", url: outputURL, in: projectURL)
        try store.registerOutput(kind: "watermark-adjustment", url: reportURL, in: projectURL)
        try store.registerArtifact(ProjectArtifactRecord(
            id: "artifact-watermark-image-\(imageHash)",
            kind: .watermarkImage,
            path: storedImage.path,
            language: nil,
            origin: .source,
            granularity: nil,
            sourceArtifactID: nil,
            sourceRevision: nil,
            dependencyIDs: [],
            contentHash: imageHash,
            createdAt: Date(),
            generator: BuildInfo.name,
            generatorVersion: BuildInfo.version,
            model: nil,
            validationStatus: .ready,
            qualityStatus: .ready,
            reviewTaskCount: 0
        ), in: projectURL)
        try store.registerArtifact(ProjectArtifactRecord(
            id: "artifact-\(id)",
            kind: .watermarkedVideo,
            path: outputURL.path,
            language: nil,
            origin: .source,
            granularity: nil,
            sourceArtifactID: "artifact-watermark-image-\(imageHash)",
            sourceRevision: nil,
            dependencyIDs: ["artifact-watermark-image-\(imageHash)"],
            contentHash: nil,
            createdAt: Date(),
            generator: BuildInfo.name,
            generatorVersion: BuildInfo.version,
            model: nil,
            validationStatus: .ready,
            qualityStatus: .ready,
            reviewTaskCount: 0
        ), in: projectURL)
        log("Watermark скопирован в проект и добавлен в новый видеофайл. Исходный файл не изменён.")
    }

    private func stableBinaryHash(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private func encoderForDerivedTimeline() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func registerTranscriptRevision(
        cues: [SubtitleCue],
        language: ArtifactLanguage,
        projectURL: URL,
        layout: ProjectLayout,
        sourceSRT: URL,
        sourceTranscript: URL,
        modelPath: String
    ) throws -> TranscriptRevision {
        let subtitleURL = layout.subtitlesURL(language: language)
        let transcriptURL = layout.transcriptURL(language: language)
        try Data(contentsOf: sourceSRT).write(to: subtitleURL, options: .atomic)
        try Data(contentsOf: sourceTranscript).write(to: transcriptURL, options: .atomic)
        let sourceText = try String(contentsOf: sourceSRT, encoding: .utf8)
        let contentHash = StableTopicHash.string(sourceText)
        let revisionID = "transcript-\(language.rawValue)-\(contentHash)"
        let transcriptArtifactID = "artifact-\(revisionID)-txt"
        let subtitleArtifactID = "artifact-\(revisionID)-srt"
        let revisionTranscriptURL = layout.transcriptRevisionURL(id: revisionID, language: language)
        let revisionSubtitleURL = layout.subtitleRevisionURL(id: revisionID, language: language)
        if !FileManager.default.fileExists(atPath: revisionTranscriptURL.path) {
            try Data(contentsOf: transcriptURL).write(to: revisionTranscriptURL, options: .atomic)
        }
        if !FileManager.default.fileExists(atPath: revisionSubtitleURL.path) {
            try Data(contentsOf: subtitleURL).write(to: revisionSubtitleURL, options: .atomic)
        }
        let revision = TranscriptRevision(
            id: revisionID,
            language: language,
            origin: .machineGenerated,
            parentRevisionID: nil,
            transcriptArtifactID: transcriptArtifactID,
            subtitleArtifactID: subtitleArtifactID,
            contentHash: contentHash,
            createdAt: Date()
        )
        let commonGenerator = BuildInfo.name
        let commonVersion = BuildInfo.version
        try store.registerArtifact(ProjectArtifactRecord(
            id: transcriptArtifactID,
            kind: .transcript,
            path: revisionTranscriptURL.path,
            language: language,
            origin: .source,
            granularity: nil,
            sourceArtifactID: nil,
            sourceRevision: revisionID,
            dependencyIDs: [],
            contentHash: StableTopicHash.string(try String(contentsOf: revisionTranscriptURL, encoding: .utf8)),
            createdAt: Date(),
            generator: commonGenerator,
            generatorVersion: commonVersion,
            model: URL(fileURLWithPath: modelPath).lastPathComponent,
            validationStatus: .ready,
            qualityStatus: .pending,
            reviewTaskCount: 0
        ), in: projectURL)
        try store.registerArtifact(ProjectArtifactRecord(
            id: subtitleArtifactID,
            kind: .subtitles,
            path: revisionSubtitleURL.path,
            language: language,
            origin: .source,
            granularity: nil,
            sourceArtifactID: transcriptArtifactID,
            sourceRevision: revisionID,
            dependencyIDs: [transcriptArtifactID],
            contentHash: contentHash,
            createdAt: Date(),
            generator: commonGenerator,
            generatorVersion: commonVersion,
            model: URL(fileURLWithPath: modelPath).lastPathComponent,
            validationStatus: .ready,
            qualityStatus: .pending,
            reviewTaskCount: 0
        ), in: projectURL)
        try store.mutate(projectURL) { manifest in
            var revisions = manifest.transcriptRevisions ?? []
            revisions.removeAll { $0.id == revision.id }
            revisions.append(revision)
            manifest.transcriptRevisions = revisions
            if manifest.languageProfile?.effective == nil {
                manifest.languageProfile?.effective = language
            }
        }
        return revision
    }

    private func ensureTranscriptRevision(
        cues: [SubtitleCue],
        language: ArtifactLanguage,
        projectURL: URL,
        layout: ProjectLayout
    ) throws -> TranscriptRevision {
        let manifest = try store.load(from: projectURL)
        if let revision = manifest.activeTranscriptRevision(for: language) {
            return revision
        }
        if !nonemptyFile(layout.transcriptURL) {
            try writeTranscript(from: cues, to: layout.transcriptURL)
        }
        return try registerTranscriptRevision(
            cues: cues,
            language: language,
            projectURL: projectURL,
            layout: layout,
            sourceSRT: layout.fullSRTURL,
            sourceTranscript: layout.transcriptURL,
            modelPath: "legacy-existing-result"
        )
    }

    private func registerTranslation(
        _ result: TranslationAdapterResult,
        sourceRevision: TranscriptRevision,
        sourceLanguage: ArtifactLanguage,
        targetLanguage: ArtifactLanguage,
        projectURL: URL,
        layout: ProjectLayout
    ) throws -> TranslationReport {
        let subtitleURL = layout.subtitlesURL(language: targetLanguage)
        let transcriptURL = layout.transcriptURL(language: targetLanguage)
        try srt.writePreservingIDs(result.cues, to: subtitleURL)
        try writeTranscript(from: result.cues, to: transcriptURL)
        let subtitleText = try String(contentsOf: subtitleURL, encoding: .utf8)
        let transcriptText = try String(contentsOf: transcriptURL, encoding: .utf8)
        let revisionHash = StableTopicHash.string("\(sourceRevision.id)|\(result.model)|\(subtitleText)")
        let revisionID = "translation-\(sourceLanguage.rawValue)-\(targetLanguage.rawValue)-\(revisionHash)"
        let transcriptArtifactID = "artifact-\(revisionID)-txt"
        let subtitleArtifactID = "artifact-\(revisionID)-srt"
        let revisionTranscriptURL = layout.transcriptRevisionURL(id: revisionID, language: targetLanguage)
        let revisionSubtitleURL = layout.subtitleRevisionURL(id: revisionID, language: targetLanguage)
        try Data(contentsOf: transcriptURL).write(to: revisionTranscriptURL, options: .atomic)
        try Data(contentsOf: subtitleURL).write(to: revisionSubtitleURL, options: .atomic)

        let revision = TranscriptRevision(
            id: revisionID,
            language: targetLanguage,
            origin: .translated,
            parentRevisionID: sourceRevision.id,
            transcriptArtifactID: transcriptArtifactID,
            subtitleArtifactID: subtitleArtifactID,
            contentHash: revisionHash,
            createdAt: Date()
        )
        let sourceCues = try srt.load(from: layout.subtitlesURL(language: sourceLanguage))
        let sourceByID = Dictionary(uniqueKeysWithValues: sourceCues.map { ($0.id, $0) })
        let translatedByID = Dictionary(uniqueKeysWithValues: result.cues.map { ($0.id, $0) })
        let tasks = result.issues.compactMap { issue -> ReviewTask? in
            guard let sourceCue = sourceByID[issue.cueID], let translatedCue = translatedByID[issue.cueID] else { return nil }
            return ReviewTask(
                id: "translation-review-\(revisionID)-cue-\(issue.cueID)",
                transcriptRevisionID: revisionID,
                status: .needsReview,
                language: targetLanguage,
                start: sourceCue.start,
                end: sourceCue.end,
                cueIDs: [issue.cueID],
                reasonCodes: issue.reasonCodes,
                confidence: nil,
                originalText: sourceCue.text,
                suggestedText: issue.candidateText ?? translatedCue.text,
                createdAt: Date(),
                resolvedAt: nil,
                dependentArtifactIDs: [transcriptArtifactID, subtitleArtifactID]
            )
        }
        let validation: ArtifactValidationStatus = tasks.isEmpty ? .ready : .needsReview
        let transcriptArtifact = ProjectArtifactRecord(
            id: transcriptArtifactID,
            kind: .transcript,
            path: revisionTranscriptURL.path,
            language: targetLanguage,
            origin: .translated,
            granularity: nil,
            sourceArtifactID: sourceRevision.transcriptArtifactID,
            sourceRevision: revisionID,
            dependencyIDs: [sourceRevision.id],
            contentHash: StableTopicHash.string(transcriptText),
            createdAt: Date(),
            generator: BuildInfo.name,
            generatorVersion: BuildInfo.version,
            model: result.model,
            validationStatus: validation,
            qualityStatus: validation,
            reviewTaskCount: tasks.count
        )
        let subtitleArtifact = ProjectArtifactRecord(
            id: subtitleArtifactID,
            kind: .subtitles,
            path: revisionSubtitleURL.path,
            language: targetLanguage,
            origin: .translated,
            granularity: nil,
            sourceArtifactID: transcriptArtifactID,
            sourceRevision: revisionID,
            dependencyIDs: [transcriptArtifactID, sourceRevision.id],
            contentHash: StableTopicHash.string(subtitleText),
            createdAt: Date(),
            generator: BuildInfo.name,
            generatorVersion: BuildInfo.version,
            model: result.model,
            validationStatus: validation,
            qualityStatus: validation,
            reviewTaskCount: tasks.count
        )
        try store.mutate(projectURL) { manifest in
            var revisions = manifest.transcriptRevisions ?? []
            revisions.removeAll { $0.id == revisionID }
            revisions.append(revision)
            manifest.transcriptRevisions = revisions
            var artifacts = manifest.artifacts ?? []
            artifacts.removeAll { $0.id == transcriptArtifactID || $0.id == subtitleArtifactID }
            artifacts.append(contentsOf: [transcriptArtifact, subtitleArtifact])
            manifest.artifacts = artifacts
            var reviewTasks = manifest.reviewTasks ?? []
            reviewTasks.removeAll { $0.transcriptRevisionID == revisionID }
            reviewTasks.append(contentsOf: tasks)
            manifest.reviewTasks = reviewTasks
        }
        let allTasks = try store.load(from: projectURL).reviewTasks ?? []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(allTasks).write(to: layout.reviewTasksURL, options: .atomic)
        return TranslationReport(
            schemaVersion: 1,
            sourceRevisionID: sourceRevision.id,
            targetRevisionID: revisionID,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            model: result.model,
            translatedAt: Date(),
            cueCount: result.cues.count,
            reviewTaskIDs: tasks.map(\.id),
            status: validation
        )
    }

    private func availableTopicLanguages(manifest: ProjectManifest, layout: ProjectLayout) -> [ArtifactLanguage] {
        let source = manifest.languageProfile?.effective ?? .ru
        var languages = [source]
        for language in ArtifactLanguage.allCases where language != source {
            if nonemptyFile(layout.subtitlesURL(language: language)),
               manifest.activeTranscriptRevision(for: language) != nil {
                languages.append(language)
            }
        }
        return languages
    }

    private func registerTopicArtifact(
        _ file: TopicsFile,
        language: ArtifactLanguage,
        granularity: TopicGranularity,
        sourceLanguage: ArtifactLanguage,
        projectURL: URL,
        layout: ProjectLayout
    ) throws {
        let manifest = try store.load(from: projectURL)
        let sourceRevision = manifest.activeTranscriptRevision(for: language)
        let sourceArtifactID = sourceRevision?.subtitleArtifactID
        let jsonURL = layout.topicsURL(language: language, granularity: granularity)
        let content = try String(contentsOf: jsonURL, encoding: .utf8)
        let contentHash = StableTopicHash.string(content)
        let artifactID = "artifact-topics-\(language.rawValue)-\(granularity.rawValue)-\(contentHash)"
        try store.registerArtifact(ProjectArtifactRecord(
            id: artifactID,
            kind: .topics,
            path: jsonURL.path,
            language: language,
            origin: language == sourceLanguage ? .source : .translated,
            granularity: granularity,
            sourceArtifactID: sourceArtifactID,
            sourceRevision: sourceRevision?.id,
            dependencyIDs: [sourceRevision?.id, sourceArtifactID].compactMap { $0 },
            contentHash: contentHash,
            createdAt: Date(),
            generator: file.adapter,
            generatorVersion: file.algorithmVersion,
            model: file.languageModel,
            validationStatus: file.status == .ready ? .ready : .needsReview,
            qualityStatus: file.status == .ready ? .ready : .needsReview,
            reviewTaskCount: 0
        ), in: projectURL)
    }

    private func refreshDetectedResults(in projectURL: URL) throws {
        let discovered = detector.discover(in: projectURL)
        try store.mutate(projectURL) { manifest in manifest.outputs = discovered }
    }

    private func expectedDuration(for output: ProjectOutput, manifest: ProjectManifest) -> TimeInterval? {
        if output.kind == "subtitled-video" {
            return manifest.durationSeconds
        }
        guard output.kind == "fragment-video" || output.kind == "fragment-subtitled-video" else { return nil }
        return manifest.fragments?.first { fragment in
            fragment.videoPath == output.path || fragment.subtitledVideoPath == output.path
        }.map { $0.end - $0.start }
    }

    static func loadTopics(projectURL: URL) throws -> TopicsFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TopicsFile.self, from: Data(contentsOf: ProjectLayout(root: projectURL).topicsURL))
    }

    static func loadTopics(
        projectURL: URL,
        language: ArtifactLanguage,
        granularity: TopicGranularity
    ) throws -> TopicsFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            TopicsFile.self,
            from: Data(contentsOf: ProjectLayout(root: projectURL).topicsURL(language: language, granularity: granularity))
        )
    }

    static func selectTopic(projectURL: URL, id: String?) throws -> TopicSegment {
        let topics = try loadTopics(projectURL: projectURL).topics
        guard let selected = id.flatMap({ wanted in topics.first { $0.id == wanted } }) ?? topics.first else {
            throw WorkflowError.missingTopics
        }
        return selected
    }

    static func selectTopic(
        projectURL: URL,
        id: String?,
        language: ArtifactLanguage,
        granularity: TopicGranularity
    ) throws -> TopicSegment {
        let topics = try loadTopics(projectURL: projectURL, language: language, granularity: granularity).topics
        guard let selected = id.flatMap({ wanted in topics.first { $0.id == wanted } }) ?? topics.first else {
            throw WorkflowError.missingTopics
        }
        return selected
    }

    private func requiredDuration(of mediaURL: URL, manifest: ProjectManifest) async throws -> TimeInterval {
        if let duration = manifest.durationSeconds, duration > 0 { return duration }
        guard let duration = try await ffmpeg.duration(of: mediaURL), duration > 0 else {
            throw WorkflowError.processFailed("Не удалось определить длительность выбранного медиафайла.")
        }
        return duration
    }

    private func uniqueFragmentIdentifier(projectURL: URL, start: TimeInterval, end: TimeInterval, name: String) -> String {
        let range = "\(TimecodeParser.identifier(start))--\(TimecodeParser.identifier(end))"
        let cleanName = sanitizedName(name)
        let base = cleanName.isEmpty ? range : "\(cleanName)_\(range)"
        var candidate = base
        var suffix = 2
        let layout = ProjectLayout(root: projectURL)
        while FileManager.default.fileExists(atPath: layout.fragmentVideoURL(kind: candidate).deletingLastPathComponent().path)
            || FileManager.default.fileExists(atPath: layout.fragmentSRTURL(kind: candidate).deletingLastPathComponent().path) {
            candidate = "\(base) (\(suffix))"
            suffix += 1
        }
        return candidate
    }

    private func sanitizedName(_ value: String) -> String {
        let value = value.precomposedStringWithCanonicalMapping
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        return String(mapped).trimmingCharacters(in: .whitespacesAndNewlines).prefix(60).description
    }

    private func cleanupPartialFiles(in projectURL: URL) {
        guard let enumerator = FileManager.default.enumerator(at: projectURL, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator where url.lastPathComponent.contains(".partial.") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func currentProgress(_ projectURL: URL) -> Double {
        (try? store.load(from: projectURL).workflow?.progress) ?? 0
    }

    private func nonemptyFile(_ url: URL) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return size > 0
    }

    private func isAtLeastAsNew(_ candidate: URL, as source: URL) -> Bool {
        guard nonemptyFile(candidate), nonemptyFile(source),
              let candidateDate = try? candidate.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              let sourceDate = try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return false }
        return candidateDate >= sourceDate
    }
}
