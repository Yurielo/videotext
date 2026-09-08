import Foundation

@main
struct TranscriptionQualityProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("Использование: videotext-quality-probe <zero-duration.srt>\n", stderr)
            exit(2)
        }

        let parsedFixture = try SRTService().loadWithReport(from: URL(fileURLWithPath: CommandLine.arguments[1]))
        try require(parsedFixture.cues.count == 1, "служебный zero-duration cue не исключен")
        try require(parsedFixture.skippedZeroDurationCount == 1, "zero-duration cue не отражен в отчете")

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("videotext-whisper-quality-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let json: [String: Any] = [
            "result": ["language": "en"],
            "transcription": [
                ["tokens": [["p": 0.96], ["p": 0.91]]],
                ["no_speech_prob": 0.82, "tokens": [["p": 0.20], ["p": 0.32]]],
                ["tokens": [["p": 0.88]]],
                ["tokens": [["p": 0.90]]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
            .write(to: temporaryURL, options: .atomic)

        let cues = [
            SubtitleCue(id: 1, start: 0, end: 2, text: "This is a valid phrase."),
            SubtitleCue(id: 2, start: 2, end: 4, text: "Low confidence phrase."),
            SubtitleCue(id: 3, start: 4, end: 5, text: "Repeated tail."),
            SubtitleCue(id: 4, start: 5, end: 6, text: "Repeated tail."),
            SubtitleCue(id: 5, start: 6, end: 7, text: "Repeated tail."),
            SubtitleCue(id: 6, start: 8, end: 10, text: "We discuss the project."),
            SubtitleCue(id: 7, start: 9, end: 11, text: "We discuss the project schedule."),
            SubtitleCue(id: 8, start: 10, end: 12, text: "We discuss the project schedule today.")
        ]
        let service = TranscriptionQualityService()
        try require(service.inferLanguage(cues: cues, whisperJSONURL: temporaryURL) == .en, "язык JSON не прочитан")
        let assessment = service.assess(
            cues: cues,
            skippedZeroDurationCount: 1,
            whisperJSONURL: temporaryURL,
            language: .en,
            transcriptRevisionID: "fixture-revision"
        )
        try require(assessment.report.status == .needsReview, "сомнительная расшифровка принята как ready")
        try require(assessment.tasks.contains { $0.cueIDs == [2] && $0.reasonCodes.contains("low-confidence") }, "нет low-confidence task")
        try require(assessment.tasks.contains { $0.cueIDs == [2] && $0.reasonCodes.contains("high-no-speech-probability") }, "нет no-speech task")
        try require(assessment.tasks.contains { $0.reasonCodes.contains("consecutive-repetition") }, "нет repetition task")
        try require(
            assessment.tasks.contains { $0.reasonCodes.contains("progressive-repetition") && $0.cueIDs == [6, 7, 8] },
            "цепочка прогрессивных повторов не собрана в одно review task"
        )
        let substringAssessment = service.assess(
            cues: [
                SubtitleCue(id: 1, start: 0, end: 1, text: "Да."),
                SubtitleCue(id: 2, start: 0.8, end: 2, text: "Иногда это полезно.")
            ],
            skippedZeroDurationCount: 0,
            whisperJSONURL: nil,
            language: .ru,
            transcriptRevisionID: "substring-fixture"
        )
        try require(
            !substringAssessment.tasks.contains { $0.reasonCodes.contains("progressive-repetition") },
            "совпадение подстроки внутри слова принято за прогрессивный повтор"
        )
        try require(assessment.report.warnings.contains { $0.contains("Pipeline продолжен") }, "нет неблокирующего предупреждения")
        try require(assessment.html.contains("class=\"needs-review\""), "нет красной review-разметки")
        try require(assessment.html.contains("Low confidence phrase."), "текст потерян в HTML")
        var catastrophicCues: [SubtitleCue] = []
        for index in 0..<110 {
            let text = index < 10 ? "Содержательная реплика номер \(index)." : "Нередианная почка."
            catastrophicCues.append(SubtitleCue(
                id: index + 1,
                start: Double(index) * 2,
                end: Double(index + 1) * 2,
                text: text
            ))
        }
        let catastrophic = service.assess(
            cues: catastrophicCues,
            skippedZeroDurationCount: 0,
            whisperJSONURL: nil,
            language: .ru,
            transcriptRevisionID: "catastrophic-fixture",
            mediaDuration: 220
        )
        try require(catastrophic.report.status == ArtifactValidationStatus.invalid, "массовая петля Whisper не получила статус invalid")
        try require(catastrophic.catastrophicIssue?.start == 20, "не найдена граница начала массовой петли")
        try require(catastrophic.report.metrics["catastrophicRepetitionCueCount"] == 100, "не сохранён размер петли")
        try require(
            catastrophic.tasks.contains {
                $0.reasonCodes.contains("catastrophic-repetition-loop") && $0.cueIDs.count == 100
            },
            "массовая петля не собрана в один диапазонный review task"
        )
        try require(catastrophic.tasks.count == 1, "массовая петля создала тысячи отдельных review task")
        try require(catastrophic.report.warnings.contains { $0.contains("автоматическая повторная расшифровка") }, "нет инструкции восстановления")
        let retry = LocalWhisperRetryService()
        try require(
            retry.isImprovement("A corrected English phrase.", over: "Low confidence phrase.", language: .en),
            "валидная локальная подсказка отклонена"
        )
        try require(
            !retry.isImprovement("Low confidence phrase.", over: "Low confidence phrase.", language: .en),
            "неизменившийся локальный повтор принят как улучшение"
        )
        try require(
            !retry.isImprovement("Исправленная русская фраза", over: "Low confidence phrase.", language: .en),
            "подсказка на неверном языке принята"
        )

        print("TRANSCRIPTION_QUALITY_PROBE_PASS")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
