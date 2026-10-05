import Foundation
import CryptoKit

/// The native translation path imports only SeminarText's already-selected
/// Whisper evidence. VideoText owns unit assembly, artifacts and provenance;
/// it never runs a second Whisper pass for timing.
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
        let sourceDocument = try await transcribe(
            mediaURL: mediaURL,
            language: source,
            executable: seminarTextExecutable,
            outputRoot: upstreamOutputRoot,
            onLog: onLog
        )
        return try await translate(
            sourceDocument: sourceDocument,
            source: source,
            target: target,
            cacheDirectory: cacheDirectory,
            onLog: onLog
        )
    }

    func transcribe(
        mediaURL: URL,
        language: ArtifactLanguage,
        executable: URL,
        modelPath: String = "",
        outputRoot: URL,
        onLog: @escaping (String) -> Void = { _ in }
    ) async throws -> TimedSourceDocument {
        let package = try await runner.transcribe(
            mediaURL: mediaURL,
            language: language,
            executable: executable,
            modelPath: modelPath,
            outputRoot: outputRoot,
            onLog: onLog
        )
        return try importer.importSelectedPackage(
            packageRoot: package,
            expectedMediaURL: mediaURL,
            expectedLanguage: language
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
        try persistSource(document.source, to: projectURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(document).write(
            to: layout.selectedTimingTranslationsURL(source: document.sourceLanguage, target: document.targetLanguage),
            options: .atomic
        )
    }

    func persistSource(_ document: TimedSourceDocument, to projectURL: URL) throws {
        let layout = ProjectLayout(root: projectURL)
        try FileManager.default.createDirectory(at: layout.selectedTimingDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(document).write(to: layout.selectedTimingSourceUnitsURL, options: .atomic)
    }

    func loadPersistedSource(projectURL: URL, mediaURL: URL) throws -> TimedSourceDocument? {
        let url = ProjectLayout(root: projectURL).selectedTimingSourceUnitsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let document = try JSONDecoder().decode(TimedSourceDocument.self, from: Data(contentsOf: url))
        try document.validateCoverage()
        guard document.sourceMediaSHA256 == SelectedTimingHash.file(mediaURL) else { return nil }
        return document
    }

    func currentIdentity() async throws -> TranslationModelIdentity {
        try await translator.identity()
    }

    /// Keeps selected timing as the source of ranges while making the current
    /// approved source revision the only text supplied to TranslateGemma.
    /// Human review may alter wording, so reusing the original machine text is
    /// never acceptable even when the media SHA still matches.
    func sourceDocument(
        _ selected: TimedSourceDocument,
        reconciledWith cues: [SubtitleCue]
    ) throws -> TimedSourceDocument {
        try selected.validateCoverage()
        guard !cues.isEmpty else {
            throw WorkflowError.processFailed("Активная исходная расшифровка пуста; selected timing перевод невозможен.")
        }
        var units: [TimedSourceUnit] = []
        var previousEnd: TimeInterval?
        for (index, cue) in cues.enumerated() {
            guard !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  cue.start >= 0,
                  cue.end >= cue.start,
                  previousEnd.map({ cue.start >= $0 }) ?? true else {
                throw WorkflowError.processFailed("Активная исходная расшифровка имеет недопустимые cue для selected timing перевода.")
            }
            // A shared endpoint is not speech overlap. Including it would pull
            // adjacent provenance into this cue and make resume non-idempotent.
            let overlaps = selected.units.filter { $0.start < cue.end && $0.end > cue.start }
            guard !overlaps.isEmpty else {
                throw WorkflowError.processFailed("Активная исходная расшифровка выходит за пределы выбранных временных данных SeminarText.")
            }
            let prefix = overlaps.first?.text.prefix(while: { $0.isWhitespace }) ?? ""
            let text = String(prefix) + cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let partIDs = overlaps.flatMap(\.sourcePartIDs).reduce(into: [String]()) { values, partID in
                if !values.contains(partID) { values.append(partID) }
            }
            units.append(TimedSourceUnit(
                id: index + 1,
                text: text,
                textSHA256: SelectedTimingHash.string(text),
                start: cue.start,
                end: cue.end,
                sourcePartIDs: partIDs
            ))
            previousEnd = cue.end
        }
        let reconciled = TimedSourceDocument(
            schemaVersion: selected.schemaVersion,
            contract: selected.contract,
            upstreamManifestSHA256: selected.upstreamManifestSHA256,
            sourceMediaSHA256: selected.sourceMediaSHA256,
            sourceText: units.map(\.text).joined(),
            units: units,
            selectedTimingEnd: selected.selectedTimingEnd,
            tokenTimeline: selected.tokenTimeline,
            qualityEvidence: selected.qualityEvidence
        )
        try reconciled.validateCoverage()
        return reconciled
    }
}

/// The packaged application owns selection of the SeminarText component that
/// implements its selected-timing contract. This must not silently fall back
/// to an arbitrary executable from PATH after release validation.
struct SeminarTextExecutableLocator {
    func resolvedExecutable() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let configured = environment["VIDEOTEXT_SEMINARTEXT_EXECUTABLE"]
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("SeminarText/seminartext")
            .standardizedFileURL
        let candidates = [bundled, configured].compactMap { $0 }
        for executable in candidates where FileManager.default.isExecutableFile(atPath: executable.path) {
            try verifyCapability(of: executable)
            return executable
        }
        throw WorkflowError.missingTool("Не найден совместимый компонент SeminarText для selected timing.")
    }

    private func verifyCapability(of executable: URL) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["transcribe", "--help"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let help = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0,
              help.contains("--language"),
              help.contains("--structured-timing") else {
            throw WorkflowError.processFailed("SeminarText не поддерживает required selected-timing contract (--language, --structured-timing): \(executable.path)")
        }
    }

    func runtimeIdentity(of executable: URL) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["runtime-identity"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let identity = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0, !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowError.processFailed("Не удалось проверить runtime identity SeminarText: \(executable.path)")
        }
        return identity.trimmingCharacters(in: .whitespacesAndNewlines)
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
        modelPath: String,
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
        var arguments = [
            "SEMINARTEXT_OUTPUT=\(invocationRoot.path)",
            "SEMINARTEXT_HEADLESS=1"
        ]
        if !modelPath.isEmpty {
            arguments.append("SEMINARTEXT_MODEL=\(modelPath)")
        }
        arguments += [
            executable.path,
            "transcribe",
            mediaURL.path,
            "--language", language.rawValue,
            "--structured-timing",
            "--no-open"
        ]
        let result = try await runner.run(env, arguments, currentDirectory: invocationRoot) { _, chunk in
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

/// Token evidence imported from the selected SeminarText Whisper attempt.
/// It is VideoText provenance and is never supplied to TranslateGemma.
struct TimedSourceToken: Codable, Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var sourcePartID: String
}

/// Quality signals from the same selected Whisper JSON-full attempt as source
/// text and timing. They remain VideoText provenance and never reach
/// TranslateGemma.
struct TimedSourceQualityEvidence: Codable, Equatable {
    var sourceUnitID: Int
    var averageTokenConfidence: Double?
    var averageNoSpeechProbability: Double?
}

struct TimedSourceDocument: Codable, Equatable {
    var schemaVersion: Int
    var contract: String
    var upstreamManifestSHA256: String
    var sourceMediaSHA256: String
    var sourceText: String
    var units: [TimedSourceUnit]
    /// Upper envelope explicitly published by SeminarText for selected JSON/SRT
    /// timing. It may exceed the prepared WAV duration because that is native
    /// Whisper padding, not a VideoText-generated extension.
    var selectedTimingEnd: TimeInterval?
    var tokenTimeline: [TimedSourceToken]
    var qualityEvidence: [TimedSourceQualityEvidence]

    init(
        schemaVersion: Int,
        contract: String,
        upstreamManifestSHA256: String,
        sourceMediaSHA256: String,
        sourceText: String,
        units: [TimedSourceUnit],
        selectedTimingEnd: TimeInterval? = nil,
        tokenTimeline: [TimedSourceToken] = [],
        qualityEvidence: [TimedSourceQualityEvidence] = []
    ) {
        self.schemaVersion = schemaVersion
        self.contract = contract
        self.upstreamManifestSHA256 = upstreamManifestSHA256
        self.sourceMediaSHA256 = sourceMediaSHA256
        self.sourceText = sourceText
        self.units = units
        self.selectedTimingEnd = selectedTimingEnd
        self.tokenTimeline = tokenTimeline
        self.qualityEvidence = qualityEvidence
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, contract, upstreamManifestSHA256, sourceMediaSHA256
        case sourceText, units, selectedTimingEnd, tokenTimeline, qualityEvidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        contract = try container.decode(String.self, forKey: .contract)
        upstreamManifestSHA256 = try container.decode(String.self, forKey: .upstreamManifestSHA256)
        sourceMediaSHA256 = try container.decode(String.self, forKey: .sourceMediaSHA256)
        sourceText = try container.decode(String.self, forKey: .sourceText)
        units = try container.decode([TimedSourceUnit].self, forKey: .units)
        selectedTimingEnd = try container.decodeIfPresent(TimeInterval.self, forKey: .selectedTimingEnd)
        tokenTimeline = try container.decodeIfPresent([TimedSourceToken].self, forKey: .tokenTimeline) ?? []
        qualityEvidence = try container.decodeIfPresent([TimedSourceQualityEvidence].self, forKey: .qualityEvidence) ?? []
    }

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
        // Token offsets retain native selected-Whisper evidence. Equal bounds
        // are valid zero-width evidence; only reverse intervals are invalid.
        guard tokenTimeline.allSatisfy({ !$0.text.isEmpty && $0.start >= 0 && $0.end >= $0.start && !$0.sourcePartID.isEmpty }) else {
            throw WorkflowError.processFailed("Selected timing source token timeline содержит недопустимый речевой интервал.")
        }
        let unitIDs = Set(units.map(\.id))
        guard Set(qualityEvidence.map(\.sourceUnitID)).count == qualityEvidence.count,
              qualityEvidence.allSatisfy({ evidence in
                  unitIDs.contains(evidence.sourceUnitID)
                      && [evidence.averageTokenConfidence, evidence.averageNoSpeechProbability].allSatisfy {
                          $0.map { (0...1).contains($0) } ?? true
                      }
              }) else {
            throw WorkflowError.processFailed("Selected timing source quality evidence содержит недопустимый provenance.")
        }
        guard selectedTimingEnd.map({ $0 > 0 && units.last!.end <= $0 + 0.000_001 }) ?? true else {
            throw WorkflowError.processFailed("Selected timing source units выходят за подписанный selected timing envelope.")
        }
    }

    func subtitleCues() throws -> [SubtitleCue] {
        try validateCoverage()
        return units.map { unit in
            SubtitleCue(id: unit.id, start: unit.start, end: unit.end, text: unit.text)
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

    func subtitleCues() throws -> [SubtitleCue] {
        try validate()
        return units.map { unit in
            SubtitleCue(id: unit.sourceUnitID, start: unit.start, end: unit.end, text: unit.text)
        }
    }

    func adapterResult() throws -> TranslationAdapterResult {
        TranslationAdapterResult(
            cues: try subtitleCues(),
            issues: [],
            model: model.model,
            modelDigest: model.digest,
            protocolVersion: model.protocolVersion,
            contextIdentity: source.upstreamManifestSHA256
        )
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
                  let selectedRange = part.selectedTimingAbsoluteRange,
                  selectedRange.startSeconds >= 0,
                  selectedRange.endSeconds > selectedRange.startSeconds,
                  previousPartEnd.map({ part.absoluteRange.startSeconds >= $0 }) ?? true else {
                throw WorkflowError.processFailed("Selected timing manifest содержит недопустимый absolute range.")
            }
            previousPartEnd = part.absoluteRange.endSeconds
            _ = try verify(part.artifacts.txt, in: packageRoot, expectedPart: part.id, fileExtension: "txt")
            _ = try verify(part.artifacts.srt, in: packageRoot, expectedPart: part.id, fileExtension: "srt")
            let jsonURL = try verify(part.artifacts.jsonFull, in: packageRoot, expectedPart: part.id, fileExtension: "json")
            let json = try JSONDecoder().decode(SelectedWhisperJSON.self, from: Data(contentsOf: jsonURL))
            var previousTokenEnd: Int?
            var previousAtomEnd: TimeInterval?
            for segment in json.transcription {
                let spokenTokens = segment.tokens.filter { !Self.isControlToken($0.text) }
                guard let firstToken = spokenTokens.first,
                      let lastToken = spokenTokens.last else { continue }
                guard segment.offsets.from >= 0,
                      segment.offsets.to >= segment.offsets.from,
                      lastToken.offsets.to > firstToken.offsets.from else {
                    throw WorkflowError.processFailed("Selected timing JSON содержит недопустимый segment interval.")
                }
                for token in spokenTokens {
                    guard token.offsets.from >= 0,
                          token.offsets.to >= token.offsets.from,
                          previousTokenEnd.map({ token.offsets.from >= $0 }) ?? true else {
                        throw WorkflowError.processFailed("Selected timing JSON содержит обратный token interval.")
                    }
                    previousTokenEnd = token.offsets.to
                    // The canonical contract publishes token offsets in the
                    // selected JSON timebase. Shift them only by the chunk's
                    // absolute offset: do not clip, compress or infer timing
                    // from SRT/segment boundaries downstream.
                    var start = part.absoluteOffsetSeconds + Double(token.offsets.from) / 1000
                    var end = part.absoluteOffsetSeconds + Double(token.offsets.to) / 1000
                    guard start >= selectedRange.startSeconds - 0.000_001,
                          end <= selectedRange.endSeconds + 0.000_001 else {
                        throw WorkflowError.processFailed("Selected timing JSON выходит за published selected timing envelope.")
                    }
                    if let previousAtomEnd {
                        guard start + 0.000_001 >= previousAtomEnd else {
                            throw WorkflowError.processFailed("Selected timing JSON содержит пересекающиеся absolute token intervals.")
                        }
                        start = max(start, previousAtomEnd)
                        end = max(end, start)
                    }
                    // JSON-full is evidence from the chosen Whisper attempt.
                    // A non-control token can legitimately have equal raw
                    // offsets after Whisper/VAD time mapping. Preserve that
                    // zero-width evidence verbatim; do not invent a duration
                    // or discard its source text. Sentence units retain their
                    // truthful envelope from the surrounding token evidence.
                    previousAtomEnd = end
                    atoms.append(SelectedTimingAtom(
                        text: token.text,
                        start: start,
                        end: end,
                        maximumEnd: selectedRange.endSeconds,
                        partID: part.id,
                        confidence: token.confidence,
                        noSpeechProbability: segment.noSpeechProbability
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
            units: units,
            selectedTimingEnd: ordered.compactMap(\.selectedTimingAbsoluteRange).map(\.endSeconds).max(),
            tokenTimeline: atoms.map {
                TimedSourceToken(text: $0.text, start: $0.start, end: $0.end, sourcePartID: $0.partID)
            },
            qualityEvidence: qualityEvidence(for: units, atoms: atoms)
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

    private func qualityEvidence(
        for units: [TimedSourceUnit],
        atoms: [SelectedTimingAtom]
    ) -> [TimedSourceQualityEvidence] {
        units.compactMap { unit in
            let matching = atoms.filter { $0.start < unit.end && $0.end > unit.start }
            let confidences = matching.compactMap(\.confidence)
            let noSpeech = matching.compactMap(\.noSpeechProbability)
            guard !confidences.isEmpty || !noSpeech.isEmpty else { return nil }
            return TimedSourceQualityEvidence(
                sourceUnitID: unit.id,
                averageTokenConfidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count),
                averageNoSpeechProbability: noSpeech.isEmpty ? nil : noSpeech.reduce(0, +) / Double(noSpeech.count)
            )
        }
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
    var selectedTimingAbsoluteRange: SeminarTextAbsoluteRange?
    var selectedAttempt: String
    var artifacts: SeminarTextArtifacts
    enum CodingKeys: String, CodingKey {
        case id, order, artifacts
        case absoluteOffsetSeconds = "absolute_offset_seconds"
        case absoluteRange = "absolute_range"
        case selectedTimingAbsoluteRange = "selected_timing_absolute_range"
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
private struct SelectedWhisperSegment: Decodable {
    var offsets: SelectedWhisperOffsets
    var tokens: [SelectedWhisperToken]
    var noSpeechProbability: Double?

    enum CodingKeys: String, CodingKey {
        case offsets, tokens
        case noSpeechProbability = "no_speech_prob"
    }
}
private struct SelectedWhisperToken: Decodable {
    var text: String
    var offsets: SelectedWhisperOffsets
    var confidence: Double?

    enum CodingKeys: String, CodingKey {
        case text, offsets
        case confidence = "p"
    }
}
private struct SelectedWhisperOffsets: Decodable { var from: Int; var to: Int }
private struct SelectedTimingAtom {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var maximumEnd: TimeInterval
    var partID: String
    var confidence: Double?
    var noSpeechProbability: Double?
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

/// A selected JSON-full envelope is the only timing extension VideoText may
/// accept beyond measured media duration. Projects without a valid selected
/// source remain constrained by their media duration.
enum SelectedTimingTimeline {
    static func permittedEnd(projectURL: URL, measuredDuration: TimeInterval?) -> TimeInterval? {
        let sourceURL = ProjectLayout(root: projectURL).selectedTimingSourceUnitsURL
        guard let data = try? Data(contentsOf: sourceURL),
              let source = try? JSONDecoder().decode(TimedSourceDocument.self, from: data),
              (try? source.validateCoverage()) != nil,
              let selectedEnd = source.selectedTimingEnd else {
            return measuredDuration
        }
        return max(measuredDuration ?? 0, selectedEnd)
    }
}
