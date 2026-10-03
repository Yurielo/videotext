import Foundation
import Darwin

private let pinnedDigest = "c49d986b0764f5881c476eb21435bb62b7abc62347aab3d4a6071e811be510a1"
private let networkTimeout: TimeInterval = 180

private struct TraceFixture: Codable {
    var cues: [SubtitleCue]
    var documentTitle: String?
}

private struct TraceRow: Codable, Equatable {
    var cueId: Int
    var text: String
}

private struct TraceUnit: Codable {
    var index: Int
    var owned: [TranslationRequestCue]
}

private struct TracePlan: Codable {
    var contextIdentity: String
    var units: [TraceUnit]
}

private struct TraceContext: Codable {
    var cueID: Int
    var context: TranslationCueContext?
}

private struct TraceIssue: Codable {
    var cueID: Int
    var reasonCodes: [String]
    var candidateText: String?
}

private struct TraceComparison: Codable {
    var cueID: Int
    var rawRowCount: Int
    var rawText: String?
    var finalText: String
    var rawTrimEqualsFinal: Bool?
}

private struct TraceWireCall: Codable {
    var index: Int
    var path: String
    var method: String
    var url: String
    var originalHeaders: [String: String]
    var sentHeaders: [String: String]
    var originalTimeout: Double
    var sentTimeout: Double
    var originalBodyFile: String
    var sentBodyFile: String
    var originalBodySHA256: String
    var sentBodySHA256: String
    var overrideApplied: Bool
    var responseFile: String?
    var httpStatus: Int?
    var responseHeaders: [String: String]?
    var responseSHA256: String?
    var rawRows: [TraceRow]?
    var rawParseError: String?
    var transportError: String?
}

private struct TraceReport: Codable {
    var schemaVersion = 1
    var probeVersion = "pr9-causal-trace-v1"
    var semanticVerdict = "NOT_EVALUATED"
    var mode: String
    var requestOverrideApplied: Bool
    var productionContractClaim: Bool
    var configuration = "DIAGNOSTIC: batchSize=32, maximumAttempts=1, checkpoint reuse disabled; at most one chat request"
    var wireScope = "Exact URLRequest.httpBody bytes plus request metadata; URLSession framing/automatic headers are not captured"
    var maximumNetworkTimeoutSeconds = networkTimeout
    var fixtureSHA256: String
    var documentTitle: String?
    var requestedModel = OllamaTranslationProvider.model
    var expectedDigest = pinnedDigest
    var verifiedDigest: String?
    var protocolVersion = OllamaTranslationProvider.protocolVersion
    var sourceHead: String?
    var buildInputManifest: String?
    var contextIdentity: String
    var calls: [TraceWireCall]
    var adapterOutcome: String
    var finalCues: [SubtitleCue]?
    var issues: [TraceIssue]
    var countAligned: Bool?
    var idOrderAligned: Bool?
    var timestampsAligned: Bool?
    var rawFinalComparisons: [TraceComparison]
    var error: String?
    var cancelled: Bool
    var diagnosticChecksPassed: Bool
}

private struct TraceFailure: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

private struct TraceHTTPReply {
    var data: Data
    var status: Int
    var headers: [String: String] = [:]
}

private typealias ScriptedHTTP = (URLRequest) async throws -> TraceHTTPReply

private func saveJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    try encoder.encode(value).write(to: url, options: .atomic)
}

private func require(_ value: Bool, _ message: String) throws {
    if !value { throw TraceFailure(message: message) }
}

private actor TraceTransport {
    let directory: URL
    let requestOverride: Data?
    let scripted: ScriptedHTTP?
    let session: URLSession?
    private(set) var calls: [TraceWireCall] = []
    private(set) var verifiedDigest: String?
    private var chatCount = 0

    init(directory: URL, requestOverride: Data?, scripted: ScriptedHTTP?) {
        self.directory = directory
        self.requestOverride = requestOverride
        self.scripted = scripted
        if scripted == nil {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = networkTimeout
            configuration.timeoutIntervalForResource = networkTimeout
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            session = URLSession(configuration: configuration)
        } else { session = nil }
    }

    func send(_ original: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let path = original.url?.path ?? ""
        let isChat = path == "/api/chat" && original.httpMethod == "POST"
        try require(original.url?.host == "127.0.0.1" && original.url?.port == 11434, "Only the production local Ollama endpoint is allowed")
        try require(isChat || (path == "/api/tags" && original.httpMethod != "POST"), "Unexpected production endpoint")
        var sent = original
        sent.timeoutInterval = min(original.timeoutInterval, networkTimeout)
        if isChat, let requestOverride { sent.httpBody = requestOverride }
        let index = calls.count
        let stem = String(format: "%03d", index)
        let originalFile = "\(stem)-request-original.body.bin"
        let sentFile = "\(stem)-request-sent.body.bin"
        let originalBody = original.httpBody ?? Data()
        let sentBody = sent.httpBody ?? Data()
        try originalBody.write(to: directory.appendingPathComponent(originalFile), options: .atomic)
        try sentBody.write(to: directory.appendingPathComponent(sentFile), options: .atomic)
        calls.append(TraceWireCall(index: index, path: path, method: original.httpMethod ?? "GET",
            url: original.url!.absoluteString, originalHeaders: original.allHTTPHeaderFields ?? [:],
            sentHeaders: sent.allHTTPHeaderFields ?? [:], originalTimeout: original.timeoutInterval,
            sentTimeout: sent.timeoutInterval, originalBodyFile: originalFile, sentBodyFile: sentFile,
            originalBodySHA256: TranslationFingerprint.data(originalBody), sentBodySHA256: TranslationFingerprint.data(sentBody),
            overrideApplied: isChat && requestOverride != nil))
        try saveJSON(calls[index], to: directory.appendingPathComponent("\(stem)-wire.json"))
        do {
            if isChat {
                try require(verifiedDigest == pinnedDigest, "Pinned model digest must be verified before chat")
                try require(chatCount == 0, "Diagnostic chat budget exhausted: no automatic retries")
                guard let body = try JSONSerialization.jsonObject(with: sentBody) as? [String: Any] else {
                    throw TraceFailure(message: "Sent chat body is not a JSON object")
                }
                try require(body["model"] as? String == OllamaTranslationProvider.model && body["stream"] as? Bool == false,
                    "Diagnostic overrides must retain the pinned model and non-streaming mode")
                chatCount += 1
            }
            let reply: TraceHTTPReply
            if let scripted { reply = try await scripted(sent) }
            else {
                guard let session else { throw TraceFailure(message: "Missing network session") }
                let (data, response) = try await session.data(for: sent)
                guard let http = response as? HTTPURLResponse else { throw TraceFailure(message: "Non-HTTP response") }
                reply = TraceHTTPReply(data: data, status: http.statusCode,
                    headers: http.allHeaderFields.reduce(into: [:]) { $0[String(describing: $1.key)] = String(describing: $1.value) })
            }
            // Persist exact response bytes before status checks, cancellation or any JSON parsing.
            let responseFile = "\(stem)-response.raw.bin"
            try reply.data.write(to: directory.appendingPathComponent(responseFile), options: .atomic)
            calls[index].responseFile = responseFile
            calls[index].httpStatus = reply.status
            calls[index].responseHeaders = reply.headers
            calls[index].responseSHA256 = TranslationFingerprint.data(reply.data)
            try saveJSON(calls[index], to: directory.appendingPathComponent("\(stem)-wire.json"))
            try Task.checkCancellation()
            if isChat {
                do {
                    guard let root = try JSONSerialization.jsonObject(with: reply.data) as? [String: Any],
                          let message = root["message"] as? [String: Any], let content = message["content"] as? String else {
                        throw TraceFailure(message: "Raw response lacks message.content")
                    }
                    try Data(content.utf8).write(to: directory.appendingPathComponent("\(stem)-response-content.txt"), options: .atomic)
                    let rows = try JSONDecoder().decode([TraceRow].self, from: Data(content.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
                    calls[index].rawRows = rows
                    try saveJSON(rows, to: directory.appendingPathComponent("\(stem)-raw-rows.json"))
                } catch { calls[index].rawParseError = error.localizedDescription }
            }
            try require(reply.status == 200, "Ollama HTTP status \(reply.status)")
            if !isChat {
                guard let root = try JSONSerialization.jsonObject(with: reply.data) as? [String: Any],
                      let models = root["models"] as? [[String: Any]],
                      let model = models.first(where: { $0["name"] as? String == OllamaTranslationProvider.model || $0["model"] as? String == OllamaTranslationProvider.model }) else {
                    throw TraceFailure(message: "Exact translategemma:4b tag is unavailable")
                }
                try require(model["digest"] as? String == pinnedDigest, "Local model digest differs from the pinned c49d986 model")
                verifiedDigest = pinnedDigest
            }
            try saveJSON(calls[index], to: directory.appendingPathComponent("\(stem)-wire.json"))
            return reply.data
        } catch {
            calls[index].transportError = String(describing: error)
            try saveJSON(calls[index], to: directory.appendingPathComponent("\(stem)-wire.json"))
            throw error
        }
    }
}

@main
struct TranslationCausalTraceProbe {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let operation = Task { try await dispatch(arguments) }
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { operation.cancel() }
        interrupt.resume()
        do {
            try await operation.value
            interrupt.cancel()
        } catch {
            interrupt.cancel()
            fputs("TRANSLATION_CAUSAL_TRACE_FAIL: \(error.localizedDescription)\n", stderr)
            exit(error is CancellationError ? 130 : 1)
        }
    }

    private static func dispatch(_ arguments: [String]) async throws {
        if arguments == ["--self-test"] { try await selfTest(); return }
        try require(arguments.count == 2 || (arguments.count == 4 && arguments[2] == "--request-override"),
            "Usage: causal-probe fixture.json output-dir [--request-override request.json] OR --self-test")
        let fixtureData = try Data(contentsOf: URL(fileURLWithPath: arguments[0]))
        let requestOverride = arguments.count == 4 ? try Data(contentsOf: URL(fileURLWithPath: arguments[3])) : nil
        if requestOverride != nil { print("CONTROLLED_DIAGNOSTIC_OVERRIDE: no production-contract or semantic claim") }
        let report = try await execute(fixtureData: fixtureData, directory: URL(fileURLWithPath: arguments[1]), requestOverride: requestOverride)
        if report.cancelled { throw CancellationError() }
        try require(report.diagnosticChecksPassed, report.error ?? "Adapter issues or raw/final structural mismatch; inspect trace-report.json")
        print("TRANSLATION_CAUSAL_TRACE_CAPTURED: structural diagnostics only; semanticVerdict=NOT_EVALUATED")
    }

    private static func execute(fixtureData: Data, directory: URL, requestOverride: Data? = nil, scripted: ScriptedHTTP? = nil) async throws -> TraceReport {
        try require(!FileManager.default.fileExists(atPath: directory.path), "Output directory already exists; evidence will not be overwritten")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try fixtureData.write(to: directory.appendingPathComponent("fixture.raw.json"), options: .atomic)
        if let requestOverride { try requestOverride.write(to: directory.appendingPathComponent("request-override.raw.json"), options: .atomic) }
        let fixture = try JSONDecoder().decode(TraceFixture.self, from: fixtureData)
        try require(!fixture.cues.isEmpty && fixture.cues.count <= 32, "Focused diagnostic requires 1...32 cues for exactly one production execution unit")
        let plan = try TranslationContextPlan(cues: fixture.cues, documentTitle: fixture.documentTitle, chunkSize: 32)
        try saveJSON(TracePlan(contextIdentity: plan.contextIdentity, units: plan.units.map { TraceUnit(index: $0.index, owned: $0.owned) }), to: directory.appendingPathComponent("context-plan.json"))
        try saveJSON(plan.units.flatMap(\.owned), to: directory.appendingPathComponent("planned-owned.json"))
        try saveJSON(plan.units.flatMap(\.owned).map { TraceContext(cueID: $0.id, context: $0.context) }, to: directory.appendingPathComponent("planned-contexts.json"))
        let transport = TraceTransport(directory: directory, requestOverride: requestOverride, scripted: scripted)
        let provider = OllamaTranslationProvider(transport: { request in try await transport.send(request) })
        var adapter = TranslationAdapter(provider: provider)
        adapter.maximumAttempts = 1
        var result: TranslationAdapterResult?
        var failure: Error?
        do {
            result = try await adapter.translate(cues: fixture.cues, source: .ru, target: .en, documentTitle: fixture.documentTitle,
                sourceIdentity: TranslationFingerprint.data(fixtureData), checkpointDirectory: nil, onProgress: { _ in }, onLog: { print($0) })
        } catch { failure = error }
        let calls = await transport.calls
        let rows = calls.filter { $0.path == "/api/chat" }.flatMap { $0.rawRows ?? [] }
        let comparisons = (result?.cues ?? []).map { cue -> TraceComparison in
            let matching = rows.filter { $0.cueId == cue.id }
            let raw = matching.count == 1 ? matching[0].text : nil
            return TraceComparison(cueID: cue.id, rawRowCount: matching.count, rawText: raw, finalText: cue.text,
                rawTrimEqualsFinal: raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) == cue.text })
        }
        let countAligned = result.map { $0.cues.count == fixture.cues.count }
        let idAligned = result.map { $0.cues.map(\.id) == fixture.cues.map(\.id) }
        let timesAligned = result.map { $0.cues.count == fixture.cues.count && zip($0.cues, fixture.cues).allSatisfy { $0.start == $1.start && $0.end == $1.end } }
        let passed = failure == nil && result?.issues.isEmpty == true && countAligned == true && idAligned == true && timesAligned == true
            && comparisons.count == fixture.cues.count && comparisons.allSatisfy { $0.rawTrimEqualsFinal == true }
        let environment = ProcessInfo.processInfo.environment
        let report = TraceReport(mode: scripted == nil ? "LOCAL_REAL_MODEL_CAUSAL_DIAGNOSTIC" : "SCRIPTED_NO_NETWORK_SELF_TEST",
            requestOverrideApplied: requestOverride != nil, productionContractClaim: false,
            fixtureSHA256: TranslationFingerprint.data(fixtureData), documentTitle: fixture.documentTitle,
            verifiedDigest: await transport.verifiedDigest, sourceHead: environment["TRACE_SOURCE_HEAD"],
            buildInputManifest: environment["TRACE_BUILD_INPUT_MANIFEST"], contextIdentity: plan.contextIdentity,
            calls: calls, adapterOutcome: result == nil ? "THREW" : (result!.issues.isEmpty ? "RETURNED_WITHOUT_STRUCTURAL_ISSUES" : "RETURNED_WITH_ISSUES"),
            finalCues: result?.cues, issues: (result?.issues ?? []).map { TraceIssue(cueID: $0.cueID, reasonCodes: $0.reasonCodes, candidateText: $0.candidateText) },
            countAligned: countAligned, idOrderAligned: idAligned, timestampsAligned: timesAligned, rawFinalComparisons: comparisons,
            error: failure.map { String(describing: $0) }, cancelled: failure.map { $0 is CancellationError } ?? false, diagnosticChecksPassed: passed)
        try saveJSON(report, to: directory.appendingPathComponent("trace-report.json"))
        print("CAUSAL_TRACE_EVIDENCE: \(directory.path)")
        return report
    }

    private static func selfTest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("videotext-causal-self-test-\(UUID().uuidString)")
        let fixture = TraceFixture(cues: [
            SubtitleCue(id: 501, start: 0.125, end: 1.625, text: "Мы ждем автобус."),
            SubtitleCue(id: 87, start: 3.125, end: 4.625, text: "А я пока..."),
            SubtitleCue(id: 704, start: 6.125, end: 7.625, text: "Отправление задерживается.")
        ], documentTitle: "Synthetic source metadata")
        let fixtureData = try JSONEncoder().encode(fixture)
        let requestOverride = Data("{\"model\":\"translategemma:4b\",\"stream\":false,\"messages\":[{\"role\":\"user\",\"content\":\"Controlled diagnostic only\"}]}\n".utf8)
        for mode in TraceSelfTestMode.allCases {
            let middle = mode == .scriptedCompletion ? "  And I am staying beside the gate.\n" : "  And I, for now...\n"
            let rows = [TraceRow(cueId: 704, text: "The departure is delayed."), TraceRow(cueId: 87, text: middle), TraceRow(cueId: 501, text: "We are waiting for the bus.")]
            let content = String(decoding: try JSONEncoder().encode(rows), as: UTF8.self)
            let replyData: Data
            if mode == .malformed { replyData = Data("not JSON\n".utf8) }
            else { replyData = try JSONSerialization.data(withJSONObject: ["done": true, "done_reason": "stop", "message": ["content": content]]) }
            let server = TraceSelfTestServer(reply: replyData, mode: mode)
            let output = root.appendingPathComponent(mode.rawValue)
            let task = Task { try await execute(fixtureData: fixtureData, directory: output, requestOverride: mode == .requestOverride ? requestOverride : nil,
                scripted: { request in try await server.respond(request) }) }
            let report = try await task.value
            let received = await server.requests
            let expectedFailure = [.httpFailure, .malformed, .wrongDigest, .cancelled].contains(mode)
            try require(report.diagnosticChecksPassed != expectedFailure, "Self-test diagnostic outcome differs from scripted control: \(mode.rawValue)")
            try require(report.semanticVerdict == "NOT_EVALUATED" && !report.productionContractClaim, "Self-test falsely claims semantic/production acceptance")
            try require(try Data(contentsOf: output.appendingPathComponent("fixture.raw.json")) == fixtureData, "Fixture bytes were not preserved")
            let chat = report.calls.filter { $0.path == "/api/chat" }
            if mode == .wrongDigest {
                try require(chat.isEmpty && received.count == 1, "Wrong digest reached chat")
                continue
            }
            try require(chat.count == 1 && received.count == 2, "Diagnostic made retries or additional requests")
            let call = chat[0]
            let original = try Data(contentsOf: output.appendingPathComponent(call.originalBodyFile))
            let sent = try Data(contentsOf: output.appendingPathComponent(call.sentBodyFile))
            let raw = try Data(contentsOf: output.appendingPathComponent(call.responseFile!))
            try require(raw == replyData && sent == received[1].httpBody, "Raw response or actual sent request bytes changed")
            try require(call.httpStatus == (mode == .httpFailure ? 503 : 200), "HTTP status was not preserved")
            try require(mode == .requestOverride ? (sent == requestOverride && original != sent) : original == sent, "Override/original byte provenance is incorrect")
            if !expectedFailure {
                try require(call.rawRows == rows && report.finalCues?.map(\.id) == fixture.cues.map(\.id), "Raw reordered rows or final source order changed")
                try require(report.rawFinalComparisons.allSatisfy { $0.rawTrimEqualsFinal == true }, "Production parser/adapter changed scripted raw text beyond trimming")
            }
            if mode == .cancelled { try require(report.cancelled, "Cancellation was not propagated after raw-byte capture") }
        }
        print("TRANSLATION_CAUSAL_TRACE_SELF_TEST_PASS: exact bytes/status, reordered IDs/times, trimming equality, override isolation, failures, digest pin and cancellation; no network or semantic acceptance")
        print("SELF_TEST_EVIDENCE: \(root.path)")
    }
}

private enum TraceSelfTestMode: String, CaseIterable {
    case fragment, scriptedCompletion, requestOverride, httpFailure, malformed, wrongDigest, cancelled
}

private actor TraceSelfTestServer {
    let reply: Data
    let mode: TraceSelfTestMode
    private(set) var requests: [URLRequest] = []

    init(reply: Data, mode: TraceSelfTestMode) { self.reply = reply; self.mode = mode }

    func respond(_ request: URLRequest) throws -> TraceHTTPReply {
        requests.append(request)
        if request.url?.path == "/api/tags" {
            let tags = try JSONSerialization.data(withJSONObject: ["models": [["name": OllamaTranslationProvider.model,
                "model": OllamaTranslationProvider.model, "digest": mode == .wrongDigest ? "wrong-digest" : pinnedDigest]]])
            return TraceHTTPReply(data: tags, status: 200)
        }
        try require(request.url?.path == "/api/chat", "Unexpected scripted endpoint")
        if mode == .cancelled { withUnsafeCurrentTask { $0?.cancel() } }
        return TraceHTTPReply(data: reply, status: mode == .httpFailure ? 503 : 200)
    }
}
