import CryptoKit
import Darwin
import Foundation

struct FFmpegCutRuntimeIdentity {
    let executableURL: URL
    let executableSHA256: String
    let fingerprint: String
}

enum FragmentCutSourceSnapshot {
    static func create(mediaURL: URL, workspaceURL: URL) -> URL? {
        let sourceURL = mediaURL.resolvingSymlinksInPath().standardizedFileURL
        let snapshotURL = workspaceURL.appendingPathComponent("cut-topic-source.snapshot")
        let result = sourceURL.path.withCString { sourcePath in
            snapshotURL.path.withCString { snapshotPath in
                clonefile(sourcePath, snapshotPath, 0)
            }
        }
        return result == 0 ? snapshotURL : nil
    }
}

struct TopicCutRenderProvenance {
    let approvedRevisionID: String
    let approvedRevisionContentHash: String
    let approvedSnapshotURL: URL
    let language: ArtifactLanguage
    let granularity: TopicGranularity
    let topicID: String
}

struct FragmentCutRenderReuseIdentity {
    private struct Input: Encodable {
        // Bump this contract if FFmpegAdapter.cutAccurate changes its arguments or output policy.
        let contract = "videotext-cut-topic-render-v1"
        let sourceVideoSHA256: String
        let approvedRevisionID: String
        let approvedRevisionContentHash: String
        let approvedSnapshotSHA256: String
        let language: String
        let granularity: String
        let topicID: String
        let startBitPattern: String
        let endBitPattern: String
        let ffmpegExecutablePath: String
        let ffmpegExecutableSHA256: String
        let ffmpegRuntimeFingerprint: String
        let appVersion: String
        let appBuild: String
    }

    let key: String
    let sourceVideoSHA256: String
    let ffmpegExecutablePath: String
    let ffmpegExecutableSHA256: String
    let ffmpegRuntimeFingerprint: String

    static func make(
        mediaURL: URL,
        start: TimeInterval,
        end: TimeInterval,
        provenance: TopicCutRenderProvenance,
        ffmpegRuntime: FFmpegCutRuntimeIdentity,
        appVersion: String = BuildInfo.version,
        appBuild: String = BuildInfo.build
    ) -> FragmentCutRenderReuseIdentity? {
        guard start.isFinite, end.isFinite, end > start,
              let sourceHash = sha256(of: mediaURL),
              let approvedSnapshotData = try? Data(contentsOf: provenance.approvedSnapshotURL),
              StableTopicHash.string(String(decoding: approvedSnapshotData, as: UTF8.self)) == provenance.approvedRevisionContentHash,
              ffmpegRuntime.executableURL.isFileURL,
              !ffmpegRuntime.executableSHA256.isEmpty,
              !ffmpegRuntime.fingerprint.isEmpty else {
            return nil
        }
        let approvedSnapshotHash = SHA256.hash(data: approvedSnapshotData)
            .map { String(format: "%02x", $0) }.joined()

        let ffmpegPath = ffmpegRuntime.executableURL.standardizedFileURL.path
        let input = Input(
            sourceVideoSHA256: sourceHash,
            approvedRevisionID: provenance.approvedRevisionID,
            approvedRevisionContentHash: provenance.approvedRevisionContentHash,
            approvedSnapshotSHA256: approvedSnapshotHash,
            language: provenance.language.rawValue,
            granularity: provenance.granularity.rawValue,
            topicID: provenance.topicID,
            startBitPattern: String(start.bitPattern, radix: 16),
            endBitPattern: String(end.bitPattern, radix: 16),
            ffmpegExecutablePath: ffmpegPath,
            ffmpegExecutableSHA256: ffmpegRuntime.executableSHA256,
            ffmpegRuntimeFingerprint: ffmpegRuntime.fingerprint,
            appVersion: appVersion,
            appBuild: appBuild
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(input) else { return nil }
        let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        return FragmentCutRenderReuseIdentity(
            key: "cut-topic-v1:\(digest)",
            sourceVideoSHA256: sourceHash,
            ffmpegExecutablePath: ffmpegPath,
            ffmpegExecutableSHA256: ffmpegRuntime.executableSHA256,
            ffmpegRuntimeFingerprint: ffmpegRuntime.fingerprint
        )
    }

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 1_048_576)
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct FragmentCutRenderReuseService {
    struct Outcome {
        let reused: Bool
        let validationReport: String
    }

    func renderOrReuse(
        records: [FragmentRecord],
        projectURL: URL,
        key: String,
        start: TimeInterval,
        end: TimeInterval,
        topicID: String,
        granularity: TopicGranularity,
        outputURL: URL,
        validate: (URL) async throws -> String,
        render: () async throws -> Void
    ) async throws -> Outcome {
        let layout = ProjectLayout(root: projectURL)
        for record in records.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard record.cutVideoReuseKey == key,
                  let expectedVideoSHA256 = record.cutVideoSHA256,
                  record.start.bitPattern == start.bitPattern,
                  record.end.bitPattern == end.bitPattern,
                  record.topicID == topicID,
                  record.topicGranularity == granularity else {
                continue
            }

            let sourceURL = URL(fileURLWithPath: record.videoPath).standardizedFileURL
            let expectedURL = layout.fragmentVideoURL(kind: record.id).standardizedFileURL
            let fragmentsRoot = layout.videoFragmentsDirectory.standardizedFileURL.path + "/"
            guard sourceURL == expectedURL,
                  sourceURL.path.hasPrefix(fragmentsRoot),
                  isRegularFile(sourceURL),
                  FragmentCutRenderReuseIdentity.sha256(of: sourceURL) == expectedVideoSHA256 else {
                continue
            }

            do {
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: sourceURL, to: outputURL)
                guard FragmentCutRenderReuseIdentity.sha256(of: outputURL) == expectedVideoSHA256 else {
                    try? FileManager.default.removeItem(at: outputURL)
                    continue
                }
                let report = try await validate(outputURL)
                return Outcome(reused: true, validationReport: report)
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        try await render()
        return Outcome(reused: false, validationReport: try await validate(outputURL))
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }
}
