import Foundation

struct TranslationRequestCue: Codable, Equatable {
    var id: Int
    var text: String
    var context: TranslationCueContext? = nil
}

struct TranslationOwnershipTask: Codable, Equatable {
    var cueId: Int
    var source: String
    var contextBefore: [TranslationContextCue]
    var contextAfter: [TranslationContextCue]
}

struct TranslationIssue: Equatable {
    var cueID: Int
    var reasonCodes: [String]
    var candidateText: String?
}

/// A structurally valid response can still lose cue ownership if the model
/// changes `sourceEcho`. It is never accepted; the provider may make one
/// correction request for exactly the failed internal subbatch.
enum TranslationOwnershipResponseError: LocalizedError, Equatable {
    case sourceEchoMismatch(cueIDs: [Int])

    var errorDescription: String? {
        switch self {
        case .sourceEchoMismatch(let cueIDs):
            return "TranslateGemma изменила sourceEcho для cueId: \(cueIDs)."
        }
    }

    var correction: String {
        switch self {
        case .sourceEchoMismatch(let cueIDs):
            return "PREVIOUS RESPONSE REJECTED: sourceEcho for cueId \(cueIDs) was altered. Return every sourceEcho byte-for-byte exactly as the corresponding source, including punctuation and whitespace. Do not translate, normalize, shorten, or rewrite sourceEcho."
        }
    }
}

/// A `length` completion is a partial constrained response. It is never
/// decoded or accepted; the provider may retry only a smaller exact owner set.
enum TranslationResponseLengthError: LocalizedError, Equatable {
    case truncated

    var errorDescription: String? {
        "TranslateGemma исчерпала лимит ответа OWNED_CONTENT."
    }
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
                } catch is TranslationOwnershipResponseError {
                    // The provider already used its sole correction retry for
                    // the failed internal subbatch. Do not reissue the whole
                    // execution unit with the same invalid ownership request.
                    reasonsByID = Dictionary(uniqueKeysWithValues: pending.map {
                        ($0.id, ["provider-error: source-echo-ownership-mismatch"])
                    })
                    break
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
    private let transport: ((URLRequest) async throws -> Data)?
    static let model = "translategemma:4b"
    static let protocolVersion = "translategemma-booktext-owned-tasks-v8-docmeta512-lineage2-overlap2x600-source-echo2-pair-schema1-formatting-entity1-ctx8k"
    private let maximumOutputTokens = 4096
    private let maximumContextTokens = 8192
    private let contextSafetyTokens = 256

    init(transport: ((URLRequest) async throws -> Data)? = nil) {
        self.transport = transport
    }

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
        var translated: [Int: String] = [:]
        for batch in try ownershipBatches(cues: cues, source: source, target: target, model: model, correction: correction) {
            try Task.checkCancellation()
            let response: [Int: String]
            do {
                response = try await translateBatch(cues: batch, source: source, target: target, model: model, correction: correction)
            } catch is TranslationResponseLengthError where correction == nil {
                // `done_reason=length` proves only this internal batch was
                // partial. Retry its same owners once as two smaller bounded
                // subbatches; a further length error remains fail-closed.
                guard batch.count > 1 else { throw TranslationResponseLengthError.truncated }
                let split = batch.count / 2
                var recovered: [Int: String] = [:]
                for recoveryBatch in [Array(batch[..<split]), Array(batch[split...])] {
                    let recoveryResponse = try await translateBatch(
                        cues: recoveryBatch, source: source, target: target, model: model, correction: nil
                    )
                    guard Set(recovered.keys).isDisjoint(with: recoveryResponse.keys) else {
                        throw WorkflowError.processFailed("TranslateGemma повторила cueId между length-recovery subbatch.")
                    }
                    recovered.merge(recoveryResponse) { current, _ in current }
                }
                response = recovered
            } catch let ownership as TranslationOwnershipResponseError where correction == nil {
                // Keep the same owned cues and schema. The correction can make
                // a near-limit batch larger, so re-plan it against the same
                // context budget before its one permitted recovery request.
                var corrected: [Int: String] = [:]
                for correctionBatch in try ownershipBatches(
                    cues: batch,
                    source: source,
                    target: target,
                    model: model,
                    correction: ownership.correction
                ) {
                    let correctionResponse = try await translateBatch(
                        cues: correctionBatch,
                        source: source,
                        target: target,
                        model: model,
                        correction: ownership.correction
                    )
                    guard Set(corrected.keys).isDisjoint(with: correctionResponse.keys) else {
                        throw WorkflowError.processFailed("TranslateGemma повторила cueId между correction subbatch.")
                    }
                    corrected.merge(correctionResponse) { current, _ in current }
                }
                response = corrected
            }
            guard Set(translated.keys).isDisjoint(with: response.keys) else {
                throw WorkflowError.processFailed("TranslateGemma повторила cueId между execution batch.")
            }
            translated.merge(response) { current, _ in current }
        }
        return translated
    }

    func ownershipBatches(
        cues: [TranslationRequestCue],
        source: ArtifactLanguage,
        target: ArtifactLanguage,
        model: String,
        correction: String?
    ) throws -> [[TranslationRequestCue]] {
        var batches: [[TranslationRequestCue]] = []
        var current: [TranslationRequestCue] = []
        for cue in cues {
            let candidate = current + [cue]
            if !current.isEmpty && estimatedContextTokens(
                cues: candidate, source: source, target: target, model: model, correction: correction
            ) > maximumContextTokens - contextSafetyTokens {
                batches.append(current)
                current = [cue]
            } else {
                current = candidate
            }
            guard estimatedContextTokens(
                cues: current, source: source, target: target, model: model, correction: correction
            ) <= maximumContextTokens - contextSafetyTokens else {
                throw WorkflowError.processFailed("CueId \(cue.id) превышает безопасный контекст TranslateGemma и требует Human Review.")
            }
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    func estimatedContextTokens(
        cues: [TranslationRequestCue],
        source: ArtifactLanguage,
        target: ArtifactLanguage,
        model: String,
        correction: String?
    ) -> Int {
        let prompt = translationPrompt(cues: cues, source: source, target: target, correction: correction)
        let body = orderedRequestBody(prompt: prompt, cues: cues, model: model)
        // Conservative for mixed JSON, English and Cyrillic; the separate
        // reserve covers tokenizer variance and chat-template overhead.
        let estimatedInput = max(1, (body.count + 2) / 3)
        return estimatedInput + outputBudget(for: cues)
    }

    private func translateBatch(
        cues: [TranslationRequestCue],
        source: ArtifactLanguage,
        target: ArtifactLanguage,
        model: String,
        correction: String?
    ) async throws -> [Int: String] {
        let prompt = translationPrompt(cues: cues, source: source, target: target, correction: correction)
        let body = orderedRequestBody(prompt: prompt, cues: cues, model: model)
        let data = try await post(path: "api/chat", body: body, timeout: 300)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw WorkflowError.processFailed("TranslateGemma вернула ответ без текста перевода.")
        }
        if root["done_reason"] as? String == "length" {
            throw TranslationResponseLengthError.truncated
        }
        let translated = normalize(content)
        guard root["done"] as? Bool != false,
              root["done_reason"] as? String == nil || root["done_reason"] as? String == "stop",
              !translated.isEmpty, !translated.contains("```"), !hasUnexpectedLabel(translated) else {
            throw WorkflowError.processFailed("TranslateGemma вернула неполный ответ OWNED_CONTENT.")
        }
        let rows = try JSONDecoder().decode([OwnedTranslation].self, from: Data(translated.utf8))
        let sourceByID = Dictionary(uniqueKeysWithValues: cues.map { ($0.id, $0.text) })
        guard rows.count == cues.count, Set(rows.map(\.cueId)).count == rows.count,
              Set(rows.map(\.cueId)) == Set(cues.map(\.id)) else {
            throw WorkflowError.processFailed("TranslateGemma нарушила ownership cueId в ответе.")
        }
        let mismatchedEchoes = rows.compactMap { row in
            sourceByID[row.cueId] == row.sourceEcho ? nil : row.cueId
        }.sorted()
        guard mismatchedEchoes.isEmpty else {
            throw TranslationOwnershipResponseError.sourceEchoMismatch(cueIDs: mismatchedEchoes)
        }
        return Dictionary(uniqueKeysWithValues: rows.map {
            ($0.cueId, removingAppendedFormattingEntities($0.text).trimmingCharacters(in: .whitespacesAndNewlines))
        })
    }

    private func removingAppendedFormattingEntities(_ text: String) -> String {
        // TranslateGemma has emitted these literal XML encodings only as
        // terminal layout/control artifacts. They are not source content and
        // would otherwise be misread as numeric translations. Do not decode
        // or alter any other entity, nor an occurrence inside the text.
        let artifacts = ["&#x0002;", "&#x20;", "&#x0A;"]
        var normalized = text
        while let artifact = artifacts.first(where: { normalized.hasSuffix($0) }) {
            normalized.removeLast(artifact.count)
        }
        return normalized
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
            : " Reproduce these tokens exactly, without translating or changing them: \(protected.joined(separator: ", "))."
        let correctionInstruction = correction.map { "\n\($0)" } ?? ""
        let tasks = cues.map { cue in
            TranslationOwnershipTask(
                cueId: cue.id,
                source: cue.text,
                contextBefore: cue.context?.before ?? [],
                contextAfter: cue.context?.after ?? []
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Field order is part of the small-model attention contract: the owned
        // identity and source must precede read-only overlap in every task.
        let tasksJSON = "[" + tasks.map { task in
            let source = String(decoding: try! encoder.encode(task.source), as: UTF8.self)
            let before = String(decoding: try! encoder.encode(task.contextBefore), as: UTF8.self)
            let after = String(decoding: try! encoder.encode(task.contextAfter), as: UTF8.self)
            return "{\"cueId\":\(task.cueId),\"source\":\(source),\"contextBefore\":\(before),\"contextAfter\":\(after)}"
        }.joined(separator: ",") + "]"
        return """
        You are a professional \(sourceName) (\(source.rawValue)) to \(targetName) (\(target.rawValue)) translator. Your goal is to accurately convey meaning and nuances while using natural, established \(targetName) terminology.
        This is a timecoded spoken transcript. Short utterances can belong to different speakers. Original subtitle cues are immutable semantic owners. Execution batching is not a sentence boundary.
        DOCUMENT_CONTEXT (read-only): \(quoted((cues.first?.context?.document ?? "Timecoded spoken transcript.").replacingOccurrences(of: "\n", with: " ")))
        SOURCE OWNERSHIP CONTRACT: Each TRANSLATION_TASK contains exactly one cueId and source plus read-only contextBefore/contextAfter. For every task, first copy that task's source exactly into sourceEcho, then translate ONLY that source into text. Read context only to interpret idioms, pronouns, ellipsis, discourse roles and recurring terminology. Never translate, copy, move, complete or emit a proposition from context or another task. Preserve source incompleteness. Preserve every proposition, negation, number, frequency, modifier, evaluation, name, referent and natural repetition expressed in source. Use established idiomatic \(targetName) terminology rather than literal calques when context determines ordinary meaning. Never redistribute clauses for fluency.\(protectedInstruction)\(correctionInstruction)
        Before answering, silently verify: (1) every cueId has its own exact sourceEcho, (2) every source proposition appears once under its own cueId, (3) no context proposition appears, (4) recurring source terms have contextually consistent idiomatic translations.
        Return exactly one JSON array object per task with cueId, exact sourceEcho, and text. No explanations.
        TRANSLATION_TASKS:
        \(tasksJSON)
        """
    }

    func outputBudget(for cues: [TranslationRequestCue]) -> Int {
        // Reserve the identity envelope even when every utterance is tiny.
        min(maximumOutputTokens, max(256, cues.reduce(0) { $0 + $1.text.count * 5 + 96 }))
    }

    func orderedRequestBody(prompt: String, cues: [TranslationRequestCue], model: String) -> Data {
        let encoder = JSONEncoder()
        func json<T: Encodable>(_ value: T) -> String {
            String(decoding: try! encoder.encode(value), as: UTF8.self)
        }
        // Each oneOf alternative binds a cueId to its own exact sourceEcho.
        // Independent enums would permit a small model to rotate valid echoes
        // between otherwise valid owners. The post-response validator remains
        // authoritative for any decoder/runtime deviation.
        let ownerPairs = cues.map { cue in
            """
            {"type":"object","properties":{"cueId":{"type":"integer","const":\(cue.id)},"sourceEcho":{"type":"string","const":\(json(cue.text))},"text":{"type":"string"}},"required":["cueId","sourceEcho","text"],"additionalProperties":false}
            """
        }.joined(separator: ",")
        let body = """
        {"model":\(json(model)),"stream":false,"format":{"type":"array","minItems":\(cues.count),"maxItems":\(cues.count),"items":{"oneOf":[\(ownerPairs)]}},"messages":[{"role":"user","content":\(json(prompt))}],"options":{"temperature":0,"num_ctx":8192,"num_predict":\(outputBudget(for: cues))}}
        """
        return Data(body.utf8)
    }

    private func quoted(_ text: String) -> String {
        String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
    }

    private struct OwnedTranslation: Decodable {
        var cueId: Int
        var sourceEcho: String
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
        try await post(path: path, body: JSONSerialization.data(withJSONObject: body), timeout: timeout)
    }

    private func post(path: String, body: Data, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
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
            try Task.checkCancellation()
            let data: Data
            if let transport {
                data = try await transport(request)
            } else {
                let (received, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw WorkflowError.topicServiceUnavailable("Ollama вернула ошибку HTTP.")
                }
                data = received
            }
            try Task.checkCancellation()
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
