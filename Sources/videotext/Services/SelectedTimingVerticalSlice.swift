import Foundation
import CryptoKit

/// The native translation path imports only SeminarText's already-selected
/// Whisper evidence. VideoText owns unit assembly, artifacts and provenance;
/// it never runs a second Whisper pass for timing.
struct SelectedTimingVerticalSlice {
    static let contract = "videotext-selected-timing-sentence-units-v1"
    // Keep the same bounded retry budget used by the established translation adapter.
    static let maximumTranslationAttempts = 2

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
        rejectedResponseEvidenceURL: URL? = nil,
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
        let rejectedResponses = SelectedTimingRejectedResponseStore(url: rejectedResponseEvidenceURL)
        try rejectedResponses.beginRun()
        var translations: [TimedTranslationUnit] = []
        for unit in sourceDocument.units {
            try Task.checkCancellation()
            let translated: String
            if let cached = cache.load(unit),
               let validated = try? validatedTranslation(cached, sourceText: unit.text, source: source, target: target) {
                translated = validated
                onLog("Selected timing: перевод unit \(unit.id) восстановлен из кэша.")
            } else {
                // This provider boundary receives only the owned text. IDs,
                // timestamps and provenance never cross into TranslateGemma.
                let requestSHA256 = translator.requestSHA256(text: unit.text, source: source, target: target)
                var accepted: String?
                for attempt in 1...Self.maximumTranslationAttempts {
                    let response = try await translator.translate(text: unit.text, source: source, target: target)
                    do {
                        accepted = try validatedTranslation(
                            response,
                            sourceText: unit.text,
                            source: source,
                            target: target
                        )
                        break
                    } catch let rejection as SelectedTimingTranslationValidationFailure {
                        try rejectedResponses.append(SelectedTimingRejectedResponseEvidence(
                            unitID: unit.id,
                            sourceLanguage: source,
                            targetLanguage: target,
                            sourceTextSHA256: unit.textSHA256,
                            requestSHA256: requestSHA256,
                            model: identity.model,
                            modelDigest: identity.digest,
                            protocolVersion: identity.protocolVersion,
                            attempt: attempt,
                            rawResponse: response,
                            latinLetterCount: rejection.latinLetterCount,
                            cyrillicLetterCount: rejection.cyrillicLetterCount,
                            validationFailureReason: rejection.message,
                            createdAt: Date()
                        ))
                        onLog("Selected timing: TranslateGemma отклонила unit \(unit.id), попытка \(attempt)/\(Self.maximumTranslationAttempts): \(rejection.message)")
                        if attempt == Self.maximumTranslationAttempts {
                            throw WorkflowError.processFailed(rejection.message)
                        }
                    }
                }
                guard let accepted else {
                    throw WorkflowError.processFailed("TranslateGemma не вернула проверенный text-only перевод.")
                }
                translated = accepted
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

    private func validatedTranslation(
        _ text: String,
        sourceText: String,
        source: ArtifactLanguage,
        target: ArtifactLanguage
    ) throws -> String {
        let translated = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else {
            throw SelectedTimingTranslationValidationFailure(
                message: "TranslateGemma вернула пустой text-only перевод.",
                text: translated
            )
        }
        let normalizedSource = normalizedTranslationText(sourceText).lowercased()
        let normalizedTarget = normalizedTranslationText(translated).lowercased()
        guard normalizedTarget != normalizedSource,
              normalizedSource.isEmpty || !normalizedTarget.contains(normalizedSource) else {
            throw SelectedTimingTranslationValidationFailure(
                message: "TranslateGemma вернула исходный текст без перевода.",
                text: translated
            )
        }
        if source == .en, target == .ru {
            let letters = translationLetterCounts(translated)
            guard letters.cyrillic > 0, letters.cyrillic >= letters.latin else {
                throw SelectedTimingTranslationValidationFailure(
                    message: "TranslateGemma вернула текст преимущественно не на русском языке.",
                    latinLetterCount: letters.latin,
                    cyrillicLetterCount: letters.cyrillic
                )
            }
        }
        if source == .ru, target == .en {
            let letters = translationLetterCounts(translated)
            guard letters.latin > 0, letters.latin >= letters.cyrillic else {
                throw SelectedTimingTranslationValidationFailure(
                    message: "TranslateGemma вернула текст преимущественно не на английском языке.",
                    latinLetterCount: letters.latin,
                    cyrillicLetterCount: letters.cyrillic
                )
            }
        }
        return translated
    }

    private func normalizedTranslationText(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func translationLetterCounts(_ text: String) -> (latin: Int, cyrillic: Int) {
        text.unicodeScalars.reduce(into: (latin: 0, cyrillic: 0)) { counts, scalar in
            switch scalar.value {
            case 0x0041...0x005A, 0x0061...0x007A:
                counts.latin += 1
            case 0x0400...0x052F:
                counts.cyrillic += 1
            default:
                break
            }
        }
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

    /// Materializes translation-owned source units from the selected timing
    /// package already produced by the canonical Core transcription. This must
    /// never invoke SeminarText or Whisper again.
    func loadOrImportCoreSource(
        projectURL: URL,
        mediaURL: URL,
        language: ArtifactLanguage
    ) throws -> TimedSourceDocument {
        let layout = ProjectLayout(root: projectURL)
        guard FileManager.default.isReadableFile(atPath: layout.seminarTextCoreEvidenceURL.path) else {
            throw WorkflowError.processFailed(
                "В проекте нет canonical SeminarText timing evidence. Перевод не будет запускать повторную расшифровку."
            )
        }
        let evidence = try JSONDecoder().decode(
            SeminarTextCoreTranscriptionEvidence.self,
            from: Data(contentsOf: layout.seminarTextCoreEvidenceURL)
        )
        guard let expectedManifestHash = evidence.selectedTimingManifestSHA256,
              !expectedManifestHash.isEmpty else {
            throw WorkflowError.processFailed(
                "Canonical SeminarText evidence не содержит selected timing manifest; повторный ASR запрещён."
            )
        }
        let persisted = try loadPersistedSource(projectURL: projectURL, mediaURL: mediaURL)
        if let persisted, persisted.upstreamManifestSHA256 == expectedManifestHash {
            return persisted
        }
        let discoveredManifests = SeminarTextSelectedTimingRunner.findManifests(in: layout.seminarTextCoreDirectory)
        let matchingManifests = discoveredManifests.filter {
            SelectedTimingHash.file($0) == expectedManifestHash
        }
        if matchingManifests.count == 1, let manifestURL = matchingManifests.first {
            guard persisted == nil else {
                throw WorkflowError.processFailed(
                    "Сохранённые source units не принадлежат canonical SeminarText attempt этого проекта."
                )
            }
            let document = try importer.importSelectedPackage(
                packageRoot: manifestURL.deletingLastPathComponent(),
                expectedMediaURL: mediaURL,
                expectedLanguage: language
            )
            guard document.upstreamManifestSHA256 == expectedManifestHash else {
                throw WorkflowError.processFailed("Selected timing source units не совпадают с canonical Core evidence.")
            }
            try persistSource(document, to: projectURL)
            return document
        }
        guard matchingManifests.isEmpty,
              discoveredManifests.count == 1,
              let manifestURL = discoveredManifests.first,
              let document = try compatibleRelocatedSourceReference(
                  manifestURL: manifestURL,
                  evidence: evidence,
                  expectedMediaURL: mediaURL,
                  expectedLanguage: language
              ) else {
            throw WorkflowError.processFailed(
                "Не найден единственный selected timing package, связанный с принятой расшифровкой. Повторный ASR не выполнялся."
            )
        }
        try persistSource(document, to: projectURL)
        try persistEvidence(
            evidence,
            selectedTimingManifestSHA256: document.upstreamManifestSHA256,
            at: layout.seminarTextCoreEvidenceURL
        )
        return document
    }

    private func compatibleRelocatedSourceReference(
        manifestURL: URL,
        evidence: SeminarTextCoreTranscriptionEvidence,
        expectedMediaURL: URL,
        expectedLanguage: ArtifactLanguage
    ) throws -> TimedSourceDocument? {
        let packageRoot = manifestURL.deletingLastPathComponent()
        // `outputDirectory` and `reference_sha256` are diagnostic location
        // evidence from the original run. A copied legacy project can retain
        // either stale value. The candidate was already discovered beneath this
        // project's SeminarText tree; validate its own immutable artifacts and
        // its actual media binding before adopting it.
        let candidateOutputDirectory = packageRoot.deletingLastPathComponent()
        let expectedMediaHash = SelectedTimingHash.file(expectedMediaURL)
        guard let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
              let source = manifest["source"] as? [String: Any],
              let reference = source["reference"] as? String,
              reference.hasPrefix("/"),
              FileManager.default.fileExists(atPath: reference),
              SelectedTimingHash.file(URL(fileURLWithPath: reference)) == expectedMediaHash,
              source["media_sha256"] as? String == expectedMediaHash,
              let transcription = manifest["transcription"] as? [String: Any],
              transcription["language"] as? String == expectedLanguage.rawValue,
              let expectedWhisperJSONHash = evidence.selectedWhisperJSONSHA256,
              !expectedWhisperJSONHash.isEmpty else {
            return nil
        }
        let coreSRTs = coreSRTs(in: candidateOutputDirectory)
        guard coreSRTs.count == 1,
              SelectedTimingHash.file(coreSRTs[0]) == evidence.sourceSRTSHA256 else {
            return nil
        }
        do {
            let importedWhisperJSON = try SeminarTextCoreWhisperEvidenceImporter().importSelectedWhisperJSON(
                packageRoot: packageRoot,
                expectedMediaURL: expectedMediaURL,
                expectedLanguage: expectedLanguage
            )
            guard SelectedTimingHash.data(importedWhisperJSON) == expectedWhisperJSONHash else {
                return nil
            }
            return try importer.importSelectedPackage(
                packageRoot: packageRoot,
                expectedMediaURL: expectedMediaURL,
                expectedLanguage: expectedLanguage
            )
        } catch {
            return nil
        }
    }

    private func coreSRTs(in outputDirectory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: outputDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.pathExtension.lowercased() == "srt",
                  url.lastPathComponent.lowercased().hasPrefix("transcript"),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url
        }.sorted { $0.path < $1.path }
    }

    private func persistEvidence(
        _ evidence: SeminarTextCoreTranscriptionEvidence,
        selectedTimingManifestSHA256: String,
        at url: URL
    ) throws {
        let reconciled = SeminarTextCoreTranscriptionEvidence(
            schemaVersion: evidence.schemaVersion,
            runtimeIdentity: evidence.runtimeIdentity,
            sourceSRTSHA256: evidence.sourceSRTSHA256,
            selectedTimingManifestSHA256: selectedTimingManifestSHA256,
            selectedWhisperJSONSHA256: evidence.selectedWhisperJSONSHA256,
            outputDirectory: evidence.outputDirectory
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(reconciled).write(to: url, options: .atomic)
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
        var qualityEvidence: [TimedSourceQualityEvidence] = []
        let qualityByUnitID = Dictionary(uniqueKeysWithValues: selected.qualityEvidence.map { ($0.sourceUnitID, $0) })
        var previousEnd: TimeInterval?
        for cue in cues {
            guard !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  cue.start >= 0,
                  cue.end > cue.start,
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
                id: cue.id,
                text: text,
                textSHA256: SelectedTimingHash.string(text),
                start: cue.start,
                end: cue.end,
                sourcePartIDs: partIDs
            ))
            let overlappingQuality = overlaps.compactMap { qualityByUnitID[$0.id] }
            if !overlappingQuality.isEmpty {
                qualityEvidence.append(TimedSourceQualityEvidence(
                    sourceUnitID: cue.id,
                    averageTokenConfidence: average(overlappingQuality.compactMap(\.averageTokenConfidence)),
                    averageNoSpeechProbability: average(overlappingQuality.compactMap(\.averageNoSpeechProbability))
                ))
            }
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
            qualityEvidence: qualityEvidence
        )
        try reconciled.validateCoverage()
        return reconciled
    }

    private func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
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

    static func findManifests(in root: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return [] }
        var manifests: [URL] = []
        while let item = enumerator.nextObject() {
            guard let url = item as? URL else { continue }
            // Published packages can retain hidden metadata after leaving .parts.
            if url.lastPathComponent.hasPrefix(".") {
                if (try? url.resourceValues(forKeys: keys).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard url.lastPathComponent == "manifest.json",
                  url.deletingLastPathComponent().lastPathComponent.hasPrefix("structured_timing"),
                  (try? url.resourceValues(forKeys: keys).isRegularFile) == true else { continue }
            manifests.append(url)
        }
        return manifests.sorted { $0.path < $1.path }
    }
}

/// Core VideoText transcription consumes the selected SeminarText Whisper
/// attempt. Its ordinary SRT remains the source of VideoText subtitles, while
/// the selected JSON-full is imported only as the established core
/// `whisper.json` evidence for quality and filler-word consumers. This is one
/// SeminarText invocation, not a second transcription or a translation path.
struct SeminarTextCoreTranscriptionRunner {
    struct Result {
        let srtURL: URL
        let outputDirectory: URL
        let selectedTimingPackageURL: URL
    }

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
    ) async throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw WorkflowError.missingTool("SeminarText: \(executable.path)")
        }
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let invocationRoot = outputRoot.appendingPathComponent("core-transcription-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: invocationRoot, withIntermediateDirectories: true)
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
        let result = try await runner.run("/usr/bin/env", arguments, currentDirectory: invocationRoot) { _, chunk in
            onLog(chunk)
        }
        guard result.exitCode == 0 else {
            throw WorkflowError.processFailed("SeminarText transcription завершился с кодом \(result.exitCode): \((result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let srtURLs = Self.findCoreSRTs(in: invocationRoot)
        guard srtURLs.count == 1, let srtURL = srtURLs.first else {
            throw WorkflowError.processFailed("SeminarText не создал один core SRT (найдено: \(srtURLs.count)).")
        }
        let manifests = SeminarTextSelectedTimingRunner.findManifests(in: invocationRoot)
        guard manifests.count == 1, let manifestURL = manifests.first else {
            throw WorkflowError.processFailed("SeminarText не создал один manifest выбранной Whisper-попытки (найдено: \(manifests.count)).")
        }
        return Result(
            srtURL: srtURL,
            outputDirectory: srtURL.deletingLastPathComponent(),
            selectedTimingPackageURL: manifestURL.deletingLastPathComponent()
        )
    }

    private static func findCoreSRTs(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.pathExtension.lowercased() == "srt",
                  url.lastPathComponent.lowercased().hasPrefix("transcript"),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }

    /// SeminarText's ordinary CLI SRT deliberately omits numeric cue headers.
    /// Keep VideoText's general SRT parser strict; this narrow adapter accepts
    /// only that documented timestamp/text form and assigns local cue IDs.
    func loadCoreSRT(from url: URL, srt: SRTService = SRTService()) throws -> [SubtitleCue] {
        do {
            return try srt.load(from: url)
        } catch {
            let normalized = try String(contentsOf: url, encoding: .utf8)
                .replacingOccurrences(of: "\r\n", with: "\n")
            let blocks = normalized.components(separatedBy: "\n\n")
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !blocks.isEmpty else {
                throw WorkflowError.invalidSRT("SeminarText core SRT не содержит субтитров.")
            }
            var cues: [SubtitleCue] = []
            for (index, block) in blocks.enumerated() {
                let lines = block.components(separatedBy: "\n")
                guard lines.count >= 2 else {
                    throw WorkflowError.invalidSRT("SeminarText core SRT: неполный блок \(index + 1).")
                }
                let times = lines[0].components(separatedBy: " --> ")
                guard times.count == 2,
                      let start = srt.parseTimestamp(times[0]),
                      let end = srt.parseTimestamp(times[1]),
                      end >= start else {
                    throw WorkflowError.invalidSRT("SeminarText core SRT: некорректный временной диапазон в блоке \(index + 1).")
                }
                let text = lines.dropFirst().joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    throw WorkflowError.invalidSRT("SeminarText core SRT: пустой текст в блоке \(index + 1).")
                }
                guard end > start else { continue }
                cues.append(SubtitleCue(id: index + 1, start: start, end: end, text: text))
            }
            guard !cues.isEmpty else {
                throw WorkflowError.invalidSRT("SeminarText core SRT содержит только реплики нулевой длительности.")
            }
            return cues
        }
    }

    /// SeminarText may leave a small overlap where adjacent prepared-media
    /// chunks meet. Preserve the raw SRT as provenance and make only this
    /// bounded boundary adjustment for VideoText's non-overlapping full.srt.
    func reconcileForVideoTextTimeline(_ cues: [SubtitleCue]) throws -> [SubtitleCue] {
        let maximumBoundaryOverlap: TimeInterval = 0.25
        var reconciled: [SubtitleCue] = []
        for cue in cues {
            guard let previous = reconciled.last else {
                reconciled.append(cue)
                continue
            }
            guard cue.start < previous.end else {
                reconciled.append(cue)
                continue
            }
            let overlap = previous.end - cue.start
            guard overlap <= maximumBoundaryOverlap, cue.end > previous.end else {
                throw WorkflowError.invalidSRT("SeminarText core SRT: небезопасное пересечение реплик \(previous.id) и \(cue.id) (\(String(format: "%.3f", overlap)) с).")
            }
            reconciled.append(SubtitleCue(id: cue.id, start: previous.end, end: cue.end, text: cue.text))
        }
        return reconciled
    }
}

struct SeminarTextCoreTranscriptionEvidence: Codable {
    let schemaVersion: Int
    let runtimeIdentity: String
    let sourceSRTSHA256: String
    let selectedTimingManifestSHA256: String?
    let selectedWhisperJSONSHA256: String?
    let outputDirectory: String
}

/// Whisper JSON-full control markers include both `[_BEG_]` and timestamp
/// markers such as `[_TT_128]`. They stay in core JSON provenance, but are not
/// spoken tokens for source units, tokenTimeline or timed-speech capability.
private func isSelectedWhisperControlToken(_ text: String) -> Bool {
    text.hasPrefix("[_") && text.hasSuffix("]")
}

/// Imports selected JSON-full artifacts from the same selected SeminarText
/// attempt into the long-standing VideoText `whisper.json` shape. The legacy
/// core consumers require only raw Whisper segment/token evidence. Their
/// absolute offsets are derived exclusively from the signed per-part offset in
/// SeminarText's manifest; no timing, confidence or text is invented.
struct SeminarTextCoreWhisperEvidenceImporter {
    func importSelectedWhisperJSON(
        packageRoot: URL,
        expectedMediaURL: URL,
        expectedLanguage: ArtifactLanguage
    ) throws -> Data {
        let manifestURL = packageRoot.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              (manifest["schema_version"] as? NSNumber)?.intValue == 1,
              manifest["artifact_type"] as? String == "seminartext.selected_whisper_timing",
              let source = manifest["source"] as? [String: Any],
              source["media_sha256"] as? String == SelectedTimingHash.file(expectedMediaURL),
              let transcription = manifest["transcription"] as? [String: Any],
              transcription["language"] as? String == expectedLanguage.rawValue,
              let rawParts = manifest["parts"] as? [[String: Any]],
              !rawParts.isEmpty else {
            throw WorkflowError.processFailed("SeminarText selected JSON manifest не соответствует media/language.")
        }

        let parts = try rawParts.sorted { lhs, rhs in
            try partOrder(lhs) < partOrder(rhs)
        }
        guard try parts.enumerated().allSatisfy({ index, part in try partOrder(part) == index }) else {
            throw WorkflowError.processFailed("SeminarText selected JSON manifest содержит неупорядоченные части.")
        }

        var rootTemplate: [String: Any]?
        var segments: [[String: Any]] = []
        var hasTimedToken = false
        for part in parts {
            let id = try partID(part)
            let offset = try absoluteOffset(part)
            let selectedRange = try selectedTimingRange(part)
            let jsonURL = try verifiedJSON(part: part, id: id, packageRoot: packageRoot)
            guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any],
                  let transcription = root["transcription"] as? [[String: Any]] else {
                throw WorkflowError.processFailed("Selected JSON-full \(id) не содержит transcription.")
            }
            if rootTemplate == nil { rootTemplate = root }
            for segment in transcription {
                try validateSelectedSegment(segment, range: selectedRange, absoluteOffset: offset, partID: id)
                let shifted = shift(segment, milliseconds: offset * 1000)
                if segmentHasTimedToken(shifted) { hasTimedToken = true }
                segments.append(shifted)
            }
        }
        guard !segments.isEmpty, hasTimedToken else {
            throw WorkflowError.processFailed("Selected JSON-full не содержит слов с временными границами для core whisper.json.")
        }
        var root = rootTemplate ?? [:]
        root["transcription"] = segments
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    func validateLegacyWhisperJSON(at url: URL) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let transcription = root["transcription"] as? [[String: Any]],
              !transcription.isEmpty else { return false }
        return transcription.contains(where: segmentHasTimedToken)
    }

    private func partOrder(_ part: [String: Any]) throws -> Int {
        guard let order = number(part["order"]), order >= 0, order.rounded() == order else {
            throw WorkflowError.processFailed("SeminarText selected JSON manifest содержит недопустимый order части.")
        }
        return Int(order)
    }

    private func partID(_ part: [String: Any]) throws -> String {
        guard let id = part["id"] as? String,
              id.range(of: "^part_[0-9]{4}$", options: .regularExpression) != nil else {
            throw WorkflowError.processFailed("SeminarText selected JSON manifest содержит недопустимый ID части.")
        }
        return id
    }

    private func absoluteOffset(_ part: [String: Any]) throws -> Double {
        guard let offset = number(part["absolute_offset_seconds"]), offset >= 0 else {
            throw WorkflowError.processFailed("SeminarText selected JSON manifest содержит недопустимый absolute offset.")
        }
        return offset
    }

    private func selectedTimingRange(_ part: [String: Any]) throws -> (start: Double, end: Double) {
        guard let range = part["selected_timing_absolute_range"] as? [String: Any],
              let start = number(range["start_seconds"]),
              let end = number(range["end_seconds"]),
              start >= 0, end > start else {
            throw WorkflowError.processFailed("SeminarText selected JSON manifest не содержит truthful selected timing envelope.")
        }
        return (start, end)
    }

    private func verifiedJSON(part: [String: Any], id: String, packageRoot: URL) throws -> URL {
        guard let artifacts = part["artifacts"] as? [String: Any],
              let json = artifacts["json_full"] as? [String: Any],
              let path = json["path"] as? String,
              path == "parts/\(id).json",
              let expectedHash = json["sha256"] as? String else {
            throw WorkflowError.processFailed("SeminarText selected JSON manifest содержит недопустимый json_full artifact.")
        }
        let url = packageRoot.appendingPathComponent(path)
        guard FileManager.default.isReadableFile(atPath: url.path),
              SelectedTimingHash.file(url) == expectedHash else {
            throw WorkflowError.processFailed("Selected JSON-full artifact не читается или не совпадает с manifest: \(path).")
        }
        return url
    }

    private func validateSelectedSegment(
        _ segment: [String: Any],
        range: (start: Double, end: Double),
        absoluteOffset: Double,
        partID: String
    ) throws {
        guard let offsets = segment["offsets"] as? [String: Any],
              let start = number(offsets["from"]),
              let end = number(offsets["to"]),
              start >= 0, end >= start,
              absoluteOffset + start / 1000 >= range.start - 0.000_001,
              absoluteOffset + end / 1000 <= range.end + 0.000_001 else {
            // The manifest's selected envelope, rather than prepared chunk
            // duration, is the only accepted authority for selected evidence.
            throw WorkflowError.processFailed("Selected JSON-full \(partID) содержит недопустимый segment timing.")
        }
        guard let tokens = segment["tokens"] as? [[String: Any]] else {
            throw WorkflowError.processFailed("Selected JSON-full \(partID) не содержит tokens.")
        }
        for token in tokens {
            guard let tokenOffsets = token["offsets"] as? [String: Any],
                  let tokenStart = number(tokenOffsets["from"]),
                  let tokenEnd = number(tokenOffsets["to"]),
                  tokenStart >= 0, tokenEnd >= 0,
                  absoluteOffset + tokenStart / 1000 >= range.start - 0.000_001,
                  absoluteOffset + tokenStart / 1000 <= range.end + 0.000_001,
                  absoluteOffset + tokenEnd / 1000 >= range.start - 0.000_001,
                  absoluteOffset + tokenEnd / 1000 <= range.end + 0.000_001 else {
                throw WorkflowError.processFailed("Selected JSON-full \(partID) содержит недопустимый token timing.")
            }
        }
    }

    private func segmentHasTimedToken(_ segment: [String: Any]) -> Bool {
        guard let tokens = segment["tokens"] as? [[String: Any]] else { return false }
        return tokens.contains { token in
            guard let text = (token["text"] as? String) ?? (token["token"] as? String),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !isSelectedWhisperControlToken(text),
                  let offsets = token["offsets"] as? [String: Any],
                  let start = number(offsets["from"]),
                  let end = number(offsets["to"]) else { return false }
            return start >= 0 && end >= 0 && end != start
        }
    }

    private func shift(_ value: [String: Any], milliseconds: Double) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, child) in value {
            if key == "offsets", var offsets = child as? [String: Any] {
                for boundary in ["from", "to"] {
                    if let value = number(offsets[boundary]) { offsets[boundary] = value + milliseconds }
                }
                result[key] = offsets
            } else if key == "timestamps", var timestamps = child as? [String: Any] {
                for boundary in ["from", "to"] {
                    if let seconds = timestamp(timestamps[boundary]) {
                        timestamps[boundary] = SRTService().formatTimestamp(seconds + milliseconds / 1000)
                            .replacingOccurrences(of: ",", with: ".")
                    }
                }
                result[key] = timestamps
            } else if let dictionary = child as? [String: Any] {
                result[key] = shift(dictionary, milliseconds: milliseconds)
            } else if let dictionaries = child as? [[String: Any]] {
                result[key] = dictionaries.map { shift($0, milliseconds: milliseconds) }
            } else {
                result[key] = child
            }
        }
        return result
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private func timestamp(_ value: Any?) -> TimeInterval? {
        if let number = number(value) { return number > 1000 ? number / 1000 : number }
        guard let text = value as? String else { return nil }
        return try? TimecodeParser.parse(text.replacingOccurrences(of: ",", with: "."))
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
        let unitIDs = units.map(\.id)
        guard schemaVersion == 1, contract == SelectedTimingVerticalSlice.contract,
              !units.isEmpty,
              unitIDs.allSatisfy({ $0 > 0 }),
              Set(unitIDs).count == unitIDs.count,
              zip(unitIDs, unitIDs.dropFirst()).allSatisfy({ $0 < $1 }),
              units.allSatisfy({ !$0.text.isEmpty && $0.start.isFinite && $0.end.isFinite
                  && $0.start >= 0 && $0.end > $0.start && !$0.sourcePartIDs.isEmpty }) else {
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
        // Token offsets are raw Whisper evidence, not executable ranges.
        // Both boundaries must be nonnegative, but their direction is retained.
        guard tokenTimeline.allSatisfy({
            !$0.text.isEmpty && $0.start.isFinite && $0.end.isFinite
                && $0.start >= 0 && $0.end >= 0 && !$0.sourcePartID.isEmpty
        }) else {
            throw WorkflowError.processFailed("Selected timing source token timeline содержит недопустимый речевой интервал.")
        }
        let validUnitIDs = Set(unitIDs)
        guard Set(qualityEvidence.map(\.sourceUnitID)).count == qualityEvidence.count,
              qualityEvidence.allSatisfy({ evidence in
                  validUnitIDs.contains(evidence.sourceUnitID)
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
        for part in ordered {
            guard part.selectedAttempt == "initial" || part.selectedAttempt == "retry" else {
                throw WorkflowError.processFailed("Selected timing manifest содержит неизвестную выбранную попытку.")
            }
            guard part.absoluteRange.startSeconds == part.absoluteOffsetSeconds,
                  part.absoluteRange.endSeconds >= part.absoluteRange.startSeconds,
                  let selectedRange = part.selectedTimingAbsoluteRange,
                  selectedRange.startSeconds >= 0,
                  selectedRange.endSeconds > selectedRange.startSeconds else {
                throw WorkflowError.processFailed("Selected timing manifest содержит недопустимый absolute range.")
            }
            // `absolute_range` describes prepared media, not selected Whisper
            // evidence. Canonical SeminarText may publish adjacent prepared
            // chunks with a small overlap; selected_timing_absolute_range and
            // the selected JSON remain the timing authority below.
            _ = try verify(part.artifacts.txt, in: packageRoot, expectedPart: part.id, fileExtension: "txt")
            _ = try verify(part.artifacts.srt, in: packageRoot, expectedPart: part.id, fileExtension: "srt")
            let jsonURL = try verify(part.artifacts.jsonFull, in: packageRoot, expectedPart: part.id, fileExtension: "json")
            let json = try JSONDecoder().decode(SelectedWhisperJSON.self, from: Data(contentsOf: jsonURL))
            for segment in json.transcription {
                let spokenTokens = segment.tokens.filter { !isSelectedWhisperControlToken($0.text) }
                guard let firstToken = spokenTokens.first else { continue }
                guard segment.offsets.from >= 0,
                      segment.offsets.to >= segment.offsets.from else {
                    throw WorkflowError.processFailed("Selected timing JSON содержит недопустимый segment interval.")
                }
                let collapsedTokenEnvelope = spokenTokens.allSatisfy {
                    $0.offsets.from == firstToken.offsets.from && $0.offsets.to == firstToken.offsets.from
                }
                let segmentEnvelope: (start: TimeInterval, end: TimeInterval)?
                if collapsedTokenEnvelope {
                    let start = part.absoluteOffsetSeconds + Double(segment.offsets.from) / 1000
                    let end = part.absoluteOffsetSeconds + Double(segment.offsets.to) / 1000
                    guard end > start,
                          start >= selectedRange.startSeconds - 0.000_001,
                          end <= selectedRange.endSeconds + 0.000_001 else {
                        throw WorkflowError.processFailed("Selected timing JSON содержит collapsed token timing без валидного native segment interval.")
                    }
                    segmentEnvelope = (start, end)
                } else {
                    segmentEnvelope = nil
                }
                for token in spokenTokens {
                    guard token.offsets.from >= 0,
                          token.offsets.to >= 0 else {
                        throw WorkflowError.processFailed("Selected timing JSON содержит недопустимый token boundary.")
                    }
                    // The canonical contract publishes token offsets in the
                    // selected JSON timebase. Shift them only by the chunk's
                    // absolute offset: do not clip, compress or infer timing
                    // from SRT/segment boundaries downstream.
                    let start = part.absoluteOffsetSeconds + Double(token.offsets.from) / 1000
                    let end = part.absoluteOffsetSeconds + Double(token.offsets.to) / 1000
                    guard start >= selectedRange.startSeconds - 0.000_001,
                          start <= selectedRange.endSeconds + 0.000_001,
                          end >= selectedRange.startSeconds - 0.000_001,
                          end <= selectedRange.endSeconds + 0.000_001 else {
                        throw WorkflowError.processFailed("Selected timing JSON выходит за published selected timing envelope.")
                    }
                    // Preserve each selected Whisper boundary and token order.
                    // Source units use an ordered range derived from a reverse
                    // token's own boundaries. Only fully collapsed token timing
                    // needs the native segment envelope. Neither changes raw
                    // tokenTimeline values or order.
                    atoms.append(SelectedTimingAtom(
                        text: token.text,
                        start: start,
                        end: end,
                        sourceUnitEnvelopeStart: segmentEnvelope?.start ?? min(start, end),
                        sourceUnitEnvelopeEnd: segmentEnvelope?.end ?? max(start, end),
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
                start: current.map(\.sourceUnitEnvelopeStart).min()!,
                // JSON-full is native Whisper evidence and may include decoder
                // padding past a media/chunk end. The manifest's signed range is
                // the truthful upper bound for this source-unit envelope; this
                // does not alter text or manufacture word-level alignment.
                end: min(current.map(\.sourceUnitEnvelopeEnd).max()!, current.last!.maximumEnd),
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
            let matching = atoms.filter { $0.sourceUnitEnvelopeStart < unit.end && $0.sourceUnitEnvelopeEnd > unit.start }
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

    private static func endsSentence(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars.last.map { ".?!…".unicodeScalars.contains($0) } ?? false
    }
}

protocol SimpleTextTranslationProvider {
    func identity() async throws -> TranslationModelIdentity
    func translate(text: String, source: ArtifactLanguage, target: ArtifactLanguage) async throws -> String
    func requestSHA256(text: String, source: ArtifactLanguage, target: ArtifactLanguage) -> String
}

extension SimpleTextTranslationProvider {
    func requestSHA256(text: String, source: ArtifactLanguage, target: ArtifactLanguage) -> String {
        SelectedTimingHash.string("\(source.rawValue)|\(target.rawValue)|\(text)")
    }
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
        let prompt = Self.prompt(text: text, source: source, target: target)
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
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !content.contains("```") else {
            throw WorkflowError.processFailed("TranslateGemma вернула неполный text-only перевод.")
        }
        return content
    }

    func requestSHA256(text: String, source: ArtifactLanguage, target: ArtifactLanguage) -> String {
        SelectedTimingHash.string(Self.prompt(text: text, source: source, target: target))
    }

    private static func prompt(text: String, source: ArtifactLanguage, target: ArtifactLanguage) -> String {
        let sourceName = source == .en ? "English" : "Russian"
        let targetName = target == .en ? "English" : "Russian"
        return """
        Translate the following \(sourceName) spoken-text passage into \(targetName).
        Return only the translated passage. Preserve meaning, negation, numbers, names, terminology and natural repetitions. Do not add context or complete unstated meaning.
        The output must be in \(targetName). Do not return \(sourceName) text.

        \(text)
        """
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

private struct SelectedTimingTranslationValidationFailure: Error {
    let message: String
    let latinLetterCount: Int
    let cyrillicLetterCount: Int

    init(message: String, text: String) {
        let counts = SelectedTimingTranslationValidationFailure.letterCounts(text)
        self.init(message: message, latinLetterCount: counts.latin, cyrillicLetterCount: counts.cyrillic)
    }

    init(message: String, latinLetterCount: Int, cyrillicLetterCount: Int) {
        self.message = message
        self.latinLetterCount = latinLetterCount
        self.cyrillicLetterCount = cyrillicLetterCount
    }

    private static func letterCounts(_ text: String) -> (latin: Int, cyrillic: Int) {
        text.unicodeScalars.reduce(into: (latin: 0, cyrillic: 0)) { counts, scalar in
            switch scalar.value {
            case 0x0041...0x005A, 0x0061...0x007A:
                counts.latin += 1
            case 0x0400...0x052F:
                counts.cyrillic += 1
            default:
                break
            }
        }
    }
}

struct SelectedTimingRejectedResponseEvidence: Codable, Equatable {
    let unitID: Int
    let sourceLanguage: ArtifactLanguage
    let targetLanguage: ArtifactLanguage
    let sourceTextSHA256: String
    let requestSHA256: String
    let model: String
    let modelDigest: String?
    let protocolVersion: String
    let attempt: Int
    let rawResponse: String
    let latinLetterCount: Int
    let cyrillicLetterCount: Int
    let validationFailureReason: String
    let createdAt: Date
}

struct SelectedTimingRejectedResponseEvidenceDocument: Codable {
    let schemaVersion: Int
    var responses: [SelectedTimingRejectedResponseEvidence]
}

private final class SelectedTimingRejectedResponseStore {
    private let url: URL?

    init(url: URL?) {
        self.url = url
    }

    func beginRun() throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func append(_ response: SelectedTimingRejectedResponseEvidence) throws {
        guard let url else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var document = (try? decoder.decode(
            SelectedTimingRejectedResponseEvidenceDocument.self,
            from: Data(contentsOf: url)
        )) ?? SelectedTimingRejectedResponseEvidenceDocument(schemaVersion: 1, responses: [])
        document.responses.append(response)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: url, options: .atomic)
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
    var sourceUnitEnvelopeStart: TimeInterval
    var sourceUnitEnvelopeEnd: TimeInterval
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
