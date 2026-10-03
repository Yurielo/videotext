import Foundation

struct TranslationRequestCue: Codable, Equatable {
    var id: Int
    var text: String
    var context: TranslationCueContext? = nil
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
    var modelDigest: String?
    var protocolVersion: String
    var contextIdentity: String? = nil
}

struct TranslationModelIdentity: Codable, Equatable {
    var model: String
    var digest: String?
    var protocolVersion: String
}

protocol TranslationAIProvider {
    func preferredModel() async throws -> String
    func preferredIdentity() async throws -> TranslationModelIdentity
    func translate(
        cues: [TranslationRequestCue],
        source: ArtifactLanguage,
        target: ArtifactLanguage,
        model: String,
        correction: String?
    ) async throws -> [Int: String]
}

extension TranslationAIProvider {
    func preferredIdentity() async throws -> TranslationModelIdentity {
        TranslationModelIdentity(
            model: try await preferredModel(),
            digest: nil,
            protocolVersion: "legacy-cue-json-v1"
        )
    }
}

struct TranslationAdapter {
    let provider: TranslationAIProvider
    var batchSize = 32
    var maximumAttempts = 2

    init(provider: TranslationAIProvider = OllamaTranslationProvider()) {
        self.provider = provider
    }

    func currentIdentity() async throws -> TranslationModelIdentity {
        try await provider.preferredIdentity()
    }

    func translate(
        cues: [SubtitleCue],
        source: ArtifactLanguage,
        target: ArtifactLanguage,
        documentTitle: String? = nil,
        sourceIdentity: String? = nil,
        checkpointDirectory: URL? = nil,
        onProgress: @escaping (Double) -> Void,
        onLog: @escaping (String) -> Void
    ) async throws -> TranslationAdapterResult {
        guard source != target else {
            throw WorkflowError.processFailed("Язык перевода должен отличаться от языка оригинала.")
        }
        guard !cues.isEmpty else { throw WorkflowError.missingFullSRT }
        let identity = try await provider.preferredIdentity()
        let model = identity.model
        let plan = try TranslationContextPlan(cues: cues, documentTitle: documentTitle, chunkSize: batchSize)
        let checkpoints = try TranslationCheckpointStore(directory: checkpointDirectory, plan: plan,
            identity: identity, source: source, target: target, sourceIdentity: sourceIdentity)
        var translatedByID: [Int: String] = [:]
        var issues: [TranslationIssue] = []
        for unit in plan.units {
            try Task.checkCancellation()
            var completed: [TranslationCheckpointEntry] = []
            for entry in checkpoints.load(unit) {
                let request = unit.owned[completed.count]
                guard validate(response: [entry.cueID: entry.text], sourceCues: [request], target: target).isEmpty else { break }
                completed.append(entry)
                translatedByID[entry.cueID] = entry.text
            }
            if !completed.isEmpty { onLog("Перевод: восстановлено cue из checkpoint — \(completed.count).") }
            var pending = Array(unit.owned.dropFirst(completed.count))
            var candidates: [Int: String] = [:]
            var reasonsByID: [Int: [String]] = [:]
            for attempt in 1...max(maximumAttempts, 1) {
                guard !pending.isEmpty else { break }
                try Task.checkCancellation()
                var receivedResponse = false
                do {
                    let response = try await provider.translate(cues: pending, source: source, target: target, model: model, correction: nil)
                    try Task.checkCancellation()
                    reasonsByID = validate(response: response, sourceCues: pending, target: target)
                    for request in pending {
                        if let text = response[request.id] {
                            if reasonsByID[request.id] == nil { translatedByID[request.id] = text }
                            else { candidates[request.id] = text }
                        }
                    }
                    pending = pending.filter { reasonsByID[$0.id] != nil }
                    receivedResponse = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    reasonsByID = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, ["provider-error: \(error.localizedDescription)"]) })
                }
                if receivedResponse {
                    completed = []
                    for request in unit.owned {
                        guard let text = translatedByID[request.id] else { break }
                        completed.append(TranslationCheckpointEntry(cueID: request.id, text: text))
                    }
                    do { try checkpoints.save(completed, unit: unit) }
                    catch { throw WorkflowError.processFailed("Не удалось сохранить checkpoint перевода: \(error.localizedDescription)") }
                }
                if !pending.isEmpty {
                    onLog("Перевод unit \(unit.index), попытка \(attempt), отклонены cueId: \(pending.map(\.id)).")
                }
                onProgress(Double(translatedByID.count) / Double(cues.count))
            }
            for request in pending {
                issues.append(TranslationIssue(cueID: request.id, reasonCodes: reasonsByID[request.id] ?? ["translation-invalid"], candidateText: candidates[request.id]))
                translatedByID[request.id] = candidates[request.id]?.trimmingCharacters(in: .whitespacesAndNewlines).nonempty ?? request.text
            }
            onProgress(Double(translatedByID.count) / Double(cues.count))
        }
        guard Set(translatedByID.keys) == Set(cues.map(\.id)) else {
            throw WorkflowError.processFailed("Сборка перевода нарушает покрытие cueId.")
        }
        try Task.checkCancellation()
        let translated = cues.map { cue in
            SubtitleCue(id: cue.id, start: cue.start, end: cue.end, text: translatedByID[cue.id] ?? cue.text)
        }
        return TranslationAdapterResult(
            cues: translated,
            issues: issues,
            model: model,
            modelDigest: identity.digest,
            protocolVersion: identity.protocolVersion,
            contextIdentity: plan.contextIdentity
        )
    }

    private func validate(
        response: [Int: String],
        sourceCues: [TranslationRequestCue],
        target: ArtifactLanguage
    ) -> [Int: [String]] {
        let expected = Set(sourceCues.map(\.id))
        guard Set(response.keys) == expected else {
            return Dictionary(uniqueKeysWithValues: sourceCues.map { ($0.id, ["cue-id-set-mismatch"]) })
        }
        var reasonsByID: [Int: [String]] = [:]
        for cue in sourceCues {
            let translated = response[cue.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var reasons: [String] = []
            if translated.isEmpty { reasons.append("empty-cue") }
            if numberTokens(cue.text) != numberTokens(translated) { reasons.append("numbers-changed") }
            for term in protectedTerms(cue.text) where !translated.localizedCaseInsensitiveContains(term) {
                reasons.append("protected-term-changed-\(term.lowercased())")
            }
            let ratio = Double(translated.count) / Double(max(cue.text.count, 1))
            if ratio < 0.12 || ratio > 7 { reasons.append("length-outlier") }
            let words = cue.text.split(whereSeparator: { !$0.isLetter })
            let nameLike = words.count >= 2 && words.allSatisfy { $0.first?.isUppercase == true }
            let evidence = linguisticEvidence(translated, source: cue.text)
            if !nameLike && evidence.contains(where: \.isLetter) && !looksLike(evidence, language: target)
                && (evidence.count >= 12 || (translated == cue.text && words.count >= 2)) {
                reasons.append("target-language-mismatch")
            }
            if !reasons.isEmpty { reasonsByID[cue.id] = reasons.sorted() }
        }
        let combined = sourceCues.map { linguisticEvidence(response[$0.id] ?? "", source: $0.text) }.joined(separator: " ")
        if combined.count >= 40 && combined.contains(where: \.isLetter) && !looksLike(combined, language: target) {
            for cue in sourceCues {
                reasonsByID[cue.id, default: []].append("target-language-mismatch")
            }
        }
        return reasonsByID.mapValues { Array(Set($0)).sorted() }
    }

    private func numberTokens(_ text: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"\d+(?:[.,]\d+)?"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]).replacingOccurrences(of: ",", with: ".") }
        }.sorted()
    }

    private func linguisticEvidence(_ text: String, source: String) -> String {
        protectedTerms(source).reduce(text) { result, token in
            result.replacingOccurrences(of: token, with: "", options: .caseInsensitive)
        }
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
    static let model = "translategemma:4b"
    static let protocolVersion = "translategemma-booktext-owned-cues-v4-docmeta512-lineage2-overlap2x600-id-array-grammar2-ctx8k"
    private let maximumOutputTokens = 4096

    func preferredModel() async throws -> String {
        (try await preferredIdentity()).model
    }

    func preferredIdentity() async throws -> TranslationModelIdentity {
        let installed = try await installedModels()
        guard let installedModel = installed.first(where: { matches($0.name, requested: Self.model) || matches($0.model ?? "", requested: Self.model) }) else {
            throw WorkflowError.topicServiceUnavailable("для перевода нужна локальная модель TranslateGemma (translategemma:4b).")
        }
        return TranslationModelIdentity(
            model: Self.model,
            digest: installedModel.digest,
            protocolVersion: Self.protocolVersion
        )
    }

    func translate(
        cues: [TranslationRequestCue],
        source: ArtifactLanguage,
        target: ArtifactLanguage,
        model: String,
        correction: String?
    ) async throws -> [Int: String] {
        guard !cues.isEmpty, Set(cues.map(\.id)).count == cues.count else {
            throw WorkflowError.processFailed("TranslateGemma получила некорректный набор владельцев cueId.")
        }
        try Task.checkCancellation()
        let prompt = translationPrompt(cues: cues, source: source, target: target, correction: correction)
        let schema: [String: Any] = [
            "type": "array", "minItems": cues.count, "maxItems": cues.count,
            "items": ["type": "object", "properties": [
                "cueId": ["type": "integer", "enum": cues.map(\.id)],
                "text": ["type": "string"]
            ], "required": ["cueId", "text"], "additionalProperties": false]
        ]
            let body: [String: Any] = [
                "model": model,
                "stream": false,
                "format": schema,
                "messages": [["role": "user", "content": prompt]],
                "options": ["temperature": 0, "num_ctx": 8192, "num_predict": outputBudget(for: cues)]
            ]
            let data = try await post(path: "api/chat", body: body, timeout: 300)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = root["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                throw WorkflowError.processFailed("TranslateGemma вернула ответ без текста перевода.")
            }
            let translated = normalize(content)
            guard root["done"] as? Bool != false,
                  root["done_reason"] as? String == nil || root["done_reason"] as? String == "stop",
                  !translated.isEmpty, !translated.contains("```"), !hasUnexpectedLabel(translated) else {
                throw WorkflowError.processFailed("TranslateGemma вернула неполный ответ OWNED_CONTENT.")
            }
        let rows = try JSONDecoder().decode([OwnedTranslation].self, from: Data(translated.utf8))
        guard rows.count == cues.count, Set(rows.map(\.cueId)).count == rows.count,
              Set(rows.map(\.cueId)) == Set(cues.map(\.id)) else {
            throw WorkflowError.processFailed("TranslateGemma нарушила ownership cueId в ответе.")
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.cueId, $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) })
    }

    func translationPrompt(
        cues: [TranslationRequestCue],
        source: ArtifactLanguage,
        target: ArtifactLanguage,
        correction: String?
    ) -> String {
        let sourceName = source == .ru ? "Russian" : "English"
        let targetName = target == .ru ? "Russian" : "English"
        let protected = protectedTokens(in: cues.map(\.text).joined(separator: " "))
        let protectedInstruction = protected.isEmpty
            ? ""
            : "Reproduce these tokens exactly, without translating or changing them: \(protected.joined(separator: ", "))."
        let ownedIDs = Set(cues.map(\.id))
        let before = Dictionary(uniqueKeysWithValues: cues.map { cue in
            (String(cue.id), (cue.context?.before ?? []).filter { !ownedIDs.contains($0.id) })
        })
        let after = Dictionary(uniqueKeysWithValues: cues.map { cue in
            (String(cue.id), (cue.context?.after ?? []).filter { !ownedIDs.contains($0.id) })
        })
        let owned = cues.map { TranslationContextCue(id: $0.id, text: $0.text) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let ownedJSON = String(decoding: try! encoder.encode(owned), as: UTF8.self)
        // Read-only context precedes the owned logical content. The identity
        // envelope is necessary for SRT assembly, never approximate reflow.
        return """
        You are a professional \(sourceName) (\(source.rawValue)) to \(targetName) (\(target.rawValue)) translator. Your goal is to accurately convey the meaning and nuances of the original \(sourceName) text while adhering to \(targetName) grammar, vocabulary, and cultural sensitivities.
        For spoken transcripts, preserving the source's incompleteness takes priority over creating a complete grammatical target-language sentence. Never repair the speaker's sentence. Translate incomplete phrases as incomplete phrases.
        DOCUMENT_CONTEXT (read-only quoted data): \(quoted(cues.first?.context?.document ?? "Timecoded spoken transcript."))
        CONTEXT_BEFORE (read-only data, keys identify the owner whose context this is): \(String(decoding: try! encoder.encode(before), as: UTF8.self))
        CONTEXT_AFTER (read-only data, keys identify the owner whose context this is): \(String(decoding: try! encoder.encode(after), as: UTF8.self))
        Use context only to interpret meaning. Translate only OWNED_CONTENT after the two blank lines. Return a JSON array with exactly one object per owned id: {"cueId": original id, "text": translated text}. Preserve each owned id; context ids have zero output ownership. Never include context-only text, explanations or commentary. Preserve numbers, names, referents, punctuation and natural repetitions. Translate each owned text without importing another cue's words. If speech is incomplete and context does not explicitly supply its continuation, preserve the incomplete fragment; do not add an implied completion or another speaker's words.
        A pronoun with an adverb but no stated predicate can be unfinished speech. Preserve its unfinished grammatical form, using an ellipsis if necessary. Do not invent a predicate from a neighboring speaker's statement.
        \(protectedInstruction)
        Produce only the \(targetName) translations in the specified identity envelope. Please translate the following \(sourceName) OWNED_CONTENT into \(targetName):


        \(ownedJSON)
        """
    }

    func outputBudget(for cues: [TranslationRequestCue]) -> Int {
        // Reserve the identity envelope even when every utterance is tiny.
        min(maximumOutputTokens, max(256, cues.reduce(0) { $0 + $1.text.count * 2 + 32 }))
    }

    private func quoted(_ text: String) -> String {
        String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
    }

    private struct OwnedTranslation: Decodable {
        var cueId: Int
        var text: String
    }

    private func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hasUnexpectedLabel(_ text: String) -> Bool {
        let prefix = text.lowercased()
        return prefix.hasPrefix("translation:") || prefix.hasPrefix("перевод:")
    }

    private func protectedTokens(in text: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9.-]*"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let projectTerms: Set<String> = ["videotext", "whisper", "ollama", "ffmpeg", "ffprobe"]
        return expression.matches(in: text, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: text) else { return nil }
            let token = String(text[tokenRange]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let lowercase = token.lowercased()
            let hasDigit = token.contains(where: \.isNumber)
            let uppercaseCount = token.filter(\.isUppercase).count
            return projectTerms.contains(lowercase) || hasDigit || (uppercaseCount > 1 && uppercaseCount < token.count)
                ? token
                : nil
        }
    }

    private func installedModels() async throws -> [InstalledModel] {
        let data = try await get(path: "api/tags", timeout: 8)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            throw WorkflowError.topicServiceUnavailable("не удалось получить список моделей Ollama.")
        }
        return models.compactMap { model in
            guard let name = model["name"] as? String else { return nil }
            return InstalledModel(name: name, model: model["model"] as? String, digest: model["digest"] as? String)
        }
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

    private func matches(_ actual: String, requested: String) -> Bool {
        actual == requested
    }

    private struct InstalledModel {
        var name: String
        var model: String?
        var digest: String?
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
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw WorkflowError.topicServiceUnavailable("Ollama не отвечает: \(error.localizedDescription)")
        }
    }

}

private extension String {
    var nonempty: String? { isEmpty ? nil : self }
}
