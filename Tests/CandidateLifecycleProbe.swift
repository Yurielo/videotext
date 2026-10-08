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
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", candidate.path]
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else {
            throw CandidateLifecycleProbeError.failed("Не удалось штатно запустить Candidate")
        }

        let launchDeadline = Date().addingTimeInterval(10)
        var application: NSRunningApplication?
        while Date() < launchDeadline {
            application = NSWorkspace.shared.runningApplications.first {
                $0.bundleURL?.standardizedFileURL == candidate
            }
            if application != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let application else {
            throw CandidateLifecycleProbeError.failed("Candidate не появился среди запущенных приложений")
        }
        let pid = application.processIdentifier
        guard application.terminate() else {
            throw CandidateLifecycleProbeError.failed("Candidate отклонил normal Quit")
        }

        let quitDeadline = Date().addingTimeInterval(10)
        while kill(pid, 0) == 0 && Date() < quitDeadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard kill(pid, 0) != 0 else {
            throw CandidateLifecycleProbeError.failed("Candidate не завершился за 10 секунд после normal Quit")
        }
        return pid
    }
}
