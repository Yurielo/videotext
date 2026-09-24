import Foundation

struct OllamaTopicProvider: TopicAIProvider {
    static let chatTimeoutSeconds: TimeInterval = 360
    let embeddingModel = "embeddinggemma:latest"
    let primaryLanguageModel = "qwen3:8b"
    let fallbackLanguageModel = "gemma3:4b"
    private let baseURL = URL(string: "http://127.0.0.1:11434")!

    func availableLanguageModels() async throws -> [String] {
        let names = try await installedModelNames()
        guard names.contains(where: { matches($0, requested: embeddingModel) }) else {
            throw WorkflowError.topicServiceUnavailable("не найдена модель \(embeddingModel).")
        }
        return [primaryLanguageModel, fallbackLanguageModel].filter { requested in
            names.contains(where: { matches($0, requested: requested) })
        }
    }

    func embeddings(for texts: [String]) async throws -> [[Double]] {
        let payload = EmbedRequest(model: embeddingModel, input: texts, truncate: true)
        let data = try await post(path: "api/embed", body: payload, timeout: 180)
        guard let response = try? JSONDecoder().decode(EmbedResponse.self, from: data),
              response.embeddings.count == texts.count else {
            throw WorkflowError.invalidTopics("не удалось прочитать embeddings из ответа Ollama.")
        }
        return response.embeddings
    }

    func reviewBoundaries(
        _ request: TopicBoundaryReviewRequest,
        model: String,
        correction: String?
    ) async throws -> TopicBoundaryReview {
        let focusSet = Set(request.focusAfterCueIds)
        let focus = request.focusAfterCueIds.map(String.init).joined(separator: ", ")
        let candidates = request.candidates.map { candidate in
            let role = focusSet.contains(candidate.afterCueId) ? "FOCUS" : "CONTEXT"
            return "\(role) afterCueId=\(candidate.afterCueId), semantic=\(format(candidate.semanticChange)), lexical=\(format(candidate.lexicalChange)), pause=\(format(candidate.pauseSeconds)), score=\(format(candidate.score))"
        }.joined(separator: "\n")
        let transcript = request.cues.map { "[cueId=\($0.id)] \($0.text)" }.joined(separator: "\n")
        let outputLanguage = request.language == .ru ? "русском" : "английском"
        let prompt = """
        Ты проверяешь смысловые границы в расшифровке видео. Временные коды запрещены.
        Для каждого cueId из focusAfterCueIds верни ровно одно решение: сохранить границу темы или удалить её.
        Решения разрешены ТОЛЬКО для строк FOCUS. Строки CONTEXT нужны для понимания и запрещены в ответе.
        Сохрани точный порядок focusAfterCueIds: [\(focus)]. Не заменяй и не повторяй cueId.
        keep=true только при реальной смене предмета, этапа, вопроса/ответа или переходе к практике.
        Не сохраняй границу из-за одной паузы, длины блока или небольшого изменения формулировки.
        Поля reason в ответе пиши на \(outputLanguage) языке.
        Детализация: \(request.granularity.title). Ориентир длительности: \(durationHint(request.granularity)).
        focusAfterCueIds: [\(focus)]

        Кандидатные метрики, включая соседний контекст:
        \(candidates)

        Локальные отрывки вокруг границ (cueId между отрывками могут идти с разрывами):
        \(limited(transcript, maximum: 9_000))

        Верни только JSON. В объекте decisions каждый обязательный cueId должен быть отдельным ключом ровно один раз:
        {"decisions":{"123":{"keep":true,"confidence":0.9,"reason":"Начинается новая самостоятельная тема"}}}
        Не добавляй start, end, time, timestamp или duration.
        \(correctionText(correction))
        """
        let response = try await chatJSON(
            model: model,
            prompt: prompt,
            schema: .boundaryReview(ids: request.focusAfterCueIds),
            as: BoundaryDictionaryResponse.self
        )
        return TopicBoundaryReview(decisions: try request.focusAfterCueIds.map { cueID in
            guard let value = response.decisions[String(cueID)] else {
                throw WorkflowError.invalidTopics("модель не вернула решение для cueId \(cueID).")
            }
            return TopicBoundaryDecision(
                afterCueId: cueID,
                keep: value.keep,
                confidence: value.confidence,
                reason: value.reason
            )
        })
    }

    func describeTopics(
        _ request: TopicDescriptionRequest,
        model: String,
        correction: String?
    ) async throws -> TopicReviewResponse {
        let blocks = request.blocks.map { block in
            let text = block.cues.map { "[cueId=\($0.id)] \($0.text)" }.joined(separator: "\n")
            return """
            RANGE startCueId=\(block.startCueId), endCueId=\(block.endCueId)
            \(limited(text, maximum: 3_500))
            """
        }.joined(separator: "\n\n")
        let previous = request.previousTitles.suffix(16).joined(separator: "; ")
        let exactRanges = request.blocks
            .map { "{\"startCueId\":\($0.startCueId),\"endCueId\":\($0.endCueId)}" }
            .joined(separator: ", ")
        let outputLanguage = request.language == .ru ? "русском" : "английском"
        let titleExample = request.language == .ru
            ? "Настройка оптического телескопа для наблюдений"
            : "Configuring an optical telescope for observations"
        let prompt = """
        Создай содержательное описание для каждого переданного диапазона расшифровки.
        Диапазоны окончательные: нельзя объединять, разделять или менять startCueId/endCueId.
        В массиве topics должно быть РОВНО \(request.blocks.count) объектов, по одному для каждого диапазона, в исходном порядке.
        Обязательные пары границ: [\(exactRanges)].
        title: конкретное название на \(outputLanguage) языке из 3-8 отдельно написанных слов, без нумерации. Два слова запрещены.
        Пример корректного названия: «\(titleExample)».
        summary: одно содержательное предложение.
        keywords: массив из 2-6 конкретных терминов или коротких фраз.
        confidence: число от 0 до 1.
        boundaryReason: почему этот раздел является самостоятельной темой.
        Не используй общие названия из слов «есть», «там», «всё», «быть», «мне».
        Не повторяй предыдущие названия: \(previous.isEmpty ? "нет" : previous).
        Все текстовые поля title, summary, keywords и boundaryReason пиши на \(outputLanguage) языке.

        \(blocks)

        Верни только JSON:
        {"topics":[{"title":"Функции блуждающего нерва","summary":"Объясняется роль нерва в регуляции организма.","keywords":["блуждающий нерв","регуляция"],"startCueId":124,"endCueId":197,"confidence":0.93,"boundaryReason":"Начинается объяснение нового анатомического понятия."}]}
        Не добавляй start, end, time, timestamp или duration.
        \(correctionText(correction))
        """
        return try await chatJSON(
            model: model,
            prompt: prompt,
            schema: .topicReview(
                starts: request.blocks.map(\.startCueId),
                ends: request.blocks.map(\.endCueId)
            ),
            as: TopicReviewResponse.self
        )
    }

    private func installedModelNames() async throws -> Set<String> {
        let request = URLRequest(url: baseURL.appendingPathComponent("api/tags"), timeoutInterval: 8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw WorkflowError.topicServiceUnavailable("Ollama не запущен или не отвечает на 127.0.0.1:11434.")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let tags = try? JSONDecoder().decode(TagResponse.self, from: data) else {
            throw WorkflowError.topicServiceUnavailable("не удалось получить список локальных моделей Ollama.")
        }
        return Set(tags.models.flatMap { [$0.name, $0.model].compactMap { $0 } })
    }

    private func chatJSON<T: Decodable>(
        model: String,
        prompt: String,
        schema: TopicResponseSchema,
        as type: T.Type
    ) async throws -> T {
        let payload = ChatRequest(
            model: model,
            stream: false,
            think: false,
            format: schema.node,
            messages: [ChatMessage(role: "user", content: prompt)],
            options: ChatOptions(temperature: 0.05, numPredict: 1_200)
        )
        let data = try await post(path: "api/chat", body: payload, timeout: Self.chatTimeoutSeconds)
        guard let response = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            throw WorkflowError.invalidTopics("повреждён ответ модели \(model).")
        }
        return try TopicJSONDecoder.decode(response.message.content, as: type)
    }

    private func post<T: Encodable>(path: String, body: T, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WorkflowError.topicServiceUnavailable("Ollama прервал обработку: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "неизвестная ошибка"
            throw WorkflowError.topicServiceUnavailable("Ollama вернул ошибку: \(message)")
        }
        return data
    }

    private func correctionText(_ correction: String?) -> String {
        guard let correction, !correction.isEmpty else { return "" }
        return """
        ПРЕДЫДУЩИЙ ОТВЕТ ОТКЛОНЁН ВАЛИДАТОРОМ: \(correction)
        Исправь каждую указанную ошибку. Не повторяй отклонённый вариант. Проверь число объектов, точные cueId и число слов в каждом title перед ответом.
        """
    }

    private func durationHint(_ granularity: TopicGranularity) -> String {
        switch granularity {
        case .detailed: return "1-3 минуты"
        case .normal: return "3-8 минут"
        case .coarse: return "8-15 минут"
        }
    }

    private func limited(_ text: String, maximum: Int) -> String {
        guard text.count > maximum else { return text }
        let headCount = maximum * 2 / 3
        return "\(text.prefix(headCount))\n[середина контекста сокращена]\n\(text.suffix(maximum - headCount))"
    }

    private func format(_ value: Double) -> String { String(format: "%.3f", value) }

    private func matches(_ actual: String, requested: String) -> Bool {
        actual == requested || actual.split(separator: ":").first == requested.split(separator: ":").first
    }

    private struct TagResponse: Decodable { var models: [TagModel] }
    private struct TagModel: Decodable { var name: String?; var model: String? }
    private struct EmbedRequest: Encodable { var model: String; var input: [String]; var truncate: Bool }
    private struct EmbedResponse: Decodable { var embeddings: [[Double]] }
    private struct ChatMessage: Codable { var role: String; var content: String }
    private struct ChatOptions: Encodable {
        var temperature: Double
        var numPredict: Int
        enum CodingKeys: String, CodingKey { case temperature; case numPredict = "num_predict" }
    }
    private struct ChatRequest: Encodable {
        var model: String
        var stream: Bool
        // qwen3 otherwise may spend the response budget in hidden reasoning and leave content empty.
        var think: Bool
        var format: TopicSchemaNode
        var messages: [ChatMessage]
        var options: ChatOptions
    }
    private struct ChatResponse: Decodable { var message: ChatMessage }
    private struct BoundaryDictionaryDecision: Decodable {
        var keep: Bool
        var confidence: Double
        var reason: String
    }
    private struct BoundaryDictionaryResponse: Decodable {
        var decisions: [String: BoundaryDictionaryDecision]
    }
}

private enum TopicResponseSchema {
    case boundaryReview(ids: [Int])
    case topicReview(starts: [Int], ends: [Int])

    var node: TopicSchemaNode {
        switch self {
        case .boundaryReview(let ids):
            let decision = TopicSchemaNode.object(
                properties: [
                    "keep": .boolean,
                    "confidence": .number,
                    "reason": .constrainedString(minimum: 8, maximum: 400)
                ],
                required: ["keep", "confidence", "reason"]
            )
            let decisions = Dictionary(uniqueKeysWithValues: ids.map { (String($0), decision) })
            return .object(
                properties: [
                    "decisions": .object(properties: decisions, required: ids.map(String.init))
                ],
                required: ["decisions"]
            )
        case .topicReview(let starts, let ends):
            let items = zip(starts, ends).map { start, end in
                TopicSchemaNode.object(
                    properties: [
                        "title": .constrainedString(minimum: 12, maximum: 120),
                        "summary": .constrainedString(minimum: 20, maximum: 600),
                        "keywords": .rangeArray(.string, minimum: 2, maximum: 8),
                        "startCueId": .constantInteger(start),
                        "endCueId": .constantInteger(end),
                        "confidence": .number,
                        "boundaryReason": .constrainedString(minimum: 12, maximum: 500)
                    ],
                    required: ["title", "summary", "keywords", "startCueId", "endCueId", "confidence", "boundaryReason"]
                )
            }
            return .object(
                properties: [
                    "topics": .tupleArray(items)
                ],
                required: ["topics"]
            )
        }
    }
}

private indirect enum TopicSchemaNode: Encodable {
    case object(properties: [String: TopicSchemaNode], required: [String])
    case array(TopicSchemaNode)
    case exactArray(TopicSchemaNode, count: Int)
    case rangeArray(TopicSchemaNode, minimum: Int, maximum: Int)
    case tupleArray([TopicSchemaNode])
    case string
    case constrainedString(minimum: Int, maximum: Int)
    case integer
    case integerChoices([Int])
    case constantInteger(Int)
    case number
    case boolean

    private enum CodingKeys: String, CodingKey {
        case type, properties, required, items, additionalProperties
        case minItems, maxItems, minLength, maxLength, prefixItems, constValue = "const", enumValues = "enum"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .object(let properties, let required):
            try values.encode("object", forKey: .type)
            try values.encode(properties, forKey: .properties)
            try values.encode(required, forKey: .required)
            try values.encode(false, forKey: .additionalProperties)
        case .array(let item):
            try values.encode("array", forKey: .type)
            try values.encode(item, forKey: .items)
        case .exactArray(let item, let count):
            try values.encode("array", forKey: .type)
            try values.encode(item, forKey: .items)
            try values.encode(count, forKey: .minItems)
            try values.encode(count, forKey: .maxItems)
        case .rangeArray(let item, let minimum, let maximum):
            try values.encode("array", forKey: .type)
            try values.encode(item, forKey: .items)
            try values.encode(minimum, forKey: .minItems)
            try values.encode(maximum, forKey: .maxItems)
        case .tupleArray(let items):
            try values.encode("array", forKey: .type)
            try values.encode(items, forKey: .prefixItems)
            try values.encode(items.count, forKey: .minItems)
            try values.encode(items.count, forKey: .maxItems)
        case .string:
            try values.encode("string", forKey: .type)
        case .constrainedString(let minimum, let maximum):
            try values.encode("string", forKey: .type)
            try values.encode(minimum, forKey: .minLength)
            try values.encode(maximum, forKey: .maxLength)
        case .integer:
            try values.encode("integer", forKey: .type)
        case .integerChoices(let choices):
            try values.encode("integer", forKey: .type)
            try values.encode(choices, forKey: .enumValues)
        case .constantInteger(let value):
            try values.encode("integer", forKey: .type)
            try values.encode(value, forKey: .constValue)
        case .number:
            try values.encode("number", forKey: .type)
        case .boolean:
            try values.encode("boolean", forKey: .type)
        }
    }
}

enum TopicJSONDecoder {
    static func decode<T: Decodable>(_ content: String, as type: T.Type) throws -> T {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first <= last {
            candidate = String(trimmed[first...last])
        } else {
            candidate = trimmed
        }
        guard let data = candidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            throw WorkflowError.invalidTopics("языковая модель вернула повреждённый JSON.")
        }
        let forbidden = Set(["start", "end", "time", "timestamp", "duration", "startTime", "endTime", "startSeconds", "endSeconds"])
        if containsForbiddenKey(object, forbidden: forbidden) {
            throw WorkflowError.invalidTopics("языковая модель попыталась вернуть временные коды.")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let preview = candidate.replacingOccurrences(of: "\n", with: " ").prefix(600)
            throw WorkflowError.invalidTopics("JSON языковой модели не соответствует контракту: \(error.localizedDescription) Ответ: \(preview)")
        }
    }

    private static func containsForbiddenKey(_ value: Any, forbidden: Set<String>) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary.keys.contains(where: forbidden.contains) { return true }
            return dictionary.values.contains { containsForbiddenKey($0, forbidden: forbidden) }
        }
        if let array = value as? [Any] {
            return array.contains { containsForbiddenKey($0, forbidden: forbidden) }
        }
        return false
    }
}

enum TopicLabelDecoder {
    static func decode(_ content: String) throws -> TopicLabel {
        try TopicJSONDecoder.decode(content, as: TopicLabel.self)
    }
}
