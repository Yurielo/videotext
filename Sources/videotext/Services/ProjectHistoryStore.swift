import Foundation

struct ProjectHistoryStore {
    let indexURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(indexURL: URL? = nil) {
        if let indexURL {
            self.indexURL = indexURL
        } else if let override = ProcessInfo.processInfo.environment["VIDEOTEXT_HISTORY_PATH"], !override.isEmpty {
            self.indexURL = URL(fileURLWithPath: override)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.indexURL = support
                .appendingPathComponent("videotext", isDirectory: true)
                .appendingPathComponent("history.json")
        }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func entries() -> [ProjectHistoryEntry] {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? decoder.decode([ProjectHistoryEntry].self, from: data) else { return [] }
        return decoded
            .filter { FileManager.default.fileExists(atPath: ProjectLayout(root: URL(fileURLWithPath: $0.projectPath)).manifestURL.path) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func record(_ manifest: ProjectManifest) throws {
        var history = entries()
        let workflow = manifest.workflow ?? ProjectWorkflowState(
            status: .ready,
            progress: 0,
            mode: .resumeProject,
            operations: [:],
            lastError: nil
        )
        let completed = workflow.operations
            .filter { $0.value.status == .completed || $0.value.status == .skipped }
            .map(\.key)
            .sorted()
        let entry = ProjectHistoryEntry(
            projectPath: manifest.projectFolderPath,
            sourceMediaPath: manifest.sourceMediaPath,
            mediaName: URL(fileURLWithPath: manifest.sourceMediaPath).lastPathComponent,
            createdAt: manifest.createdAt,
            updatedAt: manifest.updatedAt,
            status: workflow.status,
            progress: workflow.progress,
            completedOperations: completed
        )
        history.removeAll { $0.projectPath == entry.projectPath }
        history.append(entry)
        history.sort { $0.updatedAt > $1.updatedAt }
        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(history).write(to: indexURL, options: .atomic)
    }
}
