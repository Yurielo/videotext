import Foundation

struct TranslationRequestCue: Codable, Equatable {
    var id: Int
    var text: String
}

struct TranslationIssue: Equatable {
    var cueID: Int
    var reasonCodes: [String]
    var candidateText: String?
}

struct TranslationAdapterResult {
    var cues: [SubtitleCue]
    var issues: [TranslationIssue]
    var model: String
}

protocol TranslationAIProvider {
    func preferredModel() async throws -> String
    func translate(
        cues: [TranslationRequestCue],
        source: ArtifactLanguage,
        target: ArtifactLanguage,
        model: String,
        correction: String?
    ) async throws -> [Int: String]
}

struct TranslationAdapter {
    let provider: TranslationAIProvider
    var batchSize = 32
    var maximumAttempts = 2

    init(provider: TranslationAIProvider = OllamaTranslationProvider()) {
        self.provider = provider
    }

    func translate(
        cues: [SubtitleCue],
        source: ArtifactLanguage,
        target: ArtifactLanguage,
        onProgress: @escaping (Double) -> Void,
        onLog: @escaping (String) -> Void
    ) async throws -> TranslationAdapterResult {
        guard source != target else {
            throw WorkflowError.processFailed("Язык перевода должен отличаться от языка оригинала.")
        }
        guard !cues.isEmpty else { throw WorkflowError.missingFullSRT }
        let model = try await provider.preferredModel()
        var translatedByID: [Int: String] = [:]
        var issues: [TranslationIssue] = []
        let batches = stride(from: 0, to: cues.count, by: max(batchSize, 1)).map {
            Array(cues[$0..<min($0 + max(batchSize, 1), cues.count)])
        }

        for (batchIndex, batch) in batches.enumerated() {
            try Task.checkCancellation()
            let request = batch.map { TranslationRequestCue(id: $0.id, text: $0.text) }
            var lastResponse: [Int: String] = [:]
            var lastReasons: [String] = []
            var accepted = false
            for attempt in 1...max(maximumAttempts, 1) {
                let correction = lastReasons.isEmpty ? nil : lastReasons.joined(separator: "; ")
                do {
                    lastResponse = try await provider.translate(
                        cues: request,
                        source: source,
                        target: target,
                        model: model,
                        correction: correction
                    )
                    lastReasons = validate(response: lastResponse, sourceCues: request, target: target)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastReasons = ["provider-error: \(error.localizedDescription)"]
                }
                if lastReasons.isEmpty {
                    accepted = true
                    break
                }
                onLog("Пакет перевода \(batchIndex + 1)/\(batches.count), попытка \(attempt), отклонён: \(lastReasons.joined(separator: "; ")).")
            }

            if accepted {
                translatedByID.merge(lastResponse) { _, new in new }
            } else {
                for cue in batch {
                    issues.append(TranslationIssue(
                        cueID: cue.id,
                        reasonCodes: lastReasons.isEmpty ? ["translation-invalid"] : lastReasons,
                        candidateText: lastResponse[cue.id]
                    ))
                    translatedByID[cue.id] = lastResponse[cue.id]?.trimmingCharacters(in: .whitespacesAndNewlines).nonempty ?? cue.text
                }
            }
            onProgress(Double(batchIndex + 1) / Double(max(batches.count, 1)))
        }

        let translated = cues.map { cue in
            SubtitleCue(id: cue.id, start: cue.start, end: cue.end, text: translatedByID[cue.id] ?? cue.text)
        }
        return TranslationAdapterResult(cues: translated, issues: issues, model: model)
    }

    private func validate(
        response: [Int: String],
        sourceCues: [TranslationRequestCue],
        target: ArtifactLanguage
    ) -> [String] {
        let expected = Set(sourceCues.map(\.id))
        guard Set(response.keys) == expected else { return ["cue-id-set-mismatch"] }
        var reasons: [String] = []
        for cue in sourceCues {
            let translated = response[cue.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if translated.isEmpty { reasons.append("empty-cue-\(cue.id)") }
            if numberTokens(cue.text) != numberTokens(translated) { reasons.append("numbers-changed-cue-\(cue.id)") }
            for term in protectedTerms(cue.text) where !translated.localizedCaseInsensitiveContains(term) {
                reasons.append("protected-term-changed-cue-\(cue.id)-\(term.lowercased())")
            }
            let ratio = Double(translated.count) / Double(max(cue.text.count, 1))
            if ratio < 0.12 || ratio > 7 { reasons.append("length-outlier-cue-\(cue.id)") }
        }
        let combined = response.values.joined(separator: " ")
        if combined.count >= 40 && !looksLike(combined, language: target) {
            reasons.append("target-language-mismatch")
        }
        return Array(Set(reasons)).sorted()
    }

    private func numberTokens(_ text: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"\d+(?:[.,]\d+)?"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]).replacingOccurrences(of: ",", with: ".") }
        }.sorted()
    }

    private func protectedTerms(_ text: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9.-]*"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let projectTerms: Set<String> = ["videotext", "whisper", "ollama", "ffmpeg", "ffprobe"]
        return expression.matches(in: text, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: text) else { return nil }
            let token = String(text[tokenRange]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let lower = token.lowercased()
            let hasDigit = token.contains(where: \.isNumber)
            let uppercaseCount = token.filter(\.isUppercase).count
            let mixedTechnicalCase = uppercaseCount > 1 && uppercaseCount < token.count
            return projectTerms.contains(lower) || hasDigit || mixedTechnicalCase ? token : nil
        }
    }

    private func looksLike(_ text: String, language: ArtifactLanguage) -> Bool {
        let cyrillic = text.unicodeScalars.filter { (0x0400...0x04FF).contains(Int($0.value)) }.count
        let latin = text.unicodeScalars.filter {
            (0x0041...0x005A).contains(Int($0.value)) || (0x0061...0x007A).contains(Int($0.value))
        }.count
        switch language {
        case .ru: return cyrillic > latin
        case .en: return latin > cyrillic
        }
    }
}

struct OllamaTranslationProvider: TranslationAIProvider {
    private let baseURL = URL(string: "http://127.0.0.1:11434")!
    private let candidates = ["qwen3:8b", "qwen2.5:7b"]

    func preferredModel() async throws -> String {
        let installed = try await installedModels()
        guard let model = candidates.first(where: { requested in
            installed.contains { matches($0, requested: requested) }
        }) else {
            throw WorkflowError.topicServiceUnavailable("для перевода нужна локальная модель qwen3:8b или qwen2.5:7b.")
        }
        return model
    }

    func translate(
        cues: [TranslationRequestCue],
        source: ArtifactLanguage,
        target: ArtifactLanguage,
        model: String,
        correction: String?
    ) async throws -> [Int: String] {
        let sourceName = source == .ru ? "Russian" : "English"
        let targetName = target == .ru ? "Russian" : "English"
        let input = cues.map { "[cueId=\($0.id)] \($0.text)" }.joined(separator: "\n")
        let correctionText = correction.map { "\nThe previous response was rejected: \($0). Fix these errors." } ?? ""
        let prompt = """
        Translate every cue from \(sourceName) to \(targetName).
        Preserve meaning, names, terminology, numbers, and punctuation. Do not merge, split, omit, or add cues.
        Return only the JSON object required by the schema. Every input cueId must occur exactly once as a key in translations.
        \(input)
        \(correctionText)
        """
        let ids = cues.map { String($0.id) }
        let stringSchema: [String: Any] = ["type": "string", "minLength": 1]
        let translationsSchema: [String: Any] = [
            "type": "object",
            "properties": Dictionary(uniqueKeysWithValues: ids.map { ($0, stringSchema) }),
            "required": ids,
            "additionalProperties": false
        ]
        let format: [String: Any] = [
            "type": "object",
            "properties": ["translations": translationsSchema],
            "required": ["translations"],
            "additionalProperties": false
        ]
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "format": format,
            "messages": [["role": "user", "content": prompt]],
            "options": ["temperature": 0.05, "num_predict": 2400]
        ]
        let data = try await post(path: "api/chat", body: body, timeout: 420)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: contentData) as? [String: Any],
              let values = payload["translations"] as? [String: Any] else {
            throw WorkflowError.processFailed("Ollama вернула повреждённый JSON перевода.")
        }
        var result: [Int: String] = [:]
        for (key, value) in values {
            guard let id = Int(key), let text = value as? String else {
                throw WorkflowError.processFailed("Ollama вернула неверный cueId или тип текста.")
            }
            result[id] = text
        }
        return result
    }

    private func installedModels() async throws -> Set<String> {
        let data = try await get(path: "api/tags", timeout: 8)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            throw WorkflowError.topicServiceUnavailable("не удалось получить список моделей Ollama.")
        }
        return Set(models.flatMap { [$0["name"] as? String, $0["model"] as? String].compactMap { $0 } })
    }

    private func get(path: String, timeout: TimeInterval) async throws -> Data {
        let request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        return try await data(for: request)
    }

    private func post(path: String, body: [String: Any], timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await data(for: request)
    }

    private func data(for request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw WorkflowError.topicServiceUnavailable("Ollama вернула ошибку HTTP.")
            }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WorkflowError {
            throw error
        } catch {
            throw WorkflowError.topicServiceUnavailable("Ollama не отвечает: \(error.localizedDescription)")
        }
    }

    private func matches(_ actual: String, requested: String) -> Bool {
        actual == requested || actual.split(separator: ":").first == requested.split(separator: ":").first
    }
}

private extension String {
    var nonempty: String? { isEmpty ? nil : self }
}
