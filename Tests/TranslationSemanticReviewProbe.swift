import Foundation

private struct ReviewFixture: Codable {
    var cues: [SubtitleCue]
    var documentTitle: String? = nil
    var sourceLanguage: ArtifactLanguage? = nil
    var targetLanguage: ArtifactLanguage? = nil
    var semanticExpectations: [String: SemanticExpectation]? = nil
}

private struct SemanticExpectation: Codable {
    var requiredAny: [[String]]? = nil
    var forbidden: [String]? = nil
}

private struct ReviewProbeReport: Codable {
    var model: String
    var digest: String?
    var protocolVersion: String
    var cues: [SubtitleCue]
    var structuralIssueCount: Int
    var failedChecks: [String]
    var contextIdentity: String?
}

@main
struct TranslationSemanticReviewProbe {
    static func main() async {
        do {
            try validateFailureClassChecks()
            if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--check-alarms" {
                print("TRANSLATION_FAILURE_CLASS_CONTROLS_PASS: fixture alarms only; no model execution")
                return
            }
            guard CommandLine.arguments.count == 3 else {
                throw WorkflowError.processFailed("Usage: semantic-probe <review-fixture.json> <output.json>")
            }
            let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
            let fixture = try JSONDecoder().decode(ReviewFixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let source = fixture.sourceLanguage ?? .ru
            let target = fixture.targetLanguage ?? .en
            let wireDirectory = outputURL.deletingLastPathComponent().appendingPathComponent("wire-\(source.rawValue)-to-\(target.rawValue)")
            if FileManager.default.fileExists(atPath: wireDirectory.path) {
                try FileManager.default.removeItem(at: wireDirectory)
            }
            let wire = ReviewWire(directory: wireDirectory)
            let provider = OllamaTranslationProvider(transport: { try await wire.send($0) })
            let result = try await TranslationAdapter(provider: provider).translate(cues: fixture.cues, source: source, target: target, documentTitle: fixture.documentTitle, onProgress: { _ in }, onLog: { print($0) })
            var failures: [String] = []
            if !result.issues.isEmpty { failures.append("structural-validator-issues") }
            if !zip(fixture.cues, result.cues).allSatisfy({ $0.id == $1.id && $0.start == $1.start && $0.end == $1.end }) || fixture.cues.count != result.cues.count {
                failures.append("cue-alignment-changed")
            }
            let output = Dictionary(uniqueKeysWithValues: result.cues.map { ($0.id, $0.text) })
            if source == .ru && target == .en {
                failures.append(contentsOf: failureClassChecks(output))
            }
            failures.append(contentsOf: expectationChecks(output, expectations: fixture.semanticExpectations ?? [:]))
            let report = ReviewProbeReport(model: result.model, digest: result.modelDigest, protocolVersion: result.protocolVersion, cues: result.cues, structuralIssueCount: result.issues.count, failedChecks: failures, contextIdentity: result.contextIdentity)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: outputURL, options: .atomic)
            for cue in result.cues { print("\(cue.id): \(cue.text)") }
            guard failures.isEmpty else {
                throw WorkflowError.processFailed("Semantic regression failed: \(failures.joined(separator: ", "))")
            }
            print("TRANSLATION_SEMANTIC_REVIEW_PROBE_PASS: automated failure-class checks only; human review still required")
        } catch {
            fputs("TRANSLATION_SEMANTIC_REVIEW_PROBE_FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func failureClassChecks(_ output: [Int: String]) -> [String] {
            let texts = output.mapValues { $0.lowercased() }
            var failures: [String] = []
            let disconnection = texts[21] ?? ""
            if !["disconnect", "connection", "kicked out", "logged out", "dropping out"].contains(where: disconnection.contains) || ["stomach", "medical", "unwell", "sick"].contains(where: disconnection.contains) {
                failures.append("21-conferencing-meaning-not-preserved")
            }
            let frequency = texts[22] ?? ""
            if !frequency.contains("minute") || ["terrifying", "terror", "frightening", "scary"].contains(where: frequency.contains) {
                failures.append("22-frequency-or-evaluation-changed")
            }
            let referent = texts[24] ?? ""
            if !["student", "learner"].contains(where: referent.contains)
                || !["distance", "part-time", "part time", "correspondence", "external", "remote"].contains(where: referent.contains) {
                failures.append("24-student-referent-missing")
            }
            let fragment = texts[17] ?? ""
            if !fragment.contains("yuri") || !["here", "present"].contains(where: fragment.contains) {
                failures.append("17-accepted-presence-meaning-missing")
            }
            if ["here", "ready"].contains(where: (texts[13] ?? "").contains) {
                failures.append("13-neighbor-content-leaked")
            }
            if ["student", "learner"].contains(where: (texts[23] ?? "").contains) {
                failures.append("23-neighbor-content-leaked")
            }
            return failures
    }

    private static func expectationChecks(
        _ output: [Int: String],
        expectations: [String: SemanticExpectation]
    ) -> [String] {
        var failures: [String] = []
        for (key, expectation) in expectations.sorted(by: { $0.key < $1.key }) {
            guard let id = Int(key), let text = output[id]?.lowercased() else {
                failures.append("\(key)-expected-output-missing")
                continue
            }
            for alternatives in expectation.requiredAny ?? [] where !alternatives.contains(where: { text.contains($0.lowercased()) }) {
                failures.append("\(key)-required-semantic-marker-missing")
            }
            if (expectation.forbidden ?? []).contains(where: { text.contains($0.lowercased()) }) {
                failures.append("\(key)-foreign-semantic-marker-present")
            }
        }
        return failures
    }

    private static func validateFailureClassChecks() throws {
        let good: [Int: String] = [13: "Tatyana.", 17: "Yuri, and I'm still here.", 21: "I keep getting disconnected today.", 22: "Literally every minute, it's awful.", 23: "Okay, I'm ready.", 24: "Now it's the distance learners, right?"]
        guard failureClassChecks(good).isEmpty else {
            throw WorkflowError.processFailed("Regression alarm rejected its approved semantic control")
        }
        let bad: [Int: String] = [13: "Tatyana. I'm here. Ready.", 17: "Yuri, and I...", 21: "I have stomach issues today.", 22: "It's terrifying every minute.", 23: "Now we have students.", 24: "Now, definitely, are they?"]
        guard failureClassChecks(bad).count == 6 else {
            throw WorkflowError.processFailed("Regression alarm failed to reject known semantic defects")
        }
        var lostQualifier = good
        lostQualifier[24] = "Now it's the students, right?"
        guard failureClassChecks(lostQualifier) == ["24-student-referent-missing"] else {
            throw WorkflowError.processFailed("Regression alarm accepted a lost student-group qualifier")
        }
        try validateOwnershipExpectationControls()
    }

    private static func validateOwnershipExpectationControls() throws {
        let expectations: [String: SemanticExpectation] = [
            "3": SemanticExpectation(requiredAny: [["blue"], ["energy"]], forbidden: ["warm", "retina"]),
            "4": SemanticExpectation(requiredAny: [["warm"], ["red"]], forbidden: ["retina", "energy spike"]),
            "5": SemanticExpectation(requiredAny: [["retina"], ["mice"]], forbidden: ["membrane"]),
            "6": SemanticExpectation(requiredAny: [["membrane"]], forbidden: ["retina", "commercial"])
        ]
        let good = [
            3: "blue energy spike", 4: "warm light without red", 5: "retina in mice", 6: "membrane potential"
        ]
        try require(expectationChecks(good, expectations: expectations).isEmpty,
                    "Ownership controls rejected the valid cue mapping")

        let migration = [
            3: "warm light without red", 4: "retina in mice", 5: "membrane potential", 6: "blue energy spike"
        ]
        try require(!expectationChecks(migration, expectations: expectations).isEmpty,
                    "Ownership controls accepted cross-cue semantic migration")

        var loss = good
        loss[5] = ""
        try require(expectationChecks(loss, expectations: expectations).contains("5-required-semantic-marker-missing"),
                    "Ownership controls accepted a lost proposition")

        var duplicate = good
        duplicate[6] = "membrane potential and retina in mice"
        try require(expectationChecks(duplicate, expectations: expectations).contains("6-foreign-semantic-marker-present"),
                    "Ownership controls accepted a duplicated neighboring proposition")

        var contextLeak = good
        contextLeak[4] = "warm light without red and retina in mice"
        try require(expectationChecks(contextLeak, expectations: expectations).contains("4-foreign-semantic-marker-present"),
                    "Ownership controls accepted context-only leakage")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw WorkflowError.processFailed(message) }
    }
}

private actor ReviewWire {
    private let directory: URL
    private var sequence = 0

    init(directory: URL) {
        self.directory = directory
    }

    func send(_ request: URLRequest) async throws -> Data {
        sequence += 1
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefix = directory.appendingPathComponent(String(format: "%03d", sequence))
        if let body = request.httpBody {
            try body.write(to: prefix.appendingPathExtension("request.json"), options: .atomic)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try data.write(to: prefix.appendingPathExtension("response.json"), options: .atomic)
        let metadata: [String: Any] = [
            "url": request.url?.absoluteString ?? "",
            "method": request.httpMethod ?? "GET",
            "status": (response as? HTTPURLResponse)?.statusCode ?? 0
        ]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: prefix.appendingPathExtension("metadata.json"), options: .atomic)
        return data
    }
}
