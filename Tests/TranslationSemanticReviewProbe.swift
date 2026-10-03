import Foundation

private struct ReviewFixture: Codable {
    var cues: [SubtitleCue]
    var documentTitle: String? = nil
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
            let fixture = try JSONDecoder().decode(ReviewFixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let result = try await TranslationAdapter().translate(cues: fixture.cues, source: .ru, target: .en, documentTitle: fixture.documentTitle, onProgress: { _ in }, onLog: { print($0) })
            var failures: [String] = []
            if !result.issues.isEmpty { failures.append("structural-validator-issues") }
            if !zip(fixture.cues, result.cues).allSatisfy({ $0.id == $1.id && $0.start == $1.start && $0.end == $1.end }) || fixture.cues.count != result.cues.count {
                failures.append("cue-alignment-changed")
            }
            failures.append(contentsOf: failureClassChecks(Dictionary(uniqueKeysWithValues: result.cues.map { ($0.id, $0.text) })))
            let report = ReviewProbeReport(model: result.model, digest: result.modelDigest, protocolVersion: result.protocolVersion, cues: result.cues, structuralIssueCount: result.issues.count, failedChecks: failures, contextIdentity: result.contextIdentity)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
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
            if !["student", "learner"].contains(where: referent.contains) || !["distance", "part-time", "part time", "correspondence"].contains(where: referent.contains) {
                failures.append("24-student-referent-missing")
            }
            let fragment = texts[17] ?? ""
            if ["here", "ready", "waiting", "present"].contains(where: fragment.contains) {
                failures.append("17-unsupported-completion")
            }
            if ["here", "ready"].contains(where: (texts[13] ?? "").contains) {
                failures.append("13-neighbor-content-leaked")
            }
            if ["student", "learner"].contains(where: (texts[23] ?? "").contains) {
                failures.append("23-neighbor-content-leaked")
            }
            return failures
    }

    private static func validateFailureClassChecks() throws {
        let good: [Int: String] = [13: "Tatyana.", 17: "Yuri, and I...", 21: "I keep getting disconnected today.", 22: "Literally every minute, it's awful.", 23: "Okay, I'm ready.", 24: "Now it's the distance learners, right?"]
        guard failureClassChecks(good).isEmpty else {
            throw WorkflowError.processFailed("Regression alarm rejected its approved semantic control")
        }
        let bad: [Int: String] = [13: "Tatyana. I'm here. Ready.", 17: "Yuri, and I'm still here.", 21: "I have stomach issues today.", 22: "It's terrifying every minute.", 23: "Now we have students.", 24: "Now, definitely, are they?"]
        guard failureClassChecks(bad).count == 6 else {
            throw WorkflowError.processFailed("Regression alarm failed to reject known semantic defects")
        }
        var lostQualifier = good
        lostQualifier[24] = "Now it's the students, right?"
        guard failureClassChecks(lostQualifier) == ["24-student-referent-missing"] else {
            throw WorkflowError.processFailed("Regression alarm accepted a lost student-group qualifier")
        }
    }
}
