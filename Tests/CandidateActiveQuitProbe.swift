import AppKit
import Darwin
import Foundation

enum ActiveQuitProbeError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}

@main
struct CandidateActiveQuitProbe {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3 else {
                throw ActiveQuitProbeError.failed("Использование: CandidateActiveQuitProbe <app> <media>")
            }
            let app = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
            let sourceMedia = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
            let testRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("videotext-candidate-active-quit-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: testRoot) }

            let media = testRoot.appendingPathComponent("active-quit.\(sourceMedia.pathExtension)")
            try FileManager.default.copyItem(at: sourceMedia, to: media)
            let project = testRoot.appendingPathComponent("Обработка видео active-quit", isDirectory: true)
            let history = testRoot.appendingPathComponent("history.json")
            let ollamaBefore = processIDs(matching: "ollama")

            let running = try launch(
                app,
                environment: [
                    "VIDEOTEXT_RELEASE_TEST_MODE": "1",
                    "VIDEOTEXT_RELEASE_TEST_MEDIA": media.path,
                    "VIDEOTEXT_HISTORY_PATH": history.path
                ]
            )
            let owned = try waitForOwnedProcess(parentPID: running.processIdentifier, timeout: 45)
            guard running.terminate() else {
                throw ActiveQuitProbeError.failed("Candidate отклонил normal Quit во время активной операции")
            }
            try waitForExit(running.processIdentifier, timeout: 12)
            for pid in owned where kill(pid, 0) == 0 {
                throw ActiveQuitProbeError.failed("После normal Quit остался VideoText-owned child pid=\(pid)")
            }
            guard processIDs(matching: testRoot.path).isEmpty else {
                throw ActiveQuitProbeError.failed("После normal Quit остался worker временного проекта")
            }
            guard processIDs(matching: "ollama") == ollamaBefore else {
                throw ActiveQuitProbeError.failed("Normal Quit изменил unrelated/shared Ollama processes")
            }

            let manifest = project.appendingPathComponent("Support files/manifest.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else {
                throw ActiveQuitProbeError.failed("Активная операция не успела создать manifest")
            }
            let manifestObject = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
            let workflow = manifestObject?["workflow"] as? [String: Any]
            guard let status = workflow?["status"] as? String, status != "completed" else {
                throw ActiveQuitProbeError.failed("Прерванная операция записала ложный SUCCESS")
            }

            let reopened = try launch(
                app,
                environment: [
                    "VIDEOTEXT_RELEASE_TEST_MODE": "1",
                    "VIDEOTEXT_RELEASE_TEST_PROJECT": project.path,
                    "VIDEOTEXT_HISTORY_PATH": history.path
                ]
            )
            try await Task.sleep(nanoseconds: 2_000_000_000)
            guard kill(reopened.processIdentifier, 0) == 0 else {
                throw ActiveQuitProbeError.failed("Candidate не открыл прерванный проект")
            }
            guard reopened.terminate() else {
                throw ActiveQuitProbeError.failed("Candidate отклонил normal Quit после reopen")
            }
            try waitForExit(reopened.processIdentifier, timeout: 12)
            guard processIDs(matching: testRoot.path).isEmpty else {
                throw ActiveQuitProbeError.failed("После reopen/quit остался worker временного проекта")
            }
            print("CANDIDATE_ACTIVE_QUIT_PASS child=\(owned.sorted()) status=\(status) project=\(project.path)")
        } catch {
            fputs("CANDIDATE_ACTIVE_QUIT_FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func launch(_ app: URL, environment: [String: String]) throws -> NSRunningApplication {
        guard let executable = Bundle(url: app)?.executableURL else {
            throw ActiveQuitProbeError.failed("Candidate bundle has no executable")
        }
        let process = Process()
        process.executableURL = executable
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, requested in requested }
        try process.run()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let running = NSRunningApplication(processIdentifier: process.processIdentifier) {
                return running
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.terminate()
        throw ActiveQuitProbeError.failed("Candidate did not register as a running macOS application")
    }

    private static func waitForOwnedProcess(parentPID: pid_t, timeout: TimeInterval) throws -> Set<pid_t> {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let descendants = descendantProcessIDs(of: parentPID)
            if descendants.contains(where: { pid in
                let command = commandLine(pid)
                return command.contains("seminartext") || command.contains("ffmpeg") || command.contains("whisper-cli")
            }) {
                return descendants
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ActiveQuitProbeError.failed("Candidate не запустил SeminarText/ffmpeg/whisper child за \(Int(timeout)) секунд")
    }

    private static func descendantProcessIDs(of root: pid_t) -> Set<pid_t> {
        let rows = shell("ps -axo pid=,ppid=").split(separator: "\n")
        var children: [pid_t: [pid_t]] = [:]
        for row in rows {
            let values = row.split(whereSeparator: { $0.isWhitespace }).compactMap { pid_t($0) }
            if values.count == 2 { children[values[1], default: []].append(values[0]) }
        }
        var result = Set<pid_t>()
        var pending = children[root] ?? []
        while let pid = pending.popLast() {
            guard result.insert(pid).inserted else { continue }
            pending.append(contentsOf: children[pid] ?? [])
        }
        return result
    }

    private static func processIDs(matching pattern: String) -> Set<pid_t> {
        Set(shell("ps -axo pid=,command=").split(separator: "\n").compactMap { row in
            guard row.contains(pattern) else { return nil }
            return row.split(whereSeparator: { $0.isWhitespace }).first.flatMap { pid_t($0) }
        })
    }

    private static func commandLine(_ pid: pid_t) -> String {
        shell("ps -p \(pid) -o command=").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func waitForExit(_ pid: pid_t, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while kill(pid, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        guard kill(pid, 0) != 0 else {
            throw ActiveQuitProbeError.failed("Candidate pid=\(pid) не завершился после normal Quit")
        }
    }

    private static func shell(_ command: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
