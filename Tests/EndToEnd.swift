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

final class FailingHybridTopicAdapter: TopicAdapter {
    let name = "FailingHybridTopicAdapter"
    private(set) var calls = 0

    func buildTopics(
        from cues: [SubtitleCue],
        sourceSRT: URL,
        context: TopicBuildContext,
        onProgress: @escaping (Double) -> Void,
        onLog: @escaping (String) -> Void
    ) async throws -> TopicsFile {
        calls += 1
        throw WorkflowError.invalidTopics("Контрольная ошибка Hybrid Topic Engine.")
    }
}

final class RecordingTopicAdapter: TopicAdapter {
    let name = "RecordingTopicAdapter"
    private(set) var contexts: [TopicBuildContext] = []

    func buildTopics(
        from cues: [SubtitleCue],
        sourceSRT: URL,
        context: TopicBuildContext,
        onProgress: @escaping (Double) -> Void,
        onLog: @escaping (String) -> Void
    ) async throws -> TopicsFile {
        contexts.append(context)
        guard let first = cues.first, let last = cues.last else {
            throw WorkflowError.missingFullSRT
        }
        let source = try String(contentsOf: sourceSRT, encoding: .utf8)
        onProgress(1)
        return TopicsFile(
            schemaVersion: TopicAlgorithmIdentity.schemaVersion,
            algorithmVersion: TopicAlgorithmIdentity.hybridVersion,
            adapter: TopicAlgorithmIdentity.hybridAdapter,
            createdAt: Date(),
            sourceSRT: sourceSRT.path,
            sourceSignature: StableTopicHash.string(source),
            status: .ready,
            granularity: context.granularity,
            embeddingModel: "probe",
            languageModel: "probe",
            topics: [TopicSegment(
                id: "topic-1",
                title: "Проверка выбранного варианта",
                start: first.start,
                end: last.end,
                summary: "Проверяется запуск только выбранной детализации.",
                keywords: ["проверка", "вариант"],
                confidence: 1,
                boundaryReason: "probe",
                sourceCueStart: first.id,
                sourceCueEnd: last.id,
                cueIds: cues.map(\.id)
            )]
        )
    }
}

private struct E2ETranslationRow: Codable {
    var cueId: Int
    var text: String
}

private struct E2EContextIdentity: Encodable {
    var contract: String
    var cues: [SubtitleCue]
    var requests: [TranslationRequestCue]
}

// Observe the production HTTP seam without rewriting requests or model replies.
private actor E2ETranslationWire {
    static let digest = "c49d986b0764f5881c476eb21435bb62b7abc62347aab3d4a6071e811be510a1"
    static let protocolVersion = "translategemma-booktext-owned-cues-v5-docmeta512-lineage2-overlap2x600-source-anchor1-ctx8k"
    static let contract = "booktext-owned-cue-context-v1-docmeta512-lineage2-overlap2x600"

    let requests: [TranslationRequestCue]
    let contextIdentity: String
    private(set) var chats: [[Int]] = []
    private(set) var rows: [Int: String] = [:]
    private(set) var tagCalls = 0

    private let directory: URL
    private let scripted: ((URLRequest) throws -> Data)?
    private let ownershipUnitSize: Int
    private let started = Date()
    private var sequence = 0

    init(
        cues: [SubtitleCue],
        media: URL,
        directory: URL,
        ownershipUnitSize: Int = 32,
        scripted: ((URLRequest) throws -> Data)? = nil
    ) throws {
        self.directory = directory
        self.scripted = scripted
        self.ownershipUnitSize = ownershipUnitSize
        let parent = media.deletingLastPathComponent()
        let title = [
            parent.deletingLastPathComponent().lastPathComponent,
            parent.lastPathComponent,
            media.lastPathComponent
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " / ")
        let document = """
        Document type: timecoded spoken audio/video transcript. Short utterances may belong to different speakers.
        Document title (source metadata only): \(String(title.prefix(160)))
        Logical source units: original subtitle cues. Execution chunks are checkpoints, not semantic boundaries.
        """

        func neighbors(_ index: Int, _ direction: Int) -> [TranslationContextCue] {
            var result: [TranslationContextCue] = []
            var length = 0
            for distance in 1...2 {
                let next = index + distance * direction
                guard cues.indices.contains(next) else { break }
                let text = cues[next].text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard length + text.count + 1 <= 600 else { break }
                result.append(TranslationContextCue(id: cues[next].id, text: text))
                length += text.count + 1
            }
            return direction < 0 ? result.reversed() : result
        }

        requests = cues.indices.map { index in
            TranslationRequestCue(
                id: cues[index].id,
                text: cues[index].text,
                context: TranslationCueContext(
                    document: document,
                    before: neighbors(index, -1),
                    after: neighbors(index, 1)
                )
            )
        }
        contextIdentity = try TranslationFingerprint.value(
            E2EContextIdentity(contract: Self.contract, cues: cues, requests: requests)
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(cues).write(to: directory.appendingPathComponent("source-cues.json"))
        try JSONEncoder().encode(requests).write(to: directory.appendingPathComponent("expected-contexts.json"))
    }

    func send(_ request: URLRequest) async throws -> Data {
        sequence += 1
        let prefix = directory.appendingPathComponent(String(format: "wire-%03d", sequence))
        try (request.httpBody ?? Data()).write(to: prefix.appendingPathExtension("request.json"))
        var metadata: [String: Any] = [
            "url": request.url?.absoluteString ?? "",
            "method": request.httpMethod ?? "GET",
            "headers": request.allHTTPHeaderFields ?? [:],
            "timeout": request.timeoutInterval,
            "mode": scripted == nil ? "REAL_UNMODIFIED_TRANSPORT" : "MOCK_NO_NETWORK"
        ]
        do {
            try check(
                request.url?.host == "127.0.0.1" && request.url?.port == 11434,
                "Unexpected translation endpoint"
            )
            try check(Date().timeIntervalSince(started) < 2400, "Bounded translation exceeded 40 minutes")
            let owned = try validateRequest(request)
            let data: Data
            if let scripted {
                data = try scripted(request)
                metadata["httpStatus"] = 200
            } else {
                let (received, response) = try await URLSession.shared.data(for: request)
                data = received
                let http = response as? HTTPURLResponse
                metadata["httpStatus"] = http?.statusCode
                try check(http?.statusCode == 200, "Translation HTTP failure")
            }
            try data.write(to: prefix.appendingPathExtension("response.json"))
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            if request.url?.path == "/api/tags" {
                tagCalls += 1
                let models = root["models"] as? [[String: Any]] ?? []
                let model = models.first {
                    ($0["name"] as? String) == OllamaTranslationProvider.model
                        || ($0["model"] as? String) == OllamaTranslationProvider.model
                }
                try check(
                    model?["digest"] as? String == Self.digest,
                    "TranslateGemma digest differs from accepted model"
                )
            } else {
                try check(root["model"] as? String == OllamaTranslationProvider.model, "Chat response model differs")
                try check(
                    root["done"] as? Bool == true && root["done_reason"] as? String == "stop",
                    "Incomplete chat response"
                )
                let content = (root["message"] as? [String: Any])?["content"] as? String ?? ""
                let reply = try JSONDecoder().decode([E2ETranslationRow].self, from: Data(content.utf8))
                let replyIDs = reply.map(\.cueId)
                try check(
                    reply.count == owned.count && Set(replyIDs) == Set(owned) && Set(replyIDs).count == reply.count,
                    "Response emitted missing, duplicate or context-only IDs"
                )
                for row in reply {
                    rows[row.cueId] = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                .write(to: prefix.appendingPathExtension("metadata.json"))
            return data
        } catch {
            metadata["error"] = String(describing: error)
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                .write(to: prefix.appendingPathExtension("metadata.json"))
            throw error
        }
    }

    private func validateRequest(_ request: URLRequest) throws -> [Int] {
        if request.url?.path == "/api/tags" {
            try check(request.httpMethod == "GET" && request.httpBody == nil, "Unexpected identity request")
            return []
        }
        try check(request.url?.path == "/api/chat" && request.httpMethod == "POST", "Unexpected translation route")
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
        let options = body["options"] as? [String: Any] ?? [:]
        try check(
            body["model"] as? String == OllamaTranslationProvider.model && body["stream"] as? Bool == false,
            "Production translation model/stream changed"
        )
        try check(
            options["num_ctx"] as? Int == 8192 && options["temperature"] as? Int == 0,
            "Context/options changed"
        )
        let messages = body["messages"] as? [[String: String]] ?? []
        try check(messages.count == 1 && messages[0]["role"] == "user", "Unexpected prompt routing")
        let prompt = messages[0]["content"] ?? ""
        let ownedData = Data((prompt.components(separatedBy: "\n\n\n").last ?? "").utf8)
        let owned = try JSONDecoder().decode([TranslationContextCue].self, from: ownedData)
        let ids = owned.map(\.id)
        try check(
            !ids.isEmpty && ids.count <= ownershipUnitSize && Set(ids).count == ids.count,
            "Invalid owned content"
        )
        let expected = requests.filter { ids.contains($0.id) }
        try check(
            expected.map(\.id) == ids && zip(owned, expected).allSatisfy { $0.text == $1.text },
            "Owned source/order changed"
        )
        let indices = ids.compactMap { id in requests.firstIndex { $0.id == id } }
        try check(
            Set(indices.map { $0 / ownershipUnitSize }).count == 1,
            "Cross-checkpoint ownership routing"
        )
        let schema = body["format"] as? [String: Any] ?? [:]
        let properties = (schema["items"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        let idSchema = properties["cueId"] as? [String: Any] ?? [:]
        try check(
            schema["minItems"] as? Int == ids.count
                && schema["maxItems"] as? Int == ids.count
                && idSchema["enum"] as? [Int] == ids,
            "Output ownership schema changed"
        )

        func jsonLine<T: Decodable>(_ label: String, _ type: T.Type) throws -> T {
            let lines = prompt.components(separatedBy: "\n").filter { $0.hasPrefix(label) }
            try check(lines.count == 1, "Missing/duplicate context field: \(label)")
            return try JSONDecoder().decode(type, from: Data(lines[0].dropFirst(label.count).utf8))
        }

        let document = try jsonLine("DOCUMENT_CONTEXT (read-only quoted data): ", String.self)
        try check(expected.allSatisfy { $0.context?.document == document }, "Full-document metadata differs")
        let before = try jsonLine(
            "CONTEXT_BEFORE (read-only data, keys identify the owner whose context this is): ",
            [String: [TranslationContextCue]].self
        )
        let after = try jsonLine(
            "CONTEXT_AFTER (read-only data, keys identify the owner whose context this is): ",
            [String: [TranslationContextCue]].self
        )
        let ownedIDs = Set(ids)
        try check(
            Set(before.keys) == Set(ids.map(String.init)) && Set(after.keys) == Set(before.keys),
            "Context owner keys differ"
        )
        for cue in expected {
            try check(
                before[String(cue.id)] == cue.context?.before.filter { !ownedIDs.contains($0.id) }
                    && after[String(cue.id)] == cue.context?.after.filter { !ownedIDs.contains($0.id) },
                "Local overlap/context exclusion differs for \(cue.id)"
            )
        }
        chats.append(ids)
        try check(
            chats.count <= ((requests.count + ownershipUnitSize - 1) / ownershipUnitSize) * 2,
            "Unexpected extra translation chats"
        )
        return ids
    }

    private func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw EndToEndError.failed(message) }
    }
}

@main
struct EndToEndTest {
    static func main() async {
        do {
            if CommandLine.arguments == [CommandLine.arguments[0], "--translation-wire-self-test"] {
                try await validateTranslationWireMock()
                return
            }
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
            try await validateTranslationWireMock()
            try await validateUserOperationSurface()

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
            try require(topicCheckpoint.revisionIDs.count == 1, "Topic Human Review сохранил невыбранные варианты детализации")
            try validateOnlySelectedTopicVariant(
                projectURL: topicPausedResult.projectURL,
                language: .ru,
                granularity: .normal
            )
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
            try await validateRealTranslation(
                mediaURL: mediaURL,
                projectURL: initialResult.projectURL,
                modelPath: modelPath
            )
            try await validateExplicitTopicVariant(
                mediaURL: mediaURL,
                projectURL: initialResult.projectURL,
                modelPath: modelPath
            )
            try await validateHybridFailureDoesNotCreateDraft(
                mediaURL: mediaURL,
                projectURL: initialResult.projectURL,
                modelPath: modelPath
            )
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
            let processedFragment = try await resumeWithProcessedFragment(
                mediaURL: mediaURL,
                projectURL: initialResult.projectURL,
                modelPath: modelPath
            )
            try await validateProcessedFragment(processedFragment, projectURL: initialResult.projectURL)

            let finalManifest = try ProjectStore().load(from: initialResult.projectURL)
            try require(finalManifest.fragments?.count == 6, "Манифест не сохранил шесть фрагментов")
            try require(finalManifest.subtitleStyle == cyan, "Стиль субтитров не восстановится после перезапуска")
            try require(finalManifest.workflow?.operations[WorkflowOperation.transcribe.rawValue]?.outputPaths.isEmpty == false, "Операция расшифровки не сохранила выходные файлы")
            let fullSRTAfter = try Data(contentsOf: ProjectLayout(root: initialResult.projectURL).fullSRTURL)
            try require(fullSRTAfter == fullSRTBefore, "Продолжение изменило full.srt")
            try require(modificationDate(ProjectLayout(root: initialResult.projectURL).fullSRTURL) == srtDateBefore, "Продолжение повторно записало full.srt")
            try validateResultSummary(initialResult.projectURL, expectedFragments: 6, expectedTopics: .ready)
            try validateSourceMismatch(projectURL: initialResult.projectURL, parent: mediaURL.deletingLastPathComponent())

            try await validateCancellation(mediaURL: mediaURL, modelPath: modelPath, projectParent: mediaURL.deletingLastPathComponent())
            try await validateMissingAudioError(in: mediaURL.deletingLastPathComponent(), modelPath: modelPath)
            try validateLegacyManifestCompatibility(mediaURL: mediaURL, parent: mediaURL.deletingLastPathComponent())

            let finalHistory = ProjectHistoryStore().entries()
            try require(finalHistory.contains { $0.projectPath == initialResult.projectURL.path && $0.status == .completed }, "История не обновилась после продолжения")
            try require(noActiveTools(), "После E2E остались активные videotext/whisper-cli/ffmpeg/ffprobe")

            print("E2E PASS: Human Review, real TranslateGemma BookText ownership/cache/resume/provenance, gemma3 topics, fragments, ffprobe and cancellation")
            print("QA_PROJECT=\(initialResult.projectURL.path)")
        } catch {
            fputs("E2E FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func validateRealTranslation(
        mediaURL: URL,
        projectURL: URL,
        modelPath: String
    ) async throws {
        let layout = ProjectLayout(root: projectURL)
        let store = ProjectStore()
        let before = try store.load(from: projectURL)
        try require(before.languageProfile?.effective == .ru, "Release translation requires the retained Russian media")
        try require(
            (before.durationSeconds ?? 0) > 0 && (before.durationSeconds ?? 0) <= 190,
            "Translation media exceeds the bounded short-media contract"
        )

        let sourceURL = layout.subtitlesURL(language: .ru)
        let source = try SRTService().load(from: sourceURL)
        try require((1...128).contains(source.count), "Bounded full-document translation needs 1...128 cues")
        let sourceFiles = [
            layout.fullSRTURL,
            layout.transcriptURL,
            sourceURL,
            layout.transcriptURL(language: .ru)
        ]
        let sourceBytes = try sourceFiles.map { try Data(contentsOf: $0) }
        let sourceDates = sourceFiles.map { modificationDate($0) }
        let evidenceRoot = ProcessInfo.processInfo.environment["QA_E2E_EVIDENCE_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? mediaURL.deletingLastPathComponent()
        let evidence = evidenceRoot
            .appendingPathComponent("real-translation-\(UUID().uuidString)", isDirectory: true)
        let defaultAdapter = TranslationAdapter()
        try require(
            defaultAdapter.batchSize == 32 && defaultAdapter.maximumAttempts == 2,
            "Default translation execution policy changed"
        )
        let wire = try E2ETranslationWire(cues: source, media: mediaURL, directory: evidence)
        let provider = OllamaTranslationProvider(transport: { try await wire.send($0) })
        let adapter = TranslationAdapter(provider: provider)
        try require(
            OllamaTranslationProvider.model == "translategemma:4b"
                && OllamaTranslationProvider.protocolVersion == E2ETranslationWire.protocolVersion
                && TranslationContextPlan.contract == E2ETranslationWire.contract,
            "Accepted model/protocol/context contract changed"
        )
        let settings = WorkflowSettings(
            mediaURL: mediaURL,
            projectURL: projectURL,
            selectedOperations: [.translateTranscript],
            mode: .resumeProject,
            rangeStart: 0,
            rangeEnd: 1,
            fragmentName: "",
            burnFragmentSubtitles: false,
            subtitleStyle: .standard,
            selectedTopicID: nil,
            whisperModelPath: modelPath,
            whisperLanguage: "auto",
            sourceHumanReviewEnabled: false,
            translationHumanReviewEnabled: false,
            fillerAnalysisBeforeReview: false
        )

        func engine(_ controller: ProcessController) -> WorkflowEngine {
            WorkflowEngine(controller: controller, translationAdapter: adapter)
        }

        func assertSourceUnchanged() throws {
            for (index, url) in sourceFiles.enumerated() {
                let currentBytes = try Data(contentsOf: url)
                try require(currentBytes == sourceBytes[index], "Translation changed source bytes: \(url.path)")
                try require(modificationDate(url) == sourceDates[index], "Translation rewrote source: \(url.path)")
            }
        }

        func saveManifest(_ name: String) throws {
            let manifestBytes = try Data(contentsOf: layout.manifestURL)
            try manifestBytes.write(to: evidence.appendingPathComponent(name))
        }

        let identity = TranslationModelIdentity(
            model: OllamaTranslationProvider.model,
            digest: E2ETranslationWire.digest,
            protocolVersion: E2ETranslationWire.protocolVersion
        )
        let plan = try TranslationContextPlan(
            cues: source,
            documentTitle: TranslationContextPlan.documentTitle(for: mediaURL),
            chunkSize: defaultAdapter.batchSize
        )
        let wireContextIdentity = wire.contextIdentity
        try require(
            plan.contextIdentity == wireContextIdentity,
            "Independent full-document context fingerprint differs"
        )
        let current = try store.load(from: projectURL)
        guard let sourceRevision = current.activeTranscriptRevision(for: .ru) else {
            throw EndToEndError.failed("Translation lost the source revision")
        }
        let checkpoints = try TranslationCheckpointStore(
            directory: layout.translationCacheDirectory(source: .ru, target: .en),
            plan: plan,
            identity: identity,
            source: .ru,
            target: .en,
            sourceIdentity: sourceRevision.id
        )
        let executionController = ProcessController()
        let resumed = try await engine(executionController).run(settings: settings, onLog: { print($0) })
        try require(
            resumed.checkpoint == nil && resumed.topicReviewCheckpoint == nil,
            "Translation unexpectedly opened a review checkpoint"
        )
        let chats = await wire.chats
        try require(
            chats == plan.units.map { $0.owned.map(\.id) },
            "Resume repeated completed ownership or made extra chats"
        )
        let translated = try SRTService().load(from: layout.subtitlesURL(language: .en))
        try require(
            translated.count == source.count
                && translated.map(\.id) == source.map(\.id)
                && zip(source, translated).allSatisfy { $0.start == $1.start && $0.end == $1.end },
            "Translation changed exact count/IDs/order/times"
        )
        let rawRows = await wire.rows
        try require(
            Set(rawRows.keys) == Set(source.map(\.id))
                && translated.allSatisfy { rawRows[$0.id] == $0.text },
            "Final SRT contains fallback, context-only output or differs from real owned replies"
        )

        let reportURL = layout.translationReportURL(source: .ru, target: .en)
        let reportBytes = try Data(contentsOf: reportURL)
        let report = try store.decoder.decode(TranslationReport.self, from: reportBytes)
        let (manifest, reopenedMedia) = try ProjectStore().openProject(at: projectURL)
        try require(
            reopenedMedia.standardizedFileURL == mediaURL.standardizedFileURL,
            "Translated project reopened the wrong source"
        )
        try require(
            report.schemaVersion == 3
                && report.sourceRevisionID == sourceRevision.id
                && report.cueCount == source.count
                && report.sourceLanguage == .ru
                && report.targetLanguage == .en
                && report.status == .ready
                && report.reviewTaskIDs.isEmpty,
            "Translation report has unresolved technical validation or wrong source lineage"
        )
        try require(
            report.model == identity.model
                && report.modelDigest == identity.digest
                && report.protocolVersion == identity.protocolVersion
                && report.contextIdentity == wireContextIdentity,
            "Translation report lost exact model/protocol/context provenance"
        )
        let translatedSubtitleBytes = try Data(contentsOf: layout.subtitlesURL(language: .en))
        let translatedTranscriptBytes = try Data(contentsOf: layout.transcriptURL(language: .en))
        try require(
            report.subtitleSHA256 == TranslationFingerprint.data(translatedSubtitleBytes)
                && report.transcriptSHA256 == TranslationFingerprint.data(translatedTranscriptBytes),
            "Translation output hashes differ"
        )
        guard let revision = manifest.activeTranscriptRevision(for: .en) else {
            throw EndToEndError.failed("Reopened manifest lost translated revision")
        }
        try require(
            revision.id == report.targetRevisionID
                && revision.origin == .translated
                && revision.parentRevisionID == sourceRevision.id,
            "Manifest translation ownership lineage differs"
        )
        let artifacts = manifest.artifacts ?? []
        for id in [revision.transcriptArtifactID, revision.subtitleArtifactID] {
            try require(
                artifacts.contains {
                    $0.id == id
                        && $0.model == identity.model
                        && $0.sourceRevision == revision.id
                        && $0.validationStatus == .ready
                },
                "Manifest lost a ready translated artifact: \(id)"
            )
        }
        try require(
            manifest.workflow?.operations[WorkflowOperation.translateTranscript.rawValue]?.status == .completed,
            "Manifest did not complete translation"
        )
        try saveManifest("manifest-translated.json")

        let outputs = [
            layout.subtitlesURL(language: .en),
            layout.transcriptURL(language: .en),
            reportURL
        ]
        let outputBytes = try outputs.map { try Data(contentsOf: $0) }
        let outputDates = outputs.map { modificationDate($0) }
        let reopenedController = ProcessController()
        _ = try await engine(reopenedController).run(settings: settings, onLog: { print($0) })
        let chatsAfterCompletedResume = await wire.chats
        try require(chatsAfterCompletedResume == chats, "Completed resume unnecessarily called chat")
        for (index, url) in outputs.enumerated() {
            let currentBytes = try Data(contentsOf: url)
            try require(
                currentBytes == outputBytes[index] && modificationDate(url) == outputDates[index],
                "Completed resume rewrote translation output"
            )
        }

        // Rebuild only the generated report from the real persisted unit checkpoints.
        try FileManager.default.removeItem(at: reportURL)
        let cachedController = ProcessController()
        _ = try await engine(cachedController).run(settings: settings, onLog: { print($0) })
        let chatsAfterCheckpointReplay = await wire.chats
        try require(chatsAfterCheckpointReplay == chats, "Real checkpoint replay unnecessarily called chat")
        let rebuiltBytes = try Data(contentsOf: reportURL)
        let rebuilt = try store.decoder.decode(TranslationReport.self, from: rebuiltBytes)
        try require(
            rebuilt.targetRevisionID == report.targetRevisionID
                && rebuilt.modelDigest == report.modelDigest
                && rebuilt.protocolVersion == report.protocolVersion
                && rebuilt.contextIdentity == report.contextIdentity
                && rebuilt.reviewTaskIDs.isEmpty
                && rebuilt.status == .ready,
            "Checkpoint replay changed provenance or left review issues"
        )
        for (index, url) in outputs.prefix(2).enumerated() {
            let currentBytes = try Data(contentsOf: url)
            try require(currentBytes == outputBytes[index], "Checkpoint replay changed translated bytes")
        }
        for unit in plan.units {
            try require(
                checkpoints.load(unit).map(\.cueID) == unit.owned.map(\.id),
                "Checkpoint ownership is incomplete"
            )
        }
        let tagCalls = await wire.tagCalls
        try require(
            tagCalls == 2,
            "Initial translation and checkpoint replay did not perform the expected model identity checks"
        )
        for controller in [executionController, reopenedController, cachedController] {
            try require(
                !controller.launchedExecutables.contains {
                    URL(fileURLWithPath: $0).lastPathComponent == "whisper-cli"
                },
                "Translation resume unnecessarily launched Whisper"
            )
        }
        try assertSourceUnchanged()
        try saveManifest("manifest-cache-replayed.json")
        try require(noActiveTools(), "Translation left active child processes")
        print("REAL_TRANSLATION_PASS: full document metadata/local overlap/owned routing, exact cue IDs/count/order/times, source bytes, completed resume, real checkpoint replay, manifest/reopen, pinned digest/protocol/context")
        print("TRANSLATION_EVIDENCE=\(evidence.path)")
    }

    private static func validateTranslationWireMock() async throws {
        guard let path = ProcessInfo.processInfo.environment["QA_E2E_EVIDENCE_DIR"] else {
            throw EndToEndError.failed("Mock checks require an owned evidence directory")
        }
        let directory = URL(fileURLWithPath: path)
            .appendingPathComponent("wire-mock-\(UUID().uuidString)", isDirectory: true)
        let media = directory.appendingPathComponent("recording.mp4")
        let cues: [SubtitleCue] = (0..<35).map { index -> SubtitleCue in
            SubtitleCue(
                id: index * 3 + 7,
                start: Double(index * 2) + 0.125,
                end: Double(index * 2) + 1.625,
                text: "Проверяем запись номер \(index)."
            )
        }
        let wire = try E2ETranslationWire(
            cues: cues,
            media: media,
            directory: directory,
            scripted: { request in
                if request.url?.path == "/api/tags" {
                    return try JSONSerialization.data(withJSONObject: [
                        "models": [[
                            "name": OllamaTranslationProvider.model,
                            "digest": E2ETranslationWire.digest
                        ]]
                    ])
                }
                let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
                let messages = body["messages"] as? [[String: String]] ?? []
                let message = messages.first?["content"] ?? ""
                let ownedData = Data((message.components(separatedBy: "\n\n\n").last ?? "").utf8)
                let owned = try JSONDecoder().decode([TranslationContextCue].self, from: ownedData)
                let rows = owned.reversed().map { cue in
                    E2ETranslationRow(
                        cueId: cue.id,
                        text: "  We check record number \((cue.id - 7) / 3).\n"
                    )
                }
                return try JSONSerialization.data(withJSONObject: [
                    "model": OllamaTranslationProvider.model,
                    "done": true,
                    "done_reason": "stop",
                    "message": [
                        "content": String(decoding: try JSONEncoder().encode(rows), as: UTF8.self)
                    ]
                ])
            }
        )
        let adapter = TranslationAdapter(
            provider: OllamaTranslationProvider(transport: { try await wire.send($0) })
        )
        let cache = directory.appendingPathComponent("cache")

        func run(_ cancel: Bool) async throws -> TranslationAdapterResult {
            try await adapter.translate(
                cues: cues,
                source: ArtifactLanguage.ru,
                target: ArtifactLanguage.en,
                documentTitle: TranslationContextPlan.documentTitle(for: media),
                sourceIdentity: "mock-source",
                checkpointDirectory: cache,
                onProgress: { fraction in
                    if cancel && fraction > 0 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                },
                onLog: { print($0) }
            )
        }

        let stopped = Task { try await run(true) }
        do {
            _ = try await stopped.value
            throw EndToEndError.failed("Mock checkpoint cancellation failed")
        } catch is CancellationError {
            // Expected after the first persisted ownership unit.
        }
        let result = try await run(false)
        let replay = try await run(false)
        let chats = await wire.chats
        let firstOwnedIDs = cues.prefix(32).map { $0.id }
        let secondOwnedIDs = cues.suffix(3).map { $0.id }
        try require(
            chats == [firstOwnedIDs, secondOwnedIDs],
            "Mock replay repeated chat"
        )
        let wireContextIdentity = wire.contextIdentity
        try require(
            result.issues.isEmpty
                && replay.issues.isEmpty
                && result.contextIdentity == wireContextIdentity,
            "Mock adapter/context validation failed"
        )
        let sourceIDs = cues.map { $0.id }
        try require(
            result.cues.map(\.id) == sourceIDs
                && zip(cues, result.cues).allSatisfy {
                    $0.start == $1.start && $0.end == $1.end
                },
            "Mock reordered reply changed exact IDs/times"
        )
        try require(
            zip(result.cues, replay.cues).allSatisfy { $0.text == $1.text },
            "Mock checkpoint replay changed text"
        )
        print("TRANSLATION_WIRE_MOCK_PASS: independent context oracle, exact HTTP envelope, reordered rows, cancellation/persisted prefix, resume/cache without extra chat; no network or semantic verdict")
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
        try require(file.languageModel == "gemma3:4b", "Темы построены не через gemma3:4b")
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

    private static func validateOnlySelectedTopicVariant(
        projectURL: URL,
        language: ArtifactLanguage,
        granularity: TopicGranularity
    ) throws {
        let layout = ProjectLayout(root: projectURL)
        for candidate in TopicGranularity.allCases {
            let exists = FileManager.default.fileExists(
                atPath: layout.topicsURL(language: language, granularity: candidate).path
            )
            try require(
                exists == (candidate == granularity),
                "Создан невыбранный набор тем \(language.rawValue)/\(candidate.rawValue)"
            )
        }
        let legacy = try WorkflowEngine.loadTopics(projectURL: projectURL)
        try require(legacy.granularity == granularity, "Совместимый topics.json указывает не на выбранный вариант")
    }

    private static func validateExplicitTopicVariant(
        mediaURL: URL,
        projectURL: URL,
        modelPath: String
    ) async throws {
        let variantProject = projectURL
            .deletingLastPathComponent()
            .appendingPathComponent("Контрольный выбранный вариант тем", isDirectory: true)
        try? FileManager.default.removeItem(at: variantProject)
        try FileManager.default.copyItem(at: projectURL, to: variantProject)
        defer { try? FileManager.default.removeItem(at: variantProject) }

        let store = ProjectStore()
        let layout = ProjectLayout(root: variantProject)
        try? FileManager.default.removeItem(at: layout.topicsURL)
        try? FileManager.default.removeItem(at: layout.topicsTextURL)
        for language in ArtifactLanguage.allCases {
            for granularity in TopicGranularity.allCases {
                try? FileManager.default.removeItem(at: layout.topicsURL(language: language, granularity: granularity))
                try? FileManager.default.removeItem(at: layout.topicsTextURL(language: language, granularity: granularity))
            }
        }
        try store.mutate(variantProject) { manifest in
            manifest.topicRevisions = []
            manifest.topicReviewState = .newProjectDefault
            manifest.artifacts = manifest.artifacts?.filter { $0.kind != .topics }
        }

        let adapter = RecordingTopicAdapter()
        let settings = WorkflowSettings(
            mediaURL: mediaURL,
            projectURL: variantProject,
            selectedOperations: [.topicTimecoding],
            mode: .resumeProject,
            rangeStart: 0,
            rangeEnd: 1,
            fragmentName: "",
            burnFragmentSubtitles: false,
            subtitleStyle: .standard,
            selectedTopicID: nil,
            whisperModelPath: modelPath,
            whisperLanguage: "auto",
            topicGranularity: .coarse,
            artifactLanguage: .ru,
            sourceHumanReviewEnabled: false,
            fillerAnalysisBeforeReview: false,
            topicHumanReviewEnabled: false
        )
        _ = try await WorkflowEngine(store: store, hybridTopicAdapter: adapter).run(
            settings: settings,
            onLog: { _ in }
        )
        try require(
            adapter.contexts.map { "\($0.language.rawValue)-\($0.granularity.rawValue)" } == ["ru-coarse"],
            "Workflow запустил несколько или неверный вариант тематического таймкодинга"
        )
        try validateOnlySelectedTopicVariant(projectURL: variantProject, language: .ru, granularity: .coarse)
        let outputPaths = try store.load(from: variantProject)
            .workflow?.operations[WorkflowOperation.topicTimecoding.rawValue]?.outputPaths ?? []
        let unexpected = outputPaths.filter { $0.contains("detailed") || $0.contains("normal") }
        try require(unexpected.isEmpty, "В результатах операции записаны невыбранные варианты: \(unexpected.joined(separator: ", "))")
    }

    private static func validateHybridFailureDoesNotCreateDraft(
        mediaURL: URL,
        projectURL: URL,
        modelPath: String
    ) async throws {
        let failureProject = projectURL
            .deletingLastPathComponent()
            .appendingPathComponent("Контрольный отказ тематического анализа", isDirectory: true)
        try? FileManager.default.removeItem(at: failureProject)
        try FileManager.default.copyItem(at: projectURL, to: failureProject)
        defer { try? FileManager.default.removeItem(at: failureProject) }

        let store = ProjectStore()
        let layout = ProjectLayout(root: failureProject)
        var manifest = try store.ensureProject(at: failureProject, mediaURL: mediaURL, mode: .resumeProject)
        manifest.topicRevisions = []
        manifest.topicReviewState = .newProjectDefault
        manifest.artifacts = manifest.artifacts?.filter { $0.kind != .topics }
        try store.save(manifest, to: failureProject)
        // The copied completed project has compatibility aliases for the selected
        // topic set. Remove them too, otherwise this negative test sees old output.
        try? FileManager.default.removeItem(at: layout.topicsURL)
        try? FileManager.default.removeItem(at: layout.topicsTextURL)
        for language in ArtifactLanguage.allCases {
            for granularity in TopicGranularity.allCases {
                try? FileManager.default.removeItem(at: layout.topicsURL(language: language, granularity: granularity))
                try? FileManager.default.removeItem(at: layout.topicsTextURL(language: language, granularity: granularity))
            }
        }

        let hybrid = FailingHybridTopicAdapter()
        let settings = WorkflowSettings(
            mediaURL: mediaURL,
            projectURL: failureProject,
            selectedOperations: [.topicTimecoding],
            mode: .resumeProject,
            rangeStart: 0,
            rangeEnd: 1,
            fragmentName: "",
            burnFragmentSubtitles: false,
            subtitleStyle: .standard,
            selectedTopicID: nil,
            whisperModelPath: modelPath,
            whisperLanguage: "auto",
            sourceHumanReviewEnabled: false,
            fillerAnalysisBeforeReview: false,
            topicHumanReviewEnabled: true
        )
        do {
            _ = try await WorkflowEngine(
                store: store,
                hybridTopicAdapter: hybrid
            ).run(settings: settings, onLog: { _ in })
            throw EndToEndError.failed("Сбой Hybrid Topic Engine ошибочно признан успешной обработкой")
        } catch WorkflowError.invalidTopics(let message) {
            try require(message.contains("Контрольная ошибка"), "Workflow потерял исходную ошибку Hybrid Topic Engine")
        }

        let failed = try store.load(from: failureProject)
        try require(hybrid.calls == 1, "Hybrid Topic Engine не был вызван ровно один раз")
        try require(failed.workflow?.status == .failed, "Сбой тематического анализа не получил статус ошибки")
        try require(failed.topicReviewState?.pendingCheckpoint == nil, "Неуспешный тематический анализ открыл Human Review")
        try require(!FileManager.default.fileExists(atPath: layout.topicsURL.path), "Неуспешный Hybrid-анализ создал topics.json")
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

    private static func resumeWithProcessedFragment(
        mediaURL: URL,
        projectURL: URL,
        modelPath: String
    ) async throws -> FragmentRecord {
        let layout = ProjectLayout(root: projectURL)
        let fillerReport = try? FillerWordService().load(from: layout.fillerWordsURL)
        let hasFillerInRange = fillerReport?.candidates.contains { $0.end > 1 && $0.start < 6 } == true
        let projectStyle = try ProjectStore().load(from: projectURL).subtitleStyle ?? .standard
        let settings = WorkflowSettings(
            mediaURL: mediaURL,
            projectURL: projectURL,
            selectedOperations: [.renderFragment],
            mode: .resumeProject,
            rangeStart: 1,
            rangeEnd: 6,
            fragmentName: "Итоговый вариант E2E",
            burnFragmentSubtitles: true,
            subtitleStyle: projectStyle,
            selectedTopicID: nil,
            whisperModelPath: modelPath,
            whisperLanguage: "auto",
            speedFactor: 1.1,
            blurRegion: NormalizedVideoRect(x: 0.65, y: 0.05, width: 0.25, height: 0.2),
            blurIntensity: 6,
            fillerMode: .muteAll,
            sourceHumanReviewEnabled: true,
            topicHumanReviewEnabled: true,
            fragmentMuteFillerWords: hasFillerInRange,
            fragmentAdjustSpeed: true,
            fragmentApplyBlur: true
        )
        let before = (try ProjectStore().load(from: projectURL).fragments ?? []).count
        var log: [String] = []
        _ = try await WorkflowEngine().run(
            settings: settings,
            onLog: { log.append($0); print($0) }
        )
        try require(!log.contains { $0.contains("Модель Whisper:") }, "Итоговый вариант повторно запустил Whisper")
        let fragments = try ProjectStore().load(from: projectURL).fragments ?? []
        try require(fragments.count == before + 1, "Обработанный фрагмент не зарегистрирован")
        guard let fragment = fragments.first else { throw EndToEndError.failed("Обработанный фрагмент не найден") }
        try require(fragment.processingRecipe?.muteFillerWords == hasFillerInRange, "Рецепт неверно сохранил режим mute")
        return fragment
    }

    private static func validateProcessedFragment(
        _ fragment: FragmentRecord,
        projectURL: URL
    ) async throws {
        guard let outputPath = fragment.processedVideoPath,
              let recipe = fragment.processingRecipe else {
            throw EndToEndError.failed("Нет итогового файла или рецепта обработанного фрагмента")
        }
        let outputURL = URL(fileURLWithPath: outputPath)
        try require(nonemptyFile(at: outputURL), "Обработанный видеофрагмент пуст")
        try require(fragment.videoPath == outputPath, "Технический cut остался основным видео фрагмента")
        try require(recipe.adjustSpeed && recipe.applyBlur && recipe.burnSubtitles, "Рецепт потерял выбранные эффекты")
        try require(abs(recipe.speedFactor - 1.1) < 0.001, "Рецепт сохранил неверную скорость")
        let expectedDuration = (fragment.end - fragment.start) / recipe.speedFactor
        let duration = try await FFmpegAdapter().duration(of: outputURL)
        try require(duration.map { abs($0 - expectedDuration) <= 0.25 } == true, "Обработанный фрагмент имеет неверную длительность")
        let layout = ProjectLayout(root: projectURL)
        try require(nonemptyFile(at: layout.processedFragmentSRTURL(kind: fragment.id)), "Нет SRT обработанного фрагмента")
        try require(nonemptyFile(at: layout.processedFragmentRecipeURL(kind: fragment.id)), "Нет JSON-рецепта обработанного фрагмента")
        try require(!FileManager.default.fileExists(atPath: layout.fragmentVideoURL(kind: fragment.id).path), "После успеха остался технический cut")
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
        let png = (URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path, isDirectory: true)).appendingPathComponent("videotext-color-\(UUID().uuidString).png")
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
        for y in stride(from: startY, to: endY, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = color.redComponent * 255
                let g = color.greenComponent * 255
                let b = color.blueComponent * 255
                switch expected {
                case .yellow where r > 180 && g > 140 && b < 150: matches += 1
                case .cyan where r < 170 && g > 150 && b > 180: matches += 1
                default: break
                }
            }
        }
        return matches >= 8
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

    @MainActor
    private static func validateUserOperationSurface() async throws {
        try require(
            WorkflowOperation.userSelectable == [.transcribe, .translateTranscript, .topicTimecoding, .burnSubtitles],
            "В пользовательском меню присутствуют служебные операции"
        )
        try require(WorkflowOperation.transcribe.title == "Расшифровать всё видео", "Операция расшифровки не переименована")
        try require(
            WorkflowViewModel().topicGranularity == .normal,
            "Новый проект не использует обычную детализацию тем по умолчанию"
        )
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
