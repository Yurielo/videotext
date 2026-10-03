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
        // Foundation creates a separate child process group on macOS. Verify it
        // before signalling; never target a user process by executable name.
        let pid = running.processIdentifier
        let ownedGroup = getpgid(pid) == pid
        if ownedGroup { kill(-pid, SIGTERM) } else { running.terminate() }
        let deadline = Date().addingTimeInterval(gracePeriod)
        while running.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if running.isRunning {
            if ownedGroup && getpgid(pid) == pid { kill(-pid, SIGKILL) }
            else { kill(pid, SIGKILL) }
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

        let workspace = try OwnedTemporaryWorkspace()
        defer { workspace.close() }
        let temporaryDirectory = workspace.url
        process.environment?["TMPDIR"] = temporaryDirectory.path
        process.environment?["TMP"] = temporaryDirectory.path
        process.environment?["TEMP"] = temporaryDirectory.path
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
            if process.isRunning {
                controller.cancelCurrentProcess()
                process.waitUntilExit()
            }
            controller.clear(process)
            try? outputHandle.close()
            try? errorHandle.close()
            try? outputReader.close()
            try? errorReader.close()
        }

        try workspace.prepareLaunch()
        do { try process.run() }
        catch {
            // Process.run failure before launch creates no child.
            if !process.isRunning && process.processIdentifier == 0 { try workspace.abortFailedLaunch() }
            throw error
        }
        controller.register(process, executable: executable)
        try workspace.attachChild(process.processIdentifier)
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

/// Only this private namespace, identity receipt and exclusive lease authorize cleanup.
/// Unmarked historical TMP, user/project files and retained release evidence are never scanned.
final class OwnedTemporaryWorkspace {
    struct Receipt: Codable, Equatable {
        let schema: Int
        let id: String
        let path: String
        let device: UInt64
        let inode: UInt64
        let pid: Int32
        var launchPending: Bool
        var childGroup: Int32?
    }
    let url: URL
    private var receipt: Receipt
    private var lease: Int32 = -1
    private let closeLock = NSLock()
    private static let signalLock = NSLock()
    private static var liveWorkspaces: [String: WeakWorkspace] = [:]
    private final class WeakWorkspace {
        weak var value: OwnedTemporaryWorkspace?
        init(_ value: OwnedTemporaryWorkspace) { self.value = value }
    }
    private static let signalSources: [DispatchSourceSignal] = [SIGINT, SIGTERM].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            signalLock.lock()
            let workspaces = liveWorkspaces.values.compactMap { $0.value }
            signalLock.unlock()
            for workspace in workspaces { workspace.drainForTermination() }
            for workspace in workspaces { workspace.close() }
            _exit(128 + number)
        }
        source.resume()
        return source
    }
    private let fm = FileManager.default

    static var namespace: URL {
        let base = ProcessInfo.processInfo.environment["TMPDIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
        // Foundation intentionally aliases /private/var back to /var on macOS;
        // POSIX realpath gives stable receipt paths. Do not resolve the managed leaf.
        guard let pointer = realpath(base.path, nil) else {
            return base.appendingPathComponent("videotext-owned-v1-\(getuid())", isDirectory: true)
        }
        defer { free(pointer) }
        let parent = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        return parent.appendingPathComponent("videotext-owned-v1-\(getuid())", isDirectory: true)
    }
    private static func identity(_ url: URL) throws -> (UInt64, UInt64) {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else {
            throw NSError(domain: "VideoTextOwnedTMP", code: 1)
        }
        return (UInt64(info.st_dev), UInt64(info.st_ino))
    }
    private static func hasForeignOpenFiles(_ url: URL) -> Bool {
        // An unavailable/failed scanner is not proof of inactivity.
        let scanner = Process()
        scanner.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        scanner.arguments = ["-nP", "+D", url.path, "-Fp"]
        let output = Pipe()
        let errors = Pipe()
        scanner.standardOutput = output
        scanner.standardError = errors
        do { try scanner.run() } catch { return true }
        let deadline = Date().addingTimeInterval(5)
        while scanner.isRunning && Date() < deadline { usleep(20_000) }
        if scanner.isRunning {
            kill(scanner.processIdentifier, SIGKILL)
            scanner.waitUntilExit()
            return true
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        scanner.waitUntilExit()
        guard errorData.isEmpty, [0, 1].contains(scanner.terminationStatus) else { return true }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").contains {
            $0.hasPrefix("p") && Int32($0.dropFirst()) != getpid()
        }
    }
    static func recover() throws {
        let base = namespace
        if !FileManager.default.fileExists(atPath: base.path) {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        _ = try identity(base)
        let children = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
        var records: [(URL, Receipt, (UInt64, UInt64))] = []
        var incompleteCohortAuthority = false
        for child in children {
            guard let bytes = try? Data(contentsOf: child.appendingPathComponent("owner.json")),
                  let record = try? JSONDecoder().decode(Receipt.self, from: bytes),
                  record.schema == 2, record.path == child.path, record.id == child.lastPathComponent,
                  let actual = try? identity(child), actual.0 == record.device, actual.1 == record.inode,
                  record.pid > 0 else {
                // An unknown sibling can conceal a live tool's creator/group.
                incompleteCohortAuthority = true
                continue
            }
            records.append((child, record, actual))
        }
        guard !incompleteCohortAuthority else { return }
        // A tool can write an adapter sibling without currently opening its files.
        // Protect the creator's entire cohort while any proven child/launch lives.
        let pinnedCreators = Set(records.compactMap { _, record, _ -> Int32? in
            record.launchPending || groupAlive(record.childGroup) ? record.pid : nil
        })
        for (child, record, actual) in records {
            guard !pinnedCreators.contains(record.pid) else { continue }
            if kill(record.pid, 0) == 0 || errno != ESRCH { continue }
            let fd = open(child.appendingPathComponent("lease").path, O_RDWR | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            defer { Darwin.close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0, !hasForeignOpenFiles(child),
                  let latest = try? identity(child), latest == actual,
                  let latestBytes = try? Data(contentsOf: child.appendingPathComponent("owner.json")),
                  let latestRecord = try? JSONDecoder().decode(Receipt.self, from: latestBytes), latestRecord == record else { continue }
            try FileManager.default.removeItem(at: child)
        }
    }
    init() throws {
        try Self.recover()
        // Refuse growth when interrupted owned runs cannot be safely recovered.
        let children = try fm.contentsOfDirectory(at: Self.namespace, includingPropertiesForKeys: nil)
        guard children.count < 32 else { throw NSError(domain: "VideoTextOwnedTMP.capacity", code: 1) }
        let id = UUID().uuidString
        url = Self.namespace.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let actual = try Self.identity(url)
        receipt = Receipt(schema: 2, id: id, path: url.path, device: actual.0, inode: actual.1, pid: getpid(),
                          launchPending: false, childGroup: nil)
        lease = open(url.appendingPathComponent("lease").path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
        guard lease >= 0, flock(lease, LOCK_EX | LOCK_NB) == 0 else { throw NSError(domain: "VideoTextOwnedTMP.lease", code: 1) }
        try JSONEncoder().encode(receipt).write(to: url.appendingPathComponent("owner.json"), options: .atomic)
        _ = Self.signalSources
        Self.signalLock.lock()
        Self.liveWorkspaces[receipt.id] = WeakWorkspace(self)
        Self.signalLock.unlock()
    }
    private static func groupAlive(_ group: Int32?) -> Bool {
        guard let group else { return false }
        guard group > 0 else { return true }
        return kill(-group, 0) == 0 || errno != ESRCH
    }
    func prepareLaunch() throws {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard lease >= 0 else { throw CancellationError() }
        receipt.launchPending = true
        try JSONEncoder().encode(receipt).write(to: url.appendingPathComponent("owner.json"), options: .atomic)
    }
    func abortFailedLaunch() throws {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard lease >= 0 else { throw CancellationError() }
        receipt.launchPending = false
        try JSONEncoder().encode(receipt).write(to: url.appendingPathComponent("owner.json"), options: .atomic)
    }
    func attachChild(_ pid: Int32) throws {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard lease >= 0 else { throw CancellationError() }
        // If launch/group evidence cannot be recorded, retain a pending launch.
        let group = getpgid(pid)
        let endedWithoutGroup = group == -1 && errno == ESRCH && !Self.groupAlive(pid)
        guard group == pid || endedWithoutGroup else { throw NSError(domain: "VideoTextOwnedTMP.childGroup", code: 1) }
        receipt.childGroup = pid
        receipt.launchPending = false
        try JSONEncoder().encode(receipt).write(to: url.appendingPathComponent("owner.json"), options: .atomic)
    }
    private func drainOwnedGroup() {
        guard let group = receipt.childGroup, Self.groupAlive(group) else { return }
        kill(-group, SIGTERM)
        let deadline = Date().addingTimeInterval(2)
        while Self.groupAlive(group) && Date() < deadline { usleep(20_000) }
        if Self.groupAlive(group) { kill(-group, SIGKILL) }
        let killDeadline = Date().addingTimeInterval(1)
        while Self.groupAlive(group) && Date() < killDeadline { usleep(20_000) }
    }
    private func drainForTermination() {
        closeLock.lock()
        defer { closeLock.unlock() }
        drainOwnedGroup()
    }
    func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard lease >= 0 else { return }
        drainOwnedGroup()
        defer {
            Darwin.close(lease); lease = -1
            Self.signalLock.lock()
            Self.liveWorkspaces.removeValue(forKey: receipt.id)
            Self.signalLock.unlock()
        }
        guard let actual = try? Self.identity(url), actual.0 == receipt.device, actual.1 == receipt.inode,
              let bytes = try? Data(contentsOf: url.appendingPathComponent("owner.json")),
              let stored = try? JSONDecoder().decode(Receipt.self, from: bytes), stored == receipt, !receipt.launchPending, !Self.groupAlive(receipt.childGroup), !Self.hasForeignOpenFiles(url) else { return }
        try? fm.removeItem(at: url)
    }
    deinit { close() }
}
