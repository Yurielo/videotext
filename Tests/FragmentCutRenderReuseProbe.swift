import Foundation
import Darwin
import AVFoundation

private struct RealE2ERenderReport: Codable {
    let loaderOverrideDetected: Bool
    let cutRenderCount: Int
    let reuseMetadataAbsent: Bool
}

private struct FragmentCutRenderReuseFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
struct FragmentCutRenderReuseProbe {
    static func main() async {
        do {
            let avoided = try await run()
            let realE2EAvoided = try await runRealWorkflowE2E()
            print("FRAGMENT_CUT_RENDER_REUSE_PROBE_PASS simulated_prevented_ffmpeg_cut_renders=\(avoided) real_e2e_prevented_ffmpeg_cut_renders=\(realE2EAvoided)")
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

    private static func runRealWorkflowE2E() async throws -> Int {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--runtime-identity-unavailable" {
            try await runRuntimeIdentityFallbackChild(
                projectURL: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true),
                reportURL: URL(fileURLWithPath: CommandLine.arguments[3])
            )
            return 0
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fragment-cut-reuse-real-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let modelFixture = root.appendingPathComponent("ggml-real-e2e-fixture.bin")
        try Data().write(to: modelFixture)
        guard let ffmpeg = ToolRunner().resolve("ffmpeg") else {
            throw FragmentCutRenderReuseFailure(message: "FFmpeg is unavailable for real E2E")
        }
        let sourceURL = root.appendingPathComponent("source.mp4")
        let generated = try await ToolRunner().run(ffmpeg, [
            "-y", "-f", "lavfi", "-i", "testsrc=size=160x90:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-t", "8", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "64k", sourceURL.path
        ])
        try require(generated.exitCode == 0, "FFmpeg could not generate the real-video fixture: \(generated.stderr)")

        let projectURL = root.appendingPathComponent("approved-topic-project", isDirectory: true)
        let store = ProjectStore(history: ProjectHistoryStore(indexURL: root.appendingPathComponent("history.json")))
        _ = try store.ensureProject(at: projectURL, mediaURL: sourceURL, mode: .resumeProject)
        let layout = ProjectLayout(root: projectURL)
        let cues = [
            SubtitleCue(id: 1, start: 0, end: 2, text: "Первая проверочная реплика."),
            SubtitleCue(id: 2, start: 2, end: 5, text: "Вторая реплика закрывает тему.")
        ]
        try SRTService().writePreservingIDs(cues, to: layout.subtitlesURL(language: .ru))
        try SRTService().writePreservingIDs(cues, to: layout.fullSRTURL)
        let sourceSRT = try String(contentsOf: layout.subtitlesURL(language: .ru), encoding: .utf8)
        let whisperEvidence: [String: Any] = [
            "transcription": [[
                "text": "проверочная",
                "offsets": ["from": 0, "to": 1900],
                "tokens": [["text": "проверочная", "offsets": ["from": 100, "to": 900]]]
            ], [
                "text": "реплика",
                "offsets": ["from": 2000, "to": 4900],
                "tokens": [["text": "реплика", "offsets": ["from": 2200, "to": 3000]]]
            ]]
        ]
        try JSONSerialization.data(withJSONObject: whisperEvidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: layout.whisperJSONURL, options: .atomic)
        try "Временная шкала корректна\n".write(to: layout.timelineValidationURL, atomically: true, encoding: .utf8)
        try Data("{}".utf8).write(to: layout.transcriptionQualityURL, options: .atomic)
        try Data("[]".utf8).write(to: layout.reviewTasksURL, options: .atomic)
        try "<html>temporary fixture</html>".write(to: layout.transcriptReviewHTMLURL, atomically: true, encoding: .utf8)
        var manifest = try store.load(from: projectURL)
        manifest.durationSeconds = 8
        manifest.languageProfile = LanguageProfile(
            detected: .ru, effective: .ru, confidence: 1, method: "controlled-real-e2e",
            model: nil, modelVersion: nil, sampleRanges: [], manuallyOverridden: false, detectedAt: Date()
        )
        let transcript = cues.map(\.text).joined(separator: "\n\n") + "\n"
        try transcript.write(to: layout.transcriptURL, atomically: true, encoding: .utf8)
        let transcriptRevisionID = "approved-source-e2e"
        try Data(contentsOf: layout.fullSRTURL).write(
            to: layout.subtitleRevisionURL(id: transcriptRevisionID, language: .ru), options: .atomic
        )
        try transcript.write(
            to: layout.transcriptRevisionURL(id: transcriptRevisionID, language: .ru),
            atomically: true,
            encoding: .utf8
        )
        manifest.transcriptRevisions = [TranscriptRevision(
            id: transcriptRevisionID,
            language: .ru,
            origin: .userEdited,
            parentRevisionID: nil,
            transcriptArtifactID: "\(transcriptRevisionID)-txt",
            subtitleArtifactID: "\(transcriptRevisionID)-srt",
            contentHash: StableTopicHash.string(try String(contentsOf: layout.fullSRTURL, encoding: .utf8)),
            createdAt: Date(),
            reviewStatus: .approved
        )]
        try store.save(manifest, to: projectURL)

        func approveTopicRange(start: TimeInterval, end: TimeInterval, revisionID: String, parent: String?) throws {
            let file = TopicsFile(
                adapter: TopicAlgorithmIdentity.hybridAdapter,
                createdAt: Date(),
                sourceSRT: layout.subtitlesURL(language: .ru).path,
                sourceSignature: StableTopicHash.string(sourceSRT),
                status: .ready,
                granularity: .normal,
                embeddingModel: "real-e2e-fixture",
                languageModel: "real-e2e-fixture",
                topics: [TopicSegment(
                    id: "approved-topic-1", title: "Проверенная тема", start: start, end: end,
                    summary: "Реальный FFmpeg cutTopic probe.", keywords: ["проверка"], confidence: 1,
                    boundaryReason: "Controlled fixture.", cueIds: [1, 2]
                )]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let snapshotData = try encoder.encode(file)
            let snapshotURL = layout.topicRevisionJSONURL(id: revisionID)
            let textURL = layout.topicRevisionTextURL(id: revisionID)
            try FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try snapshotData.write(to: snapshotURL, options: .atomic)
            try "Утверждённая проверочная тема\n".write(to: textURL, atomically: true, encoding: .utf8)
            let revision = TopicRevision(
                id: revisionID, language: .ru, granularity: .normal, parentRevisionID: parent,
                jsonPath: snapshotURL.path, textPath: textURL.path,
                contentHash: StableTopicHash.string(String(decoding: snapshotData, as: UTF8.self)),
                status: .approved, createdAt: Date()
            )
            try store.mutate(projectURL) { manifest in
                var revisions = manifest.topicRevisions ?? []
                if let parent, let index = revisions.firstIndex(where: { $0.id == parent }) {
                    revisions[index].status = .superseded
                }
                revisions.append(revision)
                manifest.topicRevisions = revisions
                manifest.topicReviewState = TopicReviewState(
                    enabled: true, activeRevisionIDs: ["ru.normal": revisionID], pendingCheckpoint: nil
                )
            }
        }

        func settings() -> WorkflowSettings {
            WorkflowSettings(
                mediaURL: sourceURL, projectURL: projectURL, selectedOperations: [.cutTopic], mode: .resumeProject,
                rangeStart: 0, rangeEnd: 0, fragmentName: "", burnFragmentSubtitles: false,
                subtitleStyle: .standard, selectedTopicID: "approved-topic-1",
                whisperModelPath: modelFixture.path, whisperLanguage: "ru",
                topicGranularity: .normal, artifactLanguage: .ru, sourceHumanReviewEnabled: false,
                fillerAnalysisBeforeReview: false, topicHumanReviewEnabled: false
            )
        }

        try approveTopicRange(start: 1, end: 4, revisionID: "approved-r1", parent: nil)
        let controller = ProcessController(capturesLaunchArguments: true)
        let engine = WorkflowEngine(store: store, controller: controller)
        func cutAndCount() async throws -> Int {
            controller.resetLaunchLog()
            _ = try await engine.run(settings: settings(), onLog: { _ in })
            return countAccurateCuts(controller)
        }

        let firstRenders = try await cutAndCount()
        var records = try store.load(from: projectURL).fragments ?? []
        try require(firstRenders == 1 && records.count == 1,
                    "First approved cut did not execute exactly one FFmpeg render")
        let firstRecord = records[0]
        try require(firstRecord.cutVideoReuseKey != nil && firstRecord.cutVideoSHA256 != nil,
                    "First real render did not persist reusable proof")

        let secondRenders = try await cutAndCount()
        records = try store.load(from: projectURL).fragments ?? []
        try require(secondRenders == 0 && records.count == 2,
                    "Second equivalent approved cut did not reuse FFmpeg output as a separate result")
        let sameRangeRecords = records.sorted { $0.createdAt < $1.createdAt }
        try require(sameRangeRecords[0].id != sameRangeRecords[1].id
                    && sameRangeRecords[0].videoPath != sameRangeRecords[1].videoPath,
                    "Equivalent cuts did not preserve separate FragmentRecords and paths")
        try require(sameRangeRecords[0].cutVideoReuseKey == sameRangeRecords[1].cutVideoReuseKey
                    && sameRangeRecords[0].cutVideoSHA256 == sameRangeRecords[1].cutVideoSHA256,
                    "Equivalent real cuts do not have equal proof and output digests")
        try await verifyOpenableFragment(sameRangeRecords[0], projectURL: projectURL)
        try await verifyOpenableFragment(sameRangeRecords[1], projectURL: projectURL)

        try approveTopicRange(start: 2, end: 5, revisionID: "approved-r2", parent: "approved-r1")
        let changedRangeRenders = try await cutAndCount()
        records = try store.load(from: projectURL).fragments ?? []
        try require(changedRangeRenders == 1 && records.count == 3,
                    "An approved range change did not perform a fresh FFmpeg render")
        let changedRecord = try requireValue(records.last(where: { $0.start == 2 && $0.end == 5 }),
                                             "Changed approved range has no independent FragmentRecord")
        try require(changedRecord.cutVideoReuseKey != firstRecord.cutVideoReuseKey,
                    "Changed approved range reused the prior render identity")
        try await verifyOpenableFragment(changedRecord, projectURL: projectURL)

        let fallbackReportURL = root.appendingPathComponent("runtime-identity-fallback.json")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--runtime-identity-unavailable", projectURL.path, fallbackReportURL.path]
        child.environment = ProcessInfo.processInfo.environment
        child.environment?["DYLD_UNKNOWN_PROBE"] = "1"
        let childOutput = Pipe()
        child.standardOutput = childOutput
        child.standardError = childOutput
        try child.run()
        let childData = childOutput.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        try require(child.terminationStatus == 0,
                    "Missing runtime proof did not complete normal render fallback: \(String(decoding: childData, as: UTF8.self))")
        let fallback = try JSONDecoder().decode(RealE2ERenderReport.self, from: Data(contentsOf: fallbackReportURL))
        try require(fallback.loaderOverrideDetected && fallback.cutRenderCount == 1 && fallback.reuseMetadataAbsent,
                    "Unprovable FFmpeg runtime did not render normally without reusable metadata "
                        + "(override=\(fallback.loaderOverrideDetected), cuts=\(fallback.cutRenderCount), "
                        + "metadataAbsent=\(fallback.reuseMetadataAbsent))")
        records = try store.load(from: projectURL).fragments ?? []
        try require(records.count == 4, "Fallback cut did not persist its own FragmentRecord")
        try await verifyOpenableFragment(try requireValue(records.first, "Fallback result record missing"), projectURL: projectURL)

        let beforeInvalidProvenance = records.count
        let activeRevision = try requireValue(
            try store.load(from: projectURL).topicRevisions?.first(where: { $0.id == "approved-r2" }),
            "Approved range revision missing before tamper test"
        )
        let snapshotURL = URL(fileURLWithPath: activeRevision.jsonPath)
        let approvedBytes = try Data(contentsOf: snapshotURL)
        try Data("tampered-approved-topic-snapshot".utf8).write(to: snapshotURL, options: .atomic)
        controller.resetLaunchLog()
        var invalidProvenanceRejected = false
        do {
            _ = try await engine.run(settings: settings(), onLog: { _ in })
        } catch let error {
            invalidProvenanceRejected = error.localizedDescription == "Утверждённый набор тем недоступен."
        }
        try approvedBytes.write(to: snapshotURL, options: .atomic)
        let invalidRunCutCount = countAccurateCuts(controller)
        let recordsAfterInvalidRun = try store.load(from: projectURL).fragments ?? []
        try require(invalidProvenanceRejected && invalidRunCutCount == 0
                    && recordsAfterInvalidRun.count == beforeInvalidProvenance,
                    "Insufficient approved-topic provenance launched FFmpeg or created a result")

        print("REAL_CUT_TOPIC_E2E_PASS first_render=1 equivalent_rerender=0 changed_range_render=1 runtime_proof_missing_fallback=1 invalid_provenance_cut=0 records=4 opened=4")
        return 1
    }

    private static func countAccurateCuts(_ controller: ProcessController) -> Int {
        zip(controller.launchedExecutables, controller.launchedArguments).filter { executable, arguments in
            URL(fileURLWithPath: executable).lastPathComponent == "ffmpeg"
                && arguments.count > 2
                && arguments[0] == "-y"
                && arguments[1] == "-ss"
                && arguments.contains("-i")
        }.count
    }

    private static func verifyOpenableFragment(_ record: FragmentRecord, projectURL: URL) async throws {
        let expected = ProjectLayout(root: projectURL).fragmentVideoURL(kind: record.id).standardizedFileURL
        let videoURL = URL(fileURLWithPath: record.videoPath).standardizedFileURL
        try require(videoURL == expected && FileManager.default.isReadableFile(atPath: videoURL.path),
                    "Fragment Open path does not point to a readable canonical artifact")
        let asset = AVURLAsset(url: videoURL)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        try require(playable && duration.seconds.isFinite && duration.seconds > 0,
                    "Persisted fragment cannot be opened as playable media")
    }

    private static func runRuntimeIdentityFallbackChild(projectURL: URL, reportURL: URL) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard FFmpegAdapter.hasDynamicLoaderOverrides(environment: environment) else {
            throw FragmentCutRenderReuseFailure(message: "Fallback child did not receive a DYLD override")
        }
        let store = ProjectStore()
        let manifest = try store.load(from: projectURL)
        let controller = ProcessController(capturesLaunchArguments: true)
        let engine = WorkflowEngine(store: store, controller: controller)
        let settings = WorkflowSettings(
            mediaURL: URL(fileURLWithPath: manifest.sourceMediaPath),
            projectURL: projectURL,
            selectedOperations: [.cutTopic],
            mode: .resumeProject,
            rangeStart: 0,
            rangeEnd: 0,
            fragmentName: "",
            burnFragmentSubtitles: false,
            subtitleStyle: .standard,
            selectedTopicID: "approved-topic-1",
            whisperModelPath: projectURL.deletingLastPathComponent()
                .appendingPathComponent("ggml-real-e2e-fixture.bin").path,
            whisperLanguage: "ru",
            topicGranularity: .normal,
            artifactLanguage: .ru,
            sourceHumanReviewEnabled: false,
            fillerAnalysisBeforeReview: false,
            topicHumanReviewEnabled: false
        )
        controller.resetLaunchLog()
        _ = try await engine.run(settings: settings, onLog: { _ in })
        let records = try store.load(from: projectURL).fragments ?? []
        let latest = try requireValue(records.first, "Fallback workflow failed to register a result")
        let report = RealE2ERenderReport(
            loaderOverrideDetected: FFmpegAdapter.hasDynamicLoaderOverrides(environment: environment),
            cutRenderCount: countAccurateCuts(controller),
            reuseMetadataAbsent: latest.cutVideoReuseKey == nil && latest.cutVideoSHA256 == nil
        )
        try JSONEncoder().encode(report).write(to: reportURL, options: .atomic)
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw FragmentCutRenderReuseFailure(message: message) }
        return value
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
