import Foundation

@main
struct ProjectSchemaProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("Использование: videotext-project-schema-probe <legacy-manifest-v3.json>\n", stderr)
            exit(2)
        }

        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("videotext-schema-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let sourceURL = temporaryRoot.appendingPathComponent("source.mp4")
        let projectURL = temporaryRoot.appendingPathComponent("project", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try Data("synthetic-media".utf8).write(to: sourceURL)

        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        var object = try requireObject(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)))
        object["sourceMediaPath"] = sourceURL.path
        object["projectFolderPath"] = projectURL.path
        let layout = ProjectLayout(root: projectURL)
        try layout.createDirectories()
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: layout.manifestURL, options: .atomic)

        let historyURL = temporaryRoot.appendingPathComponent("history.json")
        let store = ProjectStore(history: ProjectHistoryStore(indexURL: historyURL))
        let (migrated, reopenedSource) = try store.openProject(at: projectURL)
        try require(reopenedSource.path == sourceURL.path, "после миграции изменился source path")
        try require(migrated.schemaVersion == ProjectSchema.currentVersion, "schema v3 не поднята до current")
        try require(migrated.artifacts?.isEmpty == true, "artifact registry не инициализирован")
        try require(migrated.transcriptRevisions?.isEmpty == true, "transcript revisions не инициализированы")
        try require(migrated.reviewTasks?.isEmpty == true, "review tasks не инициализированы")
        try require(migrated.humanReviewState?.sourceReviewEnabled == true, "source Human Review не включён по умолчанию")
        try require(migrated.humanReviewState?.translationReviewEnabled == false, "translation Human Review должен быть выключен по умолчанию")
        try require(migrated.humanReviewState?.fillerAnalysisBeforeReview == true, "анализ слов-паразитов перед Human Review не включён")
        try require(migrated.humanReviewState?.pendingCheckpoint == nil, "legacy migration создала ложный checkpoint")
        try require(migrated.topicRevisions?.isEmpty == true, "topic revisions не инициализированы")
        try require(migrated.topicReviewState?.enabled == true, "Human Review тем не включён по умолчанию")
        try require(migrated.topicReviewState?.pendingCheckpoint == nil, "legacy migration создала ложный topic checkpoint")
        try require(SubtitleStyleSettings.standard.fontSize == 20, "размер субтитров по умолчанию должен быть 20")
        let defaultSettings = WorkflowSettings(
            mediaURL: nil,
            projectURL: nil,
            selectedOperations: [],
            mode: .newProject,
            rangeStart: 0,
            rangeEnd: 1,
            fragmentName: "",
            burnFragmentSubtitles: false,
            subtitleStyle: .standard,
            selectedTopicID: nil,
            whisperModelPath: "",
            whisperLanguage: "ru"
        )
        try require(defaultSettings.fillerAnalysisBeforeReview, "анализ слов-паразитов должен быть включён в настройках по умолчанию")
        try require(defaultSettings.fillerMode == .muteAll, "режим mute по умолчанию должен охватывать все найденные слова-паразиты")
        let engine = WorkflowEngine(store: store)
        let planned = engine.expanded([.topicTimecoding], includeFillerAnalysisBeforeReview: true)
        try require(planned.contains(.detectFillerWords), "pre-review анализ слов-паразитов не добавлен в план")
        try require(
            planned.firstIndex(of: .assessTranscriptionQuality)! < planned.firstIndex(of: .detectFillerWords)!
                && planned.firstIndex(of: .detectFillerWords)! < planned.firstIndex(of: .topicTimecoding)!,
            "нарушен порядок quality -> filler analysis -> topics"
        )
        let plannedWithoutFillers = engine.expanded([.topicTimecoding], includeFillerAnalysisBeforeReview: false)
        try require(!plannedWithoutFillers.contains(.detectFillerWords), "выключенный pre-review анализ остался в плане")
        try require(fileManager.fileExists(atPath: layout.legacyManifestBackupURL(schemaVersion: 3).path), "нет backup schema v3")

        var uniquePaths = Set<String>()
        for language in ArtifactLanguage.allCases {
            try require(uniquePaths.insert(layout.transcriptURL(language: language).path).inserted, "transcript path collision")
            try require(uniquePaths.insert(layout.subtitlesURL(language: language).path).inserted, "subtitle path collision")
            for granularity in TopicGranularity.allCases {
                try require(uniquePaths.insert(layout.topicsURL(language: language, granularity: granularity).path).inserted, "topics path collision")
                try require(uniquePaths.insert(layout.topicCacheDirectory(language: language, granularity: granularity).path).inserted, "topic cache collision")
            }
        }

        let artifact = ProjectArtifactRecord(
            id: "transcript-ru-source-v1",
            kind: .transcript,
            path: layout.transcriptURL(language: .ru).path,
            language: .ru,
            origin: .source,
            granularity: nil,
            sourceArtifactID: nil,
            sourceRevision: "revision-1",
            dependencyIDs: [],
            contentHash: "fixture-hash",
            createdAt: Date(),
            generator: BuildInfo.name,
            generatorVersion: BuildInfo.version,
            model: "fixture-model",
            validationStatus: .ready,
            qualityStatus: .needsReview,
            reviewTaskCount: 1
        )
        try store.registerArtifact(artifact, in: projectURL)
        let artifactManifest = try store.load(from: projectURL)
        let storedArtifact = artifactManifest.artifacts?.first
        try require(artifactManifest.artifacts?.count == 1, "artifact registry count changed")
        try require(storedArtifact?.id == artifact.id, "artifact id round-trip failed")
        try require(storedArtifact?.path == artifact.path, "artifact path round-trip failed")
        try require(storedArtifact?.language == .ru, "artifact language round-trip failed")
        try require(storedArtifact?.qualityStatus == .needsReview, "artifact quality round-trip failed")

        var future = try requireObject(JSONSerialization.jsonObject(with: Data(contentsOf: layout.manifestURL)))
        future["schemaVersion"] = ProjectSchema.currentVersion + 1
        try JSONSerialization.data(withJSONObject: future, options: [.prettyPrinted, .sortedKeys])
            .write(to: layout.manifestURL, options: .atomic)
        do {
            _ = try store.load(from: projectURL)
            throw ProbeFailure(message: "future schema was accepted")
        } catch WorkflowError.unsupportedProjectSchema(let version) {
            try require(version == ProjectSchema.currentVersion + 1, "wrong rejected schema version")
        }

        print("PROJECT_SCHEMA_PROBE_PASS")
    }

    private static func requireObject(_ value: Any) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw ProbeFailure(message: "fixture is not a JSON object")
        }
        return object
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
