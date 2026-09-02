import Foundation

enum OllamaProbeError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

@main
struct OllamaTopicProbe {
    static func main() async {
        do {
            let provider = OllamaTopicProvider()
            let models = try await provider.availableLanguageModels()
            guard models.contains(provider.primaryLanguageModel), models.contains(provider.fallbackLanguageModel) else {
                throw OllamaProbeError.failed("не найдены основная и резервная модели")
            }
            let vectors = try await provider.embeddings(for: [
                "Настройка локальной модели распознавания речи",
                "Приготовление овощного супа"
            ])
            guard vectors.count == 2, vectors.allSatisfy({ $0.count == 768 }) else {
                throw OllamaProbeError.failed("embeddinggemma вернула неверный размер векторов")
            }
            let cues = [
                SubtitleCue(id: 1, start: 0, end: 10, text: "Астрономы настраивают телескоп для наблюдения звёзд."),
                SubtitleCue(id: 2, start: 10, end: 20, text: "Обсуждаются линзы и положение телескопа."),
                SubtitleCue(id: 3, start: 20, end: 30, text: "Теперь повар выбирает овощи для домашнего супа."),
                SubtitleCue(id: 4, start: 30, end: 40, text: "Овощи нарезают и добавляют в бульон.")
            ]
            let boundaryRequest = TopicBoundaryReviewRequest(
                id: "ollama-boundary",
                granularity: .detailed,
                cues: cues,
                candidates: [
                    TopicBoundaryCandidate(afterCueId: 2, semanticChange: 0.8, lexicalChange: 0.9, pauseSeconds: 0, score: 0.7)
                ],
                focusAfterCueIds: [2]
            )
            let descriptionRequest = TopicDescriptionRequest(
                id: "ollama-description",
                granularity: .detailed,
                blocks: [
                    TopicDescriptionBlock(startCueId: 1, endCueId: 2, cues: Array(cues[0...1])),
                    TopicDescriptionBlock(startCueId: 3, endCueId: 4, cues: Array(cues[2...3]))
                ],
                previousTitles: []
            )
            for model in models {
                var correction: String?
                var validBoundary = false
                for _ in 0..<2 {
                    do {
                        let boundary = try await provider.reviewBoundaries(boundaryRequest, model: model, correction: correction)
                        let issues = TopicValidator().boundaryReviewIssues(boundary, request: boundaryRequest)
                        if issues.isEmpty { validBoundary = true; break }
                        correction = issues.joined(separator: " ")
                    } catch {
                        correction = error.localizedDescription
                    }
                }
                guard validBoundary else { throw OllamaProbeError.failed("\(model) не прошла review границ: \(correction ?? "ошибка")") }
                print("BOUNDARY PASS: \(model)")
            }

            var selectedModel: String?
            for model in models where selectedModel == nil {
                var correction: String?
                for _ in 0..<2 {
                    do {
                        let review = try await provider.describeTopics(descriptionRequest, model: model, correction: correction)
                        let issues = TopicValidator().topicReviewIssues(review, request: descriptionRequest)
                        if issues.isEmpty {
                            selectedModel = model
                            print("DESCRIPTION PASS: \(model), тем: \(review.topics.count)")
                            break
                        }
                        correction = issues.joined(separator: " ")
                    } catch {
                        correction = error.localizedDescription
                    }
                }
                if selectedModel == nil {
                    print("DESCRIPTION REJECTED: \(model): \(correction ?? "ошибка")")
                }
            }
            guard selectedModel != nil else { throw OllamaProbeError.failed("ни одна LLM не создала валидные описания") }
            print("OLLAMA PROBE PASS: \(provider.embeddingModel), \(models.joined(separator: ", "))")
        } catch {
            fputs("OLLAMA PROBE FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
