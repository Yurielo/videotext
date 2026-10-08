import Foundation

@main
struct SubtitleSourceResolverProbe {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("videotext-subtitle-source-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fixture = try makeFixture(root: root)
        let source = try SubtitleSourceResolver.resolve(.source, manifest: fixture.manifest, projectURL: fixture.project)
        try require(source.language == .en && source.srtURL == fixture.layout.fullSRTURL && !source.isTranslation,
                    "source subtitles did not preserve the legacy full.srt route")

        let translated = try SubtitleSourceResolver.resolve(.approvedTranslation(.ru), manifest: fixture.manifest, projectURL: fixture.project)
        try require(translated.language == .ru && translated.srtURL == fixture.layout.subtitlesURL(language: .ru) && translated.isTranslation,
                    "approved RU subtitles did not resolve to the approved working artifact")
        try require(SubtitleSourceResolver.availableSelections(manifest: fixture.manifest, projectURL: fixture.project)
            == [.source, .approvedTranslation(.ru)], "available choices exposed an unapproved or missing variant")

        let sourceBytes = try Data(contentsOf: fixture.layout.fullSRTURL)
        let translatedBytes = try Data(contentsOf: translated.srtURL)
        try translatedBytes.write(to: fixture.layout.subtitlesURL(language: .ru), options: .atomic)
        try FileManager.default.createDirectory(at: fixture.layout.videoDirectory, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: fixture.layout.subtitledVideoURL(language: .ru))

        let fragmentURL = fixture.layout.fragmentSubtitledVideoURL(kind: "ru-fragment")
        try FileManager.default.createDirectory(at: fragmentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fragment".utf8).write(to: fragmentURL)
        var discoverable = fixture.manifest
        discoverable.fragments = [FragmentRecord(
            id: "ru-fragment", name: "RU", start: 0, end: 1, createdAt: Date(),
            videoPath: fixture.media.path, subtitlePath: fixture.layout.subtitlesURL(language: .ru).path,
            subtitledVideoPath: fragmentURL.path, ffprobeReportPath: nil, style: .standard, language: .ru
        )]
        try fixture.store.save(discoverable, to: fixture.project)
        let outputs = ResultsDetector().discover(in: fixture.project)
        try require(outputs.contains { $0.kind == "subtitled-video-ru" && $0.title == "Полное видео с русскими субтитрами" },
                    "RU full-video result is not identifiable")
        try require(outputs.contains { $0.kind == "fragment-subtitled-video-ru" && $0.title == "Фрагмент с русскими субтитрами" },
                    "RU fragment result is not identifiable")

        try Data("1\n00:00:00,000 --> 00:00:01,000\nПодменённый текст\n".utf8)
            .write(to: fixture.layout.subtitlesURL(language: .ru), options: .atomic)
        try requireThrows("a modified working translation was accepted") {
            _ = try SubtitleSourceResolver.resolve(.approvedTranslation(.ru), manifest: discoverable, projectURL: fixture.project)
        }
        try require(try Data(contentsOf: fixture.layout.fullSRTURL) == sourceBytes,
                    "rejecting RU subtitles changed the original source SRT")

        var pending = discoverable
        pending.transcriptRevisions = pending.transcriptRevisions?.map { revision in
            var revision = revision
            if revision.language == .ru { revision.reviewStatus = .pending }
            return revision
        }
        try translatedBytes.write(to: fixture.layout.subtitlesURL(language: .ru), options: .atomic)
        try requireThrows("a pending RU translation was accepted") {
            _ = try SubtitleSourceResolver.resolve(.approvedTranslation(.ru), manifest: pending, projectURL: fixture.project)
        }
        try require(SubtitleSourceResolver.availableSelections(manifest: pending, projectURL: fixture.project) == [.source],
                    "a pending RU translation was selectable")

        print("SUBTITLE_SOURCE_RESOLVER_PROBE_PASS")
    }

    private static func makeFixture(root: URL) throws -> Fixture {
        let media = root.appendingPathComponent("source.mp4")
        let project = root.appendingPathComponent("project", isDirectory: true)
        try Data("media".utf8).write(to: media)
        let store = ProjectStore(history: ProjectHistoryStore(indexURL: root.appendingPathComponent("history.json")))
        var manifest = try store.ensureProject(at: project, mediaURL: media, mode: .newProject)
        let layout = ProjectLayout(root: project)
        let sourceSRT = "1\n00:00:00,000 --> 00:00:01,000\nThe LED saves energy.\n"
        let translatedSRT = "1\n00:00:00,000 --> 00:00:01,000\nСветодиод экономит энергию.\n"
        try sourceSRT.write(to: layout.fullSRTURL, atomically: true, encoding: .utf8)
        try translatedSRT.write(to: layout.subtitlesURL(language: .ru), atomically: true, encoding: .utf8)
        try sourceSRT.write(to: layout.subtitleRevisionURL(id: "source-en", language: .en), atomically: true, encoding: .utf8)
        try translatedSRT.write(to: layout.subtitleRevisionURL(id: "translation-ru", language: .ru), atomically: true, encoding: .utf8)

        manifest.languageProfile = LanguageProfile(
            detected: .en, effective: .en, confidence: 1, method: "fixture", model: nil, modelVersion: nil,
            sampleRanges: [], manuallyOverridden: false, detectedAt: Date()
        )
        manifest.transcriptRevisions = [
            TranscriptRevision(id: "source-en", language: .en, origin: .userEdited, parentRevisionID: nil,
                               transcriptArtifactID: "source-en-txt", subtitleArtifactID: "source-en-srt",
                               contentHash: StableTopicHash.string(sourceSRT), createdAt: Date(), reviewStatus: .approved),
            TranscriptRevision(id: "translation-ru", language: .ru, origin: .translated, parentRevisionID: "source-en",
                               transcriptArtifactID: "translation-ru-txt", subtitleArtifactID: "translation-ru-srt",
                               contentHash: StableTopicHash.string(translatedSRT), createdAt: Date(), reviewStatus: .approved)
        ]
        var review = HumanReviewState.newProjectDefault
        review.activeRevisionIDs = ["en": "source-en", "ru": "translation-ru"]
        manifest.humanReviewState = review
        manifest.artifacts = [
            ProjectArtifactRecord(id: "translation-ru-srt", kind: .subtitles, path: layout.subtitlesURL(language: .ru).path,
                                  language: .ru, origin: .translated, granularity: nil, sourceArtifactID: "source-en-srt",
                                  sourceRevision: "source-en", dependencyIDs: [], contentHash: StableTopicHash.string(translatedSRT),
                                  createdAt: Date(), generator: "fixture", generatorVersion: "1", model: nil,
                                  validationStatus: .ready, qualityStatus: .ready, reviewTaskCount: 0)
        ]
        try store.save(manifest, to: project)
        return Fixture(media: media, project: project, layout: layout, store: store, manifest: manifest)
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw ProbeFailure(message: message) }
    }

    private static func requireThrows(_ message: String, _ body: () throws -> Void) throws {
        do {
            try body()
            throw ProbeFailure(message: message)
        } catch is ProbeFailure {
            throw ProbeFailure(message: message)
        } catch {
            return
        }
    }

    private struct Fixture {
        let media: URL
        let project: URL
        let layout: ProjectLayout
        let store: ProjectStore
        let manifest: ProjectManifest
    }
}

private struct ProbeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
