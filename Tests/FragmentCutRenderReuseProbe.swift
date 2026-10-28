import Foundation
import Darwin

private struct FragmentCutRenderReuseFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
struct FragmentCutRenderReuseProbe {
    static func main() async {
        do {
            let avoided = try await run()
            print("FRAGMENT_CUT_RENDER_REUSE_PROBE_PASS prevented_ffmpeg_cut_renders=\(avoided)")
        } catch {
            fputs("FRAGMENT_CUT_RENDER_REUSE_PROBE_FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw FragmentCutRenderReuseFailure(message: message) }
    }

    private static func run() async throws -> Int {
        try require(
            !FFmpegAdapter.hasDynamicLoaderOverrides(environment: ["PATH": "/usr/bin"]),
            "Ordinary PATH was incorrectly treated as a dynamic-loader override"
        )
        try require(
            FFmpegAdapter.hasDynamicLoaderOverrides(environment: ["DYLD_LIBRARY_PATH": "/tmp/custom-libraries"]),
            "A DYLD override did not disable reuse eligibility"
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fragment-cut-reuse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.mp4")
        let approvedSnapshotURL = root.appendingPathComponent("approved-topics.json")
        let ffmpegURL = root.appendingPathComponent("ffmpeg")
        try Data("source-video-bytes".utf8).write(to: sourceURL)
        let approvedSnapshotText = "immutable-approved-topic-snapshot"
        let approvedSnapshotData = Data(approvedSnapshotText.utf8)
        try approvedSnapshotData.write(to: approvedSnapshotURL)
        try Data("ffmpeg-binary-fixture".utf8).write(to: ffmpegURL)

        let provenance = TopicCutRenderProvenance(
            approvedRevisionID: "approved-r1",
            approvedRevisionContentHash: StableTopicHash.string(approvedSnapshotText),
            approvedSnapshotURL: approvedSnapshotURL,
            language: .ru,
            granularity: .normal,
            topicID: "topic-1"
        )
        let baseIdentity = try identity(
            source: sourceURL,
            ffmpeg: ffmpegURL,
            provenance: provenance,
            start: 1,
            end: 4
        )

        try Data("source-video-byteS".utf8).write(to: sourceURL)
        let changedSource = try identity(
            source: sourceURL,
            ffmpeg: ffmpegURL,
            provenance: provenance,
            start: 1,
            end: 4
        )
        try require(baseIdentity.key != changedSource.key, "Different source video bytes reused the same key")
        try Data("source-video-bytes".utf8).write(to: sourceURL)

        let changedRange = try identity(
            source: sourceURL,
            ffmpeg: ffmpegURL,
            provenance: provenance,
            start: 1,
            end: 4.001
        )
        try require(baseIdentity.key != changedRange.key, "A different exact range reused the same key")

        let changedSnapshotText = "updated-approved-topic-snapshot"
        try Data(changedSnapshotText.utf8).write(to: approvedSnapshotURL)
        let changedProvenance = TopicCutRenderProvenance(
            approvedRevisionID: "approved-r2",
            approvedRevisionContentHash: StableTopicHash.string(changedSnapshotText),
            approvedSnapshotURL: approvedSnapshotURL,
            language: .ru,
            granularity: .normal,
            topicID: "topic-1"
        )
        let changedApproval = try identity(
            source: sourceURL,
            ffmpeg: ffmpegURL,
            provenance: changedProvenance,
            start: 1,
            end: 4
        )
        try require(baseIdentity.key != changedApproval.key, "A different approved revision reused the same key")
        try approvedSnapshotData.write(to: approvedSnapshotURL)
        let inconsistentSnapshotIdentity = FragmentCutRenderReuseIdentity.make(
            mediaURL: sourceURL,
            start: 1,
            end: 4,
            provenance: changedProvenance,
            ffmpegRuntime: try ffmpegRuntime(ffmpegURL),
            appVersion: "test-version",
            appBuild: "test-build"
        )
        guard case nil = inconsistentSnapshotIdentity else {
            throw FragmentCutRenderReuseFailure(message: "A snapshot inconsistent with its approved content hash produced a reuse key")
        }

        try Data("ffmpeg-binary-fixture-v2".utf8).write(to: ffmpegURL)
        let changedFFmpeg = try identity(
            source: sourceURL,
            ffmpeg: ffmpegURL,
            provenance: provenance,
            start: 1,
            end: 4
        )
        try require(baseIdentity.key != changedFFmpeg.key, "A different FFmpeg binary reused the same key")
        try Data("ffmpeg-binary-fixture".utf8).write(to: ffmpegURL)
        let changedRuntime = try identity(
            source: sourceURL,
            ffmpeg: ffmpegURL,
            provenance: provenance,
            start: 1,
            end: 4,
            runtimeFingerprint: "fixture-runtime-with-updated-linked-library"
        )
        try require(baseIdentity.key != changedRuntime.key, "A changed linked FFmpeg runtime reused the same key")

        let projectURL = root.appendingPathComponent("project", isDirectory: true)
        let layout = ProjectLayout(root: projectURL)
        let sourceFragment = layout.fragmentVideoURL(kind: "topic-1_00-00-01--00-00-04")
        try FileManager.default.createDirectory(at: sourceFragment.deletingLastPathComponent(), withIntermediateDirectories: true)
        let renderedBytes = Data("validated-video-output".utf8)
        try renderedBytes.write(to: sourceFragment)
        let sourceDigest = try digest(renderedBytes)
        let sourceRecord = fragmentRecord(
            id: "topic-1_00-00-01--00-00-04",
            videoPath: sourceFragment.path,
            start: 1,
            end: 4,
            key: baseIdentity.key,
            digest: sourceDigest
        )
        let service = FragmentCutRenderReuseService()
        let targetURL = layout.fragmentVideoURL(kind: "topic-1_00-00-01--00-00-04 (2)")
        var ffmpegCutCalls = 0
        let reused = try await service.renderOrReuse(
            records: [sourceRecord],
            projectURL: projectURL,
            key: baseIdentity.key,
            start: 1,
            end: 4,
            topicID: "topic-1",
            granularity: .normal,
            outputURL: targetURL,
            validate: { url in
                guard try Data(contentsOf: url) == renderedBytes else {
                    throw FragmentCutRenderReuseFailure(message: "Copied video did not pass validation")
                }
                return "validated fixture"
            },
            render: {
                ffmpegCutCalls += 1
                try renderedBytes.write(to: targetURL)
            }
        )
        try require(reused.reused && ffmpegCutCalls == 0, "Equivalent render did not bypass FFmpeg")
        let reusedBytes = try Data(contentsOf: targetURL)
        try require(reusedBytes == renderedBytes, "Reused video bytes changed")
        try require(targetURL.path != sourceFragment.path, "Independent result path was not created")

        try Data("source-video-byteS".utf8).write(to: sourceURL)
        let mismatchURL = layout.fragmentVideoURL(kind: "same-topic-changed-source")
        try FileManager.default.createDirectory(at: mismatchURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sameOutputDifferentInput = try await service.renderOrReuse(
            records: [sourceRecord],
            projectURL: projectURL,
            key: changedSource.key,
            start: 1,
            end: 4,
            topicID: "topic-1",
            granularity: .normal,
            outputURL: mismatchURL,
            validate: { _ in "validated fixture" },
            render: {
                ffmpegCutCalls += 1
                try renderedBytes.write(to: mismatchURL)
            }
        )
        try require(!sameOutputDifferentInput.reused && ffmpegCutCalls == 1,
                    "Matching output SHA alone bypassed the render for different source bytes")
        try Data("source-video-bytes".utf8).write(to: sourceURL)

        var corruptedMetadataRecord = sourceRecord
        corruptedMetadataRecord.cutVideoSHA256 = String(repeating: "0", count: 64)
        let corruptCacheTarget = layout.fragmentVideoURL(kind: "corrupt-cache")
        let corruptCache = try await service.renderOrReuse(
            records: [corruptedMetadataRecord],
            projectURL: projectURL,
            key: baseIdentity.key,
            start: 1,
            end: 4,
            topicID: "topic-1",
            granularity: .normal,
            outputURL: corruptCacheTarget,
            validate: { _ in "validated fixture" },
            render: {
                ffmpegCutCalls += 1
                try FileManager.default.createDirectory(at: corruptCacheTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
                try renderedBytes.write(to: corruptCacheTarget)
            }
        )
        try require(!corruptCache.reused && ffmpegCutCalls == 2,
                    "A corrupt cached output passed the stored content digest")

        let projectStore = ProjectStore(history: ProjectHistoryStore(indexURL: root.appendingPathComponent("history.json")))
        _ = try projectStore.ensureProject(at: projectURL, mediaURL: sourceURL, mode: .newProject)
        var first = sourceRecord
        first.subtitlePath = layout.fragmentSRTURL(kind: first.id).path
        var second = fragmentRecord(
            id: "topic-1_00-00-01--00-00-04 (2)",
            videoPath: targetURL.path,
            start: 1,
            end: 4,
            key: baseIdentity.key,
            digest: sourceDigest
        )
        second.subtitlePath = layout.fragmentSRTURL(kind: second.id).path
        try projectStore.registerFragment(first, in: projectURL)
        try projectStore.registerFragment(second, in: projectURL)
        let persisted = try projectStore.load(from: projectURL).fragments ?? []
        try require(persisted.count == 2, "Independent FragmentRecord values were merged")
        try require(Set(persisted.map(\.videoPath)).count == 2, "Fragment records do not point to separate result paths")

        let legacyRecordJSON = Data(##"{"id":"legacy","name":"Legacy","start":1,"end":4,"createdAt":0,"videoPath":"/old/fragment.mp4","subtitlePath":"/old/fragment.srt","style":{"textColorHex":"#FFFFFF","outlineColorHex":"#000000","fontName":"Helvetica","fontSize":20,"outlineWidth":2,"position":"bottom","backgroundOpacity":0}}"##.utf8)
        let decodedLegacyRecord = try JSONDecoder().decode(FragmentRecord.self, from: legacyRecordJSON)
        try require(decodedLegacyRecord.cutVideoReuseKey == nil && decodedLegacyRecord.cutVideoSHA256 == nil,
                    "A prior FragmentRecord without reuse metadata did not decode as non-reusable")

        let fallbackURL = layout.fragmentVideoURL(kind: "no-proof")
        try FileManager.default.createDirectory(at: fallbackURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacyRecord = fragmentRecord(
            id: "legacy-without-proof",
            videoPath: sourceFragment.path,
            start: 1,
            end: 4,
            key: nil,
            digest: nil
        )
        let fallback = try await service.renderOrReuse(
            records: [legacyRecord],
            projectURL: projectURL,
            key: baseIdentity.key,
            start: 1,
            end: 4,
            topicID: "topic-1",
            granularity: .normal,
            outputURL: fallbackURL,
            validate: { _ in "rendered fixture" },
            render: {
                ffmpegCutCalls += 1
                try renderedBytes.write(to: fallbackURL)
            }
        )
        try require(!fallback.reused && ffmpegCutCalls == 3, "Legacy result reused without provenance proof")
        return 1
    }

    private static func identity(
        source: URL,
        ffmpeg: URL,
        provenance: TopicCutRenderProvenance,
        start: TimeInterval,
        end: TimeInterval,
        runtimeFingerprint: String = "fixture-runtime-v1"
    ) throws -> FragmentCutRenderReuseIdentity {
        guard let result = FragmentCutRenderReuseIdentity.make(
            mediaURL: source,
            start: start,
            end: end,
            provenance: provenance,
            ffmpegRuntime: try ffmpegRuntime(ffmpeg, fingerprint: runtimeFingerprint),
            appVersion: "test-version",
            appBuild: "test-build"
        ) else {
            throw FragmentCutRenderReuseFailure(message: "Could not build a complete input identity")
        }
        return result
    }

    private static func ffmpegRuntime(_ url: URL, fingerprint: String = "fixture-runtime-v1") throws -> FFmpegCutRuntimeIdentity {
        guard let digest = FragmentCutRenderReuseIdentity.sha256(of: url) else {
            throw FragmentCutRenderReuseFailure(message: "Could not hash the FFmpeg fixture")
        }
        return FFmpegCutRuntimeIdentity(executableURL: url, executableSHA256: digest, fingerprint: fingerprint)
    }

    private static func digest(_ data: Data) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let digest = FragmentCutRenderReuseIdentity.sha256(of: url) else {
            throw FragmentCutRenderReuseFailure(message: "Could not hash the output fixture")
        }
        return digest
    }

    private static func fragmentRecord(
        id: String,
        videoPath: String,
        start: TimeInterval,
        end: TimeInterval,
        key: String?,
        digest: String?
    ) -> FragmentRecord {
        FragmentRecord(
            id: id,
            name: "Утверждённая тема",
            start: start,
            end: end,
            createdAt: Date(),
            videoPath: videoPath,
            subtitlePath: "",
            subtitledVideoPath: nil,
            ffprobeReportPath: nil,
            style: .standard,
            language: .ru,
            topicGranularity: .normal,
            topicID: "topic-1",
            cutVideoReuseKey: key,
            cutVideoSHA256: digest
        )
    }
}
