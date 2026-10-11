import Foundation

@main
struct RealRawImportProbe {
    static func main() {
        do { try run() }
        catch {
            fputs("REAL_RAW_IMPORT_PROBE_FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        let args = CommandLine.arguments
        guard args.count == 6 else { throw ProbeFailure("Expected RU/EN packages, media, and result JSON") }
        let ru = try verify(
            package: URL(fileURLWithPath: args[1], isDirectory: true),
            media: URL(fileURLWithPath: args[2]), language: .ru
        )
        let en = try verify(
            package: URL(fileURLWithPath: args[3], isDirectory: true),
            media: URL(fileURLWithPath: args[4]), language: .en
        )
        try require((ru["reverseRawCount"] as? Int ?? 0) > 0,
                    "real Short-RU did not exercise reverse raw token evidence")
        let result: [String: Any] = ["status": "PASS", "ru": ru, "en": en]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: args[5]), options: .atomic)
        print("REAL_RAW_IMPORT_PROBE_PASS ruReverse=\(ru["reverseRawCount"]!) enReverse=\(en["reverseRawCount"]!)")
    }

    private struct RawToken {
        let text: String
        let from: Double
        let to: Double
    }

    private static func verify(package: URL, media: URL, language: ArtifactLanguage) throws -> [String: Any] {
        let manifestURL = package.appendingPathComponent("manifest.json")
        guard let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
              let source = manifest["source"] as? [String: Any],
              source["media_sha256"] as? String == SelectedTimingHash.file(media),
              let parts = manifest["parts"] as? [[String: Any]], !parts.isEmpty else {
            throw ProbeFailure("\(language.rawValue): selected manifest does not match original media")
        }
        var expected: [RawToken] = []
        for part in parts.sorted(by: { (number($0["order"]) ?? -1) < (number($1["order"]) ?? -1) }) {
            guard let offset = number(part["absolute_offset_seconds"]),
                  let artifacts = part["artifacts"] as? [String: Any],
                  let json = artifacts["json_full"] as? [String: Any],
                  let path = json["path"] as? String,
                  let sha = json["sha256"] as? String,
                  sha == SelectedTimingHash.file(package.appendingPathComponent(path)),
                  let partJSON = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: package.appendingPathComponent(path))
                  ) as? [String: Any],
                  let segments = partJSON["transcription"] as? [[String: Any]] else {
                throw ProbeFailure("\(language.rawValue): selected JSON artifact is invalid")
            }
            for segment in segments {
                for token in (segment["tokens"] as? [[String: Any]]) ?? [] {
                    guard let text = token["text"] as? String,
                          let offsets = token["offsets"] as? [String: Any],
                          let from = number(offsets["from"]),
                          let to = number(offsets["to"]) else {
                        throw ProbeFailure("\(language.rawValue): raw token lacks boundaries")
                    }
                    if isWhisperControl(text) { continue }
                    expected.append(RawToken(text: text, from: offset * 1000 + from, to: offset * 1000 + to))
                }
            }
        }
        let imported = try SelectedTimingImporter().importSelectedPackage(
            packageRoot: package, expectedMediaURL: media, expectedLanguage: language
        )
        try imported.validateCoverage()
        try require(imported.tokenTimeline.count == expected.count,
                    "\(language.rawValue): translation importer dropped raw tokens")
        for (actual, raw) in zip(imported.tokenTimeline, expected) {
            try require(actual.text == raw.text
                        && abs(actual.start * 1000 - raw.from) < 0.000_001
                        && abs(actual.end * 1000 - raw.to) < 0.000_001,
                        "\(language.rawValue): translation importer changed raw order/endpoints")
        }
        try require(imported.units.allSatisfy { $0.start >= 0 && $0.end > $0.start }
                    && zip(imported.units, imported.units.dropFirst()).allSatisfy { $0.end <= $1.start },
                    "\(language.rawValue): real raw evidence produced invalid executable source units")
        let roundTrip = try JSONDecoder().decode(TimedSourceDocument.self, from: JSONEncoder().encode(imported))
        try require(roundTrip == imported, "\(language.rawValue): raw values/order failed Codable round-trip")

        let coreData = try SeminarTextCoreWhisperEvidenceImporter().importSelectedWhisperJSON(
            packageRoot: package, expectedMediaURL: media, expectedLanguage: language
        )
        guard let core = try JSONSerialization.jsonObject(with: coreData) as? [String: Any],
              let coreSegments = core["transcription"] as? [[String: Any]] else {
            throw ProbeFailure("\(language.rawValue): core importer produced no transcription")
        }
        let coreTokens = coreSegments.flatMap { ($0["tokens"] as? [[String: Any]]) ?? [] }
            .filter { token in
                guard let text = token["text"] as? String else { return false }
                return !isWhisperControl(text)
            }
        try require(coreTokens.count == expected.count, "\(language.rawValue): core importer dropped raw tokens")
        for (actual, raw) in zip(coreTokens, expected) {
            let offsets = actual["offsets"] as? [String: Any]
            try require(actual["text"] as? String == raw.text
                        && abs((number(offsets?["from"]) ?? -1) - raw.from) < 0.000_001
                        && abs((number(offsets?["to"]) ?? -1) - raw.to) < 0.000_001,
                        "\(language.rawValue): core importer changed raw order/endpoints")
        }
        let expectedFillerWords = expected.filter {
            $0.text.rangeOfCharacter(from: .letters) != nil
        }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let cues = try imported.subtitleCues()
        let selectedFiller = try FillerWordService().analyze(
            selectedTiming: imported, cues: cues, language: language,
            transcriptRevisionID: "real-\(language.rawValue)-selected",
            mediaDuration: cues.last?.end
        )
        try require(selectedFiller.words.map(\.text) == expectedFillerWords,
                    "\(language.rawValue): selected filler words include controls or lost spoken tokens")
        let coreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("videotext-real-core-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: coreURL) }
        try coreData.write(to: coreURL)
        let coreFiller = try FillerWordService().analyze(
            whisperJSONURL: coreURL, cues: cues, language: language,
            transcriptRevisionID: "real-\(language.rawValue)-core",
            mediaDuration: cues.last?.end
        )
        try require(coreFiller.words.map(\.text) == expectedFillerWords,
                    "\(language.rawValue): core filler words include controls or lost spoken tokens")
        return [
            "mediaSHA256": SelectedTimingHash.file(media),
            "manifestSHA256": SelectedTimingHash.file(manifestURL),
            "tokenCount": expected.count,
            "reverseRawCount": expected.filter { $0.from > $0.to }.count,
            "unitCount": imported.units.count,
            "fillerWordCount": coreFiller.words.count,
            "coreImportedSHA256": SelectedTimingHash.data(coreData)
        ]
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func isWhisperControl(_ text: String) -> Bool {
        text.hasPrefix("[_") && text.hasSuffix("]")
    }

    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw ProbeFailure(message) }
    }
}

private struct ProbeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
