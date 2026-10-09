import Foundation

struct SimpleProjectBrowserEntry: Identifiable {
    var id: String { history.projectPath }
    var history: ProjectHistoryEntry
    var isAvailable: Bool
    var availabilityIssue: String?
    var home: SimpleProjectHomeState?
    var generatedVideoCount: Int
    var fragmentCount: Int

    var projectName: String {
        URL(fileURLWithPath: history.projectPath).lastPathComponent
    }
}

/// Builds the browser exclusively from VideoText's existing history index and
/// each known project's accepted manifest/result services.
struct SimpleProjectBrowserStateService {
    let historyStore: ProjectHistoryStore
    private let projectStore: ProjectStore
    private let resultsDetector = ResultsDetector()
    private let resultSummary = ProjectResultSummaryService()
    private let artifactValidator = SimpleProjectArtifactValidator()

    init(historyStore: ProjectHistoryStore = ProjectHistoryStore()) {
        self.historyStore = historyStore
        projectStore = ProjectStore(history: historyStore)
    }

    func entries() -> [SimpleProjectBrowserEntry] {
        historyStore.allEntries().map { history in
            let projectURL = URL(fileURLWithPath: history.projectPath, isDirectory: true)
            let manifestURL = ProjectLayout(root: projectURL).manifestURL
            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                return SimpleProjectBrowserEntry(
                    history: history,
                    isAvailable: false,
                    availabilityIssue: "Проект не найден по сохранённому пути",
                    home: nil,
                    generatedVideoCount: 0,
                    fragmentCount: 0
                )
            }
            let manifest: ProjectManifest
            do {
                manifest = try projectStore.load(from: projectURL)
            } catch {
                return SimpleProjectBrowserEntry(
                    history: history,
                    isAvailable: false,
                    availabilityIssue: "Проект повреждён или несовместим",
                    home: nil,
                    generatedVideoCount: 0,
                    fragmentCount: 0
                )
            }
            let outputs = artifactValidator.validatedOutputs(
                resultsDetector.discover(in: projectURL),
                mediaDuration: manifest.durationSeconds
            )
            let summary = resultSummary.summarize(projectURL: projectURL)
            let home = SimpleProjectHomeStateService().make(
                projectURL: projectURL,
                manifest: manifest,
                topicsDetail: summary.artifact(.topics)?.detail,
                discoveredOutputs: outputs
            )
            return SimpleProjectBrowserEntry(
                history: history,
                isAvailable: FileManager.default.isReadableFile(atPath: manifest.sourceMediaPath),
                availabilityIssue: FileManager.default.isReadableFile(atPath: manifest.sourceMediaPath)
                    ? nil
                    : "Исходный медиафайл недоступен",
                home: home,
                generatedVideoCount: artifactValidator.generatedMediaCount(outputs),
                fragmentCount: artifactValidator.availableFragmentCount(manifest.fragments ?? [])
            )
        }
    }
}

struct SimpleProjectArtifactValidator {
    private let srt = SRTService()

    func validatedOutputs(_ outputs: [ProjectOutput], mediaDuration: TimeInterval? = nil) -> [ProjectOutput] {
        outputs.filter { isUsable($0, mediaDuration: mediaDuration) }
    }

    func generatedMediaCount(_ outputs: [ProjectOutput]) -> Int {
        outputs.filter {
            $0.isGeneratedMedia
                && URL(fileURLWithPath: $0.path).pathExtension.lowercased() == "mp4"
                && nonempty(URL(fileURLWithPath: $0.path))
        }.count
    }

    func availableFragmentCount(_ fragments: [FragmentRecord]) -> Int {
        fragments.filter { fragment in
            let candidates = [fragment.processedVideoPath, fragment.subtitledVideoPath, fragment.videoPath]
                .compactMap { $0 }
                .map(URL.init(fileURLWithPath:))
            return candidates.contains(where: nonempty)
        }.count
    }

    private func isUsable(_ output: ProjectOutput, mediaDuration: TimeInterval?) -> Bool {
        let url = URL(fileURLWithPath: output.path)
        switch output.kind {
        case "full-srt", "localized-subtitles":
            guard nonempty(url),
                  let report = try? srt.loadWithReport(from: url) else { return false }
            return !report.cues.isEmpty
                && srt.validateTimeline(report.cues, mediaDuration: mediaDuration).isEmpty
        case "transcript", "localized-transcript":
            guard nonempty(url),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return true
        }
    }

    private func nonempty(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }
}
