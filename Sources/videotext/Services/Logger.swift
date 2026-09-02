import Foundation

@MainActor
final class AppLog: ObservableObject {
    @Published var text: String = ""

    func append(_ message: String) {
        let formatter = ISO8601DateFormatter()
        text += "[\(formatter.string(from: Date()))] \(message)\n"
    }

    func write(to projectURL: URL) {
        do {
            try text.write(to: ProjectLayout(root: projectURL).logURL, atomically: true, encoding: .utf8)
        } catch {
            text += "Не удалось записать журнал: \(error.localizedDescription)\n"
        }
    }
}

struct FileLog {
    let projectURL: URL

    func append(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        let url = ProjectLayout(root: projectURL).logURL
        if FileManager.default.fileExists(atPath: url.path),
           let data = line.data(using: .utf8),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
