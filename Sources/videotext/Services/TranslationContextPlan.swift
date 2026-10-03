import Foundation
import CryptoKit

struct TranslationContextCue: Codable, Equatable {
    var id: Int
    var text: String
}

struct TranslationCueContext: Codable, Equatable {
    var document: String
    var before: [TranslationContextCue]
    var after: [TranslationContextCue]
}

struct TranslationExecutionUnit {
    var index: Int
    var owned: [TranslationRequestCue]
}

struct TranslationContextPlan {
    static let contract = "booktext-owned-cue-context-v1-docmeta512-lineage2-overlap2x600"
    let contextIdentity: String
    let units: [TranslationExecutionUnit]

    static func documentTitle(for media: URL) -> String {
        let parent = media.deletingLastPathComponent()
        return [parent.deletingLastPathComponent().lastPathComponent, parent.lastPathComponent, media.lastPathComponent]
            .filter { !$0.isEmpty }.joined(separator: " / ")
    }

    init(cues: [SubtitleCue], documentTitle: String?, chunkSize: Int) throws {
        guard !cues.isEmpty, Set(cues.map(\.id)).count == cues.count else {
            throw WorkflowError.processFailed("Перевод требует непустой источник с уникальными cueId.")
        }
        let title = String((documentTitle ?? "").prefix(160))
        // Match BookText's source-metadata context: output units belong only
        // to ownership/overlap, never to a repeated document-wide text block.
        let document = """
        Document type: timecoded spoken audio/video transcript. Short utterances may belong to different speakers.
        Document title (source metadata only): \(title)
        Logical source units: original subtitle cues. Execution chunks are checkpoints, not semantic boundaries.
        """
        let requests = cues.indices.map { index in
            TranslationRequestCue(id: cues[index].id, text: cues[index].text, context: TranslationCueContext(
                document: document,
                before: Self.neighbors(cues: cues, index: index, direction: -1),
                after: Self.neighbors(cues: cues, index: index, direction: 1)
            ))
        }
        contextIdentity = try TranslationFingerprint.value(PlanIdentity(contract: Self.contract, cues: cues, requests: requests))
        let size = max(1, chunkSize)
        units = stride(from: 0, to: cues.count, by: size).enumerated().map { index, offset in
            TranslationExecutionUnit(index: index, owned: Array(requests[offset..<min(offset + size, requests.count)]))
        }
    }

    private struct PlanIdentity: Encodable {
        var contract: String
        var cues: [SubtitleCue]
        var requests: [TranslationRequestCue]
    }

    private static func neighbors(cues: [SubtitleCue], index: Int, direction: Int) -> [TranslationContextCue] {
        var result: [TranslationContextCue] = []
        var used = 0
        for distance in 1...2 {
            let neighbor = index + distance * direction
            guard cues.indices.contains(neighbor) else { break }
            let text = cues[neighbor].text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Do not join distant dialogue across an omitted, oversized cue.
            guard used + text.count + 1 <= 600 else { break }
            result.append(TranslationContextCue(id: cues[neighbor].id, text: text))
            used += text.count + 1
        }
        return direction < 0 ? result.reversed() : result
    }
}

enum TranslationFingerprint {
    static func value<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return data(try encoder.encode(value))
    }

    static func data(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }
}

struct TranslationCheckpointEntry: Codable, Equatable {
    var cueID: Int
    var text: String
}

struct TranslationCheckpointStore {
    let directory: URL?
    let runIdentity: String

    init(directory: URL?, plan: TranslationContextPlan, identity: TranslationModelIdentity,
         source: ArtifactLanguage, target: ArtifactLanguage, sourceIdentity: String?) throws {
        // Unknown digests cannot authorize persistent reuse across model changes.
        self.directory = identity.digest?.isEmpty == false ? directory : nil
        runIdentity = try TranslationFingerprint.value(RunIdentity(
            contextIdentity: plan.contextIdentity, identity: identity, source: source,
            target: target, sourceIdentity: sourceIdentity, units: plan.units.map { $0.owned.map(\.id) }
        ))
    }

    func load(_ unit: TranslationExecutionUnit) -> [TranslationCheckpointEntry] {
        guard let url = url(unit), let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.schemaVersion == 1, record.runIdentity == runIdentity,
              record.ownedIDs == unit.owned.map(\.id),
              record.entries.count <= unit.owned.count,
              record.entries.map(\.cueID) == Array(record.ownedIDs.prefix(record.entries.count)),
              record.entriesHash == (try? TranslationFingerprint.value(record.entries)) else { return [] }
        return record.entries
    }

    func save(_ entries: [TranslationCheckpointEntry], unit: TranslationExecutionUnit) throws {
        guard let url = url(unit) else { return }
        let ownedIDs = unit.owned.map(\.id)
        guard entries.map(\.cueID) == Array(ownedIDs.prefix(entries.count)), entries.count <= ownedIDs.count else {
            throw WorkflowError.processFailed("Checkpoint перевода нарушает ownership cueId.")
        }
        let record = Record(schemaVersion: 1, runIdentity: runIdentity, ownedIDs: ownedIDs,
                            entries: entries, entriesHash: try TranslationFingerprint.value(entries))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    private func url(_ unit: TranslationExecutionUnit) -> URL? {
        directory?.appendingPathComponent(runIdentity, isDirectory: true).appendingPathComponent("unit-\(unit.index).json")
    }

    private struct RunIdentity: Encodable {
        var contextIdentity: String
        var identity: TranslationModelIdentity
        var source: ArtifactLanguage
        var target: ArtifactLanguage
        var sourceIdentity: String?
        var units: [[Int]]
    }

    private struct Record: Codable {
        var schemaVersion: Int
        var runIdentity: String
        var ownedIDs: [Int]
        var entries: [TranslationCheckpointEntry]
        var entriesHash: String
    }
}

enum TranslationResumeValidator {
    static func outputsMatch(report: TranslationReport, manifest: ProjectManifest, layout: ProjectLayout) -> Bool {
        let language = report.targetLanguage
        guard report.schemaVersion == 3,
              let subtitles = try? Data(contentsOf: layout.subtitlesURL(language: language)),
              let transcript = try? Data(contentsOf: layout.transcriptURL(language: language)) else { return false }
        if let active = manifest.activeTranscriptRevision(for: language), active.origin == .userEdited {
            var cursor: TranscriptRevision? = active
            var visited: Set<String> = []
            while let revision = cursor, visited.insert(revision.id).inserted {
                if revision.id == report.targetRevisionID {
                    // Human review historically assigned the subtitle hash to
                    // both artifacts. Verify the immutable revision bytes instead.
                    return (try? Data(contentsOf: layout.subtitleRevisionURL(id: active.id, language: language))) == subtitles
                        && (try? Data(contentsOf: layout.transcriptRevisionURL(id: active.id, language: language))) == transcript
                }
                cursor = manifest.transcriptRevisions?.first { $0.id == revision.parentRevisionID }
            }
            return false
        }
        return report.subtitleSHA256 == TranslationFingerprint.data(subtitles)
            && report.transcriptSHA256 == TranslationFingerprint.data(transcript)
    }
}
