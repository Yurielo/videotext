import Foundation

private struct BenchmarkDirectionResult: Codable {
    var source: String
    var target: String
    var elapsedSeconds: Double
    var cueCount: Int
    var validCueIDs: Bool
    var adapterValidationPass: Bool
    var targetLanguagePass: Bool
    var numberPreservationPass: Bool
    var terminologyPass: Bool
    var semanticMarkerPass: Bool
    var translations: [String: String]

    var failureCount: Int {
        [validCueIDs, adapterValidationPass, targetLanguagePass, numberPreservationPass, terminologyPass, semanticMarkerPass]
            .filter { !$0 }.count
    }
}

private struct BenchmarkModelResult: Codable {
    var model: String
    var directions: [BenchmarkDirectionResult]

    var failureCount: Int { directions.reduce(0) { $0 + $1.failureCount } }
    var elapsedSeconds: Double { directions.reduce(0) { $0 + $1.elapsedSeconds } }
}

private struct BenchmarkReport: Codable {
    var createdAt: Date
    var selectedModel: String?
    var results: [BenchmarkModelResult]
}

private struct Fixture {
    var source: ArtifactLanguage
    var target: ArtifactLanguage
    var cues: [TranslationRequestCue]
    var semanticMarkerGroups: [Int: [[String]]]
}

private struct FixedTranslationProvider: TranslationAIProvider {
    var model: String
    var provider: OllamaTranslationProvider

    func preferredModel() async throws -> String { model }

    func translate(
        cues: [TranslationRequestCue],
        source: ArtifactLanguage,
        target: ArtifactLanguage,
        model: String,
        correction: String?
    ) async throws -> [Int: String] {
        try await provider.translate(cues: cues, source: source, target: target, model: model, correction: correction)
    }
}

@main
struct TranslationModelBenchmark {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw WorkflowError.processFailed("Использование: translation-model-benchmark <report.json>")
            }
            let reportURL = URL(fileURLWithPath: CommandLine.arguments[1])
            let provider = OllamaTranslationProvider()
            let models = [OllamaTranslationProvider.model]
            var modelResults: [BenchmarkModelResult] = []
            for model in models {
                var directions: [BenchmarkDirectionResult] = []
                for fixture in fixtures() {
                    let startedAt = Date()
                    let adapter = TranslationAdapter(provider: FixedTranslationProvider(model: model, provider: provider))
                    let adapterResult = try await adapter.translate(
                        cues: fixture.cues.enumerated().map { index, cue in
                            SubtitleCue(id: cue.id, start: Double(index), end: Double(index + 1), text: cue.text)
                        },
                        source: fixture.source,
                        target: fixture.target,
                        onProgress: { _ in },
                        onLog: { print("\(model): \($0)") }
                    )
                    let translated = Dictionary(uniqueKeysWithValues: adapterResult.cues.map { ($0.id, $0.text) })
                    let result = evaluate(
                        translated,
                        fixture: fixture,
                        elapsed: Date().timeIntervalSince(startedAt),
                        adapterIssueCount: adapterResult.issues.count
                    )
                    directions.append(result)
                    print("\(model) \(fixture.source.rawValue)->\(fixture.target.rawValue): failures=\(result.failureCount), elapsed=\(String(format: "%.2f", result.elapsedSeconds))s")
                }
                modelResults.append(BenchmarkModelResult(model: model, directions: directions))
            }
            let selected = modelResults.sorted {
                if $0.failureCount != $1.failureCount { return $0.failureCount < $1.failureCount }
                return $0.elapsedSeconds < $1.elapsedSeconds
            }.first
            let report = BenchmarkReport(
                createdAt: Date(),
                selectedModel: selected?.failureCount == 0 ? selected?.model : nil,
                results: modelResults
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(report).write(to: reportURL, options: .atomic)
            guard let selectedModel = report.selectedModel else {
                throw WorkflowError.processFailed("ни одна модель не прошла все обязательные проверки; см. \(reportURL.path)")
            }
            print("TRANSLATION_MODEL_BENCHMARK_PASS: selected=\(selectedModel); report=\(reportURL.path)")
        } catch {
            fputs("TRANSLATION_MODEL_BENCHMARK_FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func fixtures() -> [Fixture] {
        let ru = [
            TranslationRequestCue(id: 1, text: "В 2026 году команда videotext обработала 12 коротких видео."),
            TranslationRequestCue(id: 2, text: "Анна проверила субтитры в 09:30 и сохранила файл."),
            TranslationRequestCue(id: 3, text: "WorkflowEngine не должен перезаписывать исходный проект."),
            TranslationRequestCue(id: 4, text: "Стоимость составила 1250 рублей, а скидка - 15%."),
            TranslationRequestCue(id: 5, text: "Используйте FFmpeg и модель Whisper large-v3."),
            TranslationRequestCue(id: 6, text: "Я не думаю, что в отчёте нет ошибки,"),
            TranslationRequestCue(id: 7, text: "поэтому давайте проверим исходную запись ещё раз."),
            TranslationRequestCue(id: 8, text: "Нет, нет, это не отмена, а перенос встречи на 3 октября."),
            TranslationRequestCue(id: 9, text: "Мария сказала: «пожалуйста, не меняйте название проекта VideoText»."),
            TranslationRequestCue(id: 10, text: "В 14:05 было 2,5 минуты тишины, затем разговор продолжился."),
            TranslationRequestCue(id: 11, text: "Мы обсудили договор, однако окончательное решение пока не принято."),
            TranslationRequestCue(id: 12, text: "Повторю: резервную копию удалять нельзя.")
        ]
        let en = [
            TranslationRequestCue(id: 1, text: "In 2026, the VideoText team processed 12 short videos."),
            TranslationRequestCue(id: 2, text: "Anna reviewed the subtitles at 09:30 and saved the file."),
            TranslationRequestCue(id: 3, text: "WorkflowEngine must not overwrite the source project."),
            TranslationRequestCue(id: 4, text: "The total was 1250 dollars with a 15% discount."),
            TranslationRequestCue(id: 5, text: "Use FFmpeg and the Whisper large-v3 model."),
            TranslationRequestCue(id: 6, text: "I do not think there is no mistake in the report,"),
            TranslationRequestCue(id: 7, text: "so let us check the original recording once more."),
            TranslationRequestCue(id: 8, text: "No, no, this is not a cancellation but a move of the meeting to October 3."),
            TranslationRequestCue(id: 9, text: "Maria said, please do not change the name of the VideoText project."),
            TranslationRequestCue(id: 10, text: "At 14:05 there were 2.5 minutes of silence, then the conversation continued."),
            TranslationRequestCue(id: 11, text: "We discussed the contract, but the final decision has not yet been made."),
            TranslationRequestCue(id: 12, text: "I repeat: the backup must not be deleted.")
        ]
        return [
            Fixture(
                source: .ru,
                target: .en,
                cues: ru,
                semanticMarkerGroups: [
                    1: [["team"], ["processed"]], 2: [["anna"], ["subtitles"]],
                    3: [["workflowengine"], ["source", "original"]], 4: [["discount"]], 5: [["ffmpeg"], ["whisper"]],
                    6: [["not", "no", "don't"]], 7: [["check", "recording", "record"]], 8: [["not", "cancel"]],
                    9: [["maria"], ["videotext"]], 10: [["silence"], ["conversation"]],
                    11: [["contract"], ["not", "decision"]], 12: [["backup"], ["not", "must", "should", "cannot"]]
                ]
            ),
            Fixture(
                source: .en,
                target: .ru,
                cues: en,
                semanticMarkerGroups: [
                    1: [["команд"], ["обработ"]], 2: [["анна"], ["субтитр"]],
                    3: [["workflowengine"], ["исход", "оригинал"]], 4: [["скид"]], 5: [["ffmpeg"], ["whisper"]],
                    6: [["не", "ошиб"]], 7: [["провер", "запис"]], 8: [["не", "отмен"]],
                    9: [["мар"], ["videotext"]], 10: [["тишин"], ["разговор"]],
                    11: [["договор", "контракт"], ["не", "решени"]], 12: [["резерв", "копи"], ["не", "нельзя"]]
                ]
            )
        ]
    }

    private static func evaluate(
        _ translations: [Int: String],
        fixture: Fixture,
        elapsed: TimeInterval,
        adapterIssueCount: Int
    ) -> BenchmarkDirectionResult {
        let expectedIDs = Set(fixture.cues.map(\.id))
        let combined = translations.values.joined(separator: " ")
        let numberPreserved = fixture.cues.allSatisfy { cue in
            numberTokens(cue.text) == numberTokens(translations[cue.id] ?? "")
        }
        let requiredTerms = ["videotext", "workflowengine", "ffmpeg", "whisper", "large-v3"]
        let sourceTerms = requiredTerms.filter { term in
            fixture.cues.contains { $0.text.lowercased().contains(term) }
        }
        let terminologyPreserved = sourceTerms.allSatisfy { combined.lowercased().contains($0) }
        let semanticMarkersPresent = fixture.semanticMarkerGroups.allSatisfy { id, groups in
            let text = translations[id]?.lowercased() ?? ""
            return groups.allSatisfy { alternatives in alternatives.contains(where: text.contains) }
        }
        return BenchmarkDirectionResult(
            source: fixture.source.rawValue,
            target: fixture.target.rawValue,
            elapsedSeconds: elapsed,
            cueCount: fixture.cues.count,
            validCueIDs: Set(translations.keys) == expectedIDs && translations.values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            adapterValidationPass: adapterIssueCount == 0,
            targetLanguagePass: looksLike(combined, language: fixture.target),
            numberPreservationPass: numberPreserved,
            terminologyPass: terminologyPreserved,
            semanticMarkerPass: semanticMarkersPresent,
            translations: Dictionary(uniqueKeysWithValues: translations.map { (String($0.key), $0.value) })
        )
    }

    private static func numberTokens(_ text: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"\d+(?:[.,:]\d+)?"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]).replacingOccurrences(of: ",", with: ".") }
        }.sorted()
    }

    private static func looksLike(_ text: String, language: ArtifactLanguage) -> Bool {
        let cyrillic = text.unicodeScalars.filter { (0x0400...0x04FF).contains(Int($0.value)) }.count
        let latin = text.unicodeScalars.filter {
            (0x0041...0x005A).contains(Int($0.value)) || (0x0061...0x007A).contains(Int($0.value))
        }.count
        return language == .ru ? cyrillic > latin : latin > cyrillic
    }
}
