import SwiftUI
import AppKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = WorkflowViewModel()
    @State private var fragmentSelectionMode = FragmentSelectionMode.timecode
    @State private var showServiceResults = false
    @State private var previewTopic: TopicSegment?
    @State private var editingTopic: TopicSegment?
    @State private var editingReviewTask: ReviewTask?
    @State private var editingReviewCue: SubtitleCue?
    @State private var reviewSearch = ""
    @State private var reviewIssuesOnly = false
    @State private var confirmTopicRemoval = false
    @State private var selectedResultsTab = 0

    var body: some View {
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
        .frame(minWidth: 980, minHeight: 680)
        .alert(item: $model.alert) { alert in
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
        .sheet(item: $editingReviewTask) { task in
            if let mediaURL = model.mediaURL {
                ReviewTaskEditView(mediaURL: mediaURL, task: task) { replacement in
                    model.resolveReviewTask(task, replacementText: replacement)
                }
            }
        }
        .sheet(item: $editingReviewCue) { cue in
            if let mediaURL = model.mediaURL {
                TranscriptCueEditView(mediaURL: mediaURL, cue: cue) { replacement in
                    model.saveHumanReviewCue(cue, replacementText: replacement)
                }
            }
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
        }
        .onChange(of: model.topicReviewCheckpoint) { _, checkpoint in
            if checkpoint != nil { selectedResultsTab = 1 }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                appIdentity
                Spacer(minLength: 12)
                projectActions
                workflowActions(includeStatus: true)
            }
            VStack(spacing: 10) {
                HStack {
                    appIdentity
                    Spacer()
                    statusLabel
                }
                HStack(spacing: 10) {
                    projectActions
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

    private var projectActions: some View {
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
            Button {
                model.runDiagnostics()
            } label: {
                Image(systemName: "stethoscope")
            }
            .help("Запустить диагностику")
            .disabled(model.projectURL == nil || model.isRunning)
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
                        Toggle("Human Review исходной расшифровки", isOn: $model.sourceHumanReviewEnabled)
                            .disabled(model.isRunning || model.humanReviewCheckpoint != nil)
                        Toggle("Анализировать слова-паразиты до Human Review", isOn: $model.fillerAnalysisBeforeReview)
                            .disabled(model.isRunning || model.humanReviewCheckpoint != nil)
                        Toggle("Human Review перевода", isOn: $model.translationHumanReviewEnabled)
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
                        Text("Режим")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Режим", selection: $model.topicAnalysisMode) {
                            ForEach(TopicAnalysisMode.allCases) { value in
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
                            Text(model.topicAnalysisMode == .hybrid ? "embeddinggemma + qwen2.5" : "не используются")
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
                        Picker("Язык", selection: $model.dubbingLanguage) {
                            Text("RU · Yuri улучшенный").tag(ArtifactLanguage.ru)
                            Text("EN · Daniel улучшенный").tag(ArtifactLanguage.en)
                        }
                        .pickerStyle(.segmented)
                        Picker("Оригинальный звук", selection: $model.dubbingMixMode) {
                            ForEach(DubbingMixMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        Button {
                            model.createDubbing()
                        } label: {
                            Label("Создать дубляж", systemImage: "person.wave.2")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.projectURL == nil)
                        .help(model.dubbingLanguage == .ru ? "Создать дубляж голосом Yuri (Enhanced)" : "Создать дубляж голосом Daniel (Enhanced)")
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
                            Label("Завершить проверку", systemImage: "checkmark.seal.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRunning)
                    }
                }
                if model.topicReviewCheckpoint != nil {
                    Label(
                        "Проверьте каждый язык и уровень детализации. Изменения привязываются к существующим cue.",
                        systemImage: "pause.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
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
                    Toggle("Только замечания", isOn: $reviewIssuesOnly)
                        .toggleStyle(.checkbox)
                    Button {
                        model.approveHumanReview()
                    } label: {
                        Label("Завершить проверку", systemImage: "checkmark.seal.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRunning)
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
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить черновик") {
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
