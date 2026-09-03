import Foundation
import AppKit
import Darwin

enum EndToEndError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

@main
struct EndToEndTest {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3 else {
                throw EndToEndError.failed("Использование: videotext-e2e <видео> <модель-whisper>")
            }

            let mediaURL = URL(fileURLWithPath: CommandLine.arguments[1])
            let modelPath = CommandLine.arguments[2]
            try require(FileManager.default.fileExists(atPath: mediaURL.path), "Тестовое видео не найдено")
            try require(FileManager.default.fileExists(atPath: modelPath), "Модель Whisper не найдена")
            try require(WhisperModelLocator().bestModelPath() == modelPath, "Автопоиск выбрал неверную модель Whisper")
            try validateTimecodes()
            try validateZeroDurationSubtitles()
            try validateUserOperationSurface()

            let initialController = ProcessController()
            let initialEngine = WorkflowEngine(controller: initialController)
            let initialSettings = WorkflowSettings(
                mediaURL: mediaURL,
                projectURL: nil,
                selectedOperations: [.transcribe, .topicTimecoding, .burnSubtitles],
                mode: .newProject,
                rangeStart: 1,
                rangeEnd: 6,
                fragmentName: "",
                burnFragmentSubtitles: false,
                subtitleStyle: .standard,
                selectedTopicID: nil,
                whisperModelPath: "",
                whisperLanguage: "auto",
                topicHumanReviewEnabled: true
            )

            var initialProgress: [WorkflowProgress] = []
            let pausedResult = try await initialEngine.run(
                settings: initialSettings,
                onLog: { print($0) },
                onProgress: { initialProgress.append($0) }
            )
            guard let checkpoint = pausedResult.checkpoint else {
                throw EndToEndError.failed("Первичная обработка не остановилась для Human Review")
            }
            try require(checkpoint.kind == .sourceTranscript, "Создан неверный тип Human Review checkpoint")
            try require(!checkpoint.pendingOperations.isEmpty, "Human Review потерял очередь продолжения")
            try validateProgress(
                initialProgress,
                requireWhisperProgress: true,
                requireCompletion: false,
                requireETA: false
            )

            let approval = try HumanReviewService().approve(projectURL: pausedResult.projectURL)
            try require(approval.pendingOperations == checkpoint.pendingOperations, "При утверждении изменилась очередь продолжения")
            let resumedSettings = WorkflowSettings(
                mediaURL: mediaURL,
                projectURL: pausedResult.projectURL,
                selectedOperations: Set(approval.pendingOperations),
                mode: .resumeProject,
                rangeStart: 1,
                rangeEnd: 6,
                fragmentName: "",
                burnFragmentSubtitles: false,
                subtitleStyle: .standard,
                selectedTopicID: nil,
                whisperModelPath: modelPath,
                whisperLanguage: "auto",
                sourceHumanReviewEnabled: true,
                topicHumanReviewEnabled: true
            )
            var resumedProgress: [WorkflowProgress] = []
            let topicPausedResult = try await initialEngine.run(
                settings: resumedSettings,
                onLog: { print($0) },
                onProgress: { resumedProgress.append($0) }
            )
            try require(topicPausedResult.checkpoint == nil, "Утверждённая ревизия повторно открыла Human Review расшифровки")
            guard let topicCheckpoint = topicPausedResult.topicReviewCheckpoint else {
                throw EndToEndError.failed("Тематический таймкодинг не остановился для Human Review")
            }
            try require(topicCheckpoint.revisionIDs.count >= 3, "Topic Human Review потерял варианты детализации")
            let topicApproval = try TopicReviewService().approve(projectURL: topicPausedResult.projectURL)
            try require(topicApproval.pendingOperations == topicCheckpoint.pendingOperations, "Topic Human Review изменил очередь продолжения")
            let finalSettings = WorkflowSettings(
                mediaURL: mediaURL,
                projectURL: topicPausedResult.projectURL,
                selectedOperations: Set(topicApproval.pendingOperations),
                mode: .resumeProject,
                rangeStart: 1,
                rangeEnd: 6,
                fragmentName: "",
                burnFragmentSubtitles: false,
                subtitleStyle: .standard,
                selectedTopicID: nil,
                whisperModelPath: modelPath,
                whisperLanguage: "auto",
                sourceHumanReviewEnabled: true,
                topicHumanReviewEnabled: true
            )
            var finalProgress: [WorkflowProgress] = []
            let initialResult = try await initialEngine.run(
                settings: finalSettings,
                onLog: { print($0) },
                onProgress: { finalProgress.append($0) }
            )
            try require(initialResult.checkpoint == nil && initialResult.topicReviewCheckpoint == nil, "Утверждённый проект повторно открыл Human Review")
            try validateInitialProject(
                initialResult,
                mediaURL: mediaURL,
                progress: finalProgress,
                requireWhisperProgress: false
            )
            try validateHybridTopics(initialResult.projectURL)
            try validateProjectLocator(projectURL: initialResult.projectURL, parent: mediaURL.deletingLastPathComponent())
            try require(initialController.launchedExecutables.contains { URL(fileURLWithPath: $0).lastPathComponent == "whisper-cli" }, "Первичная расшифровка не запускала Whisper")
            try validateResultSummary(initialResult.projectURL, expectedFragments: 0, expectedTopics: .ready)

            try appendZeroDurationWhisperCue(to: ProjectLayout(root: initialResult.projectURL).fullSRTURL)
            let fullSRTBefore = try Data(contentsOf: ProjectLayout(root: initialResult.projectURL).fullSRTURL)
            let srtDateBefore = modificationDate(ProjectLayout(root: initialResult.projectURL).fullSRTURL)
            try FileManager.default.removeItem(at: ProjectLayout(root: initialResult.projectURL).transcriptURL)
            try installLegacyTopics(in: initialResult.projectURL)
            try await validateLegacyTopicUIState(projectURL: initialResult.projectURL)
            try await validateTopicResume(
                mediaURL: mediaURL,
                projectURL: initialResult.projectURL,
                modelPath: modelPath
            )

            // A fresh store/history instance simulates reopening the app.
            let reopenedHistory = ProjectHistoryStore().entries()
            guard let historyEntry = reopenedHistory.first(where: { $0.projectPath == initialResult.projectURL.path }) else {
                throw EndToEndError.failed("Проект не появился в постоянной истории")
            }
            try require(historyEntry.status == .completed, "История не сохранила завершённый статус")
            let (reopenedManifest, reopenedMedia) = try ProjectStore().openProject(at: initialResult.projectURL)
            try require(reopenedMedia.standardizedFileURL == mediaURL.standardizedFileURL, "После повторного открытия выбран неверный исходный файл")
            try require(
                reopenedManifest.schemaVersion == ProjectSchema.currentVersion,
                "Манифест не мигрирован до текущей схемы"
            )

            let yellow = SubtitleStyleSettings(
                textColorHex: "#FFD84D",
                outlineColorHex: "#000000",
                fontName: "Helvetica",
                fontSize: 30,
                outlineWidth: 2.5,
                position: .bottom,
                backgroundOpacity: 0.15
            )
            let firstFragment = try await resumeWithFragment(
                mediaURL: mediaURL,
                projectURL: initialResult.projectURL,
                modelPath: modelPath,
                name: "Жёлтый фрагмент",
                style: yellow
            )
            try await validateFragment(firstFragment, expectedDuration: 5, expectedColor: .yellow)
            let timelineReport = try String(contentsOf: ProjectLayout(root: initialResult.projectURL).timelineValidationURL, encoding: .utf8)
            try require(timelineReport.contains("Пропущено служебных реплик нулевой длительности: 1."), "Проверка не сообщила о пропущенной нулевой реплике")

            let cyan = SubtitleStyleSettings(
                textColorHex: "#65D9FF",
                outlineColorHex: "#101010",
                fontName: "Avenir Next",
                fontSize: 27,
                outlineWidth: 2,
                position: .top,
                backgroundOpacity: 0
            )
            let secondFragment = try await resumeWithFragment(
                mediaURL: mediaURL,
                projectURL: initialResult.projectURL,
                modelPath: modelPath,
                name: "Голубой фрагмент Юрий's",
                style: cyan
            )
            try await validateFragment(secondFragment, expectedDuration: 5, expectedColor: .cyan)
            try require(firstFragment.id != secondFragment.id, "Повторный диапазон перезаписал предыдущий фрагмент")

            let topicFragment = try await resumeWithTopicFragment(
                mediaURL: mediaURL,
                projectURL: initialResult.projectURL,
                modelPath: modelPath
            )
            try await validateTopicFragment(topicFragment)
            try await resumeWithoutBurn(
                mediaURL: mediaURL,
                projectURL: initialResult.projectURL,
                modelPath: modelPath,
                useTopic: false
            )
            try await resumeWithoutBurn(
                mediaURL: mediaURL,
                projectURL: initialResult.projectURL,
                modelPath: modelPath,
                useTopic: true
            )

            let finalManifest = try ProjectStore().load(from: initialResult.projectURL)
            try require(finalManifest.fragments?.count == 5, "Манифест не сохранил пять фрагментов")
            try require(finalManifest.subtitleStyle == cyan, "Стиль субтитров не восстановится после перезапуска")
            try require(finalManifest.workflow?.operations[WorkflowOperation.transcribe.rawValue]?.outputPaths.isEmpty == false, "Операция расшифровки не сохранила выходные файлы")
            let fullSRTAfter = try Data(contentsOf: ProjectLayout(root: initialResult.projectURL).fullSRTURL)
            try require(fullSRTAfter == fullSRTBefore, "Продолжение изменило full.srt")
            try require(modificationDate(ProjectLayout(root: initialResult.projectURL).fullSRTURL) == srtDateBefore, "Продолжение повторно записало full.srt")
            try validateResultSummary(initialResult.projectURL, expectedFragments: 5, expectedTopics: .ready)
            try validateSourceMismatch(projectURL: initialResult.projectURL, parent: mediaURL.deletingLastPathComponent())

            try await validateCancellation(mediaURL: mediaURL, modelPath: modelPath, projectParent: mediaURL.deletingLastPathComponent())
            try await validateMissingAudioError(in: mediaURL.deletingLastPathComponent(), modelPath: modelPath)
            try validateLegacyManifestCompatibility(mediaURL: mediaURL, parent: mediaURL.deletingLastPathComponent())

            let finalHistory = ProjectHistoryStore().entries()
            try require(finalHistory.contains { $0.projectPath == initialResult.projectURL.path && $0.status == .completed }, "История не обновилась после продолжения")
            try require(noActiveTools(), "После E2E остались активные videotext/whisper-cli/ffmpeg/ffprobe")

            print("E2E PASS: гибридные темы, фрагменты с прожигом и без него, 2 диапазона, ffprobe, кэш и остановка проверены")
            print("QA_PROJECT=\(initialResult.projectURL.path)")
        } catch {
            fputs("E2E FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func validateInitialProject(
        _ result: WorkflowResult,
        mediaURL: URL,
        progress: [WorkflowProgress],
        requireWhisperProgress: Bool
    ) throws {
        let expectedName = "Обработка видео \(mediaURL.deletingPathExtension().lastPathComponent)"
        try require(result.projectURL.lastPathComponent == expectedName, "Неверное имя автоматического проекта")
        let layout = ProjectLayout(root: result.projectURL)
        try require(directoryExists(layout.videoDirectory), "Не создана папка Video")
        try require(directoryExists(layout.textsDirectory), "Не создана папка Texts")
        try require(directoryExists(layout.supportDirectory), "Не создана папка Support files")
        let requiredFiles = [
            layout.manifestURL,
            layout.sourceAudioURL,
            layout.diagnosticsURL,
            layout.timelineValidationURL,
            layout.ffprobeReportURL,
            layout.fullSRTURL,
            layout.transcriptURL,
            layout.topicsURL,
            layout.topicsTextURL,
            layout.subtitledVideoURL
        ]
        for url in requiredFiles { try require(nonemptyFile(at: url), "Отсутствует или пуст результат: \(url.path)") }
        let cues = try SRTService().load(from: layout.fullSRTURL)
        try require(!cues.isEmpty, "full.srt не содержит субтитров")
        try validateProgress(progress, requireWhisperProgress: requireWhisperProgress)
        let payload = NotificationPayload.success(mediaName: mediaURL.lastPathComponent, elapsed: result.elapsed, projectURL: result.projectURL)
        try require(payload.title.contains("завершена") && payload.body.contains(mediaURL.lastPathComponent), "Некорректное уведомление об успехе")
    }

    private static func validateHybridTopics(_ projectURL: URL) throws {
        let file = try WorkflowEngine.loadTopics(projectURL: projectURL)
        let layout = ProjectLayout(root: projectURL)
        let sourceText = try String(contentsOf: layout.fullSRTURL, encoding: .utf8)
        let allCues = try SRTService().load(from: layout.fullSRTURL)
        let meaningfulIDs = Set(TopicTextPreprocessor().prepare(allCues).flatMap(\.cueIDs))
        let meaningfulCues = allCues
            .filter { meaningfulIDs.contains($0.id) }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        try require(file.status == .ready, "Тематический таймкодинг ошибочно помечен как черновой")
        try require(file.schemaVersion == 2, "topics.json содержит неверную версию схемы")
        try require(file.algorithmVersion == HybridTopicAdapter.algorithmVersion, "topics.json содержит неверную версию алгоритма")
        try require(file.adapter == "HybridTopicAdapter", "Использован неверный адаптер тем")
        try require(file.sourceSignature == StableTopicHash.string(sourceText), "Сигнатура исходного SRT не совпадает")
        try require(file.embeddingModel?.contains("embeddinggemma") == true, "В topics.json не записана embedding-модель")
        try require(file.languageModel?.isEmpty == false, "В topics.json не записана языковая модель")
        try require(file.topics.allSatisfy { topic in
            let wordCount = topic.title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
            return (3...8).contains(wordCount)
                && !topic.summary.isEmpty
                && (2...8).contains(topic.keywords.count)
                && (0...1).contains(topic.confidence)
                && !topic.boundaryReason.isEmpty
                && topic.duration > 0
                && topic.sourceCueStart <= topic.sourceCueEnd
        }, "topics.json не содержит обязательные качественные поля")
        let issues = TopicValidator().validate(
            file,
            expectedCues: meaningfulCues,
            mediaDuration: (try ProjectStore().load(from: projectURL)).durationSeconds
        )
        try require(issues.isEmpty, "topics.json не прошёл точную сверку с SRT: \(issues.joined(separator: " "))")
    }

    private static func validateProjectLocator(projectURL: URL, parent: URL) throws {
        let locator = ProjectLocator()
        let layout = ProjectLayout(root: projectURL)
        let expected = projectURL.standardizedFileURL
        let rootSelection = try locator.resolve(projectURL)
        let supportSelection = try locator.resolve(layout.supportDirectory)
        let manifestSelection = try locator.resolve(layout.manifestURL)
        let textsSelection = try locator.resolve(layout.textsDirectory)
        let parentSelection = try locator.resolve(parent)
        try require(rootSelection == expected, "Не открывается корневая папка проекта")
        try require(supportSelection == expected, "Не открывается Support files")
        try require(manifestSelection == expected, "Не открывается manifest.json")
        try require(textsSelection == expected, "Не открывается папка Texts")
        try require(parentSelection == expected, "Проект не найден в родительской папке")
    }

    private static func resumeWithFragment(
        mediaURL: URL,
        projectURL: URL,
        modelPath: String,
        name: String,
        style: SubtitleStyleSettings
    ) async throws -> FragmentRecord {
        let controller = ProcessController()
        let engine = WorkflowEngine(controller: controller)
        var log: [String] = []
        var progress: [WorkflowProgress] = []
        let settings = WorkflowSettings(
            mediaURL: mediaURL,
            projectURL: projectURL,
            selectedOperations: [.cutRange, .burnFragmentSubtitles],
            mode: .resumeProject,
            rangeStart: 1,
            rangeEnd: 6,
            fragmentName: name,
            burnFragmentSubtitles: true,
            subtitleStyle: style,
            selectedTopicID: nil,
            whisperModelPath: modelPath,
            whisperLanguage: "auto"
        )
        let before = (try ProjectStore().load(from: projectURL).fragments ?? []).count
        _ = try await engine.run(settings: settings, onLog: { log.append($0); print($0) }, onProgress: { progress.append($0) })
        try require(!log.contains { $0.contains("Модель Whisper:") }, "При продолжении повторно запущена транскрипция Whisper")
        try require(log.contains { $0.contains("Пропуск: Расшифровать всё видео") }, "Журнал не подтвердил пропуск расшифровки")
        try require(log.contains { $0.contains("Запуск: Проверка ffprobe") }, "ffprobe не был добавлен автоматически")
        try require(log.contains { $0.contains("Запуск: Поиск результатов") }, "Обнаружение результатов не было добавлено автоматически")
        try validateProgress(progress, requireWhisperProgress: false)
        let manifest = try ProjectStore().load(from: projectURL)
        guard let fragments = manifest.fragments, fragments.count == before + 1, let fragment = fragments.first else {
            throw EndToEndError.failed("Новый фрагмент не зарегистрирован в манифесте")
        }
        try require(fragment.style == style, "Фрагмент сохранил неверный стиль")
        return fragment
    }

    private static func resumeWithTopicFragment(
        mediaURL: URL,
        projectURL: URL,
        modelPath: String
    ) async throws -> FragmentRecord {
        let file = try WorkflowEngine.loadTopics(projectURL: projectURL)
        guard let topic = file.topics.first else { throw EndToEndError.failed("Нет темы для вырезки") }
        let restoredStyle = try ProjectStore().load(from: projectURL).subtitleStyle ?? .standard
        let controller = ProcessController()
        let settings = WorkflowSettings(
            mediaURL: mediaURL,
            projectURL: projectURL,
            selectedOperations: [.cutTopic],
            mode: .resumeProject,
            rangeStart: 0,
            rangeEnd: 1,
            fragmentName: "",
            burnFragmentSubtitles: true,
            subtitleStyle: restoredStyle,
            selectedTopicID: topic.id,
            whisperModelPath: modelPath,
            whisperLanguage: "auto"
        )
        let before = (try ProjectStore().load(from: projectURL).fragments ?? []).count
        var log: [String] = []
        _ = try await WorkflowEngine(controller: controller).run(
            settings: settings,
            onLog: { log.append($0); print($0) }
        )
        try require(!log.contains { $0.contains("Модель Whisper:") }, "Вырезка темы повторно запустила транскрипцию Whisper")
        try require(!log.contains { $0.contains("Запуск: Тематический таймкодинг") }, "Вырезка темы повторно запустила тематический анализ")
        let fragments = try ProjectStore().load(from: projectURL).fragments ?? []
        try require(fragments.count == before + 1, "Фрагмент темы не зарегистрирован")
        guard let fragment = fragments.first else { throw EndToEndError.failed("Фрагмент темы не найден") }
        try require(abs((fragment.end - fragment.start) - topic.duration) < 0.01, "Фрагмент не соответствует диапазону темы")
        try require(fragment.style == restoredStyle, "Фрагмент темы не восстановил стиль проекта")
        return fragment
    }

    private static func validateTopicFragment(_ fragment: FragmentRecord) async throws {
        let video = URL(fileURLWithPath: fragment.videoPath)
        let subtitle = URL(fileURLWithPath: fragment.subtitlePath)
        guard let subtitledPath = fragment.subtitledVideoPath else {
            throw EndToEndError.failed("Для темы не создано видео с вшитыми субтитрами")
        }
        let subtitled = URL(fileURLWithPath: subtitledPath)
        try require(nonemptyFile(at: video), "Пустой видеофрагмент темы")
        try require(nonemptyFile(at: subtitle), "Не создан fragment.srt темы")
        try require(nonemptyFile(at: subtitled), "Пустое видео темы с субтитрами")
        let cues = try SRTService().load(from: subtitle)
        try require(!cues.isEmpty, "fragment.srt темы не содержит субтитров")
        let expected = fragment.end - fragment.start
        let duration = try await FFmpegAdapter().duration(of: subtitled)
        try require(duration.map { abs($0 - expected) <= 0.25 } == true, "ffprobe выявил неверную длительность фрагмента темы")
    }

    private static func resumeWithoutBurn(
        mediaURL: URL,
        projectURL: URL,
        modelPath: String,
        useTopic: Bool
    ) async throws {
        let topic = useTopic ? try WorkflowEngine.loadTopics(projectURL: projectURL).topics.first : nil
        if useTopic, topic == nil { throw EndToEndError.failed("Нет темы для проверки отключённого прожига") }
        let controller = ProcessController()
        let operations: Set<WorkflowOperation> = useTopic ? [.cutTopic] : [.cutRange]
        let projectStyle = try ProjectStore().load(from: projectURL).subtitleStyle ?? .standard
        let settings = WorkflowSettings(
            mediaURL: mediaURL,
            projectURL: projectURL,
            selectedOperations: operations,
            mode: .resumeProject,
            rangeStart: 1,
            rangeEnd: 6,
            fragmentName: useTopic ? "Тема без прожига" : "Диапазон без прожига",
            burnFragmentSubtitles: false,
            subtitleStyle: projectStyle,
            selectedTopicID: topic?.id,
            whisperModelPath: modelPath,
            whisperLanguage: "auto"
        )
        let before = (try ProjectStore().load(from: projectURL).fragments ?? []).count
        var log: [String] = []
        _ = try await WorkflowEngine(controller: controller).run(
            settings: settings,
            onLog: { log.append($0); print($0) }
        )
        let fragments = try ProjectStore().load(from: projectURL).fragments ?? []
        try require(fragments.count == before + 1, "Фрагмент без прожига не зарегистрирован")
        guard let fragment = fragments.first else { throw EndToEndError.failed("Фрагмент без прожига не найден") }
        let videoURL = URL(fileURLWithPath: fragment.videoPath)
        let srtURL = URL(fileURLWithPath: fragment.subtitlePath)
        let unexpectedVideo = ProjectLayout(root: projectURL).fragmentSubtitledVideoURL(kind: fragment.id)
        try require(nonemptyFile(at: videoURL), "Пустой фрагмент без прожига")
        try require(nonemptyFile(at: srtURL), "Не создан fragment.srt без прожига")
        try require(fragment.ffprobeReportPath.map { nonemptyFile(at: URL(fileURLWithPath: $0)) } == true, "Нет ffprobe фрагмента без прожига")
        try require(fragment.subtitledVideoPath == nil, "Манифест ошибочно зарегистрировал прожжённый фрагмент")
        try require(!FileManager.default.fileExists(atPath: unexpectedVideo.path), "При выключенном переключателе создан fragment_subtitled.mp4")
        try require(!log.contains { $0.contains("Субтитры вшиты во фрагмент") }, "При выключенном переключателе запускался прожиг субтитров")
        try require(!log.contains { $0.contains("Модель Whisper:") }, "Фрагмент без прожига повторно запустил транскрипцию Whisper")
        let cues = try SRTService().load(from: srtURL)
        try require(!cues.isEmpty, "fragment.srt без прожига не содержит реплик")
        let duration = try await FFmpegAdapter().duration(of: videoURL)
        try require(duration.map { abs($0 - (fragment.end - fragment.start)) <= 0.25 } == true, "ffprobe выявил неверную длительность фрагмента без прожига")
    }

    private enum ExpectedColor: Equatable { case yellow, cyan }

    private static func validateFragment(_ fragment: FragmentRecord, expectedDuration: TimeInterval, expectedColor: ExpectedColor) async throws {
        let videoURL = URL(fileURLWithPath: fragment.videoPath)
        let srtURL = URL(fileURLWithPath: fragment.subtitlePath)
        guard let subtitledPath = fragment.subtitledVideoPath else { throw EndToEndError.failed("Нет пути фрагмента с субтитрами") }
        let subtitledURL = URL(fileURLWithPath: subtitledPath)
        try require(nonemptyFile(at: videoURL), "Пустой fragment.mp4")
        try require(nonemptyFile(at: srtURL), "Пустой fragment.srt")
        try require(nonemptyFile(at: subtitledURL), "Пустой fragment_subtitled.mp4")
        try require(fragment.ffprobeReportPath.map { nonemptyFile(at: URL(fileURLWithPath: $0)) } == true, "Нет ffprobe фрагмента")
        let cues = try SRTService().load(from: srtURL)
        try require(!cues.isEmpty, "fragment.srt не содержит реплик")
        try require(cues.allSatisfy { $0.start >= 0 && $0.end <= expectedDuration + 0.001 }, "fragment.srt не пересчитан относительно фрагмента")
        let duration = try await FFmpegAdapter().duration(of: subtitledURL)
        try require(duration.map { abs($0 - expectedDuration) <= 0.25 } == true, "Неточная длительность фрагмента: \(duration ?? -1)")
        let sampleTime = max(0.05, min(expectedDuration - 0.05, (cues[0].start + cues[0].end) / 2))
        try require(extractedFrameContainsColor(videoURL: subtitledURL, time: sampleTime, expected: expectedColor), "В кадре не обнаружен выбранный цвет субтитров")
    }

    private static func extractedFrameContainsColor(videoURL: URL, time: TimeInterval, expected: ExpectedColor) -> Bool {
        guard let ffmpeg = ToolRunner().resolve("ffmpeg") else { return false }
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("videotext-color-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-y", "-ss", String(format: "%.3f", time), "-i", videoURL.path, "-frames:v", "1", png.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: png),
              let bitmap = NSBitmapImageRep(data: data) else { return false }
        let startY = expected == .yellow ? bitmap.pixelsHigh / 2 : 0
        let endY = expected == .yellow ? bitmap.pixelsHigh : bitmap.pixelsHigh / 2
        var matches = 0
        var nearBlack = 0
        for y in stride(from: startY, to: endY, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = color.redComponent * 255
                let g = color.greenComponent * 255
                let b = color.blueComponent * 255
                if r < 18 && g < 18 && b < 18 { nearBlack += 1 }
                switch expected {
                case .yellow where r > 180 && g > 140 && b < 150: matches += 1
                case .cyan where r < 170 && g > 150 && b > 180: matches += 1
                default: break
                }
            }
        }
        return matches >= 8 && (expected != .yellow || nearBlack < 8_000)
    }

    private static func validateCancellation(mediaURL: URL, modelPath: String, projectParent: URL) async throws {
        guard let ffmpeg = ToolRunner().resolve("ffmpeg") else { throw EndToEndError.failed("FFmpeg не найден") }
        let ffmpegController = ProcessController()
        let ffmpegRunner = ToolRunner(controller: ffmpegController)
        let ffmpegTask = Task {
            try await ffmpegRunner.run(ffmpeg, ["-re", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=30", "-t", "30", "-f", "null", "-"])
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        ffmpegTask.cancel()
        ffmpegController.cancelCurrentProcess()
        do {
            _ = try await ffmpegTask.value
            throw EndToEndError.failed("FFmpeg не был отменён")
        } catch is CancellationError {
            // Expected.
        }
        try require(ffmpegController.activeProcessID == nil, "После отмены остался FFmpeg")

        let longVideo = projectParent.appendingPathComponent("Длинное контрольное видео для остановки.mp4")
        let generated = try await ToolRunner().run(ffmpeg, [
            "-y", "-stream_loop", "20", "-i", mediaURL.path, "-t", "120", "-c", "copy", longVideo.path
        ])
        try require(generated.exitCode == 0 && nonemptyFile(at: longVideo), "Не создано видео для остановки Whisper")
        defer { try? FileManager.default.removeItem(at: longVideo) }

        let controller = ProcessController()
        let engine = WorkflowEngine(controller: controller)
        let settings = WorkflowSettings(
            mediaURL: longVideo,
            projectURL: nil,
            selectedOperations: [.transcribe],
            mode: .newProject,
            rangeStart: 0,
            rangeEnd: 10,
            fragmentName: "",
            burnFragmentSubtitles: false,
            subtitleStyle: .standard,
            selectedTopicID: nil,
            whisperModelPath: modelPath,
            whisperLanguage: "auto"
        )
        var transcriptionStarted = false
        let task = Task {
            try await engine.run(settings: settings, onLog: { message in
                print(message)
                if message.contains("Подготовка звуковой дорожки"), !transcriptionStarted {
                    transcriptionStarted = true
                    controller.resetLaunchLog()
                }
            })
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        task.cancel()
        engine.cancel()
        do {
            _ = try await task.value
            throw EndToEndError.failed("Задание Whisper не было остановлено")
        } catch is CancellationError {
            // Expected.
        }
        let cancelledLaunches = controller.launchedExecutables.map { URL(fileURLWithPath: $0).lastPathComponent }
        try require(cancelledLaunches.contains("whisper-cli"), "Остановка не дошла до транскрипционного whisper-cli")
        try require(controller.activeProcessID == nil, "После остановки остался процесс Whisper/FFmpeg")
        let stoppedProject = projectParent.appendingPathComponent("Обработка видео \(longVideo.deletingPathExtension().lastPathComponent)")
        let manifest = try ProjectStore().load(from: stoppedProject)
        try require(manifest.workflow?.status == .stopped, "Манифест не получил статус «Остановлено»")
        try require(!containsPartialFiles(stoppedProject), "После остановки остались .partial-файлы")

        let resumeSettings = WorkflowSettings(
            mediaURL: longVideo,
            projectURL: stoppedProject,
            selectedOperations: [.createManifest, .discoverResults],
            mode: .resumeProject,
            rangeStart: 0,
            rangeEnd: 10,
            fragmentName: "",
            burnFragmentSubtitles: false,
            subtitleStyle: .standard,
            selectedTopicID: nil,
            whisperModelPath: modelPath,
            whisperLanguage: "auto"
        )
        _ = try await WorkflowEngine().run(settings: resumeSettings, onLog: { print($0) })
        let continued = try ProjectStore().load(from: stoppedProject)
        try require(continued.workflow?.status == .completed, "Остановленный проект не удалось продолжить")
    }

    private static func validateMissingAudioError(in directory: URL, modelPath: String) async throws {
        guard let ffmpeg = ToolRunner().resolve("ffmpeg") else { throw EndToEndError.failed("FFmpeg не найден") }
        let silentVideo = directory.appendingPathComponent("Контрольное видео без звука.mp4")
        let generated = try await ToolRunner().run(ffmpeg, [
            "-y", "-f", "lavfi", "-i", "color=c=black:s=320x240:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", silentVideo.path
        ])
        try require(generated.exitCode == 0, "Не удалось создать контрольное видео без звука")
        defer { try? FileManager.default.removeItem(at: silentVideo) }
        let settings = WorkflowSettings(
            mediaURL: silentVideo,
            projectURL: nil,
            selectedOperations: [.transcribe],
            mode: .newProject,
            rangeStart: 0,
            rangeEnd: 1,
            fragmentName: "",
            burnFragmentSubtitles: false,
            subtitleStyle: .standard,
            selectedTopicID: nil,
            whisperModelPath: modelPath,
            whisperLanguage: "auto"
        )
        do {
            _ = try await WorkflowEngine().run(settings: settings, onLog: { _ in })
            throw EndToEndError.failed("Видео без аудио ошибочно прошло расшифровку")
        } catch let error as EndToEndError {
            throw error
        } catch {
            try require(error.localizedDescription.contains("отсутствует аудиодорожка"), "Неверная ошибка для видео без аудио")
        }
    }

    private static func validateLegacyManifestCompatibility(mediaURL: URL, parent: URL) throws {
        let project = parent.appendingPathComponent("Старый проект videotext", isDirectory: true)
        let layout = ProjectLayout(root: project)
        try layout.createDirectories()
        defer { try? FileManager.default.removeItem(at: project) }
        let date = ISO8601DateFormatter().string(from: Date())
        let escapedSource = mediaURL.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let escapedProject = project.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let json = """
        {"appName":"videotext","appVersion":"0.2.0","build":"legacy","createdAt":"\(date)","updatedAt":"\(date)","sourceMediaPath":"\(escapedSource)","projectFolderPath":"\(escapedProject)","durationSeconds":null,"outputs":[],"diagnostics":null}
        """
        try json.write(to: layout.manifestURL, atomically: true, encoding: .utf8)
        let migrated = try ProjectStore().ensureProject(at: project, mediaURL: mediaURL, mode: .resumeProject)
        try require(
            migrated.schemaVersion == ProjectSchema.currentVersion && migrated.workflow != nil,
            "Старый manifest.json не мигрирован"
        )
    }

    private static func validateSourceMismatch(projectURL: URL, parent: URL) throws {
        let other = parent.appendingPathComponent("Другой исходный файл.mp4")
        try Data("not-the-original-video".utf8).write(to: other, options: .atomic)
        defer { try? FileManager.default.removeItem(at: other) }
        do {
            _ = try ProjectStore().ensureProject(at: projectURL, mediaURL: other, mode: .resumeProject)
            throw EndToEndError.failed("Проект принял другой исходный файл")
        } catch WorkflowError.sourceMismatch {
            // Expected.
        }
    }

    private static func validateTimecodes() throws {
        let formatted = try TimecodeParser.parse("00:12:34.500")
        let seconds = try TimecodeParser.parse("754,5")
        try require(abs(formatted - 754.5) < 0.001, "Не распознан формат ЧЧ:ММ:СС.ммм")
        try require(abs(seconds - 754.5) < 0.001, "Не распознаны секунды с запятой")
        let longTitle = String(repeating: "Название ", count: 8)
        let topic = TopicSegment(
            id: "topic-15",
            title: longTitle,
            start: 3_723.4,
            end: 3_785.2,
            duration: 1,
            keywords: [],
            cueIds: [1]
        )
        let pickerTitle = TopicPickerFormatter.title(for: topic)
        try require(
            pickerTitle.hasPrefix("topic-15 · 01:02:03–01:03:05 · 01:02 · "),
            "Список тем не показывает таймфрейминг и длительность"
        )
        try require(pickerTitle.hasSuffix("…"), "Длинное название темы не сокращено")
        try require(!pickerTitle.contains("00:01 ·"), "Список использует устаревшее поле duration вместо end-start")
        try require(TopicPickerFormatter.help(for: topic).contains(longTitle), "Подсказка не содержит полное название темы")
        do {
            _ = try TimecodeParser.parse("00:99:00")
            throw EndToEndError.failed("Некорректный таймкод принят")
        } catch is WorkflowError {}
    }

    private static func validateZeroDurationSubtitles() throws {
        let source = """
        1
        00:00:00,000 --> 00:00:01,000
        Первая реплика

        2
        00:00:01,000 --> 00:00:01,000
        Служебная реплика Whisper

        3
        00:00:01,000 --> 00:00:02,000
        Вторая реплика
        """
        let parsed = try SRTService().parseWithReport(source)
        try require(parsed.cues.map(\.id) == [1, 3], "Нулевая SRT-реплика не была пропущена")
        try require(parsed.skippedZeroDurationCount == 1, "Неверно посчитаны нулевые SRT-реплики")
        try require(SRTService().validateTimeline(parsed.cues, mediaDuration: 2).isEmpty, "Нормализованная временная шкала не прошла проверку")

        let backwards = "1\n00:00:02,000 --> 00:00:01,000\nОшибка\n"
        do {
            _ = try SRTService().parse(backwards)
            throw EndToEndError.failed("Обратный SRT-интервал ошибочно принят")
        } catch is WorkflowError {}
    }

    private static func validateUserOperationSurface() throws {
        try require(
            WorkflowOperation.userSelectable == [.transcribe, .translateTranscript, .topicTimecoding, .burnSubtitles],
            "В пользовательском меню присутствуют служебные операции"
        )
        try require(WorkflowOperation.transcribe.title == "Расшифровать всё видео", "Операция расшифровки не переименована")
    }

    private static func validateTopicResume(
        mediaURL: URL,
        projectURL: URL,
        modelPath: String
    ) async throws {
        let controller = ProcessController()
        let engine = WorkflowEngine(controller: controller)
        var log: [String] = []
        let settings = WorkflowSettings(
            mediaURL: mediaURL,
            projectURL: projectURL,
            selectedOperations: [.topicTimecoding],
            mode: .resumeProject,
            rangeStart: 0,
            rangeEnd: 1,
            fragmentName: "",
            burnFragmentSubtitles: false,
            subtitleStyle: .standard,
            selectedTopicID: nil,
            whisperModelPath: modelPath,
            whisperLanguage: "auto"
        )
        _ = try await engine.run(settings: settings, onLog: { log.append($0); print($0) })
        try require(!log.contains { $0.contains("Модель Whisper:") }, "Whisper запущен при восстановлении TXT и тематическом таймкодинге")
        let layout = ProjectLayout(root: projectURL)
        try require(nonemptyFile(at: layout.transcriptURL), "transcript.txt не восстановлен из SRT")
        try require(nonemptyFile(at: layout.topicsURL), "topics.json не создан из существующего SRT")
        try require(nonemptyFile(at: layout.topicsTextURL), "topics.txt не создан из существующего SRT")
        try require(log.contains { $0.contains("Восстановлен transcript.txt") }, "Восстановление transcript.txt не отражено в журнале")
        try require(log.contains { $0.contains("Запуск: Диагностика") }, "Диагностика не добавлена автоматически")
        try require(log.contains { $0.contains("Запуск: Манифест проекта") }, "Манифест не добавлен автоматически")
        try require(log.contains { $0.contains("Запуск: Проверка временной шкалы") }, "Проверка временной шкалы не добавлена автоматически")
        try require(
            log.contains { $0.contains("отсутствует или устарел") },
            "Устаревший topics.json не был явно отклонён"
        )
        try require(log.contains { $0.contains("Запуск: Тематический таймкодинг") }, "Тематический таймкодинг не выполнен")
        try require(log.contains { $0.contains("Запуск: Поиск результатов") }, "Обнаружение результатов не выполнено автоматически")
    }

    private static func installLegacyTopics(in projectURL: URL) throws {
        var file = try WorkflowEngine.loadTopics(projectURL: projectURL)
        file.schemaVersion = 1
        file.algorithmVersion = "legacy"
        file.adapter = "KeywordTopicAdapter"
        file.sourceSignature = ""
        file.status = .draft
        try TopicFileService().save(file, projectURL: projectURL)
        let manifest = try ProjectStore().load(from: projectURL)
        let language = manifest.languageProfile?.effective ?? .ru
        for granularity in TopicGranularity.allCases {
            var variant = file
            variant.granularity = granularity
            try TopicFileService().save(
                variant,
                projectURL: projectURL,
                language: language,
                granularity: granularity,
                updateLegacyFiles: false
            )
        }
    }

    @MainActor
    private static func validateLegacyTopicUIState(projectURL: URL) async throws {
        let model = WorkflowViewModel()
        model.openProject(projectURL)
        try require(model.topics.isEmpty, "Устаревшие темы доступны в рабочем интерфейсе")
        try require(model.selectedTopic == nil, "Устаревшая тема доступна для вырезки")
        try require(model.topicAnalysisMode == .hybrid, "Для устаревшего результата не выбран качественный пересчёт")
        try require(
            model.resultSummary.artifact(.topics)?.availability == .partial,
            "Устаревший таймкодинг не помечен как требующий пересчёта"
        )
    }

    private static func validateResultSummary(
        _ projectURL: URL,
        expectedFragments: Int,
        expectedTopics: ProjectArtifactAvailability
    ) throws {
        let summary = ProjectResultSummaryService().summarize(projectURL: projectURL)
        try require(summary.artifact(.transcription)?.availability == .ready, "Сводка не распознала готовую расшифровку")
        try require(summary.artifact(.timeline)?.availability == .ready, "Сводка не распознала проверенную временную шкалу")
        try require(summary.artifact(.topics)?.availability == expectedTopics, "Сводка неверно определила актуальность тематического таймкодинга")
        try require(summary.artifact(.subtitles)?.availability == .ready, "Сводка не распознала SRT")
        try require(summary.artifact(.subtitledVideo)?.availability == .ready, "Сводка не распознала видео с субтитрами")
        try require(summary.artifact(.diagnostics)?.availability == .ready, "Сводка не распознала диагностику")
        try require(summary.artifact(.manifest)?.availability == .ready, "Сводка не распознала манифест")
        try require(summary.artifact(.ffprobe)?.availability == .ready, "Сводка не распознала ffprobe")
        try require(summary.artifact(.discovery)?.availability == .ready, "Сводка не распознала обнаружение результатов")
        let fragments = summary.artifact(.fragments)
        let expectedState: ProjectArtifactAvailability = expectedFragments == 0 ? .missing : .ready
        try require(fragments?.availability == expectedState, "Сводка неверно определила наличие фрагментов")
        try require(fragments?.detail.contains("Фрагментов: \(expectedFragments)") == true, "Сводка неверно посчитала фрагменты")
    }

    private static func appendZeroDurationWhisperCue(to url: URL) throws {
        let service = SRTService()
        let cues = try service.load(from: url)
        guard let last = cues.last else { throw EndToEndError.failed("Нельзя добавить контрольную SRT-реплику") }
        var body = try String(contentsOf: url, encoding: .utf8)
        if !body.hasSuffix("\n\n") { body += body.hasSuffix("\n") ? "\n" : "\n\n" }
        body += "\(last.id + 1)\n\(service.formatTimestamp(last.end)) --> \(service.formatTimestamp(last.end))\nСлужебная реплика Whisper\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func validateProgress(
        _ snapshots: [WorkflowProgress],
        requireWhisperProgress: Bool,
        requireCompletion: Bool = true,
        requireETA: Bool = true
    ) throws {
        try require(!snapshots.isEmpty, "Не получены события прогресса")
        var previousOverall = 0.0
        var sawETA = false
        var sawWhisper = false
        for snapshot in snapshots {
            try require((0...1).contains(snapshot.overallFraction), "Общий процент вышел за диапазон")
            try require(snapshot.overallFraction + 0.000_001 >= previousOverall, "Общий процент уменьшился")
            previousOverall = snapshot.overallFraction
            if snapshot.estimatedTotal != nil, snapshot.remaining != nil { sawETA = true }
            if snapshot.operation == .transcribe, snapshot.operationFraction > 0, snapshot.operationFraction < 1 { sawWhisper = true }
        }
        if requireCompletion {
            try require(abs((snapshots.last?.overallFraction ?? 0) - 1) < 0.000_001, "Итоговый прогресс не достиг 100%")
        } else {
            try require((snapshots.last?.overallFraction ?? 1) < 1, "Приостановленный pipeline ошибочно достиг 100%")
        }
        if requireETA { try require(sawETA, "ETA ни разу не рассчитан") }
        if requireWhisperProgress { try require(sawWhisper, "Не получен промежуточный прогресс Whisper") }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func containsPartialFiles(_ root: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return false }
        return enumerator.allObjects.compactMap { $0 as? URL }.contains { $0.lastPathComponent.contains(".partial.") }
    }

    private static func noActiveTools() -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "comm="]
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        let activeNames = Set(text.split(separator: "\n").map { line in
            URL(fileURLWithPath: String(line).trimmingCharacters(in: .whitespacesAndNewlines)).lastPathComponent
        })
        return activeNames.isDisjoint(with: ["videotext", "whisper-cli", "ffmpeg", "ffprobe"])
    }

    private static func nonemptyFile(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.intValue > 0
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw EndToEndError.failed(message) }
    }
}
