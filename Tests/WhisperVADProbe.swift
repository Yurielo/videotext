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
        print("WHISPER_VAD_PROBE_PASS")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
