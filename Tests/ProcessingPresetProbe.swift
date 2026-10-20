import Foundation

@main
struct ProcessingPresetProbe {
    static func main() throws {
        let planner = ProcessingPresetPlanner()
        func plan(
            _ configuration: ProcessingPresetConfiguration,
            language: ArtifactLanguage? = nil,
            source: Bool = false,
            topics: Bool = false,
            translation: Bool = false
        ) -> ProcessingPresetPlan {
            planner.make(
                configuration, projectAvailable: true, effectiveLanguage: language,
                approvedSource: source, approvedTopics: topics, approvedTranslation: translation
            )
        }
        var config = ProcessingPresetConfiguration()
        precondition(plan(config).stages == [.transcription])
        precondition(plan(config, language: .ru, source: true).stages.isEmpty)

        config.goal = .topics
        config.topicGranularity = .coarse
        precondition(plan(config, language: .ru, source: true).stages == [.topics])
        precondition(plan(config, language: .ru, source: true, topics: true).stages.isEmpty)

        config.goal = .sourceSubtitles
        precondition(plan(config).stages == [.transcription, .render])
        precondition(plan(config, language: .en, source: true).stages == [.render])
        config.scope = .approvedTopic
        precondition(plan(config, language: .ru, source: true).blocker?.contains("утверждённые обычные темы") == true)
        config.topicID = "topic-1"
        precondition(plan(config, language: .ru, source: true, topics: true).stages == [.render])
        config.scope = .fullVideo

        config.goal = .translation
        config.sourceLanguage = "ru"
        config.targetLanguage = .en
        precondition(plan(config).stages == [.transcription, .translation])
        precondition(plan(config, language: .ru, source: true).stages == [.translation])
        precondition(plan(config, language: .ru, source: true, translation: true).stages.isEmpty)
        config.sourceLanguage = "en"
        config.targetLanguage = .ru
        precondition(plan(config).stages == [.transcription, .translation])
        config.targetLanguage = .en
        precondition(plan(config).blocker?.contains("RU↔EN") == true)
        config.sourceLanguage = "auto"
        precondition(plan(config).blocker?.contains("выберите язык исходника") == true)

        config.sourceLanguage = "ru"
        config.targetLanguage = .en
        config.goal = .translatedSubtitles
        precondition(plan(config).stages == [.transcription, .translation, .render])
        precondition(plan(config, language: .ru, source: true, translation: true).stages == [.render])

        config.goal = .processing
        config.effect = .speed
        precondition(plan(config).stages == [.transcription, .render])
        config.speedFactor = 2.5
        precondition(plan(config).blocker?.contains("0.5") == true)
        config.speedFactor = 1.25
        config.scope = .timeFragment
        config.muteFillers = true
        precondition(plan(config, language: .ru, source: true).stages == [.render])
        config.effect = .watermark
        precondition(plan(config, language: .ru, source: true).blocker?.contains("недоступны") == true)
        config.scope = .fullVideo
        precondition(plan(config).blocker?.contains("Mute") == true)
        config.muteFillers = false
        config.effect = .none
        precondition(plan(config).blocker?.contains("Выберите поддерживаемую") == true)

        config.goal = .fullOriginal
        config.effect = .blur
        precondition(plan(config, language: .ru, source: true).blocker?.contains("watermark") == true)
        config.effect = .watermark
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("processing-presets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let image = temporary.appendingPathComponent("logo.png")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jL1cAAAAASUVORK5CYII=")!
        try png.write(to: image)
        config.watermarkImagePath = image.path
        config.combineBlur = true
        precondition(plan(config, language: .ru, source: true).stages == [.render])
        config.goal = .fullTranslated
        precondition(plan(config, language: .ru, source: true, translation: true).stages == [.render])
        config.scope = .approvedTopic
        precondition(plan(config, language: .ru, source: true, topics: true, translation: true).blocker?.contains("контракта") == true)

        config.scope = .fullVideo
        config.name = "Мой YouTube"
        // The preset owns its flags even when Advanced contains another state;
        // direct Advanced runs with no preset keep their own settings.
        var overrideConfig = ProcessingPresetConfiguration()
        overrideConfig.muteFillers = true
        precondition(ProcessingPresetRunContract.muteFillers(overrideConfig, advanced: false))
        precondition(!ProcessingPresetRunContract.muteFillers(nil, advanced: false))
        precondition(ProcessingPresetRunContract.muteFillers(nil, advanced: true))
        precondition(ProcessingPresetRunContract.source(overrideConfig, advanced: .latestFragment) == .fullVideo)
        precondition(ProcessingPresetRunContract.source(nil, advanced: .latestFragment) == .latestFragment)
        var staleExecution = ProcessingPresetExecution(projectPath: "/probe", configuration: overrideConfig, stages: [.render])
        let ownedToken = UUID()
        precondition(!ProcessingPresetRunContract.ownsCompletion(token: nil, activeToken: ownedToken, execution: staleExecution))
        precondition(!ProcessingPresetRunContract.ownsCompletion(token: UUID(), activeToken: ownedToken, execution: staleExecution))
        precondition(ProcessingPresetRunContract.ownsCompletion(token: ownedToken, activeToken: ownedToken, execution: staleExecution))
        staleExecution.status = .awaitingReview
        precondition(!ProcessingPresetRunContract.ownsCompletion(token: ownedToken, activeToken: ownedToken, execution: staleExecution))

        let custom = CustomProcessingPresetStore(fileURL: temporary.appendingPathComponent("prefs/presets.json"))
        try custom.save([config])
        let saved = try custom.load()
        precondition(saved == [config])
        var renamed = config
        renamed.name = "Мой доклад"
        try custom.save([renamed])
        let renamedPresets = try custom.load()
        precondition(renamedPresets.first?.name == "Мой доклад")
        precondition(config.sameOutcome(as: renamed))
        renamed.watermarkOpacity = 0.4
        precondition(!config.sameOutcome(as: renamed))
        try custom.save([])
        let deletedPresets = try custom.load()
        precondition(deletedPresets.isEmpty)
        try Data("{broken".utf8).write(to: custom.fileURL)
        do {
            try custom.save([config])
            preconditionFailure("Corrupt custom preset store was overwritten")
        } catch { /* recovery copy preserved */ }
        let preservedCustomBytes = try Data(contentsOf: custom.fileURL)
        precondition(preservedCustomBytes == Data("{broken".utf8))

        let project = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var execution = ProcessingPresetExecution(
            projectPath: project.standardizedFileURL.path,
            configuration: renamed, stages: [.transcription, .translation, .render]
        )
        let executions = ProcessingPresetExecutionStore()
        try executions.save(execution, to: project)
        let started = try executions.load(from: project)
        precondition(started?.currentStage == 0)
        execution.currentStage = 1
        execution.status = .awaitingReview
        try executions.save(execution, to: project)
        let paused = try executions.load(from: project)
        precondition(paused?.status == .awaitingReview)
        let copied = temporary.appendingPathComponent("copied-project")
        try FileManager.default.createDirectory(at: executions.url(for: copied).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: executions.url(for: project), to: executions.url(for: copied))
        let moved = try executions.load(from: copied)
        precondition(moved == nil)

        // Output identity is bound to the selected goal/stage, not the newest
        // unrelated manifest output. A changed nonempty MP4 cannot reopen Ready.
        var videoConfig = ProcessingPresetConfiguration()
        videoConfig.goal = .processing
        videoConfig.effect = .blur
        var videoExecution = ProcessingPresetExecution(
            projectPath: project.standardizedFileURL.path,
            configuration: videoConfig, stages: [.render]
        )
        let renderStart = Date().addingTimeInterval(-2)
        videoExecution.stageStartedAt = renderStart
        let expectedVideo = project.appendingPathComponent("Video/Blur/expected.mp4")
        let unrelatedVideo = project.appendingPathComponent("Video/Watermark/unrelated.mp4")
        try FileManager.default.createDirectory(at: expectedVideo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelatedVideo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("verified-video-payload".utf8).write(to: expectedVideo)
        try Data("unrelated".utf8).write(to: unrelatedVideo)
        var manifest = ProjectManifest(
            appName: "videotext", appVersion: "0.7.0", build: "probe",
            createdAt: Date(), updatedAt: Date(), sourceMediaPath: "",
            projectFolderPath: project.path, durationSeconds: nil,
            outputs: [
                ProjectOutput(id: "expected", kind: "blurred-video", path: expectedVideo.path, createdAt: Date()),
                ProjectOutput(id: "unrelated", kind: "watermarked-video", path: unrelatedVideo.path, createdAt: Date().addingTimeInterval(1))
            ], diagnostics: nil
        )
        precondition(ProcessingPresetOutputSelection.select(videoExecution, manifest: manifest)?.path == expectedVideo.path)
        videoExecution.resultPath = expectedVideo.path
        videoExecution.resultSHA256 = try ProcessingPresetResultIntegrity.digest(expectedVideo)
        precondition(ProcessingPresetResultIntegrity.matches(videoExecution, projectURL: project))
        try Data("corrupted-but-nonempty".utf8).write(to: expectedVideo)
        precondition(!ProcessingPresetResultIntegrity.matches(videoExecution, projectURL: project))
        videoExecution.resultPath = unrelatedVideo.path
        precondition(!ProcessingPresetResultIntegrity.matches(videoExecution, projectURL: project))
        videoExecution.resultPath = "/outside-project/result.mp4"
        precondition(!ProcessingPresetResultIntegrity.matches(videoExecution, projectURL: project))
        manifest.outputs[0].createdAt = renderStart.addingTimeInterval(-1)
        precondition(ProcessingPresetOutputSelection.select(videoExecution, manifest: manifest) == nil)

        // Translation reuse must remain tied to the active approved source.
        let layout = ProjectLayout(root: project)
        let sourceA = TranscriptRevision(
            id: "source-A", language: .ru, origin: .userEdited, parentRevisionID: nil,
            transcriptArtifactID: "source-a-txt", subtitleArtifactID: "source-a-srt",
            contentHash: nil, createdAt: Date(), reviewStatus: .approved
        )
        let sourceB = TranscriptRevision(
            id: "source-B", language: .ru, origin: .userEdited, parentRevisionID: "source-A",
            transcriptArtifactID: "source-b-txt", subtitleArtifactID: "source-b-srt",
            contentHash: nil, createdAt: Date(), reviewStatus: .approved
        )
        let target = TranscriptRevision(
            id: "target-A", language: .en, origin: .translated, parentRevisionID: nil,
            transcriptArtifactID: "target-txt", subtitleArtifactID: "target-srt",
            contentHash: nil, createdAt: Date(), reviewStatus: .approved
        )
        let subtitles = Data("1\n00:00:00,000 --> 00:00:01,000\nApproved translation\n\n".utf8)
        let transcript = Data("Approved translation\n".utf8)
        for url in [layout.subtitlesURL(language: .en), layout.transcriptURL(language: .en),
                    layout.subtitleRevisionURL(id: target.id, language: .en)] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try subtitles.write(to: layout.subtitlesURL(language: .en))
        try subtitles.write(to: layout.subtitleRevisionURL(id: target.id, language: .en))
        try transcript.write(to: layout.transcriptURL(language: .en))
        let report = TranslationReport(
            schemaVersion: 3, sourceRevisionID: sourceA.id, targetRevisionID: target.id,
            sourceLanguage: .ru, targetLanguage: .en, model: "probe", modelDigest: nil,
            protocolVersion: nil, translatedAt: Date(), cueCount: 1, reviewTaskIDs: [],
            status: .ready, contextIdentity: nil,
            subtitleSHA256: TranslationFingerprint.data(subtitles),
            transcriptSHA256: TranslationFingerprint.data(transcript)
        )
        let reportURL = layout.translationReportURL(source: .ru, target: .en)
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(report).write(to: reportURL)
        manifest.languageProfile = LanguageProfile(
            detected: .ru, effective: .ru, confidence: 1, method: "probe", model: nil,
            modelVersion: nil, sampleRanges: [], manuallyOverridden: false, detectedAt: Date()
        )
        manifest.transcriptRevisions = [sourceA, target]
        manifest.humanReviewState = HumanReviewState(
            sourceReviewEnabled: true, translationReviewEnabled: true, activeRevisionIDs: ["ru": sourceA.id, "en": target.id],
            draftRevisionIDs: [:], pendingCheckpoint: nil
        )
        precondition(ProcessingPresetTranslationEligibility.ready(manifest: manifest, projectURL: project, approvedSource: sourceA))
        manifest.transcriptRevisions?.append(sourceB)
        manifest.humanReviewState?.activeRevisionIDs["ru"] = sourceB.id
        precondition(!ProcessingPresetTranslationEligibility.ready(manifest: manifest, projectURL: project, approvedSource: sourceB))

        try Data("{bad".utf8).write(to: executions.url(for: project), options: .atomic)
        do {
            _ = try executions.load(from: project)
            preconditionFailure("Corrupt execution was accepted")
        } catch { /* fail closed */ }
        print("ProcessingPresetProbe PASS")
    }
}
