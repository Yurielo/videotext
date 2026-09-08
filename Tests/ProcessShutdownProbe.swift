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
            print("PROCESS_SHUTDOWN_PROBE_PASS")
        } catch {
            fputs("PROCESS_SHUTDOWN_PROBE_FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
