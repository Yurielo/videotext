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
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", candidate.path]
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else {
            throw CandidateLifecycleProbeError.failed("Не удалось штатно запустить Candidate")
        }

        let appearanceAllowance: TimeInterval = 10
        let launchDeadline = Date().addingTimeInterval(appearanceAllowance)
        var application: NSRunningApplication?
        while Date() < launchDeadline {
            application = NSWorkspace.shared.runningApplications.first {
                $0.bundleURL?.standardizedFileURL == candidate
            }
            if application != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let application else {
            throw CandidateLifecycleProbeError.failed("Candidate не появился среди запущенных приложений за \(appearanceAllowance)s; elapsed=\(elapsed(since: launchStarted))s")
        }
        let pid = application.processIdentifier
        print("CANDIDATE_LIFECYCLE_OBSERVED pid=\(pid) finished_launching=\(application.isFinishedLaunching) startup_elapsed=\(elapsed(since: launchStarted))s timestamp=\(timestamp())")

        // The candidate's first AppKit window can stall for about 24 seconds.
        // isFinishedLaunching remained false even after 60 seconds in a diagnostic
        // run, so allow 30 seconds for startup before measuring normal Quit.
        let startupStabilization: TimeInterval = 30
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
