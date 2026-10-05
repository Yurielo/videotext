import Foundation

struct ProjectLayout {
    let root: URL

    var videoDirectory: URL { root.appendingPathComponent("Video", isDirectory: true) }
    var textsDirectory: URL { root.appendingPathComponent("Texts", isDirectory: true) }
    var supportDirectory: URL { root.appendingPathComponent("Support files", isDirectory: true) }
    var audioDirectory: URL { root.appendingPathComponent("Audio", isDirectory: true) }

    var transcriptsDirectory: URL { textsDirectory.appendingPathComponent("Transcripts", isDirectory: true) }
    var transcriptRevisionsDirectory: URL { transcriptsDirectory.appendingPathComponent("Revisions", isDirectory: true) }
    var subtitlesDirectory: URL { textsDirectory.appendingPathComponent("Subtitles", isDirectory: true) }
    var subtitleRevisionsDirectory: URL { subtitlesDirectory.appendingPathComponent("Revisions", isDirectory: true) }
    var topicsDirectory: URL { textsDirectory.appendingPathComponent("Topics", isDirectory: true) }
    var topicRevisionsDirectory: URL { topicsDirectory.appendingPathComponent("Revisions", isDirectory: true) }
    var reviewDirectory: URL { textsDirectory.appendingPathComponent("Review", isDirectory: true) }
    var languageDirectory: URL { supportDirectory.appendingPathComponent("Language", isDirectory: true) }
    var qualityDirectory: URL { supportDirectory.appendingPathComponent("Quality", isDirectory: true) }
    var supportReviewDirectory: URL { supportDirectory.appendingPathComponent("Review", isDirectory: true) }
    var audioSupportDirectory: URL { supportDirectory.appendingPathComponent("Audio", isDirectory: true) }
    var brandingDirectory: URL { supportDirectory.appendingPathComponent("Branding", isDirectory: true) }
    var enhancedAudioDirectory: URL { audioDirectory.appendingPathComponent("Enhanced", isDirectory: true) }
    var mutedAudioDirectory: URL { audioDirectory.appendingPathComponent("Muted", isDirectory: true) }
    var dubbingAudioDirectory: URL { audioDirectory.appendingPathComponent("Dubbing", isDirectory: true) }
    var speedVideoDirectory: URL { videoDirectory.appendingPathComponent("Speed", isDirectory: true) }
    var speedSubtitlesDirectory: URL { subtitlesDirectory.appendingPathComponent("Speed", isDirectory: true) }
    var speedTopicsDirectory: URL { topicsDirectory.appendingPathComponent("Speed", isDirectory: true) }
    var speedSupportDirectory: URL { supportDirectory.appendingPathComponent("Speed", isDirectory: true) }
    var blurVideoDirectory: URL { videoDirectory.appendingPathComponent("Blur", isDirectory: true) }
    var blurSupportDirectory: URL { supportDirectory.appendingPathComponent("Blur", isDirectory: true) }
    var watermarkVideoDirectory: URL { videoDirectory.appendingPathComponent("Watermark", isDirectory: true) }
    var watermarkSupportDirectory: URL { supportDirectory.appendingPathComponent("Watermark", isDirectory: true) }
    var mutedVideoDirectory: URL { videoDirectory.appendingPathComponent("Muted", isDirectory: true) }
    var enhancedVideoDirectory: URL { videoDirectory.appendingPathComponent("Enhanced", isDirectory: true) }
    var dubbedVideoDirectory: URL { videoDirectory.appendingPathComponent("Dubbing", isDirectory: true) }

    var manifestURL: URL { supportDirectory.appendingPathComponent("manifest.json") }
    var logURL: URL { supportDirectory.appendingPathComponent("videotext.log") }
    var sourceAudioURL: URL { supportDirectory.appendingPathComponent("source_audio.wav") }
    var timelineValidationURL: URL { supportDirectory.appendingPathComponent("timeline_validation.txt") }
    var ffprobeReportURL: URL { supportDirectory.appendingPathComponent("ffprobe.txt") }
    var diagnosticsURL: URL { supportDirectory.appendingPathComponent("diagnostics.json") }
    var languageDetectionURL: URL { languageDirectory.appendingPathComponent("language_detection.json") }
    func translationReportURL(source: ArtifactLanguage, target: ArtifactLanguage) -> URL {
        languageDirectory.appendingPathComponent("translation.\(source.rawValue)-\(target.rawValue).json")
    }
    func translationCacheDirectory(source: ArtifactLanguage, target: ArtifactLanguage) -> URL {
        languageDirectory.appendingPathComponent("Translation cache", isDirectory: true)
            .appendingPathComponent("\(source.rawValue)-\(target.rawValue)", isDirectory: true)
    }
    var transcriptionQualityURL: URL { qualityDirectory.appendingPathComponent("transcription_quality.json") }
    var reviewTasksURL: URL { supportReviewDirectory.appendingPathComponent("review_tasks.json") }
    var transcriptReviewHTMLURL: URL { reviewDirectory.appendingPathComponent("transcript_review.html") }
    var fillerWordsURL: URL { audioSupportDirectory.appendingPathComponent("filler_words.json") }
    var audioAnalysisURL: URL { audioSupportDirectory.appendingPathComponent("audio_analysis.json") }
    var fullSRTURL: URL { textsDirectory.appendingPathComponent("full.srt") }
    var transcriptURL: URL { textsDirectory.appendingPathComponent("transcript.txt") }
    var whisperJSONURL: URL { supportDirectory.appendingPathComponent("whisper.json") }
    /// Opt-in evidence imported from SeminarText selected-attempt JSON-full.
    /// This is deliberately separate from the legacy VideoText Whisper outputs.
    var selectedTimingDirectory: URL { supportDirectory.appendingPathComponent("Selected timing", isDirectory: true) }
    var selectedTimingSeminarTextDirectory: URL {
        selectedTimingDirectory.appendingPathComponent("SeminarText", isDirectory: true)
    }
    var selectedTimingSourceUnitsURL: URL { selectedTimingDirectory.appendingPathComponent("source_units.json") }
    func selectedTimingTranslationsURL(source: ArtifactLanguage, target: ArtifactLanguage) -> URL {
        selectedTimingDirectory.appendingPathComponent("translations.\(source.rawValue)-\(target.rawValue).json")
    }
    var selectedTimingTranslationCacheDirectory: URL {
        selectedTimingDirectory.appendingPathComponent("Translation cache", isDirectory: true)
    }
    var topicsURL: URL { textsDirectory.appendingPathComponent("topics.json") }
    var topicsTextURL: URL { textsDirectory.appendingPathComponent("topics.txt") }
    var topicCacheDirectory: URL { supportDirectory.appendingPathComponent("Topic cache", isDirectory: true) }
    var topicEmbeddingCacheURL: URL { topicCacheDirectory.appendingPathComponent("embeddings.json") }
    var topicLabelCacheURL: URL { topicCacheDirectory.appendingPathComponent("labels.json") }
    var subtitledVideoURL: URL { videoDirectory.appendingPathComponent("subtitled.mp4") }
    func subtitledVideoURL(language: ArtifactLanguage) -> URL {
        videoDirectory.appendingPathComponent("subtitled.\(language.rawValue).mp4")
    }

    func speedAdjustedVideoURL(source: SpeedSourceKind, language: ArtifactLanguage, factor: Double) -> URL {
        speedVideoDirectory.appendingPathComponent("\(source.rawValue).\(language.rawValue).\(speedToken(factor))x.mp4")
    }

    func speedAdjustedSRTURL(source: SpeedSourceKind, language: ArtifactLanguage, factor: Double) -> URL {
        speedSubtitlesDirectory.appendingPathComponent("\(source.rawValue).\(language.rawValue).\(speedToken(factor))x.srt")
    }

    func speedAdjustmentReportURL(source: SpeedSourceKind, language: ArtifactLanguage, factor: Double) -> URL {
        speedSupportDirectory.appendingPathComponent("\(source.rawValue).\(language.rawValue).\(speedToken(factor))x.json")
    }

    func speedAdjustedTopicsURL(source: SpeedSourceKind, language: ArtifactLanguage, factor: Double, granularity: TopicGranularity) -> URL {
        speedTopicsDirectory.appendingPathComponent("\(source.rawValue).\(language.rawValue).\(speedToken(factor))x.\(granularity.rawValue).json")
    }

    func speedAdjustedReviewTasksURL(source: SpeedSourceKind, language: ArtifactLanguage, factor: Double) -> URL {
        speedSupportDirectory.appendingPathComponent("\(source.rawValue).\(language.rawValue).\(speedToken(factor))x.review_tasks.json")
    }

    func blurredVideoURL(source: SpeedSourceKind, id: String) -> URL {
        blurVideoDirectory.appendingPathComponent("\(source.rawValue).\(safeComponent(id)).mp4")
    }

    func blurAdjustmentReportURL(id: String) -> URL {
        blurSupportDirectory.appendingPathComponent("\(safeComponent(id)).json")
    }

    func storedWatermarkImageURL(hash: String, extension fileExtension: String) -> URL {
        brandingDirectory.appendingPathComponent("watermark.\(safeComponent(hash)).\(safeComponent(fileExtension.lowercased()))")
    }

    func watermarkedVideoURL(source: SpeedSourceKind, id: String) -> URL {
        watermarkVideoDirectory.appendingPathComponent("\(source.rawValue).\(safeComponent(id)).mp4")
    }

    func watermarkAdjustmentReportURL(id: String) -> URL {
        watermarkSupportDirectory.appendingPathComponent("\(safeComponent(id)).json")
    }

    func fillerMutedAudioURL(id: String) -> URL {
        mutedAudioDirectory.appendingPathComponent("\(safeComponent(id)).m4a")
    }

    func fillerMutedVideoURL(id: String) -> URL {
        mutedVideoDirectory.appendingPathComponent("\(safeComponent(id)).mp4")
    }

    func fillerMuteReportURL(id: String) -> URL {
        audioSupportDirectory.appendingPathComponent("\(safeComponent(id)).json")
    }

    func enhancedAudioURL(id: String) -> URL {
        enhancedAudioDirectory.appendingPathComponent("\(safeComponent(id)).m4a")
    }

    func enhancedVideoURL(id: String) -> URL {
        enhancedVideoDirectory.appendingPathComponent("\(safeComponent(id)).mp4")
    }

    func audioEnhancementReportURL(id: String) -> URL {
        audioSupportDirectory.appendingPathComponent("\(safeComponent(id)).json")
    }

    func dubbedAudioURL(id: String) -> URL {
        dubbingAudioDirectory.appendingPathComponent("\(safeComponent(id)).m4a")
    }

    func dubbedVideoURL(id: String) -> URL {
        dubbedVideoDirectory.appendingPathComponent("\(safeComponent(id)).mp4")
    }

    func dubbingReportURL(id: String) -> URL {
        audioSupportDirectory.appendingPathComponent("\(safeComponent(id)).json")
    }
    var videoFragmentsDirectory: URL { videoDirectory.appendingPathComponent("Fragments", isDirectory: true) }
    var textFragmentsDirectory: URL { textsDirectory.appendingPathComponent("Fragments", isDirectory: true) }
    var supportFragmentsDirectory: URL { supportDirectory.appendingPathComponent("Fragments", isDirectory: true) }

    func transcriptURL(language: ArtifactLanguage) -> URL {
        transcriptsDirectory.appendingPathComponent("transcript.\(language.rawValue).txt")
    }

    func subtitlesURL(language: ArtifactLanguage) -> URL {
        subtitlesDirectory.appendingPathComponent("subtitles.\(language.rawValue).srt")
    }

    func transcriptRevisionURL(id: String, language: ArtifactLanguage) -> URL {
        transcriptRevisionsDirectory.appendingPathComponent("\(safeComponent(id)).\(language.rawValue).txt")
    }

    func subtitleRevisionURL(id: String, language: ArtifactLanguage) -> URL {
        subtitleRevisionsDirectory.appendingPathComponent("\(safeComponent(id)).\(language.rawValue).srt")
    }

    func topicsURL(language: ArtifactLanguage, granularity: TopicGranularity) -> URL {
        topicsDirectory
            .appendingPathComponent(language.rawValue, isDirectory: true)
            .appendingPathComponent("\(granularity.rawValue).json")
    }

    func topicsTextURL(language: ArtifactLanguage, granularity: TopicGranularity) -> URL {
        topicsDirectory
            .appendingPathComponent(language.rawValue, isDirectory: true)
            .appendingPathComponent("\(granularity.rawValue).txt")
    }

    func topicRevisionJSONURL(id: String) -> URL {
        topicRevisionsDirectory.appendingPathComponent("\(safeComponent(id)).json")
    }

    func topicRevisionTextURL(id: String) -> URL {
        topicRevisionsDirectory.appendingPathComponent("\(safeComponent(id)).txt")
    }

    func topicCacheDirectory(language: ArtifactLanguage, granularity: TopicGranularity) -> URL {
        topicCacheDirectory
            .appendingPathComponent(language.rawValue, isDirectory: true)
            .appendingPathComponent(granularity.rawValue, isDirectory: true)
    }

    func topicEmbeddingCacheURL(language: ArtifactLanguage) -> URL {
        topicCacheDirectory
            .appendingPathComponent(language.rawValue, isDirectory: true)
            .appendingPathComponent("embeddings.json")
    }

    func topicLabelCacheURL(language: ArtifactLanguage, granularity: TopicGranularity) -> URL {
        topicCacheDirectory(language: language, granularity: granularity)
            .appendingPathComponent("labels.json")
    }

    func legacyManifestBackupURL(schemaVersion: Int) -> URL {
        supportDirectory.appendingPathComponent("manifest.v\(schemaVersion).backup.json")
    }

    func fragmentVideoURL(kind: String) -> URL {
        videoFragmentsDirectory
            .appendingPathComponent(kind, isDirectory: true)
            .appendingPathComponent("fragment.mp4")
    }

    func fragmentSubtitledVideoURL(kind: String) -> URL {
        videoFragmentsDirectory
            .appendingPathComponent(kind, isDirectory: true)
            .appendingPathComponent("fragment_subtitled.mp4")
    }

    func fragmentSRTURL(kind: String) -> URL {
        textFragmentsDirectory
            .appendingPathComponent(kind, isDirectory: true)
            .appendingPathComponent("fragment.srt")
    }

    func fragmentFFprobeURL(kind: String) -> URL {
        supportFragmentsDirectory
            .appendingPathComponent(kind, isDirectory: true)
            .appendingPathComponent("ffprobe.txt")
    }

    func processedFragmentVideoURL(kind: String) -> URL {
        videoFragmentsDirectory
            .appendingPathComponent(kind, isDirectory: true)
            .appendingPathComponent("fragment_processed.mp4")
    }

    func processedFragmentSRTURL(kind: String) -> URL {
        textFragmentsDirectory
            .appendingPathComponent(kind, isDirectory: true)
            .appendingPathComponent("fragment_processed.srt")
    }

    func processedFragmentRecipeURL(kind: String) -> URL {
        supportFragmentsDirectory
            .appendingPathComponent(kind, isDirectory: true)
            .appendingPathComponent("processing_recipe.json")
    }

    func createDirectories() throws {
        let directories = [
            root,
            videoDirectory,
            textsDirectory,
            supportDirectory,
            audioDirectory,
            transcriptsDirectory,
            transcriptRevisionsDirectory,
            subtitlesDirectory,
            subtitleRevisionsDirectory,
            topicsDirectory,
            topicRevisionsDirectory,
            reviewDirectory,
            languageDirectory,
            qualityDirectory,
            supportReviewDirectory,
            audioSupportDirectory,
            brandingDirectory,
            enhancedAudioDirectory,
            mutedAudioDirectory,
            dubbingAudioDirectory,
            speedVideoDirectory,
            speedSubtitlesDirectory,
            speedTopicsDirectory,
            speedSupportDirectory,
            blurVideoDirectory,
            blurSupportDirectory,
            watermarkVideoDirectory,
            watermarkSupportDirectory,
            mutedVideoDirectory,
            enhancedVideoDirectory,
            dubbedVideoDirectory,
            topicCacheDirectory,
            videoFragmentsDirectory,
            textFragmentsDirectory,
            supportFragmentsDirectory
        ]
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func safeComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        return String(scalars)
    }

    private func speedToken(_ factor: Double) -> String {
        String(format: "%.2f", factor).replacingOccurrences(of: ".", with: "_")
    }
}
