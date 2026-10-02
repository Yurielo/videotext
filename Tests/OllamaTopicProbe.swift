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
            guard models == [provider.primaryLanguageModel] else {
                throw OllamaProbeError.failed("для тематического анализа должна быть доступна только Gemma 3")
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

            let longCues = (1...30).map { id in
                SubtitleCue(
                    id: id,
                    start: Double(id - 1) * 20,
                    end: Double(id) * 20,
                    text: "Рассматривается содержательный переход \(id): сначала объясняется практический пример, затем уточняются его причины, последствия и связь с последующим разделом занятия."
                )
            }
            let longBoundaryRequest = TopicBoundaryReviewRequest(
                id: "ollama-long-boundary",
                granularity: .normal,
                cues: longCues,
                candidates: [6, 10, 14, 18, 22, 26].map { id in
                    TopicBoundaryCandidate(afterCueId: id, semanticChange: 0.76, lexicalChange: 0.81, pauseSeconds: 0.2, score: 0.69)
                },
                focusAfterCueIds: [6, 10, 14, 18, 22, 26]
            )
            let longBoundary = try await provider.reviewBoundaries(
                longBoundaryRequest,
                model: provider.primaryLanguageModel,
                correction: nil
            )
            let longIssues = TopicValidator().boundaryReviewIssues(longBoundary, request: longBoundaryRequest)
            guard longIssues.isEmpty else {
                throw OllamaProbeError.failed("\(provider.primaryLanguageModel) не прошла длинное окно границ: \(longIssues.joined(separator: " "))")
            }
            print("LONG BOUNDARY PASS: \(provider.primaryLanguageModel), границ: \(longBoundary.decisions.count)")

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
