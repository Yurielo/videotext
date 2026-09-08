import Foundation

enum ProjectRecoveryError: LocalizedError {
    case usage
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .usage: return "Использование: recover_project.sh <video> <проект> <модель-whisper>"
        case .failed(let message): return message
        }
    }
}

@main
struct ProjectRecoveryProbe {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 4 else { throw ProjectRecoveryError.usage }
            let mediaURL = URL(fileURLWithPath: CommandLine.arguments[1])
            let projectURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let modelPath = CommandLine.arguments[3]
            guard FileManager.default.fileExists(atPath: mediaURL.path) else {
                throw ProjectRecoveryError.failed("Исходное видео не найдено: \(mediaURL.path)")
            }
            guard FileManager.default.fileExists(atPath: ProjectLayout(root: projectURL).manifestURL.path) else {
                throw ProjectRecoveryError.failed("Манифест проекта не найден: \(projectURL.path)")
            }
            guard FileManager.default.fileExists(atPath: modelPath) else {
                throw ProjectRecoveryError.failed("Модель Whisper не найдена: \(modelPath)")
            }
            let manifest = try ProjectStore().load(from: projectURL)
            let settings = WorkflowSettings(
                mediaURL: mediaURL,
                projectURL: projectURL,
                selectedOperations: [.transcribe, .topicTimecoding],
                mode: .resumeProject,
                rangeStart: 0,
                rangeEnd: 1,
                fragmentName: "",
                burnFragmentSubtitles: false,
                subtitleStyle: manifest.subtitleStyle ?? .standard,
                selectedTopicID: nil,
                whisperModelPath: modelPath,
                whisperLanguage: manifest.languageProfile?.effective?.rawValue ?? "ru",
                topicGranularity: .normal,
                topicAnalysisMode: .hybrid,
                sourceHumanReviewEnabled: false,
                translationHumanReviewEnabled: false,
                fillerAnalysisBeforeReview: false,
                topicHumanReviewEnabled: true
            )
            let result = try await WorkflowEngine().run(
                settings: settings,
                onLog: { print($0) },
                onProgress: { progress in
                    let percent = Int((progress.overallFraction * 100).rounded())
                    let operation = progress.operation?.title ?? "Подготовка"
                    fputs("\rRECOVERY_PROGRESS=\(percent)% \(operation)", stderr)
                }
            )
            fputs("\n", stderr)
            let layout = ProjectLayout(root: result.projectURL)
            let cues = try SRTService().load(from: layout.fullSRTURL)
            if let issue = TranscriptionQualityService().catastrophicIssue(cues: cues) {
                throw ProjectRecoveryError.failed("Восстановленный проект всё ещё содержит \(issue.message)")
            }
            print("PROJECT_RECOVERY_PASS")
            print("PROJECT_PATH=\(result.projectURL.path)")
            print("CUE_COUNT=\(cues.count)")
            print("TOPIC_REVIEW_PENDING=\(result.topicReviewCheckpoint != nil)")
        } catch {
            fputs("PROJECT_RECOVERY_FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
