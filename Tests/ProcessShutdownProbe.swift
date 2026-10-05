import Foundation

enum ProcessShutdownProbeError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

@main
struct ProcessShutdownProbe {
    static func main() async {
        do {
            let controller = ProcessController()
            let runner = ToolRunner(controller: controller)
            let task = Task {
                try await runner.run("/bin/sleep", ["30"])
            }
            let deadline = Date().addingTimeInterval(3)
            while controller.activeProcessID == nil && Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard let processID = controller.activeProcessID else {
                throw ProcessShutdownProbeError.failed("внешний процесс не зарегистрирован")
            }
            controller.cancelCurrentProcess(gracePeriod: 0.2)
            do {
                _ = try await task.value
            } catch is CancellationError {
                // Cancellation is an acceptable shutdown result.
            }
            guard kill(processID, 0) != 0 else {
                throw ProcessShutdownProbeError.failed("дочерний процесс остался активным после shutdown")
            }

            let groupTask = Task {
                try await runner.run("/bin/sh", ["-c", "sleep 30 >/dev/null 2>&1 & wait"])
            }
            let groupDeadline = Date().addingTimeInterval(3)
            while controller.activeProcessID == nil && Date() < groupDeadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard let groupLeader = controller.activeProcessID else {
                throw ProcessShutdownProbeError.failed("группа дочернего процесса не зарегистрирована")
            }
            controller.cancelCurrentProcess(gracePeriod: 0.2)
            do {
                _ = try await groupTask.value
            } catch is CancellationError {
                // Cancellation is an acceptable shutdown result.
            }
            guard kill(-groupLeader, 0) != 0 else {
                throw ProcessShutdownProbeError.failed("группа процесса с дочерним worker осталась активной после shutdown")
            }
            print("PROCESS_SHUTDOWN_PROBE_PASS")
        } catch {
            fputs("PROCESS_SHUTDOWN_PROBE_FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
