import Foundation
import Darwin

struct CommandResult {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

enum ToolOutputStream: Equatable {
    case stdout
    case stderr
}

final class ProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var launchLog: [String] = []

    var activeProcessID: Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    var launchedExecutables: [String] {
        lock.lock()
        defer { lock.unlock() }
        return launchLog
    }

    func resetLaunchLog() {
        lock.lock()
        launchLog.removeAll()
        lock.unlock()
    }

    func register(_ process: Process, executable: String) {
        lock.lock()
        self.process = process
        launchLog.append(executable)
        lock.unlock()
    }

    func clear(_ completedProcess: Process) {
        lock.lock()
        if process === completedProcess { process = nil }
        lock.unlock()
    }

    func cancelCurrentProcess(gracePeriod: TimeInterval = 2) {
        lock.lock()
        let running = process
        lock.unlock()
        guard let running, running.isRunning else { return }
        running.terminate()
        let deadline = Date().addingTimeInterval(gracePeriod)
        while running.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if running.isRunning {
            kill(running.processIdentifier, SIGKILL)
        }
    }
}

struct ToolRunner {
    static let defaultSearchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    let controller: ProcessController

    init(controller: ProcessController = ProcessController()) {
        self.controller = controller
    }

    func resolve(_ tool: String) -> String? {
        if tool.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: tool) {
            return tool
        }
        if tool == "ffmpeg" || tool == "ffprobe" {
            for prefix in ["/opt/homebrew/opt/ffmpeg-full/bin", "/usr/local/opt/ffmpeg-full/bin"] {
                let path = "\(prefix)/\(tool)"
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        for directory in Self.defaultSearchPaths {
            let path = "\(directory)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        onOutput: ((ToolOutputStream, String) -> Void)? = nil
    ) async throws -> CommandResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": Self.defaultSearchPaths.joined(separator: ":")
        ]) { current, _ in current }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("videotext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let outputURL = temporaryDirectory.appendingPathComponent("stdout.txt")
        let errorURL = temporaryDirectory.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        let outputReader = try FileHandle(forReadingFrom: outputURL)
        let errorReader = try FileHandle(forReadingFrom: errorURL)
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        defer {
            controller.clear(process)
            try? outputHandle.close()
            try? errorHandle.close()
            try? outputReader.close()
            try? errorReader.close()
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        try process.run()
        controller.register(process, executable: executable)
        var stdoutData = Data()
        var stderrData = Data()

        func drain(_ handle: FileHandle, stream: ToolOutputStream, into target: inout Data) throws {
            while true {
                let data = try handle.read(upToCount: 65_536) ?? Data()
                guard !data.isEmpty else { break }
                target.append(data)
                if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    onOutput?(stream, text)
                }
                if data.count < 65_536 { break }
            }
        }

        while process.isRunning {
            if Task.isCancelled {
                controller.cancelCurrentProcess()
                while process.isRunning { usleep(20_000) }
                throw CancellationError()
            }
            try drain(outputReader, stream: .stdout, into: &stdoutData)
            try drain(errorReader, stream: .stderr, into: &stderrData)
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch is CancellationError {
                controller.cancelCurrentProcess()
                while process.isRunning { usleep(20_000) }
                throw CancellationError()
            }
        }
        if Task.isCancelled { throw CancellationError() }
        try outputHandle.synchronize()
        try errorHandle.synchronize()
        try drain(outputReader, stream: .stdout, into: &stdoutData)
        try drain(errorReader, stream: .stderr, into: &stderrData)

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
