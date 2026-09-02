import Foundation

struct DiagnosticsService {
    let runner: ToolRunner

    init(runner: ToolRunner = ToolRunner()) {
        self.runner = runner
    }

    func collect() async -> DiagnosticsReport {
        let canonicalFFmpeg = runner.resolve("ffmpeg")
        let canonicalFFprobe = runner.resolve("ffprobe")
        let fallbackFFmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first {
            FileManager.default.isExecutableFile(atPath: $0) && $0 != canonicalFFmpeg
        }
        let specifications: [(String, String?, [String])] = [
            ("ffmpeg", canonicalFFmpeg, ["-version"]),
            ("ffprobe", canonicalFFprobe, ["-version"]),
            ("ffmpeg-fallback", fallbackFFmpeg, ["-version"]),
            ("whisper-cli", runner.resolve("whisper-cli"), ["--help"]),
            ("ollama", runner.resolve("ollama"), ["--version"]),
            ("brew", runner.resolve("brew"), ["--prefix"]),
            ("say", "/usr/bin/say", ["-v", "?"])
        ]
        var checks: [ToolCheck] = []
        for (name, path, arguments) in specifications {
            var version: String?
            if let path, FileManager.default.isExecutableFile(atPath: path),
               let result = try? await runner.run(path, arguments) {
                let combined = result.stdout + "\n" + result.stderr
                version = combined.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(String.init)
            }
            checks.append(ToolCheck(name: name, path: path, version: version, isAvailable: path.map(FileManager.default.isExecutableFile) ?? false))
        }

        let requiredFilters = ["subtitles", "rubberband", "boxblur", "gblur", "overlay", "afftdn", "loudnorm"]
        var capabilities = Dictionary(uniqueKeysWithValues: requiredFilters.map { ($0, false) })
        if let canonicalFFmpeg,
           let result = try? await runner.run(canonicalFFmpeg, ["-hide_banner", "-filters"]), result.exitCode == 0 {
            let available = Set(result.stdout.split(separator: "\n").compactMap { line in
                line.split(whereSeparator: { $0.isWhitespace }).dropFirst().first.map(String.init)
            })
            for filter in requiredFilters { capabilities[filter] = available.contains(filter) }
        }

        var ollamaModels: [String] = []
        if let ollama = runner.resolve("ollama"), let result = try? await runner.run(ollama, ["list"]), result.exitCode == 0 {
            ollamaModels = result.stdout.split(separator: "\n").dropFirst().compactMap { line in
                line.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
            }
        }
        var voices: [String] = []
        if let result = try? await runner.run("/usr/bin/say", ["-v", "?"]), result.exitCode == 0 {
            voices = result.stdout.split(separator: "\n").compactMap { line in
                let text = String(line)
                guard text.contains(" ru_") || text.contains(" en_") else { return nil }
                return text
            }
        }
        let blockers = await activeProcessBlockers()
        let whisperPath = runner.resolve("whisper-cli")
        let vadModelPath = WhisperVADModelLocator().bestModelPath()
        var warnings: [String] = []
        let missingFilters = capabilities.filter { !$0.value }.map(\.key).sorted()
        if !missingFilters.isEmpty { warnings.append("В каноническом FFmpeg отсутствуют фильтры: \(missingFilters.joined(separator: ", ")).") }
        for requiredModel in ["qwen3:8b", "qwen2.5:7b", "embeddinggemma"] where !ollamaModels.contains(requiredModel) {
            warnings.append("Не найдена модель Ollama \(requiredModel).")
        }
        if !blockers.isEmpty { warnings.append("Terminal-задачи изменения Homebrew заблокированы активными процессами: \(blockers.joined(separator: ", ")).") }
        let hasDaniel = voices.contains { $0.hasPrefix("Daniel (Enhanced) ") }
        let hasYuri = voices.contains { $0.hasPrefix("Yuri (Enhanced) ") }
        if !hasDaniel { warnings.append("Не установлен улучшенный мужской английский системный голос Daniel (Enhanced).") }
        if !hasYuri { warnings.append("Не установлен временно выбранный мужской русский системный голос Yuri (Enhanced).") }
        if vadModelPath == nil { warnings.append("Не найдена модель Silero VAD; Whisper будет использовать стандартную сегментацию.") }

        let terminalTasks = [
            TerminalTaskRecord(id: "TOOL-01", title: "Использовать ffmpeg-full как канонический media tool", command: nil, status: missingFilters.isEmpty ? "completed" : "failed", blockedBy: [], requiresExplicitApproval: false),
            TerminalTaskRecord(id: "TOOL-02", title: "Обновить или отвязать устаревший обычный ffmpeg после smoke-теста", command: "brew upgrade ffmpeg && brew unlink ffmpeg", status: blockers.isEmpty ? "approval-required" : "blocked", blockedBy: blockers, requiresExplicitApproval: true),
            TerminalTaskRecord(
                id: "TOOL-03",
                title: "Whisper 1.9.2, full JSON, confidence и Silero VAD проверены на RU/EN fixtures",
                command: nil,
                status: whisperPath != nil && vadModelPath != nil ? "completed" : "missing-dependency",
                blockedBy: [whisperPath == nil ? "whisper-cli" : nil, vadModelPath == nil ? "Silero VAD model" : nil].compactMap { $0 },
                requiresExplicitApproval: false
            ),
            TerminalTaskRecord(id: "MODEL-01", title: "Использовать qwen3:8b по результатам двустороннего benchmark", command: nil, status: "completed", blockedBy: [], requiresExplicitApproval: false),
            TerminalTaskRecord(
                id: "TTS-01",
                title: "Использовать системные голоса: Daniel для EN, Yuri для RU до будущей замены",
                command: nil,
                status: hasDaniel && hasYuri ? "completed" : "user-action-required",
                blockedBy: [hasDaniel ? nil : "Daniel (Enhanced)", hasYuri ? nil : "Yuri (Enhanced)"].compactMap { $0 },
                requiresExplicitApproval: false
            ),
            TerminalTaskRecord(
                id: "TTS-02",
                title: "Listening QA Piper Denis и Dmitri: оба голоса отклонены и удалены",
                command: nil,
                status: "completed-with-rejection",
                blockedBy: [],
                requiresExplicitApproval: false
            ),
            TerminalTaskRecord(id: "TTS-03", title: "В будущем подобрать более естественный мужской RU-голос", command: nil, status: "deferred", blockedBy: [], requiresExplicitApproval: false),
            TerminalTaskRecord(id: "AUDIO-01", title: "FFmpeg afftdn/loudnorm прошли RU/EN speech-noise benchmark", command: nil, status: "completed", blockedBy: [], requiresExplicitApproval: false),
            TerminalTaskRecord(
                id: "AUDIO-02",
                title: "NARA-WPE отклонён Product Owner: слышимого уменьшения реверберации нет",
                command: nil,
                status: "completed-with-rejection",
                blockedBy: [],
                requiresExplicitApproval: false
            ),
            TerminalTaskRecord(
                id: "AUDIO-03",
                title: "UVR DeEcho принят на контрольных RU/EN дорожках",
                command: nil,
                status: "completed",
                blockedBy: [],
                requiresExplicitApproval: false
            )
        ]
        let brewPrefix = checks.first(where: { $0.name == "brew" })?.version
        return DiagnosticsReport(
            path: ProcessInfo.processInfo.environment["PATH"] ?? "",
            homebrewPrefix: brewPrefix,
            tools: checks,
            canonicalFFmpegPath: canonicalFFmpeg,
            capabilities: capabilities,
            ollamaModels: ollamaModels,
            systemVoices: voices,
            warnings: warnings,
            terminalTasks: terminalTasks
        )
    }

    private func activeProcessBlockers() async -> [String] {
        guard let pgrep = runner.resolve("pgrep") else { return [] }
        var active: [String] = []
        for name in ["videotext", "whisper-cli", "ffmpeg", "ffprobe"] {
            if let result = try? await runner.run(pgrep, ["-x", name]), result.exitCode == 0,
               !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                active.append(name)
            }
        }
        return active
    }
}
