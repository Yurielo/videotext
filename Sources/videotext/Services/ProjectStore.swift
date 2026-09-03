import Foundation

struct ProjectStore {
    let encoder: JSONEncoder
    let decoder: JSONDecoder
    let history: ProjectHistoryStore

    init(history: ProjectHistoryStore = ProjectHistoryStore()) {
        self.history = history
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func createAutomaticProject(for mediaURL: URL) throws -> URL {
        guard FileManager.default.isReadableFile(atPath: mediaURL.path) else {
            throw WorkflowError.missingMedia
        }
        try validateFreeSpace(for: mediaURL)

        let parent = mediaURL.deletingLastPathComponent()
        let sourceName = mediaURL.deletingPathExtension().lastPathComponent
        let baseName = "Обработка видео \(sourceName)"
        var candidate = parent.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(baseName) (\(suffix))", isDirectory: true)
            suffix += 1
        }

        do {
            _ = try ensureProject(at: candidate, mediaURL: mediaURL, mode: .newProject)
            return candidate
        } catch let error as WorkflowError {
            throw error
        } catch {
            throw WorkflowError.cannotCreateProject(candidate.path)
        }
    }

    func ensureProject(
        at projectURL: URL,
        mediaURL: URL,
        mode: ProjectRunMode = .resumeProject
    ) throws -> ProjectManifest {
        let layout = ProjectLayout(root: projectURL)
        try layout.createDirectories()
        let fingerprint = try sourceFingerprint(for: mediaURL)

        if FileManager.default.fileExists(atPath: layout.manifestURL.path) {
            var manifest = try load(from: projectURL)
            let previousSchemaVersion = manifest.schemaVersion ?? 1
            if previousSchemaVersion < ProjectSchema.currentVersion {
                try backupManifestForMigration(layout: layout, schemaVersion: previousSchemaVersion)
            }
            if let existing = manifest.sourceFingerprint {
                guard sameSource(existing, fingerprint) else { throw WorkflowError.sourceMismatch }
            } else {
                let previous = URL(fileURLWithPath: manifest.sourceMediaPath).standardizedFileURL.path
                guard previous == mediaURL.standardizedFileURL.path else { throw WorkflowError.sourceMismatch }
            }
            manifest.sourceMediaPath = mediaURL.path
            manifest.projectFolderPath = projectURL.path
            manifest.sourceFingerprint = fingerprint
            manifest.schemaVersion = ProjectSchema.currentVersion
            manifest.appVersion = BuildInfo.version
            manifest.build = BuildInfo.build
            if manifest.workflow == nil {
                manifest.workflow = defaultWorkflow(mode: mode)
            }
            if manifest.fragments == nil { manifest.fragments = [] }
            if manifest.subtitleStyle == nil { manifest.subtitleStyle = .standard }
            if manifest.artifacts == nil { manifest.artifacts = [] }
            if manifest.transcriptRevisions == nil { manifest.transcriptRevisions = [] }
            if manifest.reviewTasks == nil { manifest.reviewTasks = [] }
            if manifest.humanReviewState == nil {
                var state = HumanReviewState.newProjectDefault
                var revisions = manifest.transcriptRevisions ?? []
                for language in ArtifactLanguage.allCases {
                    guard let index = revisions.lastIndex(where: { $0.language == language }) else { continue }
                    revisions[index].reviewStatus = .approved
                    state.activeRevisionIDs[language.rawValue] = revisions[index].id
                }
                manifest.transcriptRevisions = revisions
                manifest.humanReviewState = state
            } else if manifest.humanReviewState?.fillerAnalysisBeforeReview == nil {
                manifest.humanReviewState?.fillerAnalysisBeforeReview = true
            }
            if manifest.blurAdjustments == nil { manifest.blurAdjustments = [] }
            if manifest.watermarkAdjustments == nil { manifest.watermarkAdjustments = [] }
            if manifest.fillerMuteRecords == nil { manifest.fillerMuteRecords = [] }
            if manifest.audioEnhancements == nil { manifest.audioEnhancements = [] }
            if manifest.dubbingRecords == nil { manifest.dubbingRecords = [] }
            try save(manifest, to: projectURL)
            return manifest
        }

        let manifest = ProjectManifest(
            appName: BuildInfo.name,
            appVersion: BuildInfo.version,
            build: BuildInfo.build,
            createdAt: Date(),
            updatedAt: Date(),
            sourceMediaPath: mediaURL.path,
            projectFolderPath: projectURL.path,
            durationSeconds: nil,
            outputs: [],
            diagnostics: nil,
            schemaVersion: ProjectSchema.currentVersion,
            sourceFingerprint: fingerprint,
            workflow: defaultWorkflow(mode: mode),
            fragments: [],
            subtitleStyle: .standard,
            artifacts: [],
            languageProfile: nil,
            transcriptRevisions: [],
            reviewTasks: [],
            humanReviewState: .newProjectDefault,
            blurAdjustments: [],
            watermarkAdjustments: [],
            fillerMuteRecords: [],
            audioEnhancements: [],
            dubbingRecords: []
        )
        try save(manifest, to: projectURL)
        return manifest
    }

    func openProject(at projectURL: URL) throws -> (ProjectManifest, URL) {
        let manifestURL = ProjectLayout(root: projectURL).manifestURL
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw WorkflowError.missingProjectManifest
        }
        let manifest = try load(from: projectURL)
        let mediaURL = URL(fileURLWithPath: manifest.sourceMediaPath)
        guard FileManager.default.isReadableFile(atPath: mediaURL.path) else {
            throw WorkflowError.missingMedia
        }
        var migrated = try ensureProject(at: projectURL, mediaURL: mediaURL, mode: .resumeProject)
        if migrated.workflow?.status == .running {
            migrated.workflow?.status = .stopped
            migrated.workflow?.lastError = nil
            try save(migrated, to: projectURL)
        }
        return (migrated, mediaURL)
    }

    func load(from projectURL: URL) throws -> ProjectManifest {
        let data = try Data(contentsOf: ProjectLayout(root: projectURL).manifestURL)
        let manifest = try decoder.decode(ProjectManifest.self, from: data)
        let version = manifest.schemaVersion ?? 1
        guard version >= ProjectSchema.minimumSupportedVersion,
              version <= ProjectSchema.currentVersion else {
            throw WorkflowError.unsupportedProjectSchema(version)
        }
        return manifest
    }

    func save(_ manifest: ProjectManifest, to projectURL: URL) throws {
        var updated = manifest
        updated.updatedAt = Date()
        let data = try encoder.encode(updated)
        try data.write(to: ProjectLayout(root: projectURL).manifestURL, options: .atomic)
        try? history.record(updated)
    }

    func mutate(_ projectURL: URL, _ body: (inout ProjectManifest) throws -> Void) throws {
        var manifest = try load(from: projectURL)
        try body(&manifest)
        try save(manifest, to: projectURL)
    }

    func registerOutput(kind: String, url: URL, in projectURL: URL) throws {
        try mutate(projectURL) { manifest in
            let output = ProjectOutput(id: url.path, kind: kind, path: url.path, createdAt: Date())
            manifest.outputs.removeAll { $0.path == url.path }
            manifest.outputs.append(output)
        }
    }

    func registerArtifact(_ artifact: ProjectArtifactRecord, in projectURL: URL) throws {
        try mutate(projectURL) { manifest in
            var artifacts = manifest.artifacts ?? []
            artifacts.removeAll { $0.id == artifact.id || $0.path == artifact.path }
            artifacts.append(artifact)
            manifest.artifacts = artifacts.sorted { $0.createdAt < $1.createdAt }
        }
    }

    func registerFragment(_ fragment: FragmentRecord, in projectURL: URL) throws {
        try mutate(projectURL) { manifest in
            var fragments = manifest.fragments ?? []
            fragments.removeAll { $0.id == fragment.id }
            fragments.append(fragment)
            manifest.fragments = fragments.sorted { $0.createdAt > $1.createdAt }
            manifest.subtitleStyle = fragment.style
        }
    }

    func sourceFingerprint(for mediaURL: URL) throws -> SourceFingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: mediaURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return SourceFingerprint(
            standardizedPath: mediaURL.standardizedFileURL.path,
            fileSize: size,
            modificationTime: modified
        )
    }

    func sameSource(_ lhs: SourceFingerprint, _ rhs: SourceFingerprint) -> Bool {
        lhs.fileSize == rhs.fileSize && abs(lhs.modificationTime - rhs.modificationTime) < 0.001
    }

    private func defaultWorkflow(mode: ProjectRunMode) -> ProjectWorkflowState {
        ProjectWorkflowState(status: .ready, progress: 0, mode: mode, operations: [:], lastError: nil)
    }

    private func backupManifestForMigration(layout: ProjectLayout, schemaVersion: Int) throws {
        let backupURL = layout.legacyManifestBackupURL(schemaVersion: schemaVersion)
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        try FileManager.default.copyItem(at: layout.manifestURL, to: backupURL)
    }

    private func validateFreeSpace(for mediaURL: URL) throws {
        let values = try mediaURL.resourceValues(forKeys: [.fileSizeKey, .volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        let sourceSize = Int64(values.fileSize ?? 0)
        let required = max(1_073_741_824, sourceSize * 3 + 536_870_912)
        guard available > required else { throw WorkflowError.insufficientDiskSpace }
    }
}
