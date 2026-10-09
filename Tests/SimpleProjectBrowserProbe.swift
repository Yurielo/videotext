import Foundation

@main
struct SimpleProjectBrowserProbe {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("videotext-simple-browser-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectURL = root.appendingPathComponent("Рабочий проект", isDirectory: true)
        let layout = ProjectLayout(root: projectURL)
        try layout.createDirectories()
        let sourceURL = root.appendingPathComponent("source.mp4")
        try Data([0x01]).write(to: sourceURL)
        try "Тестовая расшифровка".write(to: layout.transcriptURL, atomically: true, encoding: .utf8)
        try "1\n00:00:00,000 --> 00:00:01,000\nТестовая расшифровка\n".write(
            to: layout.fullSRTURL,
            atomically: true,
            encoding: .utf8
        )
        try Data([0x01]).write(to: layout.subtitledVideoURL)

        let historyURL = root.appendingPathComponent("history.json")
        let historyStore = ProjectHistoryStore(indexURL: historyURL)
        let revision = TranscriptRevision(
            id: "source-ru",
            language: .ru,
            origin: .machineGenerated,
            parentRevisionID: nil,
            transcriptArtifactID: "source-text",
            subtitleArtifactID: "source-srt",
            contentHash: "source-hash",
            createdAt: Date(),
            reviewStatus: .approved
        )
        let fragmentVideoURL = root.appendingPathComponent("fragment.mp4")
        try Data([0x01]).write(to: fragmentVideoURL)
        let fragment = FragmentRecord(
            id: "fragment-1",
            name: "Фрагмент",
            start: 0,
            end: 1,
            createdAt: Date(),
            videoPath: fragmentVideoURL.path,
            subtitlePath: "/tmp/fragment.srt",
            subtitledVideoPath: nil,
            ffprobeReportPath: nil,
            style: .standard
        )
        let manifest = ProjectManifest(
            appName: "videotext",
            appVersion: "0.6.8",
            build: "test",
            createdAt: Date(),
            updatedAt: Date(),
            sourceMediaPath: sourceURL.path,
            projectFolderPath: projectURL.path,
            durationSeconds: 42,
            outputs: [],
            diagnostics: nil,
            schemaVersion: ProjectSchema.currentVersion,
            sourceFingerprint: nil,
            workflow: ProjectWorkflowState(status: .completed, progress: 1, mode: .resumeProject, operations: [:], lastError: nil),
            fragments: [fragment],
            subtitleStyle: .standard,
            artifacts: [],
            languageProfile: LanguageProfile(
                detected: .ru,
                effective: .ru,
                confidence: 1,
                method: "test",
                model: nil,
                modelVersion: nil,
                sampleRanges: [],
                manuallyOverridden: false,
                detectedAt: Date()
            ),
            transcriptRevisions: [revision],
            reviewTasks: [],
            humanReviewState: HumanReviewState(
                sourceReviewEnabled: true,
                translationReviewEnabled: true,
                fillerAnalysisBeforeReview: true,
                activeRevisionIDs: ["ru": revision.id],
                draftRevisionIDs: [:],
                pendingCheckpoint: nil
            )
        )
        try ProjectStore(history: historyStore).save(manifest, to: projectURL)

        let missingPath = root.appendingPathComponent("Перемещённый проект", isDirectory: true).path
        let stale = ProjectHistoryEntry(
            projectPath: missingPath,
            sourceMediaPath: "/tmp/missing.mp4",
            mediaName: "Перемещённый проект",
            createdAt: Date(),
            updatedAt: Date().addingTimeInterval(60),
            status: .ready,
            progress: 0,
            completedOperations: []
        )
        let corruptProjectURL = root.appendingPathComponent("Повреждённый проект", isDirectory: true)
        let corruptLayout = ProjectLayout(root: corruptProjectURL)
        try corruptLayout.createDirectories()
        try Data("{not-json".utf8).write(to: corruptLayout.manifestURL)
        let corrupt = ProjectHistoryEntry(
            projectPath: corruptProjectURL.path,
            sourceMediaPath: sourceURL.path,
            mediaName: "corrupt.mp4",
            createdAt: Date(),
            updatedAt: Date().addingTimeInterval(30),
            status: .failed,
            progress: 0,
            completedOperations: []
        )
        var history = historyStore.allEntries()
        history.append(contentsOf: [stale, corrupt])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(history).write(to: historyURL, options: .atomic)

        try ProjectStore(history: historyStore).save(manifest, to: projectURL)

        let allHistory = historyStore.allEntries()
        try expect(allHistory.count == 3, "Project Browser должен сохранять stale и corrupt history")
        try expect(allHistory.first?.projectPath == missingPath, "История должна оставаться отсортированной по updatedAt")
        try expect(historyStore.entries().count == 2, "Advanced history не должна менять прежнюю фильтрацию missing manifest")

        let entries = SimpleProjectBrowserStateService(historyStore: historyStore).entries()
        let available = try required(entries.first { $0.id == projectURL.path }, "Рабочий проект отсутствует")
        let unavailable = try required(entries.first { $0.id == missingPath }, "Stale проект отсутствует")
        let corruptEntry = try required(entries.first { $0.id == corruptProjectURL.path }, "Corrupt проект отсутствует")

        try expect(available.isAvailable, "Рабочий проект ошибочно помечен отсутствующим")
        try expect(available.home?.sourceLanguage == .ru, "Project Browser не показывает язык источника")
        try expect(available.home?.artifact(.transcription).readiness == .ready, "Project Browser не показывает готовую расшифровку")
        try expect(available.home?.artifact(.topics).readiness == .missing, "Project Browser выдумал готовые темы")
        try expect(available.home?.artifact(.translation).readiness == .missing, "Project Browser выдумал готовый перевод")
        try expect(available.generatedVideoCount == 1, "Project Browser неверно считает готовые видео")
        try expect(available.fragmentCount == 1, "Project Browser неверно считает фрагменты")
        try expect(!unavailable.isAvailable && unavailable.home == nil, "Missing проект должен быть показан честно, без snapshot")
        try expect(unavailable.availabilityIssue != nil, "Missing проект должен объяснять недоступность")
        try expect(!corruptEntry.isAvailable, "Corrupt проект нельзя предлагать для открытия")
        try expect(corruptEntry.availabilityIssue == "Проект повреждён или несовместим", "Corrupt manifest ошибочно назван отсутствующим")

        let emptyText = root.appendingPathComponent("empty.txt")
        let malformedSRT = root.appendingPathComponent("malformed.srt")
        let overlappingSRT = root.appendingPathComponent("overlapping.srt")
        let outOfRangeSRT = root.appendingPathComponent("out-of-range.srt")
        try Data().write(to: emptyText)
        try "not an srt".write(to: malformedSRT, atomically: true, encoding: .utf8)
        try "1\n00:00:00,000 --> 00:00:02,000\nПервый\n\n2\n00:00:01,500 --> 00:00:03,000\nВторой\n".write(
            to: overlappingSRT,
            atomically: true,
            encoding: .utf8
        )
        try "1\n00:00:44,000 --> 00:00:45,000\nПоздний\n".write(
            to: outOfRangeSRT,
            atomically: true,
            encoding: .utf8
        )
        let validator = SimpleProjectArtifactValidator()
        let invalidOutputs = [
            ProjectOutput(id: emptyText.path, kind: "localized-transcript", path: emptyText.path, createdAt: Date()),
            ProjectOutput(id: malformedSRT.path, kind: "localized-subtitles", path: malformedSRT.path, createdAt: Date()),
            ProjectOutput(id: overlappingSRT.path, kind: "localized-subtitles", path: overlappingSRT.path, createdAt: Date()),
            ProjectOutput(id: outOfRangeSRT.path, kind: "localized-subtitles", path: outOfRangeSRT.path, createdAt: Date())
        ]
        try expect(
            validator.validatedOutputs(invalidOutputs, mediaDuration: 42).isEmpty,
            "Пустой TXT, malformed, overlapping или out-of-range SRT не должен выглядеть готовым"
        )
        let zeroVideo = root.appendingPathComponent("zero.mp4")
        try Data().write(to: zeroVideo)
        let generatedOutputs = [
            ProjectOutput(id: layout.subtitledVideoURL.path, kind: "subtitled-video", path: layout.subtitledVideoURL.path, createdAt: Date()),
            ProjectOutput(id: zeroVideo.path, kind: "subtitled-video", path: zeroVideo.path, createdAt: Date())
        ]
        try expect(validator.generatedMediaCount(generatedOutputs) == 1, "Zero-byte video не должен попадать в счётчик")
        var missingFragment = fragment
        missingFragment.id = "fragment-missing"
        missingFragment.videoPath = root.appendingPathComponent("missing-fragment.mp4").path
        try expect(validator.availableFragmentCount([fragment, missingFragment]) == 1, "Missing fragment не должен попадать в счётчик")

        print("SIMPLE_PROJECT_BROWSER_PROBE_PASS")
    }

    private static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw ProbeFailure(message: message) }
        return value
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

// The focused browser probe never creates topic artifacts. SRTService links
// against this helper for unrelated speed-adjustment code in the full target.
enum StableTopicHash {
    static func string(_ value: String) -> String { value }
}
