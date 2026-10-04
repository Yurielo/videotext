import Foundation
import CryptoKit

/// The bounded PR #9 path. It imports only SeminarText's already-selected
/// native Whisper evidence; it neither invokes VideoText Whisper nor changes
/// the legacy full.srt translation path.
struct SelectedTimingVerticalSlice {
    static let contract = "videotext-selected-timing-sentence-units-v1"

    let runner: SeminarTextSelectedTimingRunner
    let importer: SelectedTimingImporter
    let translator: SimpleTextTranslationProvider

    init(
        runner: SeminarTextSelectedTimingRunner = SeminarTextSelectedTimingRunner(),
        importer: SelectedTimingImporter = SelectedTimingImporter(),
        translator: SimpleTextTranslationProvider = OllamaSimpleTextTranslateGemma()
    ) {
        self.runner = runner
        self.importer = importer
        self.translator = translator
    }

    func execute(
        mediaURL: URL,
        source: ArtifactLanguage,
        target: ArtifactLanguage,
        seminarTextExecutable: URL,
        upstreamOutputRoot: URL,
        cacheDirectory: URL? = nil,
        onLog: @escaping (String) -> Void = { _ in }
    ) async throws -> TimedTranslationDocument {
        guard source != target else {
            throw WorkflowError.processFailed("Язык перевода selected timing должен отличаться от языка источника.")
        }
        let package = try await runner.transcribe(
            mediaURL: mediaURL,
            language: source,
            executable: seminarTextExecutable,
            outputRoot: upstreamOutputRoot,
            onLog: onLog
        )
        let sourceDocument = try importer.importSelectedPackage(
            packageRoot: package,
            expectedMediaURL: mediaURL,
            expectedLanguage: source
        )
        return try await translate(
            sourceDocument: sourceDocument,
            source: source,
            target: target,
            cacheDirectory: cacheDirectory,
            onLog: onLog
        )
    }

    func translate(
        sourceDocument: TimedSourceDocument,
        source: ArtifactLanguage,
        target: ArtifactLanguage,
        cacheDirectory: URL? = nil,
        onLog: @escaping (String) -> Void = { _ in }
    ) async throws -> TimedTranslationDocument {
        guard source != target else {
            throw WorkflowError.processFailed("Язык перевода selected timing должен отличаться от языка источника.")
        }
        try sourceDocument.validateCoverage()
        let identity = try await translator.identity()
        let cache = SimpleTextTranslationCache(
            directory: cacheDirectory,
            document: sourceDocument,
            identity: identity,
            source: source,
            target: target
        )
        var translations: [TimedTranslationUnit] = []
        for unit in sourceDocument.units {
            try Task.checkCancellation()
            let translated: String
            if let cached = cache.load(unit) {
                translated = cached
                onLog("Selected timing: перевод unit \(unit.id) восстановлен из кэша.")
            } else {
                // This provider boundary receives only the owned text. IDs,
                // timestamps and provenance never cross into TranslateGemma.
                translated = try await translator.translate(text: unit.text, source: source, target: target)
                guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw WorkflowError.processFailed("TranslateGemma вернула пустой перевод source unit \(unit.id).")
                }
                try cache.save(translated, for: unit)
            }
            translations.append(TimedTranslationUnit(
                sourceUnitID: unit.id,
                sourceTextSHA256: unit.textSHA256,
                text: translated.trimmingCharacters(in: .whitespacesAndNewlines),
                start: unit.start,
                end: unit.end
            ))
        }
        let result = TimedTranslationDocument(
            schemaVersion: 1,
            contract: Self.contract,
            source: sourceDocument,
            sourceLanguage: source,
            targetLanguage: target,
            model: identity,
            units: translations
        )
        try result.validate()
        return result
    }

    func persist(_ document: TimedTranslationDocument, to projectURL: URL) throws {
        let layout = ProjectLayout(root: projectURL)
        try FileManager.default.createDirectory(at: layout.selectedTimingDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(document.source).write(to: layout.selectedTimingSourceUnitsURL, options: .atomic)
        try encoder.encode(document).write(
            to: layout.selectedTimingTranslationsURL(source: document.sourceLanguage, target: document.targetLanguage),
            options: .atomic
        )
    }
}

struct SeminarTextSelectedTimingRunner {
    let runner: ToolRunner

    init(runner: ToolRunner = ToolRunner()) {
        self.runner = runner
    }

    func transcribe(
        mediaURL: URL,
        language: ArtifactLanguage,
        executable: URL,
        outputRoot: URL,
        onLog: @escaping (String) -> Void = { _ in }
    ) async throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw WorkflowError.missingTool("SeminarText: \(executable.path)")
        }
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        // An invocation owns exactly one child directory. This prevents a
        // previous successful package under the caller's output root from
        // being mistaken for evidence from the current transcription.
        let invocationRoot = outputRoot.appendingPathComponent("selected-timing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: invocationRoot, withIntermediateDirectories: true)
        let env = "/usr/bin/env"
        guard FileManager.default.isExecutableFile(atPath: env) else {
            throw WorkflowError.missingTool("/usr/bin/env")
        }
        let result = try await runner.run(env, [
            "SEMINARTEXT_OUTPUT=\(invocationRoot.path)",
            "SEMINARTEXT_HEADLESS=1",
            executable.path,
            "transcribe",
            mediaURL.path,
            "--language", language.rawValue,
            "--structured-timing",
            "--no-open"
        ], currentDirectory: invocationRoot) { _, chunk in
            onLog(chunk)
        }
        guard result.exitCode == 0 else {
            throw WorkflowError.processFailed("SeminarText structured timing завершился с кодом \(result.exitCode): \((result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let manifests = Self.findManifests(in: invocationRoot)
        guard manifests.count == 1 else {
            throw WorkflowError.processFailed("SeminarText не создал один selected timing manifest (найдено: \(manifests.count)).")
        }
        return manifests[0].deletingLastPathComponent()
    }

    private static func findManifests(in root: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.lastPathComponent == "manifest.json",
                  url.deletingLastPathComponent().lastPathComponent.hasPrefix("structured_timing"),
                  (try? url.resourceValues(forKeys: keys).isRegularFile) == true else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }
}

struct TimedSourceUnit: Codable, Equatable {
    var id: Int
    var text: String
    var textSHA256: String
    var start: TimeInterval
    var end: TimeInterval
    var sourcePartIDs: [String]
}

struct TimedSourceDocument: Codable, Equatable {
    var schemaVersion: Int
    var contract: String
    var upstreamManifestSHA256: String
    var sourceMediaSHA256: String
    var sourceText: String
    var units: [TimedSourceUnit]

    func validateCoverage() throws {
        guard schemaVersion == 1, contract == SelectedTimingVerticalSlice.contract,
              !units.isEmpty, units.map(\.id) == Array(1...units.count),
              units.allSatisfy({ !$0.text.isEmpty && $0.start >= 0 && $0.end >= $0.start && !$0.sourcePartIDs.isEmpty }) else {
            throw WorkflowError.processFailed("Selected timing source units нарушают базовую структуру.")
        }
        for (previous, current) in zip(units, units.dropFirst()) where current.start < previous.end {
            throw WorkflowError.processFailed("Selected timing source units имеют пересекающиеся интервалы.")
        }
        let reconstructed = units.map(\.text).joined()
        guard reconstructed == sourceText else {
            throw WorkflowError.processFailed("Selected timing source loss/duplication: units не покрывают исходный текст ровно один раз.")
        }
        guard units.allSatisfy({ SelectedTimingHash.string($0.text) == $0.textSHA256 }) else {
            throw WorkflowError.processFailed("Selected timing source units имеют неверный text SHA-256.")
        }
    }
}

struct TimedTranslationUnit: Codable, Equatable {
    var sourceUnitID: Int
    var sourceTextSHA256: String
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

struct TimedTranslationDocument: Codable, Equatable {
    var schemaVersion: Int
    var contract: String
    var source: TimedSourceDocument
    var sourceLanguage: ArtifactLanguage
    var targetLanguage: ArtifactLanguage
    var model: TranslationModelIdentity
    var units: [TimedTranslationUnit]

    func validate() throws {
        try source.validateCoverage()
        guard schemaVersion == 1, contract == SelectedTimingVerticalSlice.contract,
              sourceLanguage != targetLanguage,
              units.count == source.units.count else {
            throw WorkflowError.processFailed("Selected timing translation нарушает структуру документа.")
        }
        for (sourceUnit, translated) in zip(source.units, units) {
            guard translated.sourceUnitID == sourceUnit.id,
                  translated.sourceTextSHA256 == sourceUnit.textSHA256,
                  translated.start == sourceUnit.start,
                  translated.end == sourceUnit.end,
                  !translated.text.isEmpty else {
                throw WorkflowError.processFailed("Selected timing translation потерял provenance source unit \(sourceUnit.id).")
            }
        }
    }
}

struct SelectedTimingImporter {
    func importSelectedPackage(
        packageRoot: URL,
        expectedMediaURL: URL,
        expectedLanguage: ArtifactLanguage
    ) throws -> TimedSourceDocument {
        guard FileManager.default.fileExists(atPath: expectedMediaURL.path) else {
            throw WorkflowError.processFailed("Selected timing source media не найден.")
        }
        let manifestURL = packageRoot.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(SeminarTextSelectedTimingManifest.self, from: manifestData)
        guard manifest.schemaVersion == 1,
              manifest.artifactType == "seminartext.selected_whisper_timing",
              manifest.transcription.language == expectedLanguage.rawValue,
              manifest.source.mediaSHA256 == SelectedTimingHash.file(expectedMediaURL) else {
            throw WorkflowError.processFailed("Selected timing manifest не соответствует выбранному media/language.")
        }
        let ordered = manifest.parts.sorted { $0.order < $1.order }
        guard ordered.map(\.order) == Array(0..<ordered.count), !ordered.isEmpty else {
            throw WorkflowError.processFailed("Selected timing manifest содержит неупорядоченные части.")
        }

        var atoms: [SelectedTimingAtom] = []
        var previousPartEnd: TimeInterval?
        for part in ordered {
            guard part.selectedAttempt == "initial" || part.selectedAttempt == "retry" else {
                throw WorkflowError.processFailed("Selected timing manifest содержит неизвестную выбранную попытку.")
            }
            guard part.absoluteRange.startSeconds == part.absoluteOffsetSeconds,
                  part.absoluteRange.endSeconds >= part.absoluteRange.startSeconds,
                  previousPartEnd.map({ part.absoluteRange.startSeconds >= $0 }) ?? true else {
                throw WorkflowError.processFailed("Selected timing manifest содержит недопустимый absolute range.")
            }
            previousPartEnd = part.absoluteRange.endSeconds
            _ = try verify(part.artifacts.txt, in: packageRoot, expectedPart: part.id, fileExtension: "txt")
            _ = try verify(part.artifacts.srt, in: packageRoot, expectedPart: part.id, fileExtension: "srt")
            let jsonURL = try verify(part.artifacts.jsonFull, in: packageRoot, expectedPart: part.id, fileExtension: "json")
            let json = try JSONDecoder().decode(SelectedWhisperJSON.self, from: Data(contentsOf: jsonURL))
            var previousTokenEnd: Int?
            for segment in json.transcription {
                for token in segment.tokens where !Self.isControlToken(token.text) {
                    guard token.offsets.from >= 0,
                          token.offsets.to >= token.offsets.from,
                          previousTokenEnd.map({ token.offsets.from >= $0 }) ?? true else {
                        throw WorkflowError.processFailed("Selected timing JSON содержит обратный token interval.")
                    }
                    previousTokenEnd = token.offsets.to
                    atoms.append(SelectedTimingAtom(
                        text: token.text,
                        start: part.absoluteOffsetSeconds + Double(token.offsets.from) / 1000,
                        end: part.absoluteOffsetSeconds + Double(token.offsets.to) / 1000,
                        maximumEnd: part.absoluteRange.endSeconds,
                        partID: part.id
                    ))
                }
            }
        }
        guard !atoms.isEmpty else {
            throw WorkflowError.processFailed("Selected timing JSON не содержит речевых token timestamps.")
        }
        let units = try sentenceUnits(from: atoms)
        let document = TimedSourceDocument(
            schemaVersion: 1,
            contract: SelectedTimingVerticalSlice.contract,
            upstreamManifestSHA256: SelectedTimingHash.data(manifestData),
            sourceMediaSHA256: manifest.source.mediaSHA256,
            sourceText: atoms.map(\.text).joined(),
            units: units
        )
        try document.validateCoverage()
        return document
    }

    private func sentenceUnits(from atoms: [SelectedTimingAtom]) throws -> [TimedSourceUnit] {
        var units: [TimedSourceUnit] = []
        var current: [SelectedTimingAtom] = []
        func flush() throws {
            guard !current.isEmpty else { return }
            let text = current.map(\.text).joined()
            guard !text.isEmpty else { throw WorkflowError.processFailed("Selected timing создал пустой source unit.") }
            let partIDs = current.reduce(into: [String]()) { result, atom in
                if result.last != atom.partID { result.append(atom.partID) }
            }
            units.append(TimedSourceUnit(
                id: units.count + 1,
                text: text,
                textSHA256: SelectedTimingHash.string(text),
                start: current.first!.start,
                // JSON-full is native Whisper evidence and may include decoder
                // padding past a media/chunk end. The manifest's signed range is
                // the truthful upper bound for this source-unit envelope; this
                // does not alter text or manufacture word-level alignment.
                end: min(current.last!.end, current.last!.maximumEnd),
                sourcePartIDs: partIDs
            ))
            current.removeAll(keepingCapacity: true)
        }
        for atom in atoms {
            current.append(atom)
            if Self.endsSentence(atom.text) { try flush() }
        }
        try flush()
        return units
    }

    private func verify(_ artifact: SeminarTextArtifact, in packageRoot: URL, expectedPart: String, fileExtension: String) throws -> URL {
        let expectedPath = "parts/\(expectedPart).\(fileExtension)"
        guard artifact.path == expectedPath else {
            throw WorkflowError.processFailed("Selected timing manifest содержит недопустимый artifact path.")
        }
        let url = packageRoot.appendingPathComponent(artifact.path)
        guard FileManager.default.fileExists(atPath: url.path),
              SelectedTimingHash.file(url) == artifact.sha256 else {
            throw WorkflowError.processFailed("Selected timing artifact hash не совпадает: \(artifact.path).")
        }
        return url
    }

    private static func isControlToken(_ value: String) -> Bool {
        value.hasPrefix("[_") && value.hasSuffix("_]")
    }

    private static func endsSentence(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars.last.map { ".?!…".unicodeScalars.contains($0) } ?? false
    }
}

protocol SimpleTextTranslationProvider {
    func identity() async throws -> TranslationModelIdentity
    func translate(text: String, source: ArtifactLanguage, target: ArtifactLanguage) async throws -> String
}

struct OllamaSimpleTextTranslateGemma: SimpleTextTranslationProvider {
    private let baseURL = URL(string: "http://127.0.0.1:11434")!
    private let transport: ((URLRequest) async throws -> Data)?
    static let model = "translategemma:4b"
    static let protocolVersion = "translategemma-simple-text-v1"

    init(transport: ((URLRequest) async throws -> Data)? = nil) {
        self.transport = transport
    }

    func identity() async throws -> TranslationModelIdentity {
        let data = try await request(URLRequest(url: baseURL.appendingPathComponent("api/tags")))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]],
              let model = models.first(where: { ($0["name"] as? String) == Self.model || ($0["model"] as? String) == Self.model }),
              let digest = model["digest"] as? String, !digest.isEmpty else {
            throw WorkflowError.topicServiceUnavailable("для selected timing перевода нужна локальная TranslateGemma (translategemma:4b).")
        }
        return TranslationModelIdentity(model: Self.model, digest: digest, protocolVersion: Self.protocolVersion)
    }

    func translate(text: String, source: ArtifactLanguage, target: ArtifactLanguage) async throws -> String {
        let sourceName = source == .en ? "English" : "Russian"
        let targetName = target == .en ? "English" : "Russian"
        let prompt = """
        Translate the following \(sourceName) spoken-text passage into \(targetName).
        Return only the translated passage. Preserve meaning, negation, numbers, names, terminology and natural repetitions. Do not add context or complete unstated meaning.

        \(text)
        """
        let body: [String: Any] = [
            "model": Self.model,
            "stream": false,
            "messages": [["role": "user", "content": prompt]],
            "options": ["temperature": 0]
        ]
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"), timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await self.request(request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["done"] as? Bool != false,
              let message = root["message"] as? [String: Any],
              let content = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty, !content.contains("```") else {
            throw WorkflowError.processFailed("TranslateGemma вернула неполный text-only перевод.")
        }
        return content
    }

    private func request(_ request: URLRequest) async throws -> Data {
        if let transport { return try await transport(request) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WorkflowError.topicServiceUnavailable("Ollama вернула ошибку HTTP для text-only перевода.")
        }
        return data
    }
}

struct SimpleTextTranslationCache {
    let directory: URL?
    let runIdentity: String

    init(directory: URL?, document: TimedSourceDocument, identity: TranslationModelIdentity, source: ArtifactLanguage, target: ArtifactLanguage) {
        self.directory = identity.digest?.isEmpty == false ? directory : nil
        runIdentity = SelectedTimingHash.string("\(document.upstreamManifestSHA256)|\(identity.model)|\(identity.digest ?? "")|\(identity.protocolVersion)|\(source.rawValue)|\(target.rawValue)")
    }

    func load(_ unit: TimedSourceUnit) -> String? {
        guard let url = url(for: unit),
              let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.schemaVersion == 1,
              record.runIdentity == runIdentity,
              record.unitID == unit.id,
              record.sourceTextSHA256 == unit.textSHA256,
              record.start == unit.start,
              record.end == unit.end,
              !record.text.isEmpty else { return nil }
        return record.text
    }

    func save(_ text: String, for unit: TimedSourceUnit) throws {
        guard let url = url(for: unit) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record = Record(schemaVersion: 1, runIdentity: runIdentity, unitID: unit.id,
                            sourceTextSHA256: unit.textSHA256, start: unit.start, end: unit.end, text: text)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }

    private func url(for unit: TimedSourceUnit) -> URL? {
        directory?.appendingPathComponent(runIdentity, isDirectory: true)
            .appendingPathComponent("unit-\(unit.id)-\(unit.textSHA256).json")
    }

    private struct Record: Codable {
        var schemaVersion: Int
        var runIdentity: String
        var unitID: Int
        var sourceTextSHA256: String
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }
}

private struct SeminarTextSelectedTimingManifest: Decodable {
    var schemaVersion: Int
    var artifactType: String
    var source: SeminarTextSource
    var transcription: SeminarTextTranscription
    var parts: [SeminarTextPart]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case artifactType = "artifact_type"
        case source, transcription, parts
    }
}

private struct SeminarTextSource: Decodable { var mediaSHA256: String; enum CodingKeys: String, CodingKey { case mediaSHA256 = "media_sha256" } }
private struct SeminarTextTranscription: Decodable { var language: String }
private struct SeminarTextPart: Decodable {
    var id: String
    var order: Int
    var absoluteOffsetSeconds: TimeInterval
    var absoluteRange: SeminarTextAbsoluteRange
    var selectedAttempt: String
    var artifacts: SeminarTextArtifacts
    enum CodingKeys: String, CodingKey {
        case id, order, artifacts
        case absoluteOffsetSeconds = "absolute_offset_seconds"
        case absoluteRange = "absolute_range"
        case selectedAttempt = "selected_attempt"
    }
}
private struct SeminarTextAbsoluteRange: Decodable {
    var startSeconds: TimeInterval
    var endSeconds: TimeInterval
    enum CodingKeys: String, CodingKey {
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
    }
}
private struct SeminarTextArtifacts: Decodable {
    var txt: SeminarTextArtifact
    var srt: SeminarTextArtifact
    var jsonFull: SeminarTextArtifact
    enum CodingKeys: String, CodingKey { case txt, srt; case jsonFull = "json_full" }
}
private struct SeminarTextArtifact: Decodable { var path: String; var sha256: String }
private struct SelectedWhisperJSON: Decodable { var transcription: [SelectedWhisperSegment] }
private struct SelectedWhisperSegment: Decodable { var tokens: [SelectedWhisperToken] }
private struct SelectedWhisperToken: Decodable { var text: String; var offsets: SelectedWhisperOffsets }
private struct SelectedWhisperOffsets: Decodable { var from: Int; var to: Int }
private struct SelectedTimingAtom {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var maximumEnd: TimeInterval
    var partID: String
}

enum SelectedTimingHash {
    static func data(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func string(_ text: String) -> String { data(Data(text.utf8)) }
    static func file(_ url: URL) -> String {
        data((try? Data(contentsOf: url)) ?? Data())
    }
}
