import AppKit
import Darwin
import Foundation

enum CandidateLifecycleProbeError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}

@main
struct CandidateLifecycleProbe {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw CandidateLifecycleProbeError.failed("Использование: CandidateLifecycleProbe <videotext.app>")
            }
            let candidate = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                throw CandidateLifecycleProbeError.failed("Candidate не найден: \(candidate.path)")
            }

            let firstPID = try launchAndQuit(candidate)
            let secondPID = try launchAndQuit(candidate)
            guard firstPID != secondPID else {
                throw CandidateLifecycleProbeError.failed("Candidate не был перезапущен после normal Quit")
            }
            print("CANDIDATE_LIFECYCLE_PROBE_PASS first_pid=\(firstPID) second_pid=\(secondPID)")
        } catch {
            fputs("CANDIDATE_LIFECYCLE_PROBE_FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func launchAndQuit(_ candidate: URL) throws -> pid_t {
        let launchStarted = Date()
        guard let executable = Bundle(url: candidate)?.executableURL else {
            throw CandidateLifecycleProbeError.failed("Candidate bundle has no executable")
        }
        let process = Process()
        process.executableURL = executable
        try process.run()
        let pid = process.processIdentifier

        let registrationAllowance: TimeInterval = 5
        let registrationDeadline = Date().addingTimeInterval(registrationAllowance)
        var application: NSRunningApplication?
        while Date() < registrationDeadline {
            application = NSRunningApplication(processIdentifier: pid)
            if application != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let application else {
            process.terminate()
            throw CandidateLifecycleProbeError.failed("Candidate не зарегистрировался как запущенное macOS-приложение за \(registrationAllowance)s; pid=\(pid) elapsed=\(elapsed(since: launchStarted))s")
        }
        print("CANDIDATE_LIFECYCLE_OBSERVED pid=\(pid) finished_launching=\(application.isFinishedLaunching) startup_elapsed=\(elapsed(since: launchStarted))s timestamp=\(timestamp())")

        // LaunchServices can report isFinishedLaunching as false indefinitely for
        // an app opened from the release runner. The owned PID is the readiness
        // target, so give its event loop a brief startup interval instead.
        let startupStabilization: TimeInterval = 2
        let stabilizationDeadline = Date().addingTimeInterval(startupStabilization)
        while Date() < stabilizationDeadline {
            guard kill(pid, 0) == 0 else {
                throw CandidateLifecycleProbeError.failed("Candidate завершился во время запуска: pid=\(pid) elapsed=\(elapsed(since: launchStarted))s")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        print("CANDIDATE_LIFECYCLE_READY pid=\(pid) finished_launching=\(application.isFinishedLaunching) startup_elapsed=\(elapsed(since: launchStarted))s timestamp=\(timestamp())")
        let quitStarted = Date()
        guard application.terminate() else {
            throw CandidateLifecycleProbeError.failed("Candidate отклонил normal Quit: pid=\(pid) timestamp=\(timestamp())")
        }
        print("CANDIDATE_LIFECYCLE_QUIT_SENT pid=\(pid) startup_elapsed=\(elapsed(since: launchStarted))s timestamp=\(timestamp())")

        let quitDeadline = quitStarted.addingTimeInterval(10)
        while kill(pid, 0) == 0 && Date() < quitDeadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard kill(pid, 0) == -1 && errno == ESRCH else {
            throw CandidateLifecycleProbeError.failed("Candidate не завершился за 10 секунд после normal Quit: pid=\(pid) quit_elapsed=\(elapsed(since: quitStarted))s timestamp=\(timestamp())")
        }
        print("CANDIDATE_LIFECYCLE_EXIT pid=\(pid) quit_elapsed=\(elapsed(since: quitStarted))s timestamp=\(timestamp())")
        return pid
    }

    private static func elapsed(since date: Date) -> String {
        String(format: "%.3f", Date().timeIntervalSince(date))
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
