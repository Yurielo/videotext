import Foundation

@main
struct WhisperVADProbe {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("videotext-vad-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("ggml-silero-v5.1.2.bin")
        try Data([0x56, 0x41, 0x44]).write(to: model)

        let located = WhisperVADModelLocator(searchRoots: [root.path]).bestModelPath()
        try require(located == model.path, "locator не нашёл приоритетную Silero VAD model")

        let adapter = WhisperCLITranscriber(
            vadModelLocator: WhisperVADModelLocator(searchRoots: [root.path])
        )
        let arguments = adapter.commandArguments(
            audioURL: root.appendingPathComponent("source.wav"),
            outputBase: root.appendingPathComponent("full.partial"),
            modelPath: "/models/whisper.bin",
            language: "ru",
            vadModelPath: located
        )
        try require(arguments.contains("-ojf"), "не запрошен full JSON")
        try require(arguments.contains("--print-confidence"), "не запрошен confidence")
        try require(arguments.contains("--vad"), "VAD не включен")
        guard let modelFlag = arguments.firstIndex(of: "-vm"), modelFlag + 1 < arguments.count else {
            throw ProbeFailure(message: "нет аргумента VAD model")
        }
        try require(arguments[modelFlag + 1] == model.path, "в Whisper передана неверная VAD model")

        let fallback = adapter.commandArguments(
            audioURL: root.appendingPathComponent("source.wav"),
            outputBase: root.appendingPathComponent("full.partial"),
            modelPath: "/models/whisper.bin",
            language: "ru",
            vadModelPath: nil
        )
        try require(!fallback.contains("--vad") && !fallback.contains("-vm"), "fallback не отключил VAD")
        try require(!WhisperChunkPlanner.shouldSegment(duration: 20 * 60), "порог сегментации включён слишком рано")
        try require(WhisperChunkPlanner.shouldSegment(duration: 20 * 60 + 1), "длинное видео не переведено на сегменты")
        let chunks = WhisperChunkPlanner.chunks(duration: 965)
        try require(chunks.count == 4, "неверное число пятиминутных сегментов")
        try require(chunks.first?.coreStart == 0 && chunks.last?.coreEnd == 965, "сегменты не покрывают видео полностью")
        try require(chunks[1].coreStart == chunks[0].coreEnd, "между core-диапазонами появилась дыра")
        try require(chunks[1].extractionStart < chunks[1].coreStart, "нет защитного перекрытия сегментов")
        try validateSegmentMerge(root: root)
        print("WHISPER_VAD_PROBE_PASS")
    }

    private static func validateSegmentMerge(root: URL) throws {
        let firstSRT = root.appendingPathComponent("first.srt")
        let secondSRT = root.appendingPathComponent("second.srt")
        let firstJSON = root.appendingPathComponent("first.json")
        let secondJSON = root.appendingPathComponent("second.json")
        let mergedJSON = root.appendingPathComponent("merged.json")
        try SRTService().write([
            SubtitleCue(id: 1, start: 299, end: 300, text: "Первая часть.")
        ], to: firstSRT)
        try SRTService().write([
            SubtitleCue(id: 1, start: 1.6, end: 2.6, text: "Вторая часть.")
        ], to: secondSRT)
        try writeJSON(to: firstJSON, start: 299_000, end: 300_000, tokenStart: 299_100, tokenEnd: 299_900)
        try writeJSON(to: secondJSON, start: 1_600, end: 2_600, tokenStart: 1_700, tokenEnd: 2_500)
        let outputs = [
            WhisperChunkOutput(
                chunk: WhisperChunk(index: 0, coreStart: 0, coreEnd: 300, extractionStart: 0, extractionEnd: 301.5),
                srtURL: firstSRT,
                jsonURL: firstJSON
            ),
            WhisperChunkOutput(
                chunk: WhisperChunk(index: 1, coreStart: 300, coreEnd: 600, extractionStart: 298.5, extractionEnd: 600),
                srtURL: secondSRT,
                jsonURL: secondJSON
            )
        ]
        let merger = SegmentedWhisperTranscriber(runner: ToolRunner(), vadModelLocator: WhisperVADModelLocator(searchRoots: []))
        let cues = try merger.merge(outputs: outputs, mediaDuration: 600, jsonURL: mergedJSON)
        try require(cues.count == 2, "объединитель потерял или продублировал cue на перекрытии")
        try require(abs(cues[1].start - 300.1) < 0.001, "второй cue не получил глобальное смещение")
        let rootObject = try JSONSerialization.jsonObject(with: Data(contentsOf: mergedJSON)) as? [String: Any]
        let segments = rootObject?["transcription"] as? [[String: Any]]
        let tokens = segments?[1]["tokens"] as? [[String: Any]]
        let offsets = tokens?.first?["offsets"] as? [String: Any]
        let shifted = (offsets?["from"] as? NSNumber)?.doubleValue
        try require(shifted == 300_200, "token offsets не переведены в глобальную шкалу")
    }

    private static func writeJSON(
        to url: URL,
        start: Int,
        end: Int,
        tokenStart: Int,
        tokenEnd: Int
    ) throws {
        let object: [String: Any] = [
            "result": ["language": "ru"],
            "transcription": [[
                "offsets": ["from": start, "to": end],
                "timestamps": ["from": "00:00:00.000", "to": "00:00:01.000"],
                "text": "Тест.",
                "tokens": [[
                    "text": "Тест",
                    "p": 0.9,
                    "offsets": ["from": tokenStart, "to": tokenEnd],
                    "timestamps": ["from": "00:00:00.100", "to": "00:00:00.900"]
                ]]
            ]]
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
