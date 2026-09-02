import Foundation

struct WhisperModelLocator {
    private let fileManager = FileManager.default

    func resolvedModelPath(_ userPath: String) throws -> String {
        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let expanded = expandTilde(trimmed)
            if fileManager.isReadableFile(atPath: expanded) {
                return expanded
            }
            throw WorkflowError.processFailed("Файл модели Whisper не найден: \(expanded)")
        }

        if let path = bestModelPath() {
            return path
        }

        throw WorkflowError.processFailed("Не найдена модель Whisper `.bin`. Укажите путь к модели вручную, например ggml-large-v3.bin или ggml-base.bin.")
    }

    func bestModelPath() -> String? {
        let preferredNames = [
            "ggml-large-v3.bin",
            "ggml-large-v3-turbo.bin",
            "ggml-medium.bin",
            "ggml-small.bin",
            "ggml-base.bin",
            "ggml-base.en.bin"
        ]

        for name in preferredNames {
            for root in directSearchRoots() {
                let path = URL(fileURLWithPath: root).appendingPathComponent(name).path
                if fileManager.isReadableFile(atPath: path) {
                    return path
                }
            }
        }
        return candidateFiles().first
    }

    private func directSearchRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/models",
            "\(home)/whisper-models",
            "\(home)/Downloads",
            "\(home)/whisper.cpp/models",
            "\(home)/Developer/whisper.cpp/models",
            "\(home)/Documents/whisper.cpp/models",
            "\(home)/Library/Application Support/Keyboop/models",
            "/opt/homebrew/share/whisper-cpp",
            "/opt/homebrew/share/whisper.cpp/models",
            "/usr/local/share/whisper.cpp/models"
        ]
    }

    private func candidateFiles() -> [String] {
        var results: [String] = []
        let roots = directSearchRoots().filter { !$0.hasSuffix("/Downloads") }
        for root in roots where fileManager.fileExists(atPath: root) {
            if let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                for case let url as URL in enumerator {
                    guard url.pathExtension == "bin", url.lastPathComponent.hasPrefix("ggml-") else { continue }
                    results.append(url.path)
                }
            }
        }
        return Array(Set(results)).sorted()
    }

    private func expandTilde(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}

struct WhisperVADModelLocator {
    private let fileManager = FileManager.default
    private let searchRoots: [String]?

    init(searchRoots: [String]? = nil) {
        self.searchRoots = searchRoots
    }

    func bestModelPath() -> String? {
        let preferredNames = [
            "ggml-silero-v5.1.2.bin",
            "ggml-silero-v5.1.0.bin",
            "ggml-silero-v5.0.0.bin",
            "ggml-silero-v6.2.0.bin"
        ]
        let roots = searchRoots ?? defaultSearchRoots()
        for name in preferredNames {
            for root in roots {
                let path = URL(fileURLWithPath: root).appendingPathComponent(name).path
                if fileManager.isReadableFile(atPath: path) { return path }
            }
        }
        for root in roots where fileManager.fileExists(atPath: root) {
            guard let names = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            let candidates = names.sorted().filter { name in
                name.lowercased().hasPrefix("ggml-silero") && (name as NSString).pathExtension == "bin"
            }
            if let name = candidates.first {
                return URL(fileURLWithPath: root).appendingPathComponent(name).path
            }
        }
        return nil
    }

    private func defaultSearchRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/models",
            "\(home)/whisper-models",
            "\(home)/whisper.cpp/models",
            "\(home)/Developer/whisper.cpp/models",
            "\(home)/Documents/whisper.cpp/models",
            "/opt/homebrew/share/whisper-cpp",
            "/opt/homebrew/share/whisper.cpp/models",
            "/usr/local/share/whisper.cpp/models"
        ]
    }
}
