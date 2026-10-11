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

        let reverseFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ReverseRawTokens.json")
        let reverseReport = try service.analyze(
            whisperJSONURL: reverseFixture,
            cues: [SubtitleCue(id: 4, start: 0, end: 1.2, text: "Um I um speak.")],
            language: .en,
            transcriptRevisionID: "reverse-raw-revision"
        )
        try require(reverseReport.words.map(\.text) == ["Um", "I", "um", "speak."],
                    "raw reverse token disappeared or changed source order")
        try require(reverseReport.words[0].start == 0.12 && reverseReport.words[0].end == 0.08
                    && reverseReport.words[2].start == 0.34 && reverseReport.words[2].end == 0.31,
                    "raw reverse token endpoints were normalized")
        try require(reverseReport.candidates.filter { $0.normalized == "um" }.count == 2
                    && reverseReport.candidates.allSatisfy { $0.start >= 0 && $0.end > $0.start },
                    "reverse raw token was dropped from filler analysis or became an invalid mute range")

        let zeroWidth = root.appendingPathComponent("zero-width-and-reverse.json")
        let zeroWidthJSON: [String: Any] = ["transcription": [["tokens": [
            ["text": " Um", "offsets": ["from": 100, "to": 100], "p": 0.9],
            ["text": " uh", "offsets": ["from": 300, "to": 200], "p": 0.9]
        ]]]]
        try JSONSerialization.data(withJSONObject: zeroWidthJSON).write(to: zeroWidth)
        let zeroWidthReport = try service.analyze(
            whisperJSONURL: zeroWidth,
            cues: [SubtitleCue(id: 5, start: 0, end: 1, text: "Um uh")],
            language: .en,
            transcriptRevisionID: "zero-width-and-reverse"
        )
        try require(zeroWidthReport.words.map(\.text) == ["Um", "uh"]
                    && zeroWidthReport.words[0].start == 0.1 && zeroWidthReport.words[0].end == 0.1
                    && zeroWidthReport.words[1].start == 0.3 && zeroWidthReport.words[1].end == 0.2,
                    "zero-width or reverse raw word was removed or rewritten")
        try require(zeroWidthReport.candidates.count == 1
                    && zeroWidthReport.candidates[0].normalized == "uh"
                    && zeroWidthReport.candidates[0].start == 0.2
                    && zeroWidthReport.candidates[0].end == 0.3,
                    "invalid zero-width candidate was emitted or valid reverse evidence was lost")

        let outsideMedia = root.appendingPathComponent("outside-playable-media.json")
        let outsideMediaJSON: [String: Any] = ["transcription": [["tokens": [
            ["text": " Um", "offsets": ["from": 300, "to": 200], "p": 0.9],
            ["text": " uh", "offsets": ["from": 1500, "to": 1400], "p": 0.9]
        ]]]]
        try JSONSerialization.data(withJSONObject: outsideMediaJSON).write(to: outsideMedia)
        let outsideMediaReport = try service.analyze(
            whisperJSONURL: outsideMedia,
            cues: [SubtitleCue(id: 6, start: 0, end: 2, text: "Um uh")],
            language: .en,
            transcriptRevisionID: "outside-playable-media",
            mediaDuration: 1
        )
        try require(outsideMediaReport.words.map(\.text) == ["Um", "uh"]
                    && outsideMediaReport.words[1].start == 1.5
                    && outsideMediaReport.words[1].end == 1.4,
                    "outside-media raw token evidence was dropped or clipped")
        try require(outsideMediaReport.candidates.count == 1
                    && outsideMediaReport.candidates[0].normalized == "um"
                    && outsideMediaReport.candidates[0].start == 0.2
                    && outsideMediaReport.candidates[0].end == 0.3,
                    "outside-media executable candidate was emitted or in-range candidate was lost")

        let splitPhrase = root.appendingPathComponent("split-phrase-cue.json")
        let splitPhraseJSON: [String: Any] = ["transcription": [["tokens": [
            ["text": " you", "offsets": ["from": 400, "to": 500], "p": 0.9],
            ["text": " know", "offsets": ["from": 800, "to": 1000], "p": 0.9]
        ]]]]
        try JSONSerialization.data(withJSONObject: splitPhraseJSON).write(to: splitPhrase)
        let splitPhraseReport = try service.analyze(
            whisperJSONURL: splitPhrase,
            cues: [
                SubtitleCue(id: 7, start: 0, end: 0.3, text: "Earlier."),
                SubtitleCue(id: 8, start: 0.6, end: 1.4, text: "You know.")
            ],
            language: .en,
            transcriptRevisionID: "split-phrase-cue",
            mediaDuration: 1.4
        )
        try require(splitPhraseReport.words.map(\.text) == ["you", "know"]
                    && splitPhraseReport.words[0].start == 0.4
                    && splitPhraseReport.words[0].end == 0.5,
                    "first out-of-cue raw word was changed or removed")
        try require(splitPhraseReport.candidates.count == 1
                    && splitPhraseReport.candidates[0].normalized == "you know"
                    && splitPhraseReport.candidates[0].cueID == 8
                    && splitPhraseReport.candidates[0].start == 0.4
                    && splitPhraseReport.candidates[0].end == 1.0,
                    "multiword actionable phrase was assigned the first raw word's invalid cue")

        let controls = root.appendingPathComponent("whisper-controls.json")
        let controlsJSON: [String: Any] = ["transcription": [["tokens": [
            ["text": "[_BEG_]", "offsets": ["from": 0, "to": 0]],
            ["text": " um", "offsets": ["from": 100, "to": 200], "p": 0.9],
            ["text": "[_TT_128]", "offsets": ["from": 200, "to": 200]]
        ]]]]
        try JSONSerialization.data(withJSONObject: controlsJSON).write(to: controls)
        let controlsReport = try service.analyze(
            whisperJSONURL: controls,
            cues: [SubtitleCue(id: 9, start: 0, end: 1, text: "um")],
            language: .en,
            transcriptRevisionID: "control-marker-filter"
        )
        try require(controlsReport.words.map(\.text) == ["um"]
                    && controlsReport.candidates.count == 1
                    && controlsReport.candidates[0].normalized == "um",
                    "Whisper control markers leaked into filler word evidence")
        print("REVERSE_RAW_FILLER_PRESERVATION_PASS")
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
