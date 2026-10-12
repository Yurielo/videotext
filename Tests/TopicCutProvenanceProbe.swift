import Foundation
import Darwin

private struct TopicCutProvenanceFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
struct TopicCutProvenanceProbe {
    static func main() {
        do {
            try run()
            print("TOPIC_CUT_PROVENANCE_PROBE_PASS")
        } catch {
            fputs("TOPIC_CUT_PROVENANCE_PROBE_FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TopicCutProvenanceFailure(message: message) }
    }

    private static func expectFailure(_ message: String, _ body: () throws -> Void) throws {
        do {
            try body()
            throw TopicCutProvenanceFailure(message: message)
        } catch let failure as TopicCutProvenanceFailure {
            throw failure
        } catch {
            // Expected fail-closed path.
        }
    }

    private static func topic(start: TimeInterval = 1, end: TimeInterval = 3) -> TopicSegment {
        TopicSegment(
            id: "approved-topic",
            title: "Утверждённая тема",
            start: start,
            end: end,
            summary: "Проверочная тема.",
            keywords: ["проверка"],
            confidence: 1,
            boundaryReason: "Fixture",
            cueIds: [1, 2]
        )
    }

    private static func topicsFile(topic: TopicSegment) -> TopicsFile {
        TopicsFile(
            adapter: TopicAlgorithmIdentity.hybridAdapter,
            createdAt: Date(timeIntervalSince1970: 1),
            sourceSRT: "fixture/full.srt",
            sourceSignature: "fixture-source",
            status: .ready,
            granularity: .normal,
            embeddingModel: "fixture",
            languageModel: "fixture",
            topics: [topic]
        )
    }

    private static func makeFixture(
        root: URL,
        topic: TopicSegment = topic(),
        status: TopicRevisionStatus = .approved,
        active: Bool = true
    ) throws -> (store: ProjectStore, project: URL, manifest: ProjectManifest, revision: TopicRevision, file: TopicsFile) {
        let project = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let media = root.appendingPathComponent("source-\(UUID().uuidString).mp4")
        try Data("fixture media".utf8).write(to: media)
        let store = ProjectStore(history: ProjectHistoryStore(indexURL: root.appendingPathComponent("history-\(UUID().uuidString).json")))
        var manifest = try store.ensureProject(at: project, mediaURL: media, mode: .newProject)
        let layout = ProjectLayout(root: project)
        let file = topicsFile(topic: topic)
        try TopicFileService().save(file, projectURL: project, language: .ru, granularity: .normal, updateLegacyFiles: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let immutable = try encoder.encode(file)
        let revisionID = "topics-ru-normal-approved-fixture"
        let immutableURL = layout.topicRevisionJSONURL(id: revisionID)
        try FileManager.default.createDirectory(at: immutableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try immutable.write(to: immutableURL, options: .atomic)
        let revision = TopicRevision(
            id: revisionID,
            language: .ru,
            granularity: .normal,
            parentRevisionID: nil,
            jsonPath: immutableURL.path,
            textPath: layout.topicRevisionTextURL(id: revisionID).path,
            contentHash: StableTopicHash.string(String(decoding: immutable, as: UTF8.self)),
            status: status,
            createdAt: Date()
        )
        manifest.topicRevisions = [revision]
        manifest.topicReviewState = TopicReviewState(
            enabled: true,
            activeRevisionIDs: active ? [revision.variantKey: revisionID] : [:],
            pendingCheckpoint: nil
        )
        try store.save(manifest, to: project)
        return (store, project, manifest, revision, file)
    }

    private static func selected(_ fixture: (store: ProjectStore, project: URL, manifest: ProjectManifest, revision: TopicRevision, file: TopicsFile), id: String? = "approved-topic") throws -> TopicSegment {
        let manifest = try fixture.store.load(from: fixture.project)
        return try WorkflowEngine.approvedTopic(
            manifest: manifest,
            projectURL: fixture.project,
            selectedTopicID: id,
            language: .ru,
            granularity: .normal
        )
    }

    private static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("topic-cut-provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let valid = try makeFixture(root: root)
        let resolved = try selected(valid)
        try require(resolved.id == "approved-topic" && resolved.start == 1 && resolved.end == 3,
                    "Approved topic was not resolved verbatim from its immutable snapshot")

        try expectFailure("Nil selectedTopicID fell back to an arbitrary topic") {
            _ = try selected(valid, id: nil)
        }
        try expectFailure("Unknown selectedTopicID fell back to an arbitrary topic") {
            _ = try selected(valid, id: "unknown-topic")
        }

        let unapproved = try makeFixture(root: root, status: .pending)
        try expectFailure("Unapproved topic revision was accepted") {
            _ = try selected(unapproved)
        }
        let inactive = try makeFixture(root: root, active: false)
        try expectFailure("Topic without an active approved revision was accepted") {
            _ = try selected(inactive)
        }

        let workingMutation = try makeFixture(root: root)
        var mutatedWorking = workingMutation.file
        mutatedWorking.topics[0].start = 2
        mutatedWorking.topics[0].end = 4
        try TopicFileService().save(mutatedWorking, projectURL: workingMutation.project, language: .ru, granularity: .normal, updateLegacyFiles: false)
        let immutableResolved = try selected(workingMutation)
        try require(immutableResolved.start == 1 && immutableResolved.end == 3,
                    "Mutated working topics file replaced the approved snapshot range")

        let snapshotMutation = try makeFixture(root: root)
        let immutableURL = URL(fileURLWithPath: snapshotMutation.revision.jsonPath)
        try Data("tampered approved snapshot".utf8).write(to: immutableURL, options: .atomic)
        try expectFailure("Tampered approved snapshot was accepted") {
            _ = try selected(snapshotMutation)
        }

        let invalidRange = try makeFixture(root: root, topic: topic(start: 3, end: 1))
        try expectFailure("Invalid approved executable range was accepted") {
            _ = try selected(invalidRange)
        }
    }
}
