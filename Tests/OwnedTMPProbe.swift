import Foundation
import Darwin

@main struct OwnedTMPProbe {
    static func main() async throws {
        if CommandLine.arguments.contains("--recover") {
            try OwnedTemporaryWorkspace.recover()
            return
        }
        if CommandLine.arguments.contains("--orphan") || CommandLine.arguments.contains("--orphan-adapter") {
            let adapter = CommandLine.arguments.contains("--orphan-adapter") ? try OwnedTemporaryWorkspace() : nil
            let workspace = try OwnedTemporaryWorkspace()
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["20"]
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try workspace.prepareLaunch()
            try child.run()
            try workspace.attachChild(child.processIdentifier)
            if let adapter { print("\(adapter.url.path) \(workspace.url.path) \(child.processIdentifier)") }
            else { print("\(workspace.url.path) \(child.processIdentifier)") }
            fflush(stdout)
            sleep(20)
            workspace.close()
            adapter?.close()
            return
        }
        if CommandLine.arguments.contains("--wait") {
            let workspace = try OwnedTemporaryWorkspace()
            print(workspace.url.path)
            fflush(stdout)
            sleep(20)
            workspace.close()
            return
        }
        if CommandLine.arguments.contains("--abandon") {
            let workspace = try OwnedTemporaryWorkspace()
            try Data("stale".utf8).write(to: workspace.url.appendingPathComponent("payload"))
            print(workspace.url.path)
            fflush(stdout)
            _exit(0)
        }
        let base = OwnedTemporaryWorkspace.namespace
        try OwnedTemporaryWorkspace.recover()
        func snapshot() -> (Int, Int) {
            let fm = FileManager.default
            let children = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            let count = children.filter { fm.fileExists(atPath: $0.appendingPathComponent("owner.json").path) }.count
            var bytes = 0
            if let entries = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
                for case let file as URL in entries {
                    if let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), info.isRegularFile == true {
                        bytes += info.fileSize ?? 0
                    }
                }
            }
            return (count, bytes)
        }
        let beforeSnapshot = snapshot()
        let runner = ToolRunner()
        for _ in 0..<12 {
            let result = try await runner.run("/bin/sh", ["-c", "echo fixture > \"$TMPDIR/scratch\"; printf ok"])
            precondition(result.stdout == "ok" && result.exitCode == 0)
            let failed = try await runner.run("/bin/sh", ["-c", "echo fixture > \"$TMPDIR/scratch\"; exit 7"])
            precondition(failed.exitCode == 7)
        }
        let background = try await runner.run("/bin/sh", ["-c", "sleep 20 >/dev/null 2>&1 & printf %s $!"])
        let backgroundPID = Int32(background.stdout)!
        precondition(kill(backgroundPID, 0) != 0, "background descendant survived successful command")
        do { _ = try await runner.run("/does-not-exist", []) } catch { }
        let task = Task { try await runner.run("/bin/sleep", ["10"]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; preconditionFailure("cancel passed") } catch is CancellationError { }
        let unknown = base.appendingPathComponent("foreign-unknown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: unknown) }
        let live = try OwnedTemporaryWorkspace()
        try OwnedTemporaryWorkspace.recover()
        precondition(FileManager.default.fileExists(atPath: live.url.path))
        precondition(FileManager.default.fileExists(atPath: unknown.path))
        live.close()
        precondition(!FileManager.default.fileExists(atPath: live.url.path))
        precondition(FileManager.default.fileExists(atPath: unknown.path))
        let afterSnapshot = snapshot()
        precondition(beforeSnapshot == afterSnapshot)
        print("OWNED_TMP_PASS cycles=12 owned_before=\(beforeSnapshot.0) owned_after=\(afterSnapshot.0) bytes_before=\(beforeSnapshot.1) bytes_after=\(afterSnapshot.1) success/failure/cancel/launch-failure/unknown/live")
    }
}
