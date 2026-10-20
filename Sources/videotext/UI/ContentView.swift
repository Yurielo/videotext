import SwiftUI
import AppKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers

private enum SimpleSubtitledVideoSource: String, CaseIterable, Identifiable {
    case source
    case approvedTranslation

    var id: Self { self }
}

/// Local UI state only: an unselected picker is neutral until the user asks to
/// create a topic fragment. It does not alter workflow state or persisted data.
struct SimpleTopicFragmentValidation: Equatable {
    private(set) var createAttemptedWithoutSelection = false

    var showsSelectionError: Bool { createAttemptedWithoutSelection }

    @discardableResult
    mutating func beginCreate(selectedTopicID: String?) -> Bool {
        guard selectedTopicID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            createAttemptedWithoutSelection = true
            return false
        }
        createAttemptedWithoutSelection = false
        return true
    }

    mutating func didSelectTopic() {
        createAttemptedWithoutSelection = false
    }

    mutating func reset() {
        createAttemptedWithoutSelection = false
    }
}

private enum SimpleProjectHomeGoal: String, CaseIterable, Identifiable {
    case presets
    case textContent
    case subtitledVideo
    case fragment
    case processVideo

    var id: Self { self }

    var title: String {
        switch self {
        case .presets: return "Пакеты обработки"
        case .textContent: return "Текст и содержание"
        case .subtitledVideo: return "Видео с субтитрами"
        case .fragment: return "Фрагмент видео"
        case .processVideo: return "Обработать видео"
        }
    }

    var detail: String {
        switch self {
        case .presets: return "Выберите результат · один запуск · проверка по ходу"
        case .textContent: return "Расшифровка · Темы · Перевод · Слова-паразиты"
        case .subtitledVideo: return "Полное видео · Исходные субтитры"
        case .fragment: return "По теме · По времени · По тексту"
        case .processVideo: return "Слова-паразиты · Скорость · Blur · Watermark · Звук"
        }
    }
}

/// Presentation intent for one explicitly started Simple translation.
/// It only opens the existing Human Review when that translation has actually
/// completed and persisted its review checkpoint.
struct SimpleTranslationPresentation {
    private struct Intent {
        var target: ArtifactLanguage
        var startedAt: Date
        var sawRunning = false
        var sawCompletion = false
    }

    private var intent: Intent?
    private var presentedCheckpoint: HumanReviewCheckpoint?
    private(set) var projectPath: String?

    mutating func begin(projectURL: URL, target: ArtifactLanguage, now: Date = Date()) {
        projectPath = projectURL.standardizedFileURL.path
        presentedCheckpoint = nil
        intent = Intent(
            target: target,
            // Persisted checkpoint dates may have whole-second precision.
            startedAt: Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        )
    }

    mutating func reset() {
        intent = nil
        presentedCheckpoint = nil
        projectPath = nil
    }

    private mutating func cancelPendingReview() {
        intent = nil
    }

    private func belongsTo(_ projectURL: URL?) -> Bool {
        guard let projectURL else { return false }
        return projectPath == projectURL.standardizedFileURL.path
    }

    private func matches(_ checkpoint: HumanReviewCheckpoint, projectURL: URL?) -> Bool {
        guard let intent, belongsTo(projectURL), checkpoint.kind == .translatedTranscript,
              checkpoint.createdAt >= intent.startedAt else { return false }
        return checkpoint.language == intent.target
    }

    func suppressesReviewAlert(title: String, projectURL: URL?, checkpoint: HumanReviewCheckpoint?) -> Bool {
        guard title == "Требуется Human Review", belongsTo(projectURL),
              let checkpoint, checkpoint.kind == .translatedTranscript else { return false }
        if matches(checkpoint, projectURL: projectURL) { return true }
        return presentedCheckpoint?.revisionID == checkpoint.revisionID
            && presentedCheckpoint?.language == checkpoint.language
    }

    func translationRunAlert(_ alert: AppAlert, projectURL: URL?) -> AppAlert {
        guard intent != nil, belongsTo(projectURL), presentedCheckpoint == nil else { return alert }
        var display = alert
        if alert.title == "Обработка остановлена" {
            display.message = "Перевод не завершён. Его можно создать заново из утверждённой расшифровки."
        } else if alert.title == "Ошибка" || alert.title == "Ошибка обработки" || alert.title == "Перевод не выполнен" {
            display.title = "Не удалось создать перевод"
            display.message = "Проверьте доступность TranslateGemma и повторите попытку."
        }
        return display
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
}

struct ContentView: View {
    @ObservedObject var model: WorkflowViewModel
    @State private var fragmentSelectionMode = FragmentSelectionMode.timecode
    @State private var showServiceResults = false
    @State private var previewTopic: TopicSegment?
    @State private var editingTopic: TopicSegment?
    @State private var reviewingBoundaryTopic: TopicSegment?
    @State private var editingReviewTask: ReviewTask?
    @State private var editingReviewCue: SubtitleCue?
    @State private var reviewSearch = ""
    @State private var reviewIssuesOnly = false
    @State private var confirmTopicRemoval = false
    @State private var selectedResultsTab = 0
    @State private var presentationMode: ProjectPresentationMode = .simple
    @State private var showProjectBrowser = false
    @State private var projectSearch = ""
    @State private var selectedBrowserProjectPath: String?
    @State private var knownProjects: [SimpleProjectBrowserEntry] = []
    @State private var simpleReviewTarget: SimpleProjectHomeReviewTarget?
    @State private var showsSimpleTextContent = false
    @State private var showsSimplePresets = false
    @State private var simplePresetConfiguration = ProcessingPresetConfiguration()
    @State private var selectedCustomPresetID: UUID?
    @State private var showsSimpleSubtitledVideo = false
    @State private var showsSimpleFragment = false
    @State private var showsSimpleProcessing = false
    @State private var simpleSubtitledVideoSource: SimpleSubtitledVideoSource = .source
    @State private var simpleSubtitledVideoActionStarted = false
    @State private var simpleFragmentStartText = "00:00:00"
    @State private var simpleFragmentEndText = "00:00:02"
    @State private var simpleFragmentActionStarted = false
    @State private var simpleSelectedTopicFragmentID: String?
    @State private var simpleSelectedTopicFragmentTitle: String?
    @State private var simpleTopicFragmentActionStarted = false
    @State private var simpleTopicCutIsActive = false
    @State private var simpleTopicFragmentValidation = SimpleTopicFragmentValidation()
    @State private var simpleTranscription = SimpleTranscriptionPresentation()
    @State private var simpleTranslation = SimpleTranslationPresentation()

    var body: some View {
        Group {
            if presentationMode == .simple {
                simpleRoot
            } else {
                advancedRoot
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .alert(item: simpleDisplayedAlert) { alert in
            if model.projectURL != nil {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Папка проекта")) { model.openProjectFolder() },
                    secondaryButton: .cancel(Text("Закрыть"))
                )
            }
            return Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("Закрыть"))
            )
        }
        .sheet(item: $previewTopic) { topic in
            if let mediaURL = model.mediaURL {
                TopicPreviewView(mediaURL: mediaURL, topic: topic)
            }
        }
        .sheet(item: $editingTopic) { topic in
            TopicEditView(topic: topic) { title, summary, start, end in
                model.saveTopicEdits(title: title, summary: summary, startText: start, endText: end)
            }
        }
        .sheet(item: $reviewingBoundaryTopic) { topic in
            if let projectURL = model.projectURL,
               let context = TopicReviewCueContext(
                   topic: topic,
                   topics: model.topics,
                   cues: topicReviewCues(projectURL: projectURL, language: model.artifactLanguage)
               ) {
                TopicBoundaryReviewView(topic: topic, context: context) { start, end in
                    model.selectedTopicID = topic.id
                    return model.saveTopicEdits(
                        title: topic.title,
                        summary: topic.summary,
                        startText: TimecodeParser.display(start),
                        endText: TimecodeParser.display(end)
                    )
                }
            }
        }
        .sheet(item: $editingReviewTask) { task in
            if let mediaURL = model.mediaURL {
                ReviewTaskEditView(mediaURL: mediaURL, task: task) { replacement in
                    model.resolveReviewTask(task, replacementText: replacement)
                }
            }
        }
        .sheet(isPresented: $showProjectBrowser) {
            simpleProjectBrowser
        }
        .sheet(item: $simpleReviewTarget) { target in
            simpleHumanReviewSheet(target)
        }
        .confirmationDialog(
            "Удалить границу темы?",
            isPresented: $confirmTopicRemoval,
            titleVisibility: .visible
        ) {
            Button("Удалить и присоединить к соседней", role: .destructive) {
                model.removeSelectedTopicBoundary()
            }
            Button("Отмена", role: .cancel) {}
        }
        .onChange(of: model.humanReviewCheckpoint) { _, checkpoint in
            if checkpoint != nil { selectedResultsTab = 2 }
            if checkpoint == nil { simpleReviewTarget = nil }
            updateSimpleHumanReview()
        }
        .onChange(of: model.isRunning) { _, isRunning in
            if !isRunning { simpleTopicCutIsActive = false }
            updateSimpleHumanReview()
        }
        .onChange(of: model.alert?.id) { _, _ in
            updateSimpleHumanReview()
        }
        .onChange(of: model.projectURL) { _, _ in
            simpleTranscription.reset()
            simpleTranslation.reset()
            simpleReviewTarget = nil
            editingReviewCue = nil
            reviewSearch = ""
            reviewIssuesOnly = false
            showsSimpleTextContent = false
            showsSimplePresets = false
            selectedCustomPresetID = nil
            simplePresetConfiguration = simplePresetConfiguration.portableForSaving()
            if let source = model.projectURL.flatMap({ try? ProjectStore().load(from: $0).languageProfile?.effective }) {
                simplePresetConfiguration.targetLanguage = source.translationTarget
            }
            showsSimpleSubtitledVideo = false
            showsSimpleFragment = false
            showsSimpleProcessing = false
            simpleSubtitledVideoSource = .source
            simpleSubtitledVideoActionStarted = false
            simpleFragmentStartText = "00:00:00"
            simpleFragmentEndText = "00:00:02"
            simpleFragmentActionStarted = false
            simpleSelectedTopicFragmentID = nil
            simpleSelectedTopicFragmentTitle = nil
            simpleTopicFragmentActionStarted = false
            simpleTopicCutIsActive = false
            simpleTopicFragmentValidation.reset()
        }
        .onChange(of: presentationMode) { _, mode in
            if mode != .simple {
                simpleTranscription.reset()
                simpleTranslation.reset()
            }
        }
        .onChange(of: model.topicReviewCheckpoint) { _, checkpoint in
            if checkpoint != nil { selectedResultsTab = 1 }
        }
    }

    private var advancedRoot: some View {
        VStack(spacing: 0) {
            header
            Divider()
            progressPanel
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HSplitView {
                historyPanel
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 260)
                controls
                    .frame(minWidth: 320, idealWidth: 380, maxWidth: 430)
                results
                    .frame(minWidth: 420, idealWidth: 620)
            }
        }
        .sheet(item: $editingReviewCue) { cue in
            humanReviewCueEditor(cue)
        }
    }

    private var simpleRoot: some View {
        VStack(spacing: 0) {
            simpleHeader
            Divider()
            if model.isRunning {
                simpleProgressPanel
                Divider()
            }
            if model.projectURL == nil {
                simpleEmptyState
            } else {
                simpleProjectHome
            }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                appIdentity
                Spacer(minLength: 12)
                advancedPresentationModePicker
                projectActions()
                workflowActions(includeStatus: true)
            }
            VStack(spacing: 10) {
                HStack {
                    appIdentity
                    Spacer()
                    advancedPresentationModePicker
                    statusLabel
                }
                HStack(spacing: 10) {
                    projectActions()
                    Spacer(minLength: 8)
                    workflowActions(includeStatus: false)
                }
            }
        }
        .padding()
    }

    private var appIdentity: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("videotext")
                    .font(.title2.bold())
                Text("Версия \(BuildInfo.version) / сборка \(BuildInfo.build)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var simpleAppIdentity: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            Text("videotext")
                .font(.title2.bold())
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var advancedPresentationModePicker: some View {
        Picker("Режим", selection: $presentationMode) {
            ForEach(ProjectPresentationMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
        .accessibilityLabel("Режим интерфейса")
    }

    private var simplePresentationModePicker: some View {
        Picker("", selection: $presentationMode) {
            ForEach(ProjectPresentationMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize(horizontal: true, vertical: false)
        .frame(width: 190)
        .accessibilityLabel("Режим интерфейса")
        .accessibilityIdentifier("simple.modePicker")
    }

    private var simpleHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                simpleAppIdentity
                Spacer(minLength: 12)
                simplePresentationModePicker
                simpleProjectActions
            }
            VStack(spacing: 10) {
                HStack {
                    simpleAppIdentity
                    Spacer()
                    simplePresentationModePicker
                }
                simpleProjectActions
            }
        }
        .padding()
    }

    private var simpleProgressPanel: some View {
        let fraction = SimpleTranscriptionPresentation.fraction(model.progress.overallFraction)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(simpleProgressStage)
                    .font(.subheadline.bold())
                    .accessibilityIdentifier("simple.progress.stage")
                Spacer()
                Text("Выполнено: \(percent(fraction))")
                    .monospacedDigit()
                Button(role: .destructive) {
                    model.stop()
                } label: {
                    Label(model.isStopping ? "Остановка..." : "Остановить обработку", systemImage: "stop.fill")
                }
                .disabled(model.isStopping)
                .accessibilityIdentifier("simple.progress.stop")
            }
            ProgressView(value: fraction, total: 1)
                .accessibilityIdentifier("simple.progress.fraction")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simple.progress.panel")
    }

    private var simpleEmptyState: some View {
        let recent = Array(simpleProjectBrowserEntries.filter(\.isAvailable).prefix(4))
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Продолжить работу")
                        .font(.title2.bold())
                    Spacer()
                    Button("Все проекты") {
                        handleSimpleNavigation(.openKnownProjects)
                    }
                    .buttonStyle(.bordered)
                }

                if recent.isEmpty {
                    ContentUnavailableView("Проектов пока нет", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    VStack(spacing: 0) {
                        ForEach(recent) { entry in
                            simpleProjectBrowserRow(entry, compact: true)
                            if entry.id != recent.last?.id { Divider() }
                        }
                    }
                }

                Divider()

                Button {
                    handleSimpleNavigation(.locateProjectOnDisk)
                } label: {
                    Label("Найти проект на диске…", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(28)
        }
        .onAppear(perform: reloadSimpleProjectBrowser)
    }

    private var simpleProjectActions: some View {
        HStack(spacing: 10) {
            Button {
                handleSimpleNavigation(.createFromMedia)
            } label: {
                Label("Новый проект", systemImage: "plus")
            }
            .disabled(model.isRunning)
            Button {
                handleSimpleNavigation(.openKnownProjects)
            } label: {
                Label("Открыть проект", systemImage: "folder")
            }
            .disabled(model.isRunning)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var simpleProjectBrowserEntries: [SimpleProjectBrowserEntry] {
        knownProjects
    }

    private var filteredSimpleProjectBrowserEntries: [SimpleProjectBrowserEntry] {
        let query = projectSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return simpleProjectBrowserEntries }
        return simpleProjectBrowserEntries.filter { entry in
            entry.projectName.localizedCaseInsensitiveContains(query)
                || entry.history.mediaName.localizedCaseInsensitiveContains(query)
                || entry.history.projectPath.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedSimpleProjectBrowserEntry: SimpleProjectBrowserEntry? {
        guard let selectedBrowserProjectPath else { return nil }
        return filteredSimpleProjectBrowserEntries.first { $0.id == selectedBrowserProjectPath }
    }

    private var simpleProjectBrowser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Все проекты")
                    .font(.title2.bold())
                Spacer()
                TextField("Поиск", text: $projectSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                Button("Закрыть") {
                    dismissSimpleProjectBrowser()
                }
            }
            .padding(18)

            Divider()

            if filteredSimpleProjectBrowserEntries.isEmpty {
                ContentUnavailableView("Проекты не найдены", systemImage: "folder")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredSimpleProjectBrowserEntries, selection: $selectedBrowserProjectPath) { entry in
                    simpleProjectBrowserRow(entry, compact: false)
                        .tag(entry.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            openSimpleProject(entry)
                        }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Button {
                    handleSimpleNavigation(.locateProjectOnDisk)
                } label: {
                    Label("Найти проект на диске…", systemImage: "folder")
                }
                .disabled(model.isRunning)
                Spacer()
                Button("Открыть") {
                    if let entry = selectedSimpleProjectBrowserEntry {
                        openSimpleProject(entry)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedSimpleProjectBrowserEntry?.isAvailable != true || model.isRunning)
            }
            .padding(18)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 620)
        .onAppear {
            projectSearch = ""
            selectedBrowserProjectPath = filteredSimpleProjectBrowserEntries.first(where: \.isAvailable)?.id
        }
    }

    @ViewBuilder
    private func simpleProjectBrowserRow(_ entry: SimpleProjectBrowserEntry, compact: Bool) -> some View {
        if compact {
            Button {
                openSimpleProject(entry)
            } label: {
                simpleProjectBrowserRowContent(entry, compact: true)
            }
            .buttonStyle(.plain)
            .disabled(!entry.isAvailable || model.isRunning)
        } else {
            simpleProjectBrowserRowContent(entry, compact: false)
        }
    }

    private func simpleProjectBrowserRowContent(_ entry: SimpleProjectBrowserEntry, compact: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isAvailable ? "folder.fill" : "folder.badge.questionmark")
                .foregroundStyle(entry.isAvailable ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(entry.projectName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(entry.history.updatedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if entry.history.mediaName != entry.projectName {
                    Text(entry.history.mediaName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let home = entry.home {
                    Text(home.currentState)
                        .font(.caption.weight(.semibold))
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            if let language = home.sourceLanguage {
                                Text(language.russianTitle)
                            }
                            ForEach(home.artifacts) { artifact in
                                Label(simpleBrowserArtifactLabel(artifact), systemImage: simpleArtifactIcon(artifact.readiness))
                                    .foregroundStyle(simpleArtifactColor(artifact.readiness))
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            if let language = home.sourceLanguage {
                                Text(language.russianTitle)
                            }
                            ForEach(home.artifacts) { artifact in
                                Label(simpleBrowserArtifactLabel(artifact), systemImage: simpleArtifactIcon(artifact.readiness))
                                    .foregroundStyle(simpleArtifactColor(artifact.readiness))
                            }
                        }
                    }
                    .font(.caption)
                    .lineLimit(1)
                    if !compact {
                        Text("Видео: \(entry.generatedVideoCount) · Фрагменты: \(entry.fragmentCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let issue = entry.availabilityIssue {
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if compact, entry.isAvailable { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
        }
        .padding(.vertical, compact ? 10 : 7)
    }

    private func handleSimpleNavigation(_ action: SimpleProjectNavigationAction) {
        switch action {
        case .openKnownProjects:
            reloadSimpleProjectBrowser()
            showProjectBrowser = true
        case .createFromMedia:
            if let url = openMediaFile() { model.selectMedia(url) }
        case .locateProjectOnDisk:
            if let url = openProjectDirectory() {
                model.openProject(url)
                dismissSimpleProjectBrowser()
            }
        }
    }

    private func openSimpleProject(_ entry: SimpleProjectBrowserEntry) {
        guard entry.isAvailable, !model.isRunning else { return }
        model.openProject(URL(fileURLWithPath: entry.history.projectPath, isDirectory: true))
        dismissSimpleProjectBrowser()
    }

    private func dismissSimpleProjectBrowser() {
        showProjectBrowser = false
        projectSearch = ""
        selectedBrowserProjectPath = nil
    }

    private func reloadSimpleProjectBrowser() {
        knownProjects = SimpleProjectBrowserStateService().entries()
    }

    private func simpleBrowserArtifactLabel(_ artifact: SimpleProjectHomeArtifact) -> String {
        let base = "\(artifact.kind.title): \(artifact.readiness.title)"
        guard artifact.readiness == .ready || artifact.readiness == .needsReview else { return base }
        return "\(base) · \(artifact.detail)"
    }

    private var simpleProjectHome: some View {
        let state = simpleHomeState
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(state.mediaName)
                        .font(.title2.bold())
                        .lineLimit(2)
                    HStack(spacing: 10) {
                        Text(state.projectName)
                        if let duration = state.durationSeconds, duration > 0 {
                            Text(TimeTextFormatter.string(duration))
                                .monospacedDigit()
                        }
                        if let language = state.sourceLanguage {
                            Text(language.russianTitle)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    Label(simpleCurrentState(state), systemImage: simpleStateIcon(state))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(simpleStateColor(state))
                        .accessibilityIdentifier("simple.project.status")
                }

                simpleSectionTitle(state.artifact(.transcription).readiness == .ready ? "Готово" : "Результаты")
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(state.artifacts) { artifact in
                        simpleArtifactRow(artifact, section: "ready")
                    }
                }

                simpleSectionTitle("Что хотите получить?")
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                    spacing: 8
                ) {
                    simpleGoalCard(.presets, icon: "square.stack.3d.up", reveal: { goal in
                        proxy.scrollTo(goal.rawValue, anchor: .top)
                    })
                    simpleGoalCard(.textContent, icon: "text.alignleft", reveal: { goal in
                        proxy.scrollTo(goal.rawValue, anchor: .top)
                    })
                    simpleGoalCard(.subtitledVideo, icon: "captions.bubble", reveal: { goal in
                        proxy.scrollTo(goal.rawValue, anchor: .top)
                    })
                    simpleGoalCard(.fragment, icon: "scissors", reveal: { goal in
                        proxy.scrollTo(goal.rawValue, anchor: .top)
                    })
                    simpleGoalCard(.processVideo, icon: "slider.horizontal.3", reveal: { goal in
                        proxy.scrollTo(goal.rawValue, anchor: .top)
                    })
                }
                .frame(maxWidth: 680, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("simple.goals.grid")

                if showsSimplePresets {
                    simpleProcessingPresetsPanel
                        .id(SimpleProjectHomeGoal.presets.rawValue)
                }

                if showsSimpleTextContent {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            simpleSectionTitle("Текст и содержание")
                            Spacer()
                            Button("Скрыть") { showsSimpleTextContent = false }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("simple.textContent.collapse")
                        }
                        simpleTopicsRecoveryMessage(state.artifact(.topics), section: "textContent")
                        ForEach(state.artifacts.filter {
                            $0.kind == .transcription || $0.kind == .topics || $0.kind == .translation
                        }) { artifact in
                            simpleArtifactRow(artifact, section: "textContent")
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("simple.textContent.panel")
                    .id(SimpleProjectHomeGoal.textContent.rawValue)
                }

                if showsSimpleSubtitledVideo {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            simpleSectionTitle("Видео с субтитрами")
                            Spacer()
                            Button("Скрыть") { showsSimpleSubtitledVideo = false }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("simple.subtitledVideo.collapse")
                        }
                        simpleSourceSubtitledVideoPanel()
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("simple.subtitledVideo.panel")
                    .id(SimpleProjectHomeGoal.subtitledVideo.rawValue)
                }

                if showsSimpleFragment {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            simpleSectionTitle("Фрагмент видео")
                            Spacer()
                            Button("Скрыть") { showsSimpleFragment = false }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("simple.fragment.collapse")
                        }
                        simpleCutTopicPanel()
                        simpleCutRangePanel()
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("simple.fragment.panel")
                    .id(SimpleProjectHomeGoal.fragment.rawValue)
                }

                if showsSimpleProcessing {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            simpleSectionTitle("Обработать видео")
                            Spacer()
                            Button("Скрыть") { showsSimpleProcessing = false }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("simple.processVideo.collapse")
                        }
                        simpleAudioEnhancementPanel()
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("simple.processVideo.panel")
                    .id(SimpleProjectHomeGoal.processVideo.rawValue)
                }

                simpleSectionTitle("Последние результаты")
                if state.recentResults.isEmpty {
                    Text("Готовых результатов пока нет")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(state.recentResults) { output in
                            simpleRecentResultRow(output)
                        }
                    }
                }
                }
                .frame(maxWidth: 920, alignment: .leading)
                .padding(18)
            }
        }
    }

    private var simpleHomeState: SimpleProjectHomeState {
        simpleHomeState(topicGranularity: model.topicGranularity)
    }

    private func simpleHomeState(topicGranularity: TopicGranularity) -> SimpleProjectHomeState {
        guard let projectURL = model.projectURL else {
            return SimpleProjectHomeState(
                projectName: "",
                mediaName: "",
                durationSeconds: nil,
                sourceLanguage: nil,
                currentState: "",
                artifacts: [],
                recentResults: []
            )
        }
        let manifest = try? ProjectStore().load(from: projectURL)
        let outputs = SimpleProjectArtifactValidator().validatedOutputs(
            model.outputs,
            mediaDuration: manifest?.durationSeconds
        )
        let service = SimpleProjectHomeStateService()
        let selectedState = service.make(
            projectURL: projectURL,
            manifest: manifest,
            topicsDetail: model.resultSummary.artifact(.topics)?.detail,
            discoveredOutputs: outputs,
            topicLanguage: manifest?.languageProfile?.effective,
            topicGranularity: topicGranularity
        )
        return selectedState
    }

    private func simpleSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
    }

    private func simpleArtifactRow(_ artifact: SimpleProjectHomeArtifact, section: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Image(systemName: simpleArtifactIcon(artifact.readiness))
                    .foregroundStyle(simpleArtifactColor(artifact.readiness))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.displayTitle)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("simple.\(section).\(artifact.kind.rawValue).title")
                    Text(artifact.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 230, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                Text(artifact.readiness.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(simpleArtifactColor(artifact.readiness))
                    .accessibilityIdentifier("simple.\(section).\(artifact.kind.rawValue).status")
                if let path = artifact.openOutputPath,
                   artifact.kind != .topics || artifact.isUsableForTopicCut {
                    Button("Открыть") {
                        openSimpleResult(path)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("simple.\(section).\(artifact.kind.rawValue).open")
                }
                if let target = artifact.reviewTarget, target != .topics,
                   let language = artifact.language {
                    Button("Исправить") {
                        openSimpleReview(target, language: language)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canOpenHumanReview(language: language))
                    .accessibilityIdentifier("simple.\(section).\(artifact.kind.rawValue).correct")
                }
                if artifact.kind == .transcription,
                   artifact.readiness == .missing || artifact.readiness == .failed {
                    if let language = model.simpleTranscriptionLockedLanguage {
                        Label("Язык проекта: \(language.russianTitle)", systemImage: "lock")
                            .font(.subheadline)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("simple.\(section).transcription.projectLanguage")
                    } else {
                        Picker("Язык", selection: $model.whisperLanguage) {
                            Text("RU").tag("ru")
                            Text("EN").tag("en")
                            Text("Авто").tag("auto")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 210)
                        .disabled(model.isRunning || model.humanReviewCheckpoint != nil || model.topicReviewCheckpoint != nil)
                        .accessibilityLabel("Язык расшифровки")
                        .accessibilityIdentifier("simple.\(section).transcription.language")
                    }
                    Button("Создать расшифровку") {
                        startSimpleTranscription()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStartSimpleTranscription)
                    .accessibilityIdentifier("simple.\(section).transcription.create")
                }
                simpleTranslationActions(artifact, section: section)
            }
            simpleTopicsActions(artifact, section: section)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simple.\(section).\(artifact.kind.rawValue).row")
    }

    @ViewBuilder
    private func simpleTopicsActions(_ artifact: SimpleProjectHomeArtifact, section: String) -> some View {
        if artifact.kind == .topics, section == "textContent" {
            if model.topicReviewCheckpoint != nil || artifact.readiness == .needsReview {
                Label("Проверка тем доступна только в расширенном режиме", systemImage: "arrow.right.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("simple.\(section).topics.advancedHandoff")
            } else if artifact.readiness == .missing || artifact.readiness == .failed {
                if simpleHasCanonicalActiveSelectedTopicRevision {
                    EmptyView()
                } else if !simpleSourceTranscriptIsApproved {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Сначала утвердите расшифровку, затем можно создать темы.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("simple.\(section).topics.unavailable")
                        Button("Создать темы") {}
                            .buttonStyle(.borderedProminent)
                            .disabled(true)
                            .accessibilityIdentifier("simple.\(section).topics.create")
                    }
                } else {
                    if simpleTopicGranularityNeedsChoice {
                        Picker("Детализация", selection: Binding(
                            get: { model.topicGranularity },
                            set: { model.selectTopicVariant(language: model.artifactLanguage, granularity: $0) }
                        )) {
                            ForEach(TopicGranularity.allCases) { value in
                                Text(value.title).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                        .disabled(model.isRunning)
                        .accessibilityIdentifier("simple.\(section).topics.granularity")
                    }
                    if !model.canCreateTopicsFromAcceptedTranscript && !model.isRunning {
                        Text("Сейчас создать темы нельзя. Проверьте состояние расшифровки и файлов проекта.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("simple.\(section).topics.unavailable")
                    }
                    Button("Создать темы") {
                        startSimpleTopicsCreation()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canCreateTopicsFromAcceptedTranscript)
                    .accessibilityIdentifier("simple.\(section).topics.create")
                }
            }
        }
    }

    @ViewBuilder
    private func simpleTopicsRecoveryMessage(_ artifact: SimpleProjectHomeArtifact, section: String) -> some View {
        if (artifact.readiness == .missing || artifact.readiness == .failed),
           simpleHasCanonicalActiveSelectedTopicRevision {
            let normalTopicCutAvailable = !model.simpleApprovedTopicOptions.isEmpty
            Text(artifact.isUsableForTopicCut
                ? (normalTopicCutAvailable
                    ? "Текст тем недоступен для открытия. Восстановите файл. Отсутствие текста само по себе не блокирует создание фрагмента по утверждённой теме."
                    : "Текст тем недоступен для открытия. Восстановите файл. Для создания фрагмента по теме нужны доступные утверждённые темы обычной детализации.")
                : "Утверждённые темы недоступны. Восстановите файлы проекта или откройте корректный проект.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("simple.\(section).topics.unavailable")
        }
    }

    @ViewBuilder
    private func simpleTranslationActions(_ artifact: SimpleProjectHomeArtifact, section: String) -> some View {
        if artifact.kind == .translation, section == "textContent",
           artifact.readiness == .missing || artifact.readiness == .failed {
            if !simpleSourceTranscriptIsApproved {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Сначала утвердите расшифровку, затем можно создать перевод.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("simple.\(section).translation.unavailable")
                    Button("Создать перевод") {}
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                        .accessibilityIdentifier("simple.\(section).translation.create")
                }
            } else {
                if !model.canTranslate && !model.isRunning {
                    Text(model.translationStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("simple.\(section).translation.unavailable")
                }
                Button("Создать перевод") {
                    startSimpleTranslation()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canTranslate)
                .accessibilityIdentifier("simple.\(section).translation.create")
            }
        }
    }

    private var simpleSourceTranscriptIsApproved: Bool {
        guard let projectURL = model.projectURL,
              let manifest = try? ProjectStore().load(from: projectURL),
              let language = manifest.languageProfile?.effective else { return false }
        return manifest.activeTranscriptRevision(for: language)?.reviewStatus == .approved
    }

    private var simpleHasCanonicalActiveNormalTopicRevision: Bool {
        simpleHasCanonicalActiveTopicRevision(granularity: .normal)
    }

    private var simpleHasCanonicalActiveSelectedTopicRevision: Bool {
        simpleHasCanonicalActiveTopicRevision(granularity: model.topicGranularity)
    }

    private func simpleHasCanonicalActiveTopicRevision(granularity: TopicGranularity) -> Bool {
        guard let projectURL = model.projectURL,
              let manifest = try? ProjectStore().load(from: projectURL),
              let language = manifest.languageProfile?.effective else { return false }
        let key = "\(language.rawValue).\(granularity.rawValue)"
        guard let activeID = manifest.topicReviewState?.activeRevisionIDs[key] else { return false }
        guard let revisions = manifest.topicRevisions,
              revisions.filter({ $0.id == activeID }).count == 1,
              let revision = revisions.first(where: { $0.id == activeID }),
              revision.language == language,
              revision.granularity == granularity,
              revision.status == .approved else {
            return true
        }
        let expected = ProjectLayout(root: projectURL).topicRevisionJSONURL(id: revision.id)
            .standardizedFileURL.path
        let stored = URL(fileURLWithPath: revision.jsonPath).standardizedFileURL.path
        return stored == expected
    }

    private var simpleTopicGranularityNeedsChoice: Bool {
        guard let projectURL = model.projectURL,
              let manifest = try? ProjectStore().load(from: projectURL),
              let language = manifest.languageProfile?.effective else { return false }
        let existingCanonicalVariants = Set<TopicGranularity>(
            (manifest.topicReviewState?.activeRevisionIDs ?? [:]).keys.compactMap { key in
                let parts = key.split(separator: ".")
                guard parts.count == 2, parts[0] == language.rawValue else { return nil }
                return TopicGranularity(rawValue: String(parts[1]))
            }
        )
        return existingCanonicalVariants.count > 1
    }

    private func simpleGoalCard(
        _ goal: SimpleProjectHomeGoal,
        icon: String,
        reveal: @escaping (SimpleProjectHomeGoal) -> Void
    ) -> some View {
        Button {
            if goal == .presets {
                showsSimplePresets = true
            } else if goal == .textContent {
                showsSimpleTextContent = true
            } else if goal == .subtitledVideo {
                showsSimpleSubtitledVideo = true
            } else if goal == .fragment {
                showsSimpleFragment = true
            } else {
                showsSimpleProcessing = true
            }
            DispatchQueue.main.async { reveal(goal) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(goal.title)
                        .font(.headline)
                    Text(goal.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.45), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(goal.title)
        .accessibilityIdentifier("simple.goal.\(goal.rawValue)")
    }

    private var simpleProcessingPresetsPanel: some View {
        let configuration = simplePresetConfiguration
        let plan = model.processingPresetPlan(configuration)
        let execution = model.processingPresetExecution
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                simpleSectionTitle("Пакеты обработки")
                Spacer()
                Button("Скрыть") { showsSimplePresets = false }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("simple.presets.collapse")
            }
            Text("Выберите результат и нажмите «Создать». Проверка расшифровки, тем и перевода остаётся обязательной; после утверждения пакет продолжится.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Результат", selection: Binding(
                get: { simplePresetConfiguration.goal },
                set: { goal in
                    simplePresetConfiguration.goal = goal
                    simplePresetConfiguration.scope = .fullVideo
                    simplePresetConfiguration.effect = goal == .fullOriginal || goal == .fullTranslated
                        ? .watermark : (goal == .processing ? .blur : .none)
                    simplePresetConfiguration.muteFillers = false
                    simplePresetConfiguration = simplePresetConfiguration.clearingHiddenOptions()
                }
            )) {
                ForEach(ProcessingPresetGoal.allCases) { goal in
                    Text(goal.title).tag(goal)
                }
            }
            .accessibilityIdentifier("simple.presets.goal")

            HStack {
                Picker("Язык исходника", selection: $simplePresetConfiguration.sourceLanguage) {
                    Text("Авто").tag("auto")
                    Text("Русский").tag("ru")
                    Text("Английский").tag("en")
                }
                .accessibilityIdentifier("simple.presets.sourceLanguage")
                if configuration.goal.needsTranslation {
                    Picker("Перевести на", selection: $simplePresetConfiguration.targetLanguage) {
                        ForEach(ArtifactLanguage.allCases) { language in
                            Text(language.rawValue.uppercased()).tag(language)
                        }
                    }
                    .accessibilityIdentifier("simple.presets.targetLanguage")
                }
            }
            if configuration.goal == .topics {
                Picker("Детализация тем", selection: $simplePresetConfiguration.topicGranularity) {
                    ForEach(TopicGranularity.allCases) { granularity in
                        Text(granularity.title).tag(granularity)
                    }
                }
                .accessibilityIdentifier("simple.presets.granularity")
            }
            if configuration.goal.needsVideo {
                Picker("Объём видео", selection: Binding(
                    get: { simplePresetConfiguration.scope },
                    set: { scope in
                        simplePresetConfiguration.scope = scope
                        if configuration.goal == .fullOriginal || configuration.goal == .fullTranslated {
                            simplePresetConfiguration.effect = scope == .fullVideo ? .watermark : .none
                        }
                        if scope != .timeFragment { simplePresetConfiguration.muteFillers = false }
                        simplePresetConfiguration = simplePresetConfiguration.clearingHiddenOptions()
                    }
                )) {
                    ForEach(ProcessingPresetScope.allCases.filter {
                        $0 != .approvedTopic || configuration.goal == .sourceSubtitles || configuration.goal == .translatedSubtitles
                    }) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .accessibilityIdentifier("simple.presets.scope")
                if configuration.scope == .timeFragment {
                    HStack {
                        TextField("Начало, сек", value: $simplePresetConfiguration.fragmentStart, format: .number)
                        TextField("Конец, сек", value: $simplePresetConfiguration.fragmentEnd, format: .number)
                    }
                    .accessibilityIdentifier("simple.presets.fragmentRange")
                }
                if configuration.scope == .approvedTopic {
                    Picker("Утверждённая тема", selection: $simplePresetConfiguration.topicID) {
                        Text("Выберите тему").tag(nil as String?)
                        ForEach(model.simpleApprovedTopicOptions) { topic in
                            Text(topic.title).tag(topic.id as String?)
                        }
                    }
                    .accessibilityIdentifier("simple.presets.approvedTopic")
                }
                if configuration.goal == .processing || configuration.goal == .fullOriginal || configuration.goal == .fullTranslated {
                    Picker("Обработка", selection: Binding(
                        get: { simplePresetConfiguration.effect },
                        set: { effect in
                            simplePresetConfiguration.effect = effect
                            simplePresetConfiguration = simplePresetConfiguration.clearingHiddenOptions()
                        }
                    )) {
                        ForEach(ProcessingPresetEffect.allCases.filter { effect in
                            if configuration.goal == .fullOriginal || configuration.goal == .fullTranslated {
                                return configuration.scope == .fullVideo ? effect == .watermark
                                    : [.none, .speed, .blur].contains(effect)
                            }
                            return configuration.scope == .timeFragment
                                ? [.none, .speed, .blur].contains(effect) : effect != .none
                        }) { effect in
                            Text(effect.title).tag(effect)
                        }
                    }
                    .accessibilityIdentifier("simple.presets.effect")
                    if configuration.effect == .speed {
                        HStack {
                            Slider(value: $simplePresetConfiguration.speedFactor, in: 0.5...2, step: 0.05)
                            Text("\(configuration.speedFactor, specifier: "%.2f")x")
                        }
                        .accessibilityIdentifier("simple.presets.speed")
                    }
                    if configuration.effect == .blur || configuration.combineBlur {
                        HStack {
                            Text("Интенсивность blur")
                            Slider(value: $simplePresetConfiguration.blurIntensity, in: 1...30, step: 1)
                            Text("\(Int(configuration.blurIntensity))")
                        }
                        .accessibilityIdentifier("simple.presets.blur")
                        HStack {
                            TextField("X", value: $simplePresetConfiguration.blurRegion.x, format: .number)
                            TextField("Y", value: $simplePresetConfiguration.blurRegion.y, format: .number)
                            TextField("Ширина", value: $simplePresetConfiguration.blurRegion.width, format: .number)
                            TextField("Высота", value: $simplePresetConfiguration.blurRegion.height, format: .number)
                        }
                        .accessibilityIdentifier("simple.presets.blurRegion")
                    }
                    if configuration.effect == .watermark {
                        HStack {
                            Button("Выбрать watermark") {
                                simplePresetConfiguration.watermarkImagePath = openWatermarkImage()?.path
                            }
                            Text(configuration.watermarkImagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Не выбран")
                                .font(.caption)
                                .lineLimit(1)
                        }
                        Picker("Положение", selection: $simplePresetConfiguration.watermarkPosition) {
                            ForEach(WatermarkPosition.allCases.filter { $0 != .manual }) { position in
                                Text(position.title).tag(position)
                            }
                        }
                        Toggle("Размыть выбранную область вместе с watermark", isOn: $simplePresetConfiguration.combineBlur)
                        HStack {
                            Text("Прозрачность")
                            Slider(value: $simplePresetConfiguration.watermarkOpacity, in: 0...1)
                        }
                        .accessibilityIdentifier("simple.presets.watermark")
                    }
                    if configuration.effect == .audioEnhancement {
                        Picker("Профиль звука", selection: $simplePresetConfiguration.audioEnhancementProfile) {
                            ForEach(AudioEnhancementProfile.allCases) { profile in
                                Text(profile.title).tag(profile)
                            }
                        }
                    }
                    if configuration.scope == .timeFragment {
                        Toggle("Заглушить найденные слова-паразиты", isOn: $simplePresetConfiguration.muteFillers)
                    }
                }
                if configuration.needsSourceSubtitles || configuration.needsTranslatedSubtitles {
                    HStack {
                        Text("Размер субтитров")
                        Slider(value: $simplePresetConfiguration.subtitleStyle.fontSize, in: 12...36, step: 1)
                        Text("\(Int(configuration.subtitleStyle.fontSize))")
                    }
                    Picker("Положение субтитров", selection: $simplePresetConfiguration.subtitleStyle.position) {
                        ForEach(SubtitlePosition.allCases) { position in
                            Text(position.title).tag(position)
                        }
                    }
                    .accessibilityIdentifier("simple.presets.subtitleStyle")
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("План").font(.subheadline.weight(.semibold))
                Text("Результат: \(plan.result)")
                    .font(.caption.weight(.medium))
                    .accessibilityIdentifier("simple.presets.expectedResult")
                ForEach(plan.reused, id: \.self) { item in
                    Text("Используем готовое: \(item)").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(plan.stages.enumerated()), id: \.offset) { index, stage in
                    Text("\(index + 1). \(stage.title)").font(.caption)
                }
                if let blocker = plan.blocker {
                    Text(blocker).font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("simple.presets.blocker")
                }
            }
            HStack {
                Button("Создать") { _ = model.startProcessingPreset(configuration) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!plan.canCreate || model.isRunning || model.isStopping
                        || model.humanReviewCheckpoint != nil || model.topicReviewCheckpoint != nil)
                    .accessibilityIdentifier("simple.presets.create")
                if model.isRunning {
                    Button("Остановить") { model.stop() }
                        .accessibilityIdentifier("simple.presets.stop")
                } else if let execution, execution.status != .complete {
                    Button("Продолжить пакет") { _ = model.resumeProcessingPreset() }
                        .disabled(model.humanReviewCheckpoint != nil || model.topicReviewCheckpoint != nil)
                        .accessibilityIdentifier("simple.presets.resume")
                }
            }
            if let execution {
                let total = max(execution.stages.count, 1)
                let fraction = execution.status == .complete ? 1 :
                    (Double(execution.currentStage) + (model.isRunning ? model.progress.overallFraction : 0)) / Double(total)
                ProgressView(value: min(max(fraction, 0), 1), total: 1)
                    .accessibilityIdentifier("simple.presets.progress")
                if model.isRunning {
                    Text(model.progress.remaining.map { "Осталось примерно \(TimeTextFormatter.string($0))" }
                        ?? "Оценка времени уточняется")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("simple.presets.eta")
                }
                Text("Пакет: \(execution.configuration.goal.title) · \(execution.status.rawValue) · \(min(execution.currentStage + 1, total))/\(total)")
                    .font(.caption)
                    .accessibilityIdentifier("simple.presets.status")
                if let error = execution.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if execution.status == .awaitingReview {
                    Button("Открыть проверку") {
                        if let checkpoint = model.humanReviewCheckpoint {
                            showsSimpleTextContent = true
                            presentSimpleReview(checkpoint.kind == .sourceTranscript ? .source : .translation)
                        } else if model.topicReviewCheckpoint != nil {
                            presentationMode = .advanced
                            selectedResultsTab = 1
                        }
                    }
                    .accessibilityIdentifier("simple.presets.review")
                }
                if execution.status == .complete, let path = execution.resultPath {
                    HStack {
                        Button("Открыть") { openSimpleResult(path) }
                        Button("Показать в Finder") {
                            model.revealResult(ProjectOutput(id: path, kind: "user-facing-media", path: path, createdAt: Date()))
                        }
                    }
                    .accessibilityIdentifier("simple.presets.result")
                }
            }
            Divider()
            Text("Пользовательский пакет").font(.subheadline.weight(.semibold))
            Picker("Сохранённый", selection: $selectedCustomPresetID) {
                Text("Новый пакет").tag(nil as UUID?)
                ForEach(model.customProcessingPresets) { preset in
                    Text(preset.name).tag(preset.id as UUID?)
                }
            }
            .onChange(of: selectedCustomPresetID) { _, id in
                if let preset = model.customProcessingPresets.first(where: { $0.id == id }) {
                    simplePresetConfiguration = preset.clearingHiddenOptions()
                } else {
                    simplePresetConfiguration.id = UUID()
                    simplePresetConfiguration.name = ""
                }
            }
            TextField("Название, например «Мой YouTube»", text: $simplePresetConfiguration.name)
                .accessibilityIdentifier("simple.presets.custom.name")
            HStack {
                Button("Сохранить") {
                    if model.saveCustomProcessingPreset(simplePresetConfiguration) {
                        selectedCustomPresetID = simplePresetConfiguration.id
                    }
                }
                .accessibilityIdentifier("simple.presets.custom.save")
                if let id = selectedCustomPresetID {
                    Button("Удалить", role: .destructive) {
                        model.deleteCustomProcessingPreset(id: id)
                        selectedCustomPresetID = nil
                    }
                    .accessibilityIdentifier("simple.presets.custom.delete")
                }
            }
            Text("Режим «Автоматически» для публикации непроверенного перевода пока недоступен. Пакеты работают «С проверкой».")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("simple.presets.reviewPolicy")
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simple.presets.panel")
    }

    @ViewBuilder
    private func simpleAudioEnhancementPanel() -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Улучшение звука")
                .font(.subheadline.weight(.semibold))
            Text("Создаёт отдельное видео с улучшенным звуком. Исходное видео не изменяется.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Профиль", selection: $model.audioEnhancementProfile) {
                ForEach(AudioEnhancementProfile.allCases) { profile in
                    Text(profile.title).tag(profile)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("simple.processVideo.audio.profile")

            if let output = simpleLatestOutput(kind: "enhanced-video") {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Видео с улучшенным звуком")
                            .fontWeight(.semibold)
                        Text("Готово")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Открыть") { openSimpleResult(output.path) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("simple.processVideo.audio.open")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("simple.processVideo.audio.ready")
            } else {
                Button("Создать видео с улучшенным звуком") {
                    model.enhanceAudio()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.projectURL == nil || model.isRunning || model.isStopping)
                .accessibilityIdentifier("simple.processVideo.audio.create")
            }

            Divider()

            Text("Скорость")
                .font(.subheadline.weight(.semibold))
            Picker("Источник скорости", selection: $model.speedSource) {
                ForEach(SpeedSourceKind.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("simple.processVideo.speed.source")
            HStack {
                Slider(value: $model.speedFactor, in: 0.5...2, step: 0.05)
                Text("\(model.speedFactor, specifier: "%.2f")x")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            Button("Создать видео с изменённой скоростью") { model.createSpeedAdjustedVideo() }
                .buttonStyle(.borderedProminent)
                .disabled(model.projectURL == nil || model.isRunning || model.isStopping)
                .accessibilityIdentifier("simple.processVideo.speed.create")
            if let output = simpleLatestOutput(kind: "speed-adjusted-video") {
                simpleProcessingOpenResult("Видео с изменённой скоростью", output: output, identifier: "simple.processVideo.speed")
            }

            Divider()

            Text("Статический blur")
                .font(.subheadline.weight(.semibold))
            Toggle("Размыть область в правом верхнем углу", isOn: $model.blurEnabled)
                .accessibilityIdentifier("simple.processVideo.blur.enabled")
            if model.blurEnabled {
                Picker("Источник blur", selection: $model.blurSource) {
                    ForEach(SpeedSourceKind.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Интенсивность")
                    Slider(value: $model.blurIntensity, in: 1...30, step: 1)
                    Text("\(Int(model.blurIntensity))")
                        .monospacedDigit()
                        .frame(width: 24, alignment: .trailing)
                }
                Button("Создать видео с blur") { model.createBlurredVideo() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.projectURL == nil || model.isRunning || model.isStopping)
                    .accessibilityIdentifier("simple.processVideo.blur.create")
                Text("Для выбора другой области blur используйте расширенный режим до создания файла.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("simple.processVideo.blur.advancedDetail")
                if let output = simpleLatestOutput(kind: "blurred-video") {
                    simpleProcessingOpenResult("Видео с blur", output: output, identifier: "simple.processVideo.blur")
                }
            }

            Divider()

            Text("Watermark")
                .font(.subheadline.weight(.semibold))
            HStack {
                Button("Выбрать изображение") { model.watermarkImageURL = openWatermarkImage() }
                    .accessibilityIdentifier("simple.processVideo.watermark.select")
                if let imageURL = model.watermarkImageURL {
                    Text(imageURL.lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Picker("Положение watermark", selection: $model.watermarkPosition) {
                ForEach(WatermarkPosition.allCases) { position in
                    Text(position.title).tag(position)
                }
            }
            Button("Создать видео с watermark") { model.createWatermarkedVideo() }
                .buttonStyle(.borderedProminent)
                .disabled(model.projectURL == nil || model.watermarkImageURL == nil || model.isRunning || model.isStopping)
                .accessibilityIdentifier("simple.processVideo.watermark.create")
            if let output = simpleLatestOutput(kind: "watermarked-video") {
                simpleProcessingOpenResult("Видео с watermark", output: output, identifier: "simple.processVideo.watermark")
            }

            Divider()

            Text("Слова-паразиты")
                .font(.subheadline.weight(.semibold))
            Button("Найти слова-паразиты") { model.analyzeFillerWords() }
                .buttonStyle(.bordered)
                .disabled(model.projectURL == nil || model.isRunning || model.isStopping)
                .accessibilityIdentifier("simple.processVideo.filler.analyze")
            if model.fillerCandidates.isEmpty {
                Text("Сначала выполните анализ. Если кандидатов нет, видео без удаления слов не создаётся.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Кандидатов: \(model.fillerCandidates.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Выбрать уверенные") { model.selectHighConfidenceFillers() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("simple.processVideo.filler.selectHighConfidence")
                Button("Создать видео без выбранных слов") {
                    model.fillerMode = .muteSelected
                    model.muteFillerWords()
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        model.isRunning || model.isStopping
                            || model.selectedFillerCandidateIDs.isEmpty
                    )
                    .accessibilityIdentifier("simple.processVideo.filler.create")
            }
            if let output = simpleLatestOutput(kind: "filler-muted-video") {
                simpleProcessingOpenResult("Видео без выбранных слов", output: output, identifier: "simple.processVideo.filler")
            }
        }
    }

    private func simpleProcessingOpenResult(
        _ title: String,
        output: ProjectOutput,
        identifier: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(title).font(.caption.weight(.semibold))
            Spacer()
            Button("Открыть") { openSimpleResult(output.path) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("\(identifier).open")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(identifier).ready")
    }

    private func simpleLatestOutput(kind: String) -> ProjectOutput? {
        model.outputs
            .filter { $0.kind == kind && $0.isGeneratedMedia && FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    @ViewBuilder
    private func simpleSourceSubtitledVideoPanel() -> some View {
        let targetLanguage = model.simpleApprovedTranslatedSubtitleTarget
        let selectedSource = simpleSubtitledVideoSource == .approvedTranslation && targetLanguage != nil
            ? SimpleSubtitledVideoSource.approvedTranslation
            : .source

        if let targetLanguage {
            Picker("Субтитры", selection: $simpleSubtitledVideoSource) {
                Text("Исходные").tag(SimpleSubtitledVideoSource.source)
                Text("Переведённые (\(targetLanguage.rawValue.uppercased()))")
                    .tag(SimpleSubtitledVideoSource.approvedTranslation)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("simple.subtitledVideo.source")
            .onChange(of: simpleSubtitledVideoSource) { _, _ in
                simpleSubtitledVideoActionStarted = false
            }
        } else {
            Text("Переведённые субтитры станут доступны после утверждения перевода.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("simple.subtitledVideo.translation.unavailable")
        }

        switch selectedSource {
        case .source:
            simpleSourceSubtitledVideoContent()
        case .approvedTranslation:
            simpleTranslatedSubtitledVideoContent(targetLanguage: targetLanguage!)
        }
    }

    @ViewBuilder
    private func simpleSourceSubtitledVideoContent() -> some View {
        if let output = simpleSourceSubtitledVideoOutput {
            simpleSubtitledVideoReadyContent(
                title: "Видео с исходными субтитрами",
                output: output,
                identifier: "simple.subtitledVideo"
            )
        } else {
            let availability = simpleSourceSubtitledVideoAvailability
            simpleSubtitledVideoCreationContent(
                availability: availability,
                action: { model.startSimpleSourceSubtitledVideoFromAcceptedTranscript() },
                identifier: "simple.subtitledVideo"
            )
        }
    }

    @ViewBuilder
    private func simpleTranslatedSubtitledVideoContent(targetLanguage: ArtifactLanguage) -> some View {
        if let output = simpleTranslatedSubtitledVideoOutput(language: targetLanguage) {
            simpleSubtitledVideoReadyContent(
                title: "Видео с переведёнными субтитрами (\(targetLanguage.rawValue.uppercased()))",
                output: output,
                identifier: "simple.subtitledVideo.translation"
            )
        } else {
            let availability = simpleTranslatedSubtitledVideoAvailability(targetLanguage: targetLanguage)
            simpleSubtitledVideoCreationContent(
                availability: availability,
                action: { model.startSimpleTranslatedSubtitledVideoFromAcceptedTranscript() },
                identifier: "simple.subtitledVideo.translation"
            )
        }
    }

    private func simpleSubtitledVideoReadyContent(
        title: String,
        output: ProjectOutput,
        identifier: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.semibold)
                Text("Готово")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Открыть") { openSimpleResult(output.path) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("\(identifier).open")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(identifier).ready")
    }

    private func simpleSubtitledVideoCreationContent(
        availability: SimpleSourceSubtitledVideoAvailability,
        action: @escaping () -> Bool,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(availability.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("\(identifier).availability")
            if simpleSubtitledVideoActionStarted, model.status == "Ошибка" {
                Text(model.alert?.message ?? "Видео с субтитрами не создано. Исправьте проблему и повторите попытку.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("\(identifier).error")
            }
            Button("Создать видео с субтитрами") {
                simpleSubtitledVideoActionStarted = action()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!availability.canCreate)
            .accessibilityIdentifier("\(identifier).create")
        }
    }

    private struct SimpleSourceSubtitledVideoAvailability {
        var canCreate: Bool
        var message: String
    }

    /// The ViewModel is the single authority for accepted-transcript reuse.
    /// Simple only renders its availability; it does not inspect SRT or timing
    /// provenance, and it never transports settings through Advanced state.
    private var simpleSourceSubtitledVideoAvailability: SimpleSourceSubtitledVideoAvailability {
        if model.canCreateSourceSubtitledVideoFromAcceptedTranscript {
            return .init(canCreate: true, message: "Будут использованы утверждённые исходные субтитры.")
        }
        if model.isStopping {
            return .init(canCreate: false, message: "Останавливаем обработку.")
        }
        return .init(
            canCreate: false,
            message: "Сначала утвердите исходную расшифровку и подготовьте исходные субтитры для этого видео."
        )
    }

    private func simpleTranslatedSubtitledVideoAvailability(
        targetLanguage: ArtifactLanguage
    ) -> SimpleSourceSubtitledVideoAvailability {
        if model.canCreateTranslatedSubtitledVideoFromAcceptedTranscript {
            return .init(
                canCreate: true,
                message: "Будут использованы утверждённые переведённые субтитры \(targetLanguage.rawValue.uppercased())."
            )
        }
        if model.isStopping {
            return .init(canCreate: false, message: "Останавливаем обработку.")
        }
        return .init(
            canCreate: false,
            message: "Утвердите перевод и подготовьте его субтитры для этого видео."
        )
    }

    private var simpleSourceSubtitledVideoOutput: ProjectOutput? {
        model.outputs.first {
            $0.kind == "subtitled-video"
                && $0.isGeneratedMedia
                && FileManager.default.fileExists(atPath: $0.path)
        }
    }

    @ViewBuilder
    private func simpleCutTopicPanel() -> some View {
        // Simple topic cutting intentionally consumes the canonical normal
        // approved snapshot selected by simpleTopicCutWorkflowRequest. Advanced
        // controls may retain a different granularity without changing it.
        let topicsArtifact = simpleHomeState(topicGranularity: .normal).artifact(.topics)
        let options = model.simpleApprovedTopicOptions
        let selectedTopicID = simpleSelectedTopicFragmentID ?? ""
        let availability = model.simpleTopicCutAvailability(topicID: selectedTopicID)
        let hasSelection = !selectedTopicID.isEmpty
        let topicCutIsActive = simpleTopicCutIsActive
            && (model.isRunning || model.isStopping)
        let anotherWorkflowIsActive = (model.isRunning || model.isStopping) && !topicCutIsActive
        // Missing selection is a local form state, rather than a workflow error.
        // Keep Create enabled while an approved-topic list is available so the
        // user receives validation only after explicitly requesting creation.
        let canAttemptCreate = !options.isEmpty && !model.isRunning && !model.isStopping
        let availabilityMessage = options.isEmpty
            ? "Нет доступных утверждённых тем. Сначала создайте и утвердите темы для принятой расшифровки."
            : (!hasSelection ? "Выберите тему, чтобы создать фрагмент." : availability.message)

        VStack(alignment: .leading, spacing: 8) {
            Text("По теме")
                .font(.subheadline.weight(.semibold))
            if !topicsArtifact.isUsableForTopicCut {
                VStack(alignment: .leading, spacing: 3) {
                    Text(topicsArtifact.detail)
                    if simpleHasCanonicalActiveNormalTopicRevision {
                        Text("Утверждённые темы недоступны. Восстановите файлы проекта или откройте корректный проект.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("simple.fragment.topic.unavailable")
            } else if topicCutIsActive {
                Picker("Тема", selection: .constant(simpleSelectedTopicFragmentID)) {
                    Text(simpleSelectedTopicFragmentTitle ?? selectedTopicID)
                        .tag(simpleSelectedTopicFragmentID)
                }
                .disabled(true)
                .accessibilityIdentifier("simple.fragment.topic.picker")
                Text(availability.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("simple.fragment.topic.availability")
                ProgressView(value: min(max(model.progress.operationFraction, 0), 1), total: 1)
                    .accessibilityIdentifier("simple.fragment.topic.progress")
            } else if anotherWorkflowIsActive {
                Text(availability.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("simple.fragment.topic.availability")
            } else if options.isEmpty {
                Text(availabilityMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("simple.fragment.topic.unavailable")
            } else {
                Picker("Тема", selection: $simpleSelectedTopicFragmentID) {
                    Text("Выберите утверждённую тему").tag(nil as String?)
                    ForEach(options) { option in
                        Text("\(option.title) · \(TimecodeParser.display(option.start))–\(TimecodeParser.display(option.end))")
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .tag(option.id as String?)
                    }
                }
                .onChange(of: simpleSelectedTopicFragmentID) { _, _ in
                    simpleTopicFragmentActionStarted = false
                    simpleTopicCutIsActive = false
                    simpleSelectedTopicFragmentTitle = options.first(where: { $0.id == simpleSelectedTopicFragmentID }).map {
                        "\($0.title) · \(TimecodeParser.display($0.start))–\(TimecodeParser.display($0.end))"
                    }
                    simpleTopicFragmentValidation.reset()
                }
                .accessibilityIdentifier("simple.fragment.topic.picker")
                Text(availabilityMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("simple.fragment.topic.availability")
                if simpleTopicFragmentValidation.showsSelectionError && !hasSelection {
                    Text("Выберите утверждённую тему, затем создайте фрагмент.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("simple.fragment.topic.validation")
                }
            }
            if topicsArtifact.isUsableForTopicCut && !topicCutIsActive {
                if simpleTopicFragmentActionStarted, model.status == "Ошибка" {
                    Text(model.alert?.message ?? "Фрагмент по теме не создан. Исправьте проблему и повторите попытку.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("simple.fragment.topic.error")
                }
                Button("Создать фрагмент") {
                    guard simpleTopicFragmentValidation.beginCreate(selectedTopicID: simpleSelectedTopicFragmentID),
                          let topicID = simpleSelectedTopicFragmentID else {
                        return
                    }
                    let started = model.startSimpleTopicCutFromAcceptedTranscript(topicID: topicID)
                    simpleTopicFragmentActionStarted = started
                    simpleTopicCutIsActive = started
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAttemptCreate)
                .accessibilityIdentifier("simple.fragment.topic.create")

            }
            if let output = simpleLatestFragmentOutput {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Последний фрагмент готов")
                            .fontWeight(.semibold)
                        Text("Готово")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Открыть") { openSimpleResult(output.path) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("simple.fragment.topic.open")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("simple.fragment.topic.ready")
            }
        }
    }

    @ViewBuilder
    private func simpleCutRangePanel() -> some View {
        let availability = model.simpleCutRangeAvailability(
            startText: simpleFragmentStartText,
            endText: simpleFragmentEndText
        )
        VStack(alignment: .leading, spacing: 8) {
            Text("По времени")
                .font(.subheadline.weight(.semibold))
            HStack(alignment: .top, spacing: 12) {
                simpleFragmentTimeField("Начало", text: $simpleFragmentStartText, identifier: "simple.fragment.start")
                simpleFragmentTimeField("Конец", text: $simpleFragmentEndText, identifier: "simple.fragment.end")
            }
            Text(availability.message)
                .font(.caption)
                .foregroundStyle(availability.canCreate ? Color.secondary : Color.red)
                .accessibilityIdentifier("simple.fragment.availability")
            if simpleFragmentActionStarted, model.status == "Ошибка" {
                Text(model.alert?.message ?? "Фрагмент не создан. Исправьте проблему и повторите попытку.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("simple.fragment.error")
            }
            Button("Создать фрагмент") {
                simpleFragmentActionStarted = model.startSimpleCutRangeFromAcceptedTranscript(
                    startText: simpleFragmentStartText,
                    endText: simpleFragmentEndText
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(!availability.canCreate)
            .accessibilityIdentifier("simple.fragment.create")

            if let output = simpleLatestFragmentOutput {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Последний фрагмент готов")
                            .fontWeight(.semibold)
                        Text("Готово")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Открыть") { openSimpleResult(output.path) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("simple.fragment.open")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("simple.fragment.ready")
            }
        }
    }

    private func simpleFragmentTimeField(
        _ title: String,
        text: Binding<String>,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.bold())
            TextField("ЧЧ:ММ:СС", text: text)
                .monospacedDigit()
                .accessibilityLabel("\(title) фрагмента")
                .accessibilityIdentifier(identifier)
        }
    }

    private var simpleLatestFragmentOutput: ProjectOutput? {
        model.outputs
            .filter {
                $0.kind == "fragment-video"
                    && $0.isGeneratedMedia
                    && FileManager.default.fileExists(atPath: $0.path)
            }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    private func simpleTranslatedSubtitledVideoOutput(language: ArtifactLanguage) -> ProjectOutput? {
        model.outputs.first {
            $0.kind == "subtitled-video-\(language.rawValue)"
                && $0.isGeneratedMedia
                && FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private func simpleRecentResultRow(_ output: SimpleProjectHomeResult) -> some View {
        HStack(spacing: 10) {
            Image(systemName: output.isGeneratedMedia ? "film" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(output.title)
                .fontWeight(.semibold)
                .frame(maxWidth: 360, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Button("Открыть") { openSimpleResult(output.path) }
                .buttonStyle(.bordered)
            Button {
                model.revealResult(ProjectOutput(
                    id: output.path,
                    kind: output.isGeneratedMedia ? "user-facing-media" : "user-facing-text",
                    path: output.path,
                    createdAt: output.createdAt
                ))
            } label: {
                Image(systemName: "folder")
            }
            .help("Показать в Finder")
        }
        .padding(.vertical, 3)
    }

    private func openSimpleReview(_ target: SimpleProjectHomeReviewTarget, language: ArtifactLanguage) {
        guard let kind = target.checkpointKind,
              model.canOpenHumanReview(language: language),
              model.beginHumanReview(language: language),
              let checkpoint = model.humanReviewCheckpoint,
              checkpoint.kind == kind, checkpoint.language == language else {
            return
        }
        presentSimpleReview(target)
    }

    private func presentSimpleReview(_ target: SimpleProjectHomeReviewTarget) {
        reviewSearch = ""
        reviewIssuesOnly = false
        showsSimpleTextContent = true
        simpleReviewTarget = target
    }

    private var simpleDisplayedAlert: Binding<AppAlert?> {
        Binding(
            get: {
                guard let alert = model.alert else { return nil }
                if presentationMode == .simple,
                   simpleTranscription.suppressesReviewAlert(
                       title: alert.title,
                       projectURL: model.projectURL,
                       checkpoint: model.humanReviewCheckpoint
                   ) { return nil }
                if presentationMode == .simple,
                   simpleTranslation.suppressesReviewAlert(
                       title: alert.title,
                       projectURL: model.projectURL,
                       checkpoint: model.humanReviewCheckpoint
                   ) { return nil }
                if presentationMode == .simple {
                    let translationAlert = simpleTranslation.translationRunAlert(alert, projectURL: model.projectURL)
                    if translationAlert.id != alert.id || translationAlert.title != alert.title || translationAlert.message != alert.message {
                        return translationAlert
                    }
                    return simpleTranscription.sourceRunAlert(alert, projectURL: model.projectURL)
                }
                return alert
            },
            set: { model.alert = $0 }
        )
    }

    private func startSimpleTranscription() {
        guard presentationMode == .simple, model.canStartSimpleTranscription,
              let projectURL = model.projectURL else { return }
        simpleTranscription.begin(projectURL: projectURL, language: model.simpleTranscriptionLanguage)
        if model.startSimpleTranscription() {
            showsSimpleTextContent = true
            updateSimpleHumanReview()
        } else {
            simpleTranscription.cancelPendingReview()
        }
    }

    private func startSimpleTopicsCreation() {
        guard presentationMode == .simple, model.canCreateTopicsFromAcceptedTranscript else { return }
        model.startSimpleTopicsFromAcceptedTranscript()
        showsSimpleTextContent = true
    }

    private func startSimpleTranslation() {
        guard presentationMode == .simple, model.canTranslate,
              let projectURL = model.projectURL,
              let direction = model.translationDirection else { return }
        simpleTranslation.begin(projectURL: projectURL, target: direction.target)
        model.translateApprovedTranscript()
        showsSimpleTextContent = true
        updateSimpleHumanReview()
    }

    private func updateSimpleHumanReview() {
        guard presentationMode == .simple else { return }
        if let alert = model.alert,
           simpleTranscription.suppressesReviewAlert(
               title: alert.title,
               projectURL: model.projectURL,
               checkpoint: model.humanReviewCheckpoint
           ) {
            model.alert = nil
        }
        if simpleTranscription.observe(
            projectURL: model.projectURL,
            mode: presentationMode,
            isRunning: model.isRunning,
            checkpoint: model.humanReviewCheckpoint,
            failedOrStopped: model.status == "Ошибка" || model.status == "Остановлено"
        ) != nil {
            presentSimpleReview(.source)
        }
        if let alert = model.alert,
           simpleTranslation.suppressesReviewAlert(
               title: alert.title,
               projectURL: model.projectURL,
               checkpoint: model.humanReviewCheckpoint
           ) {
            model.alert = nil
        }
        if simpleTranslation.observe(
            projectURL: model.projectURL,
            mode: presentationMode,
            isRunning: model.isRunning,
            checkpoint: model.humanReviewCheckpoint,
            failedOrStopped: model.status == "Ошибка" || model.status == "Остановлено"
                || model.status == "Перевод не выполнен"
        ) != nil {
            presentSimpleReview(.translation)
        }
    }

    private var simpleProgressStage: String {
        if model.isStopping { return "Останавливаем обработку" }
        if model.progress.operation == .translateTranscript { return "Создаём перевод" }
        if model.progress.operation == .burnSubtitles { return "Создаём видео с субтитрами" }
        if model.progress.operation == .cutRange || model.progress.operation == .cutTopic {
            return "Создаём фрагмент"
        }
        return SimpleTranscriptionPresentation.stage(operation: model.progress.operation, isStopping: false)
    }

    private func simpleHumanReviewSheet(_ target: SimpleProjectHomeReviewTarget) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(target == .source ? "Проверка расшифровки" : "Проверка перевода")
                    .font(.headline)
                Spacer()
                Button("Закрыть") { simpleReviewTarget = nil }
                    .accessibilityIdentifier("simple.review.\(target.rawValue).close")
            }
            reviewTasksPanel
        }
        .frame(minWidth: 720, minHeight: 520, alignment: .topLeading)
        .padding(18)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simple.review.\(target.rawValue).sheet")
        .sheet(item: $editingReviewCue) { cue in
            humanReviewCueEditor(cue)
        }
    }

    @ViewBuilder
    private func humanReviewCueEditor(_ cue: SubtitleCue) -> some View {
        if let mediaURL = model.mediaURL {
            TranscriptCueEditView(mediaURL: mediaURL, cue: cue) { replacement in
                model.saveHumanReviewCue(cue, replacementText: replacement)
            }
        }
    }

    private func openSimpleResult(_ path: String) {
        model.openResult(ProjectOutput(
            id: path,
            kind: "user-facing-text",
            path: path,
            createdAt: Date()
        ))
    }

    private func simpleCurrentState(_ state: SimpleProjectHomeState) -> String {
        if model.isRunning {
            if model.progress.operation == .cutRange || model.progress.operation == .cutTopic {
                return model.isStopping ? "Останавливаем обработку" : "Создаём фрагмент"
            }
            return SimpleTranscriptionPresentation.stage(operation: model.progress.operation, isStopping: model.isStopping)
        }
        if model.status == "Остановлено" { return "Обработка остановлена" }
        if model.status == "Ошибка" { return "Требуется внимание" }
        switch state.artifact(.transcription).readiness {
        case .missing: return "Расшифровка не создана"
        case .failed: return "Расшифровка не завершена"
        case .needsReview: return "Расшифровка ожидает проверки"
        case .ready: return state.currentState
        }
    }

    private func simpleStateIcon(_ state: SimpleProjectHomeState) -> String {
        if model.isRunning { return model.isStopping ? "stop.circle" : "waveform" }
        if model.status == "Остановлено" { return "stop.circle" }
        if model.status == "Ошибка" { return "exclamationmark.circle.fill" }
        if state.artifacts.contains(where: { $0.readiness == .failed }) { return "xmark.circle.fill" }
        if state.artifacts.contains(where: { $0.readiness == .needsReview }) { return "exclamationmark.circle.fill" }
        if state.artifact(.transcription).readiness == .missing { return "minus.circle" }
        return "checkmark.circle.fill"
    }

    private func simpleStateColor(_ state: SimpleProjectHomeState) -> Color {
        if model.isRunning { return model.isStopping ? .orange : .accentColor }
        if model.status == "Остановлено" { return .orange }
        if model.status == "Ошибка" { return .red }
        if state.artifacts.contains(where: { $0.readiness == .failed }) { return .red }
        if state.artifact(.transcription).readiness == .missing { return .secondary }
        return state.artifacts.contains(where: { $0.readiness == .needsReview }) ? .orange : .green
    }

    private func simpleArtifactIcon(_ readiness: SimpleProjectHomeReadiness) -> String {
        switch readiness {
        case .ready: return "checkmark.circle.fill"
        case .needsReview: return "exclamationmark.circle.fill"
        case .missing: return "minus.circle"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func simpleArtifactColor(_ readiness: SimpleProjectHomeReadiness) -> Color {
        switch readiness {
        case .ready: return .green
        case .needsReview: return .orange
        case .missing: return .secondary
        case .failed: return .red
        }
    }

    private func projectActions(includeDiagnostics: Bool = true) -> some View {
        HStack(spacing: 10) {
            Button {
                if let url = openMediaFile() { model.selectMedia(url) }
            } label: {
                Label("Новый проект", systemImage: "plus")
            }
            .disabled(model.isRunning)
            Button {
                if let url = openProjectDirectory() { model.openProject(url) }
            } label: {
                Label("Открыть проект", systemImage: "folder.badge.plus")
            }
            .disabled(model.isRunning)
            Button {
                model.openProjectFolder()
            } label: {
                Label("Папка проекта", systemImage: "folder")
            }
            .disabled(model.projectURL == nil)
            if includeDiagnostics {
                Button {
                    model.runDiagnostics()
                } label: {
                    Image(systemName: "stethoscope")
                }
                .help("Запустить диагностику")
                .disabled(model.projectURL == nil || model.isRunning)
            }
        }
    }

    private func workflowActions(includeStatus: Bool) -> some View {
        HStack(spacing: 10) {
            if includeStatus {
                statusLabel
            }
            Button {
                model.run()
            } label: {
                Label(model.isRunning ? "Выполняется..." : "Запустить", systemImage: model.isRunning ? "hourglass" : "play.fill")
            }
            .disabled(
                model.isRunning || model.projectURL == nil || model.selectedOperations.isEmpty
                    || model.humanReviewCheckpoint != nil || model.topicReviewCheckpoint != nil
            )
            .keyboardShortcut(.return, modifiers: .command)
            Button(role: .destructive) {
                model.stop()
            } label: {
                Label(model.isStopping ? "Остановка..." : "Остановить", systemImage: "stop.fill")
            }
            .disabled(!model.isRunning || model.isStopping)
        }
    }

    private var statusLabel: some View {
        Text(model.status)
            .font(.headline)
            .lineLimit(1)
            .frame(minWidth: 92, alignment: .trailing)
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.progress.operation?.title ?? model.status)
                    .font(.subheadline.bold())
                Spacer()
                Text("Операция: \(percent(model.progress.operationFraction))")
                    .monospacedDigit()
                Text("Всего: \(percent(model.progress.overallFraction))")
                    .monospacedDigit()
                    .fontWeight(.semibold)
            }
            ProgressView(value: model.progress.overallFraction, total: 1)
            HStack(spacing: 24) {
                metric("Прошло", TimeTextFormatter.string(model.progress.elapsed))
                metric("Всего примерно", model.progress.estimatedTotal.map(TimeTextFormatter.string) ?? "Оценка уточняется")
                metric("Осталось примерно", model.progress.remaining.map(TimeTextFormatter.string) ?? "Оценка уточняется")
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("История заданий")
                    .font(.headline)
                Spacer()
                Button {
                    model.reloadHistory()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Обновить историю")
                .disabled(model.isRunning)
            }
            if model.history.isEmpty {
                ContentUnavailableView("История пуста", systemImage: "clock.arrow.circlepath")
            } else {
                List(model.history) { entry in
                    Button {
                        model.openHistoryEntry(entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.mediaName)
                                .font(.subheadline.bold())
                                .lineLimit(2)
                            HStack {
                                statusMark(entry.status)
                                Text(entry.status.title)
                                Spacer()
                                Text("\(Int((entry.progress * 100).rounded()))%")
                                    .monospacedDigit()
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Text(entry.updatedAt, style: .date)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Label("Продолжить", systemImage: "arrow.forward.circle")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isRunning)
                }
            }
        }
        .padding()
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Текущий проект").font(.headline)
                    Text(model.mediaURL?.lastPathComponent ?? "Медиафайл не выбран")
                        .font(.subheadline)
                    Text(model.projectURL?.path ?? "Создайте или откройте проект")
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(model.projectURL?.path ?? "Создайте или откройте проект")
                }

                if model.humanReviewCheckpoint != nil {
                    GroupBox("Требуется Human Review") {
                        Button {
                            selectedResultsTab = 2
                        } label: {
                            Label("Открыть редактор расшифровки", systemImage: "pencil.and.list.clipboard")
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                }

                GroupBox("Операции полного проекта") {
                    VStack(alignment: .leading) {
                        ForEach(WorkflowOperation.userSelectable) { operation in
                            Toggle(operation.title, isOn: Binding(
                                get: { model.selectedOperations.contains(operation) },
                                set: { isOn in
                                    if isOn { model.selectedOperations.insert(operation) }
                                    else { model.selectedOperations.remove(operation) }
                                }
                            ))
                        }
                        if model.selectedOperations.contains(.burnSubtitles) {
                            subtitleSourcePicker
                        }
                    }
                    .padding(6)
                }

                GroupBox("Расшифровка") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Путь к модели Whisper", text: $model.whisperModelPath)
                            Button("Выбрать") {
                                if let url = openWhisperModel() { model.whisperModelPath = url.path }
                            }
                        }
                        Picker("Язык распознавания", selection: $model.whisperLanguage) {
                            Text("RU").tag("ru")
                            Text("Авто").tag("auto")
                            Text("EN").tag("en")
                        }
                        .pickerStyle(.segmented)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Label("Контекст и термины временно недоступны", systemImage: "info.circle")
                                .foregroundStyle(.secondary)
                            if model.hasUnsupportedTranscriptionContext {
                                Spacer()
                                Button("Удалить сохранённый контекст") {
                                    model.clearUnsupportedTranscriptionContext()
                                }
                                .disabled(model.isRunning)
                            }
                        }
                        .font(.caption)
                        .help("Bundled SeminarText пока не поддерживает пользовательский контекст распознавания. Введённый ранее контекст не будет молча проигнорирован.")
                        Toggle("Human Review исходной расшифровки", isOn: $model.sourceHumanReviewEnabled)
                            .disabled(model.isRunning || model.humanReviewCheckpoint != nil)
                        Toggle("Анализировать слова-паразиты до Human Review", isOn: $model.fillerAnalysisBeforeReview)
                            .disabled(model.isRunning || model.humanReviewCheckpoint != nil)
                        if model.humanReviewCheckpoint == nil {
                            Button {
                                model.beginHumanReview()
                            } label: {
                                Label("Открыть расшифровку для Human Review", systemImage: "pencil.and.list.clipboard")
                            }
                            .disabled(!model.canBeginHumanReview)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(6)
                }

                GroupBox("Перевод") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.translationStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button {
                                model.translateApprovedTranscript()
                            } label: {
                                Label(model.translationActionTitle, systemImage: "character.book.closed")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canTranslate)
                            Spacer()
                            Label("Human Review обязателен", systemImage: "checkmark.seal")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                }

                GroupBox("Тематический таймкодинг") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Язык")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Язык", selection: Binding(
                            get: { model.artifactLanguage },
                            set: { model.selectTopicVariant(language: $0, granularity: model.topicGranularity) }
                        )) {
                            ForEach(model.availableArtifactLanguages) { language in
                                Text(language.rawValue.uppercased()).tag(language)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text("Детализация")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Детализация", selection: Binding(
                            get: { model.topicGranularity },
                            set: { model.selectTopicVariant(language: model.artifactLanguage, granularity: $0) }
                        )) {
                            ForEach(TopicGranularity.allCases) { value in
                                Text(value.title).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Toggle("Human Review тематического таймкодинга", isOn: $model.topicHumanReviewEnabled)
                            .disabled(model.isRunning || model.topicReviewCheckpoint != nil)
                        if model.topicReviewCheckpoint == nil {
                            Button {
                                model.beginTopicReview()
                            } label: {
                                Label("Открыть темы для Human Review", systemImage: "list.bullet.clipboard")
                            }
                            .disabled(model.projectURL == nil || model.topics.isEmpty)
                        }
                        HStack {
                            Text(model.artifactLanguage == detectedSourceLanguage ? "Оригинал" : "Перевод")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Качественный: embeddinggemma + gemma3:4b")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    .padding(6)
                }

                GroupBox("Фрагмент") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Название фрагмента", text: $model.fragmentName)
                        Picker("Способ выбора", selection: $fragmentSelectionMode) {
                            ForEach(FragmentSelectionMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        if fragmentSelectionMode == .timecode {
                            HStack(alignment: .top, spacing: 12) {
                                timecodeField("Начало", text: $model.rangeStartText)
                                timecodeField("Конец", text: $model.rangeEndText)
                            }
                            Text("Длительность: \(model.rangeDurationText)")
                                .font(.caption)
                                .foregroundStyle(model.isRangeValid ? .secondary : Color.red)
                        } else if fragmentSelectionMode == .topic {
                            Picker("Тема", selection: $model.selectedTopicID) {
                                Text("Первая найденная").tag("")
                                ForEach(model.topics) { topic in
                                    Text(TopicPickerFormatter.title(for: topic))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .help(TopicPickerFormatter.help(for: topic))
                                        .tag(topic.id)
                                }
                            }
                        } else {
                            TextField("Начало со слов", text: $model.quoteStartText)
                                .onChange(of: model.quoteStartText) { _, _ in model.clearQuoteCandidates() }
                            TextField("Конец словами", text: $model.quoteEndText)
                                .onChange(of: model.quoteEndText) { _, _ in model.clearQuoteCandidates() }
                            HStack {
                                Stepper(
                                    "До: \(model.quoteLeadPadding, specifier: "%.1f") с",
                                    value: $model.quoteLeadPadding,
                                    in: 0...5,
                                    step: 0.1
                                )
                                Stepper(
                                    "После: \(model.quoteTrailingPadding, specifier: "%.1f") с",
                                    value: $model.quoteTrailingPadding,
                                    in: 0...5,
                                    step: 0.1
                                )
                            }
                            Button {
                                model.findQuoteCandidates()
                            } label: {
                                Label("Найти диапазоны", systemImage: "text.magnifyingglass")
                            }
                            .disabled(
                                model.quoteStartText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || model.quoteEndText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                            if !model.quoteCandidates.isEmpty {
                                Picker("Совпадение", selection: $model.selectedQuoteCandidateID) {
                                    Text("Выберите вариант").tag("")
                                    ForEach(model.quoteCandidates) { candidate in
                                        Text("\(TimecodeParser.display(candidate.start))–\(TimecodeParser.display(candidate.end)) · \(candidate.context)")
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .tag(candidate.id)
                                    }
                                }
                            }
                        }

                        Toggle("Вшить субтитры во фрагмент", isOn: $model.burnFragmentSubtitles)
                            .help("Создать fragment.srt из полной расшифровки и вшить его в готовый фрагмент")
                        if model.burnFragmentSubtitles {
                            subtitleSourcePicker
                        }

                        Divider()
                        Text("Обработка итогового файла")
                            .font(.headline)
                        Toggle("Mute слов-паразитов", isOn: $model.fragmentMuteFillerWords)
                            .help("Заглушить найденные слова-паразиты в выбранном диапазоне; режим задаётся в панели анализа")
                        Toggle("Изменить скорость", isOn: $model.fragmentAdjustSpeed)
                        if model.fragmentAdjustSpeed {
                            HStack {
                                Slider(value: $model.speedFactor, in: 0.5...2, step: 0.05)
                                Text("\(model.speedFactor, specifier: "%.2f")x")
                                    .monospacedDigit()
                                    .frame(width: 48, alignment: .trailing)
                            }
                        }
                        Toggle("Добавить статический blur", isOn: $model.fragmentApplyBlur)
                        if model.fragmentApplyBlur {
                            BlurRegionSelector(mediaURL: model.mediaURL, region: $model.blurRegion)
                                .frame(minHeight: 140)
                                .aspectRatio(16 / 9, contentMode: .fit)
                            HStack {
                                Text("Интенсивность")
                                Slider(value: $model.blurIntensity, in: 1...30, step: 1)
                                Text("\(Int(model.blurIntensity))")
                                    .monospacedDigit()
                                    .frame(width: 24, alignment: .trailing)
                            }
                            Toggle("Ограничить blur по времени исходного видео", isOn: $model.blurUsesTimeRange)
                            if model.blurUsesTimeRange {
                                HStack(alignment: .top, spacing: 12) {
                                    timecodeField("Начало blur", text: $model.blurStartText)
                                    timecodeField("Конец blur", text: $model.blurEndText)
                                }
                            }
                        }

                        Button {
                            model.createProcessedFragment(selectionMode: fragmentSelectionMode)
                        } label: {
                            Label("Создать итоговый вариант", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            model.projectURL == nil
                                || (fragmentSelectionMode == .timecode && !model.isRangeValid)
                                || (fragmentSelectionMode == .topic && model.topics.isEmpty)
                                || (fragmentSelectionMode == .quote && model.selectedQuoteCandidate == nil)
                        )

                        if fragmentSelectionMode == .timecode {
                            Button {
                                model.createFragment()
                            } label: {
                                Label("Вырезать по таймкоду", systemImage: "scissors")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.projectURL == nil || !model.isRangeValid)
                        } else if fragmentSelectionMode == .topic {
                            Button {
                                model.createTopicFragment()
                            } label: {
                                Label("Вырезать выбранную тему", systemImage: "scissors")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.projectURL == nil || model.topics.isEmpty)
                        } else {
                            Button {
                                model.createQuoteFragment()
                            } label: {
                                Label("Вырезать по цитатам", systemImage: "scissors")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.projectURL == nil || model.selectedQuoteCandidate == nil)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(6)
                }

                GroupBox("Скорость") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Источник", selection: $model.speedSource) {
                            ForEach(SpeedSourceKind.allCases) { source in
                                Text(source.title).tag(source)
                            }
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            Slider(value: $model.speedFactor, in: 0.5...2, step: 0.05)
                            Text("\(model.speedFactor, specifier: "%.2f")x")
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }
                        Button {
                            model.createSpeedAdjustedVideo()
                        } label: {
                            Label("Создать файл", systemImage: "gauge.with.dots.needle.67percent")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.projectURL == nil)
                    }
                    .padding(6)
                }

                GroupBox("Статический blur") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Включить blur", isOn: $model.blurEnabled)
                        if model.blurEnabled {
                            Picker("Источник", selection: $model.blurSource) {
                                ForEach(SpeedSourceKind.allCases) { source in
                                    Text(source.title).tag(source)
                                }
                            }
                            .pickerStyle(.segmented)
                            BlurRegionSelector(mediaURL: model.mediaURL, region: $model.blurRegion)
                                .frame(minHeight: 150)
                                .aspectRatio(16 / 9, contentMode: .fit)
                            HStack {
                                Text("Интенсивность")
                                Slider(value: $model.blurIntensity, in: 1...30, step: 1)
                                Text("\(Int(model.blurIntensity))")
                                    .monospacedDigit()
                                    .frame(width: 24, alignment: .trailing)
                            }
                            Toggle("Ограничить по времени", isOn: $model.blurUsesTimeRange)
                            if model.blurUsesTimeRange {
                                HStack(alignment: .top, spacing: 12) {
                                    timecodeField("Начало", text: $model.blurStartText)
                                    timecodeField("Конец", text: $model.blurEndText)
                                }
                            }
                            Button {
                                model.createBlurredVideo()
                            } label: {
                                Label("Создать файл", systemImage: "drop.halffull")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.projectURL == nil)
                        }
                    }
                    .padding(6)
                }

                GroupBox("Watermark") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button {
                                model.watermarkImageURL = openWatermarkImage()
                            } label: {
                                Label("Выбрать изображение", systemImage: "photo")
                            }
                            Spacer()
                            if let imageURL = model.watermarkImageURL {
                                Text(imageURL.lastPathComponent)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(imageURL.path)
                            }
                        }
                        Picker("Источник", selection: $model.watermarkSource) {
                            ForEach(SpeedSourceKind.allCases) { source in
                                Text(source.title).tag(source)
                            }
                        }
                        .pickerStyle(.segmented)
                        if model.watermarkImageURL != nil {
                            WatermarkPreview(
                                mediaURL: model.mediaURL,
                                watermarkURL: model.watermarkImageURL,
                                position: model.watermarkPosition,
                                manualX: model.watermarkManualX,
                                manualY: model.watermarkManualY,
                                relativeWidth: model.watermarkRelativeWidth,
                                margin: model.watermarkMargin,
                                opacity: model.watermarkOpacity
                            )
                            .frame(minHeight: 150)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            if model.watermarkRelativeWidth < 0.05 {
                                Label("Watermark может быть слишком мелким", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(Color.orange)
                            }
                        }
                        Picker("Положение", selection: $model.watermarkPosition) {
                            ForEach(WatermarkPosition.allCases) { position in
                                Text(position.title).tag(position)
                            }
                        }
                        if model.watermarkPosition == .manual {
                            HStack {
                                Text("X")
                                Slider(value: $model.watermarkManualX, in: 0...1)
                                Text("Y")
                                Slider(value: $model.watermarkManualY, in: 0...1)
                            }
                        } else {
                            HStack {
                                Text("Отступ")
                                Slider(value: $model.watermarkMargin, in: 0...0.2)
                                Text("\(Int(model.watermarkMargin * 100))%")
                                    .monospacedDigit()
                            }
                        }
                        HStack {
                            Text("Размер")
                            Slider(value: $model.watermarkRelativeWidth, in: 0.03...0.6)
                            Text("\(Int(model.watermarkRelativeWidth * 100))%")
                                .monospacedDigit()
                        }
                        HStack {
                            Text("Прозрачность")
                            Slider(value: $model.watermarkOpacity, in: 0.05...1)
                            Text("\(Int(model.watermarkOpacity * 100))%")
                                .monospacedDigit()
                        }
                        Toggle("Ограничить по времени", isOn: $model.watermarkUsesTimeRange)
                        if model.watermarkUsesTimeRange {
                            HStack(alignment: .top, spacing: 12) {
                                timecodeField("Начало", text: $model.watermarkStartText)
                                timecodeField("Конец", text: $model.watermarkEndText)
                            }
                        }
                        Toggle("Добавить выбранный blur в этот файл", isOn: $model.watermarkIncludesBlur)
                        Toggle("Вшить выбранные субтитры в этот файл", isOn: $model.watermarkBurnSubtitles)
                        Button {
                            model.createWatermarkedVideo()
                        } label: {
                            Label("Создать файл", systemImage: "photo.badge.checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.projectURL == nil || model.watermarkImageURL == nil)
                    }
                    .padding(6)
                }

                GroupBox("Слова-паразиты") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button {
                                model.analyzeFillerWords()
                            } label: {
                                Label("Проанализировать", systemImage: "text.magnifyingglass")
                            }
                            Spacer()
                            Text("Кандидатов: \(model.fillerCandidates.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !model.fillerCandidates.isEmpty {
                            TextField("Поиск", text: $model.fillerSearch)
                            HStack {
                                Button("Выбрать все") { model.selectAllFillers() }
                                Button("Выбрать уверенные") { model.selectHighConfidenceFillers() }
                                Button("Снять выбор") {
                                    for id in model.selectedFillerCandidateIDs { model.setFillerCandidate(id, selected: false) }
                                }
                            }
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 6) {
                                    ForEach(model.filteredFillerCandidates) { candidate in
                                        HStack(spacing: 8) {
                                            Toggle("", isOn: Binding(
                                                get: { model.selectedFillerCandidateIDs.contains(candidate.id) },
                                                set: { selected in
                                                    model.setFillerCandidate(candidate.id, selected: selected)
                                                }
                                            ))
                                            .labelsHidden()
                                            VStack(alignment: .leading, spacing: 2) {
                                                HStack {
                                                    Text(candidate.text).fontWeight(.semibold)
                                                    Text(TimecodeParser.display(candidate.start))
                                                        .monospacedDigit()
                                                        .foregroundStyle(.secondary)
                                                    if candidate.highConfidence {
                                                        Image(systemName: "checkmark.seal.fill")
                                                            .foregroundStyle(Color.green)
                                                            .help("Уверенный кандидат")
                                                    }
                                                }
                                                Text(candidate.context)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(2)
                                            }
                                            Spacer()
                                            Button { model.previewFiller(candidate, afterMute: false) } label: {
                                                Image(systemName: "speaker.wave.2")
                                            }
                                            .help("Прослушать оригинал")
                                            Button { model.previewFiller(candidate, afterMute: true) } label: {
                                                Image(systemName: "speaker.slash")
                                            }
                                            .help("Прослушать после mute")
                                            .disabled(!model.outputs.contains { $0.kind == "filler-muted-video" })
                                            Button { model.keepFillerCandidate(candidate.id) } label: {
                                                Image(systemName: "hand.thumbsup")
                                            }
                                            .help("Оставить как смысловое употребление")
                                        }
                                    }
                                }
                            }
                            .frame(height: 220)
                            Picker("Режим", selection: $model.fillerMode) {
                                ForEach(FillerProcessingMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            Button {
                                model.muteFillerWords()
                            } label: {
                                Label("Создать аудио и видео", systemImage: "speaker.slash.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                model.fillerMode == .detectOnly
                                    || (model.fillerMode == .muteSelected && model.selectedFillerCandidateIDs.isEmpty)
                                    || (model.fillerMode == .muteHighConfidence && !model.fillerCandidates.contains(where: \.highConfidence))
                            )
                        }
                    }
                    .padding(6)
                }

                GroupBox("Улучшение звука") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Профиль", selection: $model.audioEnhancementProfile) {
                            ForEach(AudioEnhancementProfile.allCases) { profile in
                                Text(profile.title).tag(profile)
                            }
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            Button {
                                model.analyzeAudio()
                            } label: {
                                Label("Анализ", systemImage: "waveform.path.ecg")
                            }
                            Button {
                                model.enhanceAudio()
                            } label: {
                                Label("Создать файл", systemImage: "waveform.badge.plus")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        HStack {
                            Button { model.previewAudioEnhancement(after: false) } label: {
                                Label("До", systemImage: "speaker.wave.2")
                            }
                            Button { model.previewAudioEnhancement(after: true) } label: {
                                Label("После", systemImage: "speaker.wave.3")
                            }
                            .disabled(!model.outputs.contains { $0.kind == "enhanced-video" })
                        }
                    }
                    .padding(6)
                }

                GroupBox("Нейтральный дубляж") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Недоступен в текущей сборке: для дубляжа требуется перевод.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                subtitleStylePanel

                Button {
                    model.loadDetectedResults()
                } label: {
                    Label("Обновить результаты", systemImage: "arrow.clockwise")
                }
            }
            .padding()
            .disabled(model.isRunning)
        }
    }

    @ViewBuilder
    private var subtitleSourcePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Субтитры", selection: $model.subtitleSource) {
                ForEach(model.availableSubtitleSources) { source in
                    Text(model.subtitleSourceTitle(source)).tag(source)
                }
            }
            .disabled(model.isRunning)
            if let message = model.subtitleSourceUnavailableMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func timecodeField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.bold())
            TextField("ЧЧ:ММ:СС.ммм", text: text)
                .monospacedDigit()
                .accessibilityLabel("\(title) фрагмента")
        }
    }

    private var subtitleStylePanel: some View {
        GroupBox("Оформление субтитров") {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    ColorPicker("Цвет текста", selection: textColorBinding, supportsOpacity: false)
                    ForEach(["#FFFFFF", "#FFD84D", "#65D9FF", "#6FE38A"], id: \.self) { hex in
                        Button {
                            model.subtitleStyle.textColorHex = hex
                        } label: {
                            Circle()
                                .fill(Color(nsColor: NSColor(hexRGB: hex)))
                                .frame(width: 18, height: 18)
                                .overlay(Circle().stroke(Color.secondary, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("Выбрать цвет \(hex)")
                    }
                }
                ColorPicker("Цвет обводки", selection: outlineColorBinding, supportsOpacity: false)
                Picker("Шрифт", selection: $model.subtitleStyle.fontName) {
                    ForEach(["Helvetica", "Arial", "Avenir Next", "Georgia"], id: \.self) { Text($0).tag($0) }
                }
                Stepper("Размер: \(Int(model.subtitleStyle.fontSize))", value: $model.subtitleStyle.fontSize, in: 14...64, step: 1)
                Stepper("Обводка: \(model.subtitleStyle.outlineWidth, specifier: "%.1f")", value: $model.subtitleStyle.outlineWidth, in: 0...6, step: 0.5)
                Picker("Положение", selection: $model.subtitleStyle.position) {
                    ForEach(SubtitlePosition.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Фон: \(Int(model.subtitleStyle.backgroundOpacity * 100))%")
                        .font(.caption)
                    Slider(value: $model.subtitleStyle.backgroundOpacity, in: 0...0.8)
                }
                subtitlePreview
            }
            .padding(6)
        }
    }

    private var subtitlePreview: some View {
        ZStack {
            Color(nsColor: .darkGray)
            VStack {
                if model.subtitleStyle.position == .middle || model.subtitleStyle.position == .bottom { Spacer() }
                Text("Пример субтитров")
                    .font(.custom(model.subtitleStyle.fontName, size: min(model.subtitleStyle.fontSize, 34)))
                    .foregroundStyle(Color(nsColor: NSColor(hexRGB: model.subtitleStyle.textColorHex)))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(model.subtitleStyle.backgroundOpacity))
                    .shadow(color: Color(nsColor: NSColor(hexRGB: model.subtitleStyle.outlineColorHex)), radius: model.subtitleStyle.outlineWidth)
                if model.subtitleStyle.position == .middle || model.subtitleStyle.position == .top { Spacer() }
            }
            .padding(10)
        }
        .aspectRatio(16 / 5, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("Предварительный просмотр субтитров")
    }

    private var results: some View {
        TabView(selection: $selectedResultsTab) {
            projectResults
                .tabItem { Label("Результаты", systemImage: "checklist") }
                .tag(0)
            topicEditor
                .tabItem { Label("Темы", systemImage: "list.bullet.rectangle") }
                .tag(1)
            reviewTasksPanel
                .tabItem { Label("Проверка (\(model.unresolvedReviewTasks.count))", systemImage: "exclamationmark.bubble") }
                .tag(2)
            journal
                .tabItem { Label("Журнал", systemImage: "text.alignleft") }
                .tag(3)
        }
    }

    private var projectResults: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Состояние результатов")
                    .font(.headline)
                Spacer()
                Button {
                    model.loadDetectedResults()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Обновить состояние результатов")
                .disabled(model.projectURL == nil || model.isRunning)
            }
            if let lastStatus = model.resultSummary.lastRunStatus {
                HStack {
                    Text("Последний запуск")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(lastStatus.title)
                        .fontWeight(.semibold)
                        .foregroundStyle(lastStatus == .failed ? Color.red : .primary)
                }
                .font(.caption)
                if lastStatus == .failed, let message = model.resultSummary.lastError {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(message)
                }
            }
            ForEach(model.resultSummary.artifacts.filter { !$0.kind.isAdditionalService }) { artifact in
                resultStatusRow(artifact)
            }
            DisclosureGroup("Служебные этапы", isExpanded: $showServiceResults) {
                VStack(spacing: 2) {
                    ForEach(model.resultSummary.artifacts.filter { $0.kind.isAdditionalService }) { artifact in
                        resultStatusRow(artifact)
                    }
                }
                .padding(.top, 4)
            }
            .font(.subheadline.bold())
            Divider()
            Text("Файлы проекта")
                .font(.subheadline.bold())
            List(model.outputs) { output in
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading) {
                        Text(output.title)
                            .font(.subheadline.bold())
                        Text(output.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .help(output.path)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    Button {
                        model.openResult(output)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderless)
                    .help("Открыть результат")
                    Button {
                        model.revealResult(output)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Показать результат в Finder")
                }
            }
        }
        .padding()
    }

    private var topicEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Темы видео")
                        .font(.headline)
                    Text("\(model.topics.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if let status = model.topicsFileStatus {
                        Text(status == .ready ? "Готов" : "Черновой")
                            .font(.caption.bold())
                            .foregroundStyle(status == .ready ? Color.green : Color.orange)
                    }
                    Spacer()
                    if model.topicReviewCheckpoint != nil {
                        Button {
                            model.approveTopicReview()
                        } label: {
                            Label("Завершить проверку тем", systemImage: "checkmark.seal.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRunning)
                    }
                }
                if model.topicReviewCheckpoint != nil {
                    Label(
                        "Проверка тем: выберите тему, сверьте её с исходными репликами и утвердите набор после правок.",
                        systemImage: "pause.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                if model.topicReviewCheckpoint != nil, let topic = model.selectedTopic,
                   let projectURL = model.projectURL {
                    TopicReviewSurface(
                        topic: topic,
                        topics: model.topics,
                        projectURL: projectURL,
                        language: model.artifactLanguage,
                        onPreview: { previewTopic = topic },
                        onEdit: { editingTopic = topic },
                        onChangeBoundary: { reviewingBoundaryTopic = topic },
                        onSplit: { model.splitSelectedTopic() },
                        onMerge: { model.mergeSelectedTopicWithNext() }
                    )
                }
                HStack(spacing: 8) {
                    Spacer()
                    topicIconButton("Просмотреть", systemImage: "play.fill") {
                        previewTopic = model.selectedTopic
                    }
                    topicIconButton("Изменить", systemImage: "pencil") {
                        editingTopic = model.selectedTopic
                    }
                    topicIconButton("Разделить", systemImage: "rectangle.split.2x1") {
                        model.splitSelectedTopic()
                    }
                    topicIconButton("Объединить со следующей", systemImage: "arrow.triangle.merge") {
                        model.mergeSelectedTopicWithNext()
                    }
                    Button(role: .destructive) {
                        confirmTopicRemoval = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Удалить границу темы")
                    .disabled(model.selectedTopic == nil || model.isRunning)
                    Button {
                        model.createTopicFragment()
                    } label: {
                        Image(systemName: "scissors")
                    }
                    .help(model.burnFragmentSubtitles ? "Вырезать тему с субтитрами" : "Вырезать тему")
                    .disabled(model.selectedTopic == nil || model.isRunning)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 12) {
                    Label(model.topicGranularity.title, systemImage: "slider.horizontal.3")
                    if !model.topicsAlgorithmVersion.isEmpty {
                        Text(model.topicsAlgorithmVersion)
                            .help("Версия алгоритма тематического таймкодинга")
                    }
                    Spacer()
                }
                HStack(spacing: 12) {
                    if !model.topicsEmbeddingModel.isEmpty {
                        Label(model.topicsEmbeddingModel, systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    if !model.topicsLanguageModel.isEmpty {
                        Label(model.topicsLanguageModel, systemImage: "brain")
                    }
                    Spacer()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if model.topics.isEmpty {
                ContentUnavailableView("Темы не созданы", systemImage: "list.bullet.rectangle")
            } else {
                Table(model.topics, selection: topicSelection) {
                    TableColumn("Название") { topic in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(topic.title)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                            Text(topic.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .width(min: 180, ideal: 270)
                    TableColumn("Начало") { topic in
                        Text(TimecodeParser.display(topic.start)).monospacedDigit()
                    }
                    .width(86)
                    TableColumn("Конец") { topic in
                        Text(TimecodeParser.display(topic.end)).monospacedDigit()
                    }
                    .width(86)
                    TableColumn("Длительность") { topic in
                        Text(TimeTextFormatter.string(topic.duration)).monospacedDigit()
                    }
                    .width(80)
                    TableColumn("Уверенность") { topic in
                        Text("\(Int((topic.confidence * 100).rounded()))%")
                            .monospacedDigit()
                    }
                    .width(80)
                    TableColumn("Причина границы") { topic in
                        Text(topic.boundaryReason)
                            .lineLimit(2)
                            .help(topic.boundaryReason)
                    }
                    .width(min: 130, ideal: 180)
                }
            }
        }
        .padding()
    }

    private var reviewTasksPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.humanReviewCheckpoint == nil ? "Требует ручной проверки" : "Human Review")
                        .font(.headline)
                    Text(reviewPanelSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    guard let projectURL = model.projectURL else { return }
                    NSWorkspace.shared.open(ProjectLayout(root: projectURL).transcriptReviewHTMLURL)
                } label: {
                    Image(systemName: "doc.richtext")
                }
                .help("Открыть HTML-отчёт")
                .disabled(model.projectURL == nil)
            }

            if let checkpoint = model.humanReviewCheckpoint {
                HStack(spacing: 10) {
                    Label(checkpoint.language.rawValue.uppercased(), systemImage: "pause.circle.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(.orange)
                    TextField("Поиск в расшифровке", text: $reviewSearch)
                        .accessibilityIdentifier("humanReview.search")
                    Toggle("Только замечания", isOn: $reviewIssuesOnly)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("humanReview.issuesOnly")
                    Button {
                        model.approveHumanReview()
                    } label: {
                        Label("Завершить проверку", systemImage: "checkmark.seal.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRunning)
                    .accessibilityIdentifier("humanReview.approve")
                }

                List(filteredReviewCues) { cue in
                    Button {
                        editingReviewCue = cue
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: reviewCueIDs.contains(cue.id) ? "exclamationmark.triangle.fill" : "text.bubble")
                                .foregroundStyle(reviewCueIDs.contains(cue.id) ? Color.red : Color.secondary)
                            Text("\(TimecodeParser.display(cue.start)) – \(TimecodeParser.display(cue.end))")
                                .font(.caption.monospacedDigit())
                                .frame(width: 175, alignment: .leading)
                            Text(cue.text)
                                .foregroundStyle(reviewCueIDs.contains(cue.id) ? Color.red : Color.primary)
                                .lineLimit(3)
                            Spacer()
                            Image(systemName: "pencil")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isRunning)
                    .accessibilityIdentifier("humanReview.cue.\(cue.id).edit")
                }
            }

            if model.humanReviewCheckpoint != nil {
                EmptyView()
            } else if model.unresolvedReviewTasks.isEmpty {
                ContentUnavailableView {
                    Label("Заданий нет", systemImage: "checkmark.circle")
                } actions: {
                    Button("Начать Human Review") {
                        model.beginHumanReview()
                    }
                    .disabled(!model.canBeginHumanReview)
                }
            } else {
                List(model.unresolvedReviewTasks) { task in
                    Button {
                        editingReviewTask = task
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .accessibilityLabel("Требуется ручная проверка")
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("\(TimecodeParser.display(task.start)) - \(TimecodeParser.display(task.end))")
                                        .font(.caption.monospacedDigit().bold())
                                    Spacer()
                                    Text(task.language.rawValue.uppercased())
                                        .font(.caption.bold())
                                }
                                Text(task.originalText)
                                    .foregroundStyle(.red)
                                    .lineLimit(3)
                                Text(reviewReason(task.reasonCodes))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isRunning)
                }
            }
        }
        .padding()
    }

    private var journal: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Журнал")
                .font(.headline)
            ScrollView {
                Text(model.log.text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding()
    }

    private var topicSelection: Binding<String?> {
        Binding(
            get: { model.selectedTopic?.id },
            set: { model.selectedTopicID = $0 ?? "" }
        )
    }

    private var detectedSourceLanguage: ArtifactLanguage {
        guard let projectURL = model.projectURL,
              let language = try? ProjectStore().load(from: projectURL).languageProfile?.effective else {
            return model.artifactLanguage
        }
        return language
    }

    private func topicIconButton(_ help: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .help(help)
        .disabled(model.selectedTopic == nil || model.isRunning)
    }

    private func reviewReason(_ codes: [String]) -> String {
        codes.map { code in
            switch code {
            case "low-confidence": return "Низкая уверенность распознавания"
            case "implausible-text-rate": return "Слишком высокая скорость текста"
            case "global-repetition-loop": return "Возможное зацикливание Whisper"
            case "consecutive-repetition": return "Повторяющийся фрагмент"
            case "repetitive-tail": return "Подозрительный повтор в конце"
            case "high-no-speech-probability": return "Whisper считает фрагмент вероятной тишиной"
            case "invalid-cue-duration": return "Некорректная длительность реплики"
            case "overlapping-cues": return "Перекрывающиеся временные интервалы"
            case "long-untranscribed-gap": return "Длинный участок без расшифровки"
            case "cue-id-set-mismatch": return "Перевод изменил состав реплик"
            case "target-language-mismatch": return "Результат получен не на целевом языке"
            case let value where value.hasPrefix("empty-cue-"): return "В переводе пропущена реплика"
            case let value where value.hasPrefix("numbers-changed-cue-"): return "В переводе изменены числа"
            case let value where value.hasPrefix("length-outlier-cue-"): return "Подозрительно изменилась длина текста"
            case let value where value.hasPrefix("provider-error:"): return "Ошибка локальной модели перевода"
            case "local-whisper-retry-suggested": return "Whisper предложил локальный повторный вариант"
            case "local-whisper-retry-no-improvement": return "Повтор Whisper не улучшил результат"
            case "local-whisper-retry-failed": return "Локальный повтор Whisper завершился ошибкой"
            case "local-whisper-retry-unavailable": return "Локальный повтор Whisper недоступен"
            default: return code
            }
        }.joined(separator: ", ")
    }

    private func resultStatusRow(_ artifact: ProjectArtifactSummary) -> some View {
        HStack(spacing: 9) {
            Image(systemName: artifactSymbol(artifact.availability))
                .foregroundStyle(artifactColor(artifact.availability))
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 1) {
                Text(artifact.kind.title)
                    .font(.subheadline)
                Text(artifact.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(artifact.detail)
            }
            Spacer()
            Text(artifact.availability.title)
                .font(.caption.bold())
                .foregroundStyle(artifactColor(artifact.availability))
        }
        .frame(minHeight: 34)
    }

    private func artifactSymbol(_ availability: ProjectArtifactAvailability) -> String {
        switch availability {
        case .ready: return "checkmark.circle.fill"
        case .partial: return "circle.lefthalf.filled"
        case .missing: return "minus.circle"
        case .invalid: return "exclamationmark.triangle.fill"
        }
    }

    private func artifactColor(_ availability: ProjectArtifactAvailability) -> Color {
        switch availability {
        case .ready: return .green
        case .partial: return .orange
        case .missing: return .secondary
        case .invalid: return .red
        }
    }

    private var textColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hexRGB: model.subtitleStyle.textColorHex)) },
            set: { model.subtitleStyle.textColorHex = NSColor($0).hexRGB }
        )
    }

    private var outlineColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hexRGB: model.subtitleStyle.outlineColorHex)) },
            set: { model.subtitleStyle.outlineColorHex = NSColor($0).hexRGB }
        )
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit())
        }
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    private func statusMark(_ status: ProjectStatus) -> some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 7, height: 7)
    }

    private func statusColor(_ status: ProjectStatus) -> Color {
        switch status {
        case .ready: return .secondary
        case .running: return .blue
        case .completed: return .green
        case .awaitingReview: return .orange
        case .stopped: return .orange
        case .failed: return .red
        }
    }

    private var reviewCueIDs: Set<Int> {
        Set(model.unresolvedReviewTasks.flatMap(\.cueIDs))
            .union(model.fillerCandidates.map(\.cueID))
    }

    private var filteredReviewCues: [SubtitleCue] {
        let query = reviewSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.reviewCues.filter { cue in
            (!reviewIssuesOnly || reviewCueIDs.contains(cue.id))
                && (query.isEmpty || cue.text.localizedCaseInsensitiveContains(query))
        }
    }

    private var reviewPanelSubtitle: String {
        guard let checkpoint = model.humanReviewCheckpoint else {
            return "Исправления сохраняются новой ревизией."
        }
        let kind = checkpoint.kind == .sourceTranscript ? "исходной расшифровки" : "перевода"
        return "Pipeline приостановлен для проверки \(kind); cue ID и таймкоды защищены."
    }

    private func openMediaFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .audio, .mpeg4Movie, .quickTimeMovie]
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func openProjectDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Открыть проект videotext"
        panel.prompt = "Открыть"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder, .json]
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func openWhisperModel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let binType = UTType(filenameExtension: "bin") { panel.allowedContentTypes = [binType] }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func openWatermarkImage() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Выбрать watermark"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["png", "jpg", "jpeg", "webp"].compactMap { UTType(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private func topicReviewCues(projectURL: URL, language: ArtifactLanguage) -> [SubtitleCue] {
    let layout = ProjectLayout(root: projectURL)
    let localized = layout.subtitlesURL(language: language)
    let source = FileManager.default.fileExists(atPath: localized.path) ? localized : layout.fullSRTURL
    return (try? SRTService().load(from: source)) ?? []
}

private struct TopicReviewSurface: View {
    let topic: TopicSegment
    let topics: [TopicSegment]
    let projectURL: URL
    let language: ArtifactLanguage
    let onPreview: () -> Void
    let onEdit: () -> Void
    let onChangeBoundary: () -> Void
    let onSplit: () -> Void
    let onMerge: () -> Void

    private var context: TopicReviewCueContext? {
        TopicReviewCueContext(
            topic: topic,
            topics: topics,
            cues: topicReviewCues(projectURL: projectURL, language: language)
        )
    }

    private var canSplit: Bool { topic.cueIds.count >= 2 }

    private var canMerge: Bool {
        guard let index = topics.firstIndex(where: { $0.id == topic.id }) else { return false }
        return index + 1 < topics.count
    }

    var body: some View {
        GroupBox("Проверка выбранной темы") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(topic.title)
                        .font(.headline)
                    Text(topic.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Label("Начало: \(TimecodeParser.display(topic.start))", systemImage: "clock")
                        Label("Конец: \(TimecodeParser.display(topic.end))", systemImage: "clock")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                Text("Действия")
                    .font(.subheadline.bold())
                VStack(alignment: .leading, spacing: 6) {
                    topicAction("Просмотреть фрагмент", systemImage: "play.fill", action: onPreview)
                    topicAction("Изменить название и описание", systemImage: "pencil", action: onEdit)
                    topicAction("Изменить границы по репликам", systemImage: "arrow.left.and.right", action: onChangeBoundary)
                    topicAction("Разделить по средней реплике", systemImage: "rectangle.split.2x1", action: onSplit)
                        .disabled(!canSplit)
                    topicAction("Объединить со следующей", systemImage: "arrow.triangle.merge", action: onMerge)
                        .disabled(!canMerge)
                }

                Divider()
                Text("Исходная расшифровка")
                    .font(.subheadline.bold())
                Text("Показаны реплики темы и соседний контекст. Границы можно ставить только между этими целыми репликами.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let context {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(context.contextCues, id: \.id) { cue in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(roleTitle(context.role(for: cue)))
                                        .font(.caption2.bold())
                                        .foregroundStyle(roleColor(context.role(for: cue)))
                                        .frame(width: 60, alignment: .leading)
                                    Text(TimecodeParser.display(cue.start))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 78, alignment: .leading)
                                    Text(cue.text)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                }
                                .padding(6)
                                .background(context.role(for: cue) == .inside ? Color.accentColor.opacity(0.10) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                    .frame(minHeight: 110, maxHeight: 190)
                } else {
                    Label("Не удалось сопоставить тему с репликами исходной расшифровки.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(6)
        }
    }

    private func roleTitle(_ role: TopicReviewCueContext.Role) -> String {
        switch role {
        case .before: return "До темы"
        case .inside: return "В теме"
        case .after: return "После темы"
        }
    }

    private func roleColor(_ role: TopicReviewCueContext.Role) -> Color {
        switch role {
        case .inside: return .accentColor
        case .before, .after: return .secondary
        }
    }

    private func topicAction(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

private struct TopicBoundaryReviewView: View {
    let topic: TopicSegment
    let context: TopicReviewCueContext
    let onSave: (TimeInterval, TimeInterval) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var startCueID: Int
    @State private var endCueID: Int

    init(
        topic: TopicSegment,
        context: TopicReviewCueContext,
        onSave: @escaping (TimeInterval, TimeInterval) -> Bool
    ) {
        self.topic = topic
        self.context = context
        self.onSave = onSave
        _startCueID = State(initialValue: context.currentStartCueID)
        _endCueID = State(initialValue: context.currentEndCueID)
    }

    private var startCue: SubtitleCue? { context.cue(id: startCueID) }
    private var endCue: SubtitleCue? { context.cue(id: endCueID) }
    private var selectionIsValid: Bool {
        guard let startCue, let endCue else { return false }
        return startCue.start <= endCue.end
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Границы темы по репликам")
                .font(.headline)
            Text(topic.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Выберите целые реплики, которые войдут в тему. VideoText сохранит cue-границы и автоматически перераспределит соседние темы без пропусков.")
                .font(.caption)
                .foregroundStyle(.secondary)

            cuePicker(
                title: "Тема начинается с",
                selection: $startCueID,
                cues: context.startChoices,
                disabled: context.startChoices.count == 1
            )
            cuePicker(
                title: "Тема заканчивается после",
                selection: $endCueID,
                cues: context.endChoices,
                disabled: context.endChoices.count == 1
            )

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить границы") {
                    guard let startCue, let endCue,
                          onSave(startCue.start, endCue.end) else { return }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!selectionIsValid)
            }
        }
        .padding()
        .frame(width: 620)
    }

    @ViewBuilder
    private func cuePicker(
        title: String,
        selection: Binding<Int>,
        cues: [SubtitleCue],
        disabled: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.bold())
            Picker(title, selection: selection) {
                ForEach(cues, id: \.id) { cue in
                    Text(cueTitle(cue)).tag(cue.id)
                }
            }
            .labelsHidden()
            .disabled(disabled)
        }
    }

    private func cueTitle(_ cue: SubtitleCue) -> String {
        let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = text.count > 88 ? String(text.prefix(87)) + "…" : text
        return "\(TimecodeParser.display(cue.start)) · \(preview)"
    }
}

private struct TopicPreviewView: View {
    let mediaURL: URL
    let topic: TopicSegment
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer
    @State private var stopTask: Task<Void, Never>?

    init(mediaURL: URL, topic: TopicSegment) {
        self.mediaURL = mediaURL
        self.topic = topic
        _player = State(initialValue: AVPlayer(url: mediaURL))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(topic.title)
                        .font(.headline)
                    Text("\(TimecodeParser.display(topic.start)) - \(TimecodeParser.display(topic.end))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Закрыть") { dismiss() }
            }
            VideoPlayer(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
            Text(topic.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 760, minHeight: 520)
        .onAppear { playTopic() }
        .onDisappear {
            stopTask?.cancel()
            player.pause()
        }
    }

    private func playTopic() {
        player.seek(to: CMTime(seconds: topic.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        stopTask?.cancel()
        stopTask = Task {
            let duration = max(0, topic.end - topic.start)
            try? await Task.sleep(nanoseconds: UInt64(min(duration, 86_400) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { player.pause() }
        }
    }
}

private struct ReviewTaskEditView: View {
    let mediaURL: URL
    let task: ReviewTask
    let onSave: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var replacementText: String
    @State private var player: AVPlayer
    @State private var stopTask: Task<Void, Never>?

    init(mediaURL: URL, task: ReviewTask, onSave: @escaping (String) -> Bool) {
        self.mediaURL = mediaURL
        self.task = task
        self.onSave = onSave
        _replacementText = State(initialValue: task.suggestedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? task.suggestedText!
            : task.originalText)
        _player = State(initialValue: AVPlayer(url: mediaURL))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Ручная проверка", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text("\(TimecodeParser.display(task.start)) - \(TimecodeParser.display(task.end))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Закрыть") { dismiss() }
            }
            VideoPlayer(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
            HStack {
                Button {
                    playRange()
                } label: {
                    Label("Прослушать фрагмент", systemImage: "play.fill")
                }
                Spacer()
                if let confidence = task.confidence {
                    Text("Уверенность: \(Int((confidence * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            TextEditor(text: $replacementText)
                .font(.body)
                .frame(minHeight: 100)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.35)))
                .accessibilityLabel("Исправленный текст фрагмента")
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить исправление") {
                    if onSave(replacementText) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(replacementText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 760, minHeight: 620)
        .onAppear { playRange() }
        .onDisappear {
            stopTask?.cancel()
            player.pause()
        }
    }

    private func playRange() {
        stopTask?.cancel()
        player.seek(to: CMTime(seconds: task.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        stopTask = Task {
            let duration = max(0, task.end - task.start)
            try? await Task.sleep(nanoseconds: UInt64(min(duration, 86_400) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { player.pause() }
        }
    }
}

private struct TranscriptCueEditView: View {
    let mediaURL: URL
    let cue: SubtitleCue
    let onSave: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var replacementText: String
    @State private var player: AVPlayer
    @State private var stopTask: Task<Void, Never>?

    init(mediaURL: URL, cue: SubtitleCue, onSave: @escaping (String) -> Bool) {
        self.mediaURL = mediaURL
        self.cue = cue
        self.onSave = onSave
        _replacementText = State(initialValue: cue.text)
        _player = State(initialValue: AVPlayer(url: mediaURL))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Редактирование текста", systemImage: "text.cursor")
                        .font(.headline)
                    Text("\(TimecodeParser.display(cue.start)) – \(TimecodeParser.display(cue.end))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Закрыть") { dismiss() }
                    .accessibilityIdentifier("humanReview.cueEditor.close")
            }
            VideoPlayer(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
            HStack {
                Button {
                    playRange()
                } label: {
                    Label("Прослушать фрагмент", systemImage: "play.fill")
                }
                Spacer()
                Label("Таймкод защищён", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: $replacementText)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.35)))
                .accessibilityLabel("Исправленный текст cue")
                .accessibilityIdentifier("humanReview.cueEditor.text")
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .accessibilityIdentifier("humanReview.cueEditor.cancel")
                Button("Сохранить черновик") {
                    if onSave(replacementText) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(replacementText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("humanReview.cueEditor.save")
            }
        }
        .padding()
        .frame(minWidth: 760, minHeight: 620)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("humanReview.cueEditor")
        .onAppear { playRange() }
        .onDisappear {
            stopTask?.cancel()
            player.pause()
        }
    }

    private func playRange() {
        stopTask?.cancel()
        player.seek(to: CMTime(seconds: cue.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        stopTask = Task {
            let duration = max(0, cue.end - cue.start)
            try? await Task.sleep(nanoseconds: UInt64(min(duration, 86_400) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { player.pause() }
        }
    }
}

private struct TopicEditView: View {
    let topic: TopicSegment
    let onSave: (String, String, String, String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var summary: String
    @State private var startText: String
    @State private var endText: String

    init(topic: TopicSegment, onSave: @escaping (String, String, String, String) -> Bool) {
        self.topic = topic
        self.onSave = onSave
        _title = State(initialValue: topic.title)
        _summary = State(initialValue: topic.summary)
        _startText = State(initialValue: TimecodeParser.display(topic.start))
        _endText = State(initialValue: TimecodeParser.display(topic.end))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Изменить тему")
                .font(.headline)
            TextField("Название", text: $title)
            TextField("Описание", text: $summary, axis: .vertical)
                .lineLimit(2...5)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Начало").font(.caption.bold())
                    TextField("ЧЧ:ММ:СС.ммм", text: $startText).monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Конец").font(.caption.bold())
                    TextField("ЧЧ:ММ:СС.ммм", text: $endText).monospacedDigit()
                }
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") {
                    if onSave(title, summary, startText, endText) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding()
        .frame(width: 520)
    }
}

private struct BlurRegionSelector: View {
    let mediaURL: URL?
    @Binding var region: NormalizedVideoRect
    @State private var frameImage: NSImage?
    @State private var dragStart: NormalizedVideoRect?
    @State private var resizeStart: NormalizedVideoRect?

    var body: some View {
        GeometryReader { proxy in
            let content = fittedRect(in: proxy.size)
            ZStack {
                Color.black
                if let frameImage {
                    Image(nsImage: frameImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Rectangle()
                    .fill(Color.white.opacity(0.16))
                    .overlay(Rectangle().stroke(Color.white, lineWidth: 2))
                    .frame(width: content.width * region.width, height: content.height * region.height)
                    .position(
                        x: content.minX + content.width * (region.x + region.width / 2),
                        y: content.minY + content.height * (region.y + region.height / 2)
                    )
                    .gesture(moveGesture(content: content))
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
                    .position(
                        x: content.minX + content.width * (region.x + region.width),
                        y: content.minY + content.height * (region.y + region.height)
                    )
                    .gesture(resizeGesture(content: content))
                    .help("Изменить размер области blur")
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .task(id: mediaURL) { await loadFrame() }
        .accessibilityLabel("Выбор области статического blur")
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        guard let frameImage, frameImage.size.width > 0, frameImage.size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let scale = min(size.width / frameImage.size.width, size.height / frameImage.size.height)
        let fitted = CGSize(width: frameImage.size.width * scale, height: frameImage.size.height * scale)
        return CGRect(
            x: (size.width - fitted.width) / 2,
            y: (size.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    private func moveGesture(content: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let initial = dragStart ?? region
                if dragStart == nil { dragStart = initial }
                region.x = min(max(0, initial.x + value.translation.width / max(content.width, 1)), 1 - initial.width)
                region.y = min(max(0, initial.y + value.translation.height / max(content.height, 1)), 1 - initial.height)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(content: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let initial = resizeStart ?? region
                if resizeStart == nil { resizeStart = initial }
                region.width = min(max(0.03, initial.width + value.translation.width / max(content.width, 1)), 1 - initial.x)
                region.height = min(max(0.03, initial.height + value.translation.height / max(content.height, 1)), 1 - initial.y)
            }
            .onEnded { _ in resizeStart = nil }
    }

    @MainActor
    private func loadFrame() async {
        frameImage = nil
        guard let mediaURL else { return }
        let asset = AVURLAsset(url: mediaURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        guard let result = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) else { return }
        frameImage = NSImage(cgImage: result.image, size: .zero)
    }
}

private struct WatermarkPreview: View {
    let mediaURL: URL?
    let watermarkURL: URL?
    let position: WatermarkPosition
    let manualX: Double
    let manualY: Double
    let relativeWidth: Double
    let margin: Double
    let opacity: Double
    @State private var frameImage: NSImage?

    var body: some View {
        GeometryReader { proxy in
            let frameSize = frameImage?.size ?? proxy.size
            let fitted = fittedRect(imageSize: frameSize, in: proxy.size)
            ZStack {
                Color.black
                if let frameImage {
                    Image(nsImage: frameImage).resizable().aspectRatio(contentMode: .fit)
                }
                if let watermarkURL, let watermark = NSImage(contentsOf: watermarkURL), watermark.size.width > 0 {
                    let width = fitted.width * relativeWidth
                    let height = min(fitted.height, width * watermark.size.height / watermark.size.width)
                    let origin = watermarkOrigin(frame: fitted, size: CGSize(width: width, height: height))
                    Image(nsImage: watermark)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .opacity(opacity)
                        .frame(width: width, height: height)
                        .position(x: origin.x + width / 2, y: origin.y + height / 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .task(id: mediaURL) { await loadFrame() }
        .accessibilityLabel("Предварительный просмотр watermark")
    }

    private func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: container) }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func watermarkOrigin(frame: CGRect, size: CGSize) -> CGPoint {
        let insetX = frame.width * margin
        let insetY = frame.height * margin
        switch position {
        case .topLeft: return CGPoint(x: frame.minX + insetX, y: frame.minY + insetY)
        case .topRight: return CGPoint(x: frame.maxX - size.width - insetX, y: frame.minY + insetY)
        case .bottomLeft: return CGPoint(x: frame.minX + insetX, y: frame.maxY - size.height - insetY)
        case .bottomRight: return CGPoint(x: frame.maxX - size.width - insetX, y: frame.maxY - size.height - insetY)
        case .manual:
            return CGPoint(
                x: min(frame.maxX - size.width, max(frame.minX, frame.minX + frame.width * manualX)),
                y: min(frame.maxY - size.height, max(frame.minY, frame.minY + frame.height * manualY))
            )
        }
    }

    @MainActor
    private func loadFrame() async {
        frameImage = nil
        guard let mediaURL else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: mediaURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        guard let result = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) else { return }
        frameImage = NSImage(cgImage: result.image, size: .zero)
    }
}

private extension NSColor {
    convenience init(hexRGB: String) {
        let clean = hexRGB.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&value)
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    var hexRGB: String {
        let color = usingColorSpace(.sRGB) ?? self
        return String(
            format: "#%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }
}
