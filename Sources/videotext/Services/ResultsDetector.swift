import Foundation

struct ResultsDetector {
    func discover(in projectURL: URL) -> [ProjectOutput] {
        let layout = ProjectLayout(root: projectURL)
        let manifest = try? ProjectStore().load(from: projectURL)
        var outputs: [ProjectOutput] = []

        for url in [layout.videoDirectory, layout.audioDirectory, layout.textsDirectory, layout.supportDirectory] {
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let itemURL as URL in enumerator {
                guard (try? itemURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                guard !itemURL.lastPathComponent.contains(".partial.") else { continue }
                guard !isUnapprovedTranslationArtifact(itemURL, manifest: manifest, layout: layout) else { continue }
                outputs.append(makeOutput(kind: kindForFile(itemURL, manifest: manifest), url: itemURL))
            }
        }
        return outputs.sorted { $0.path < $1.path }
    }

    private func isUnapprovedTranslationArtifact(
        _ url: URL,
        manifest: ProjectManifest?,
        layout: ProjectLayout
    ) -> Bool {
        guard let manifest, let sourceLanguage = manifest.languageProfile?.effective else { return false }
        let standardizedPath = url.standardizedFileURL.path
        for target in ArtifactLanguage.allCases where target != sourceLanguage {
            let active = manifest.activeTranscriptRevision(for: target)
            let approved = active?.reviewStatus == .approved
                && (active?.origin == .translated || active?.origin == .userEdited)
            let targetWorkingPaths: Set<String> = [
                layout.transcriptURL(language: target).standardizedFileURL.path,
                layout.subtitlesURL(language: target).standardizedFileURL.path
            ]
            let activeRevisionPaths = Set(active.map { revision in
                [
                    layout.transcriptRevisionURL(id: revision.id, language: target).standardizedFileURL.path,
                    layout.subtitleRevisionURL(id: revision.id, language: target).standardizedFileURL.path
                ]
            } ?? [])
            let isTargetText = standardizedPath.hasSuffix(".\(target.rawValue).txt")
                || standardizedPath.hasSuffix(".\(target.rawValue).srt")
            if isTargetText && (!approved || (!targetWorkingPaths.contains(standardizedPath)
                                              && !activeRevisionPaths.contains(standardizedPath))) {
                return true
            }
            if !approved && (
                standardizedPath == layout.translationReportURL(source: sourceLanguage, target: target).standardizedFileURL.path
                    || standardizedPath == layout.selectedTimingTranslationsURL(source: sourceLanguage, target: target).standardizedFileURL.path
            ) {
                return true
            }
        }
        return false
    }

    private func makeOutput(kind: String, url: URL) -> ProjectOutput {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return ProjectOutput(id: url.path, kind: kind, path: url.path, createdAt: date)
    }

    private func kindForFile(_ url: URL, manifest: ProjectManifest?) -> String {
        switch url.lastPathComponent {
        case "fragment.mp4": return "fragment-video"
        case "fragment_subtitled.mp4":
            let language = manifest?.fragments?.first {
                $0.subtitledVideoPath.map {
                    URL(fileURLWithPath: $0).standardizedFileURL.path == url.standardizedFileURL.path
                } ?? false
            }?.language
            return language.map { "fragment-subtitled-video-\($0.rawValue)" } ?? "fragment-subtitled-video"
        case "fragment_processed.mp4": return "processed-fragment-video"
        case "fragment.srt": return "fragment-srt"
        case "fragment_processed.srt": return "processed-fragment-srt"
        case "processing_recipe.json": return "processed-fragment-recipe"
        case "subtitled.mp4": return "subtitled-video"
        case "subtitled.ru.mp4": return "subtitled-video-ru"
        case "subtitled.en.mp4": return "subtitled-video-en"
        case "full.srt": return "full-srt"
        case "transcript.txt": return "transcript"
        case "topics.json": return "topics"
        case "topics.txt": return "topics-text"
        case "manifest.json": return "manifest"
        case "videotext.log": return "log"
        case "source_audio.wav": return "source-audio"
        case "timeline_validation.txt": return "timeline-validation"
        case "ffprobe.txt": return url.path.contains("Support files/Fragments/") ? "fragment-ffprobe" : "ffprobe"
        case "diagnostics.json": return "diagnostics"
        case "language_detection.json": return "language-detection"
        case "transcription_quality.json": return "transcription-quality"
        case "review_tasks.json": return "review-tasks"
        case "transcript_review.html": return "transcript-review"
        case "whisper.json": return "whisper-json"
        default:
            if url.path.contains("Video/Speed/"), url.pathExtension == "mp4" { return "speed-adjusted-video" }
            if url.path.contains("Subtitles/Speed/"), url.pathExtension == "srt" { return "speed-adjusted-subtitles" }
            if url.path.contains("Topics/Speed/"), url.pathExtension == "json" { return "speed-adjusted-topics" }
            if url.path.contains("Support files/Speed/"), url.lastPathComponent.hasSuffix(".review_tasks.json") { return "speed-adjusted-review-tasks" }
            if url.path.contains("Support files/Speed/"), url.pathExtension == "json" { return "speed-adjustment" }
            if url.path.contains("Video/Blur/"), url.pathExtension == "mp4" { return "blurred-video" }
            if url.path.contains("Support files/Blur/"), url.pathExtension == "json" { return "blur-adjustment" }
            if url.path.contains("Video/Watermark/"), url.pathExtension == "mp4" { return "watermarked-video" }
            if url.path.contains("Support files/Watermark/"), url.pathExtension == "json" { return "watermark-adjustment" }
            if url.path.contains("Support files/Branding/"), url.lastPathComponent.hasPrefix("watermark.") { return "watermark-image" }
            if url.path.contains("Audio/Muted/"), url.pathExtension == "m4a" { return "filler-muted-audio" }
            if url.path.contains("Video/Muted/"), url.pathExtension == "mp4" { return "filler-muted-video" }
            if url.lastPathComponent == "filler_words.json" { return "filler-analysis" }
            if url.lastPathComponent.hasPrefix("filler-mute-"), url.pathExtension == "json" { return "filler-mute-report" }
            if url.lastPathComponent == "audio_analysis.json" { return "audio-analysis" }
            if url.path.contains("Audio/Enhanced/"), url.pathExtension == "m4a" { return "enhanced-audio" }
            if url.path.contains("Video/Enhanced/"), url.pathExtension == "mp4" { return "enhanced-video" }
            if url.lastPathComponent.hasPrefix("audio-enhancement-"), url.pathExtension == "json" { return "audio-enhancement-report" }
            if url.path.contains("Audio/Dubbing/"), url.pathExtension == "m4a" { return "dubbed-audio" }
            if url.path.contains("Video/Dubbing/"), url.pathExtension == "mp4" { return "dubbed-video" }
            if url.lastPathComponent.hasPrefix("dubbing-"), url.pathExtension == "json" { return "dubbing-report" }
            if url.lastPathComponent.hasPrefix("translation."), url.pathExtension == "json" { return "translation-report" }
            if url.lastPathComponent.hasPrefix("transcript."), url.pathExtension == "txt" { return "localized-transcript" }
            if url.lastPathComponent.hasPrefix("subtitles."), url.pathExtension == "srt" { return "localized-subtitles" }
            return "project-file"
        }
    }
}
