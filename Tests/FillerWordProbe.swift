import Foundation

@main
struct FillerWordProbe {
    static func main() throws {
        let root = (URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path, isDirectory: true)).appendingPathComponent("videotext-filler-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FillerWordService()

        let ru = root.appendingPathComponent("ru.json")
        try write(words: ["Ээ", "это", "ээ", "типа", "пример", "типа", "данных"], to: ru)
        let ruReport = try service.analyze(
            whisperJSONURL: ru,
            cues: [SubtitleCue(id: 11, start: 0, end: 7, text: "Ээ это ээ типа пример типа данных")],
            language: .ru,
            transcriptRevisionID: "ru-revision"
        )
        let ruAcoustic = ruReport.candidates.filter { $0.normalized == "ээ" }
        try require(ruAcoustic.count == 2 && ruAcoustic.allSatisfy(\.highConfidence), "повторяющееся RU междометие не стало уверенным")
        try require(ruReport.candidates.filter { $0.normalized == "типа" }.allSatisfy { !$0.highConfidence }, "неоднозначное RU слово стало auto-mute")
        try require(ruReport.words.allSatisfy { $0.cueID == 11 && $0.transcriptRevisionID == "ru-revision" }, "word timeline потерял cue/revision")

        let en = root.appendingPathComponent("en.json")
        try write(words: ["Um", "I", "um", "like", "this", "like", "that"], to: en)
        let enReport = try service.analyze(
            whisperJSONURL: en,
            cues: [SubtitleCue(id: 3, start: 0, end: 7, text: "Um I um like this like that")],
            language: .en,
            transcriptRevisionID: "en-revision"
        )
        try require(enReport.candidates.filter { $0.normalized == "um" }.allSatisfy(\.highConfidence), "повторяющееся EN междометие не стало уверенным")
        try require(enReport.candidates.filter { $0.normalized == "like" }.allSatisfy { !$0.highConfidence }, "semantic like стало auto-mute")
        print("FILLER_WORD_PROBE_PASS")
    }

    private static func write(words: [String], to url: URL) throws {
        let tokens: [[String: Any]] = words.enumerated().map { index, word in
            ["text": word, "offsets": ["from": index * 1000, "to": index * 1000 + 600], "p": 0.9]
        }
        let data = try JSONSerialization.data(withJSONObject: ["transcription": [["tokens": tokens]]], options: [.prettyPrinted])
        try data.write(to: url)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
