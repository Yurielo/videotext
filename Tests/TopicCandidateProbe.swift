import Foundation

private struct CandidateEmbeddingCache: Decodable {
    var values: [String: [Double]]
}

@main
struct TopicCandidateProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fputs("Использование: TopicCandidateProbe <full.srt> <embeddings.json>\n", stderr)
            exit(2)
        }
        let srtURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let cacheURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let cues = try SRTService().load(from: srtURL)
        let paragraphs = TopicTextPreprocessor().prepare(cues)
        let cache = try JSONDecoder().decode(CandidateEmbeddingCache.self, from: Data(contentsOf: cacheURL))
        let vectors = try paragraphs.map { paragraph -> [Double] in
            let key = StableTopicHash.string(paragraph.text)
            guard let vector = cache.values[key] else {
                throw WorkflowError.invalidTopics("в кэше отсутствует embedding абзаца \(key).")
            }
            return vector
        }
        let candidates = TopicBoundaryDetector().candidates(
            paragraphs: paragraphs,
            embeddings: vectors,
            granularity: .normal
        )
        let times = Dictionary(uniqueKeysWithValues: paragraphs.compactMap { paragraph in
            paragraph.cueIDs.last.map { ($0, paragraph.end) }
        })
        let orderedTimes = candidates.compactMap { times[$0.afterCueId] }.sorted()
        let gaps = zip(orderedTimes, orderedTimes.dropFirst()).map { $1 - $0 }
        print("CANDIDATE PROBE: paragraphs=\(paragraphs.count), candidates=\(candidates.count)")
        if !gaps.isEmpty {
            print(String(format: "CANDIDATE GAPS: min=%.0fs, avg=%.0fs, max=%.0fs", gaps.min()!, gaps.reduce(0, +) / Double(gaps.count), gaps.max()!))
        }
    }
}
