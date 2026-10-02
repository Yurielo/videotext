import Foundation

@main
struct ReviewTaskProbe {
    static func main() throws {
        let fileManager = FileManager.default
        let root = (URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? fileManager.temporaryDirectory.path, isDirectory: true)).appendingPathComponent("videotext-review-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4")
        let project = root.appendingPathComponent("project", isDirectory: true)
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("media".utf8).write(to: source)

        let history = ProjectHistoryStore(indexURL: root.appendingPathComponent("history.json"))
        let store = ProjectStore(history: history)
        var manifest = try store.ensureProject(at: project, mediaURL: source, mode: .newProject)
        let layout = ProjectLayout(root: project)
        let cues = [
            SubtitleCue(id: 7, start: 1.25, end: 3.75, text: "Wrong text"),
            SubtitleCue(id: 9, start: 4, end: 6, text: "Keep me")
        ]
        try SRTService().writePreservingIDs(cues, to: layout.fullSRTURL)
        try SRTService().writePreservingIDs(cues, to: layout.subtitlesURL(language: .en))
        let transcript = "Wrong text\n\nKeep me\n"
        try transcript.write(to: layout.transcriptURL, atomically: true, encoding: .utf8)
        try transcript.write(to: layout.transcriptURL(language: .en), atomically: true, encoding: .utf8)

        let parent = TranscriptRevision(
            id: "machine-parent",
            language: .en,
            origin: .machineGenerated,
            parentRevisionID: nil,
            transcriptArtifactID: "machine-txt",
            subtitleArtifactID: "machine-srt",
            contentHash: "parent-hash",
            createdAt: Date()
        )
        let task = ReviewTask(
            id: "task-7",
            transcriptRevisionID: parent.id,
            status: .needsReview,
            language: .en,
            start: 1.25,
            end: 3.75,
            cueIDs: [7],
            reasonCodes: ["low-confidence"],
            confidence: 0.2,
            originalText: "Wrong text",
            suggestedText: nil,
            createdAt: Date(),
            resolvedAt: nil,
            dependentArtifactIDs: []
        )
        manifest.transcriptRevisions = [parent]
        manifest.reviewTasks = [task]
        try store.save(manifest, to: project)

        let result = try ReviewTaskService(store: store).resolve(
            projectURL: project,
            taskID: task.id,
            replacementText: "Correct text"
        )
        try require(result.tasks.first?.status == .resolved, "review task не закрыт")
        try require(result.revision.origin == .userEdited, "не создана userEdited revision")
        try require(result.revision.parentRevisionID == parent.id, "потеряна parent revision")
        try require(result.cues[0].id == 7 && result.cues[0].start == 1.25 && result.cues[0].text == "Correct text", "cue ID/таймкод/текст не сохранены")
        try require(
            result.cues[1].id == cues[1].id &&
                result.cues[1].start == cues[1].start &&
                result.cues[1].end == cues[1].end &&
                result.cues[1].text == cues[1].text,
            "несвязанный cue изменен"
        )
        try require(fileManager.fileExists(atPath: layout.transcriptRevisionURL(id: parent.id, language: .en).path), "машинная TXT revision не сохранена")
        try require(fileManager.fileExists(atPath: layout.subtitleRevisionURL(id: parent.id, language: .en).path), "машинная SRT revision не сохранена")
        try require(fileManager.fileExists(atPath: layout.transcriptRevisionURL(id: result.revision.id, language: .en).path), "user TXT revision не сохранена")
        let savedCueIDs = try SRTService().load(from: layout.fullSRTURL).map(\.id)
        try require(savedCueIDs == [7, 9], "SRT перенумерован")

        print("REVIEW_TASK_PROBE_PASS")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
