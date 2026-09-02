import Foundation

@main
struct ProjectSummaryProbe {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fputs("Использование: videotext-summary-probe <папка-проекта>\n", stderr)
            exit(2)
        }

        let projectURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let summary = ProjectResultSummaryService().summarize(projectURL: projectURL)
        if let status = summary.lastRunStatus {
            print("LAST_RUN=\(status.title)")
        }
        if let error = summary.lastError {
            print("LAST_ERROR=\(error)")
        }
        for artifact in summary.artifacts {
            print("\(artifact.kind.title)=\(artifact.availability.title) | \(artifact.detail)")
        }
    }
}
