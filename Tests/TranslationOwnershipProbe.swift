import Foundation

@main
struct TranslationOwnershipProbe {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("videotext-ownership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try verifyDocumentMetadata()
        print("path_metadata_lineage=PASS metadata_bound=PASS no_guessed_description=PASS")
        try await verifySourceAnchorContractWiring()
        try await verifyProductionSingleBatchContract()
        try await verifyProductionBatchFailures()
        try await verifyProductionSourceEchoCorrectionRetry()
        print("ownership_task_prompt=PASS source_span_isolation=PASS scripted_context_routing=PASS scripted_alignment=PASS live_semantics=NOT_TESTED")
        print("source_echo_rejection=PASS scripted_http_single_batch_contract=PASS production_schema_truncation_failure_cancellation=PASS")
        try await verifyOwnershipAndBoundaries()
        print("ownership=PASS boundary_context=PASS alignment=PASS duplicate_input=PASS")
        try await verifyContextResponseRejection()
        try await verifySelectiveRetryAndProviderFailure()
        try await verifyOwnershipMismatchStopsAtAdapter(directory: root.appendingPathComponent("ownership-mismatch"))
        try await verifyUnresolvedPrefix(directory: root.appendingPathComponent("unresolved"))
        print("context_only_response=PASS selective_retry=PASS provider_failure_retry=PASS ownership_mismatch_fail_closed=PASS unresolved_prefix=PASS")
        try await verifyCheckpointWriteFailure(directory: root.appendingPathComponent("write-failure"))
        print("checkpoint_write_failure_fatal=PASS")
        try await verifyCancellationAndResume(directory: root.appendingPathComponent("cancellation"))
        print("cancellation_prefix=PASS resume_no_recompute=PASS")
        try await verifyFinalCueCancellation(directory: root.appendingPathComponent("final-cancellation"))
        try await verifyWrongLanguageAndNames(directory: root.appendingPathComponent("language"))
        try verifyQuotedContextPrompt()
        try verifySparseContextPrompt()
        try verifyOutputBudget()
        try verifyAdaptiveRequestBatches()
        try verifyCorrectionAdaptiveRequestBatches()
        print("cancelled_unit_not_committed=PASS source_echo_review=PASS name_exception=PASS quoted_context=PASS")
        print("sparse_context_direction=PASS owner_context_association=PASS output_budget=PASS adaptive_request_batches=PASS correction_batch_safety=PASS generic_fragment_instruction=PASS")
        try await verifyNeutralTokens()
        print("numeric_only=PASS protected_token_passthrough=PASS token_changes_rejected=PASS")
        try await verifyInvalidation(directory: root.appendingPathComponent("invalidation"))
        print("unchanged_cache=PASS ancestor_context_invalidation=PASS v5_to_v7_protocol_invalidation=PASS title_source_overlap_digest_protocol_identity_invalidation=PASS")
        try await verifyCheckpointCorruption(directory: root.appendingPathComponent("corruption"))
        print("corrupt_checkpoint=PASS tampered_checkpoint=PASS")
        try verifyReportCompatibilityAndResume(directory: root.appendingPathComponent("report-resume"))
        print("legacy_report_decode=PASS machine_output_integrity=PASS human_revision_bytes_lineage=PASS")
        print("TRANSLATION_OWNERSHIP_PROBE_PASS: deterministic mock checks only; no model or semantic acceptance")
    }

    private static func fixture() -> [SubtitleCue] {
        let ids = [41, 7, 92, 13, 81, 3, 55]
        let texts = ["Opening subject.", "A sentence begins,", "then continues here.", "An unfinished thought...", "Another speaker responds.", "The discussion continues.", "Closing remark."]
        return ids.enumerated().map { index, id in
            SubtitleCue(id: id, start: Double(index * 2) + 0.125, end: Double(index * 2) + 1.375, text: texts[index])
        }
    }

    private static func configuration(_ cues: [SubtitleCue]? = nil) -> OwnershipConfiguration {
        OwnershipConfiguration(cues: cues ?? fixture(), title: TranslationContextPlan.documentTitle(for: fixtureMedia()), sourceIdentity: "source-revision-a", identity: mockIdentity())
    }

    private static func fixtureMedia() -> URL {
        URL(fileURLWithPath: "/ownership-fixture/Archive Sessions/Track A/recording.mp4")
    }

    private static func verifyDocumentMetadata() throws {
        for (path, expected) in [
            ("/ignored-root/ignored-parent/Workshop Zoom/Session B/recording 07.mp4", "Workshop Zoom / Session B / recording 07.mp4"),
            ("/ignored-root/Archive Sessions/Track A/recording.mp4", "Archive Sessions / Track A / recording.mp4")
        ] {
            let title = TranslationContextPlan.documentTitle(for: URL(fileURLWithPath: path))
            try require(title == expected, "Source metadata is not exactly two parent names plus filename")
            let plan = try TranslationContextPlan(cues: fixture(), documentTitle: title, chunkSize: 3)
            let document = plan.units[0].owned[0].context!.document
            let lines = document.components(separatedBy: "\n").filter { $0.hasPrefix("Document title (source metadata only): ") }
            try require(lines == ["Document title (source metadata only): " + expected], "Document title contains a guessed description or wrong lineage")
            if !expected.contains("Zoom") {
                try require(!document.localizedCaseInsensitiveContains("zoom"), "Document context guessed Zoom without source-path evidence")
            }
        }
        let longMedia = URL(fileURLWithPath: "/ignored-root/" + String(repeating: "a", count: 180) + "/Track A/recording.mp4")
        let longTitle = TranslationContextPlan.documentTitle(for: longMedia)
        let bounded = try TranslationContextPlan(cues: fixture(), documentTitle: longTitle, chunkSize: 3)
        let expectedLine = "Document title (source metadata only): " + String(longTitle.prefix(160))
        try require(bounded.units.flatMap(\.owned).allSatisfy { $0.context!.document.components(separatedBy: "\n").contains(expectedLine) }, "Source title metadata is not bounded consistently to 160 characters")
    }

    private static func mockIdentity() -> TranslationModelIdentity {
        TranslationModelIdentity(model: "ownership-mock", digest: "verified-mock-digest-a", protocolVersion: "ownership-test-protocol-a")
    }

    private static func run(
        _ configuration: OwnershipConfiguration,
        provider: OwnershipProvider,
        directory: URL? = nil,
        batchSize: Int = 3,
        source: ArtifactLanguage = .ru,
        target: ArtifactLanguage = .en
    ) async throws -> TranslationAdapterResult {
        var adapter = TranslationAdapter(provider: provider)
        adapter.batchSize = batchSize
        return try await adapter.translate(
            cues: configuration.cues, source: source, target: target,
            documentTitle: configuration.title, sourceIdentity: configuration.sourceIdentity,
            checkpointDirectory: directory, onProgress: { _ in }, onLog: { _ in }
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw OwnershipFailure(message: message) }
    }

    private static func assertAlignment(_ result: TranslationAdapterResult, source: [SubtitleCue]) throws {
        try require(result.cues.count == source.count, "Output cue count changed")
        try require(result.cues.map(\.id) == source.map(\.id), "Output IDs/order changed")
        try require(zip(result.cues, source).allSatisfy { $0.start == $1.start && $0.end == $1.end }, "Output timestamps changed")
        try require(Set(result.cues.map(\.id)).count == source.count, "Duplicate output ownership")
    }

    private static func assertSuccessful(_ result: TranslationAdapterResult, source: [SubtitleCue]) throws {
        try assertAlignment(result, source: source)
        try require(result.issues.isEmpty, "Successful mock translation left issues")
        try require(zip(result.cues, source).allSatisfy { $0.text == OwnershipProvider.output($1.text) }, "Output includes context or lost an owned response")
        try require(result.modelDigest != nil, "Mock provenance lost model digest")
    }

    private static func verifyOwnershipAndBoundaries() async throws {
        let source = fixture()
        let config = configuration(source)
        let baseline = try TranslationContextPlan(cues: source, documentTitle: config.title, chunkSize: 1)
        let baselineRequests = baseline.units.flatMap(\.owned)
        for size in [1, 2, 3, 32] {
            let plan = try TranslationContextPlan(cues: source, documentTitle: config.title, chunkSize: size)
            let owned = plan.units.flatMap(\.owned)
            try require(plan.units.map(\.index) == Array(plan.units.indices), "Execution unit indexes are unstable")
            try require(owned.map(\.id) == source.map(\.id), "Planner dropped/reordered owned cues")
            let counts = owned.reduce(into: [Int: Int]()) { $0[$1.id, default: 0] += 1 }
            try require(source.allSatisfy { counts[$0.id] == 1 }, "Every cue must have exactly one owner")
            try require(plan.contextIdentity == baseline.contextIdentity, "Execution chunk size changed semantic context identity")
            try require(owned == baselineRequests, "Execution chunk boundary changed context")

            for (index, request) in owned.enumerated() {
                guard let context = request.context else { throw OwnershipFailure(message: "Owned request has no context") }
                let before = Array(source[max(0, index - 2)..<index])
                let after = Array(source[(index + 1)..<min(source.count, index + 3)])
                try require(context.before.map(\.id) == before.map(\.id) && context.before.map(\.text) == before.map(\.text), "Before-context crossed the wrong source boundary")
                try require(context.after.map(\.id) == after.map(\.id) && context.after.map(\.text) == after.map(\.text), "After-context crossed the wrong source boundary")
                try require(!context.before.contains { $0.id == request.id } && !context.after.contains { $0.id == request.id }, "Target has duplicate context ownership")
                try require(context.document == baselineRequests[index].context?.document, "Document context changed across units")
            }

            let provider = OwnershipProvider(identity: config.identity)
            let result = try await run(config, provider: provider, batchSize: size)
            let calls = await provider.calls
            try assertSuccessful(result, source: source)
            try require(calls.map { $0.map(\.id) } == plan.units.map { $0.owned.map(\.id) }, "Provider did not receive complete owned execution units")
            try require(calls.flatMap { $0 } == baselineRequests, "Adapter changed planned context")
            try require(result.contextIdentity == plan.contextIdentity, "Result lost context provenance")
        }

        let duplicateProvider = OwnershipProvider(identity: config.identity)
        do {
            _ = try await run(configuration([source[0], source[0]]), provider: duplicateProvider)
            throw OwnershipFailure(message: "Duplicate source IDs were accepted")
        } catch is OwnershipFailure {
            throw OwnershipFailure(message: "Duplicate source IDs were accepted")
        } catch let error as WorkflowError {
            guard case .processFailed = error else { throw error }
        }
        let duplicateCalls = await duplicateProvider.calls
        try require(duplicateCalls.isEmpty, "Duplicate source reached the translation provider")
    }

    private static func verifyContextResponseRejection() async throws {
        let config = configuration()
        let target = config.cues[1].id
        let extra = config.cues[2].id
        let provider = OwnershipProvider(identity: config.identity, behavior: .extraOnce(target: target, extra: extra))
        let result = try await run(config, provider: provider, batchSize: 2)
        let calls = await provider.calls
        try assertSuccessful(result, source: config.cues)
        let expectedGroups = [[41, 7], [41, 7], [92, 13], [81, 3], [55]]
        try require(calls.map { $0.map(\.id) } == expectedGroups, "Extra context response did not invalidate only its execution unit")
        try require(calls[0] == calls[1], "Rejected-response retry changed its owned cues/context")
        let missingProvider = OwnershipProvider(identity: config.identity, behavior: .missingOnce(target: target))
        let recovered = try await run(config, provider: missingProvider)
        let missingCalls = await missingProvider.calls
        try assertSuccessful(recovered, source: config.cues)
        try require(missingCalls.map { $0.map(\.id) } == [[41, 7, 92], [41, 7, 92], [13, 81, 3], [55]], "Missing ID did not reject the structurally invalid response")
        try require(missingCalls[0] == missingCalls[1], "Missing-ID retry changed source context")
    }

    private static func verifySelectiveRetryAndProviderFailure() async throws {
        let config = configuration()
        let provider = OwnershipProvider(identity: config.identity, behavior: .emptyOnce(target: config.cues[1].id))
        let result = try await run(config, provider: provider)
        let calls = await provider.calls
        try assertSuccessful(result, source: config.cues)
        try require(calls.map { $0.map(\.id) } == [[41, 7, 92], [7], [13, 81, 3], [55]], "Selective retry recomputed successful owned responses")
        try require(calls[1] == calls[0].filter { $0.id == config.cues[1].id }, "Selective retry changed immutable source context")

        let throwing = OwnershipProvider(identity: config.identity, behavior: .throwOnCallOnce(2))
        let recovered = try await run(config, provider: throwing)
        let throwingCalls = await throwing.calls
        try assertSuccessful(recovered, source: config.cues)
        try require(throwingCalls.map { $0.map(\.id) } == [[41, 7, 92], [13, 81, 3], [13, 81, 3], [55]], "Provider error did not retry the complete failed unit while retaining earlier units")
        try require(throwingCalls[1] == throwingCalls[2], "Provider-error retry changed its owned unit/context")
    }

    private static func verifyOwnershipMismatchStopsAtAdapter(directory: URL) async throws {
        let config = configuration(Array(fixture().prefix(3)))
        let provider = OwnershipProvider(identity: config.identity, behavior: .throwOwnershipMismatch)
        let result = try await run(config, provider: provider, directory: directory)
        let calls = await provider.calls
        try assertAlignment(result, source: config.cues)
        try require(calls.map { $0.map(\.id) } == [config.cues.map(\.id)],
                    "sourceEcho mismatch retried the complete adapter execution unit")
        try require(result.issues.map(\.cueID) == config.cues.map(\.id)
                    && result.issues.allSatisfy { $0.reasonCodes == ["provider-error: source-echo-ownership-mismatch"] && $0.candidateText == nil },
                    "sourceEcho mismatch was not preserved as a typed fail-closed review issue")
        try require(zip(result.cues, config.cues).allSatisfy { $0.text == $1.text },
                    "sourceEcho mismatch replaced a source cue with unverified output")
        let plan = try TranslationContextPlan(cues: config.cues, documentTitle: config.title, chunkSize: 3)
        let store = try checkpointStore(config, plan: plan, directory: directory)
        try require(store.load(plan.units[0]).isEmpty, "sourceEcho mismatch wrote an unverified checkpoint")
        let record = directory.appendingPathComponent(store.runIdentity, isDirectory: true).appendingPathComponent("unit-0.json")
        try require(!FileManager.default.fileExists(atPath: record.path), "sourceEcho mismatch left a checkpoint record")
    }

    private static func verifyUnresolvedPrefix(directory: URL) async throws {
        let config = configuration(Array(fixture().prefix(3)))
        let failedID = config.cues[1].id
        let provider = OwnershipProvider(identity: config.identity, behavior: .alwaysEmpty(target: failedID))
        let result = try await run(config, provider: provider, directory: directory)
        let calls = await provider.calls
        try assertAlignment(result, source: config.cues)
        try require(calls.map { $0.map(\.id) } == [[41, 7, 92], [7]], "Unresolved cue did not retry only its invalid ID")
        try require(result.issues.count == 1 && result.issues[0].cueID == failedID, "Unresolved issue disappeared")
        try require(result.issues[0].reasonCodes.contains("empty-cue"), "Unresolved cue lost its validation reason")
        try require(result.issues[0].candidateText == "", "Unresolved candidate evidence disappeared")
        try require(result.cues[2].text == OwnershipProvider.output(config.cues[2].text), "Unresolved sibling discarded a successful owned response")

        let plan = try TranslationContextPlan(cues: config.cues, documentTitle: config.title, chunkSize: 3)
        let store = try checkpointStore(config, plan: plan, directory: directory)
        try require(store.load(plan.units[0]).map(\.cueID) == [config.cues[0].id], "Checkpoint cached an unresolved cue or jumped beyond its prefix")
        let resumed = OwnershipProvider(identity: config.identity)
        let recovered = try await run(config, provider: resumed, directory: directory)
        let resumedCalls = await resumed.calls
        try assertSuccessful(recovered, source: config.cues)
        try require(resumedCalls.map { $0.map(\.id) } == [Array(config.cues.dropFirst().map(\.id))], "Resume did not remove only the checkpointed prefix from pending ownership")
    }

    private static func verifyCancellationAndResume(directory: URL) async throws {
        let config = configuration()
        let provider = OwnershipProvider(identity: config.identity, behavior: .cancelOnCall(2, throwError: false))
        let task = Task { try await run(config, provider: provider, directory: directory, batchSize: 1) }
        do {
            _ = try await task.value
            throw OwnershipFailure(message: "Cancelled translation returned a completed result")
        } catch is CancellationError { }
        let calls = await provider.calls
        try require(calls.map { $0.map(\.id) } == [[41], [7]], "Cancellation continued translating after the cancelled second execution unit")
        let plan = try TranslationContextPlan(cues: config.cues, documentTitle: config.title, chunkSize: 1)
        let store = try checkpointStore(config, plan: plan, directory: directory)
        try require(store.load(plan.units[0]).map(\.cueID) == [config.cues[0].id], "Cancellation lost the completed prefix")
        try require(plan.units.dropFirst().allSatisfy { store.load($0).isEmpty }, "Cancellation checkpointed unprocessed units")
        try assertNoPartialFiles(directory)

        let resumed = OwnershipProvider(identity: config.identity)
        let result = try await run(config, provider: resumed, directory: directory, batchSize: 1)
        let resumedCalls = await resumed.calls
        try assertSuccessful(result, source: config.cues)
        try require(resumedCalls.map { $0.map(\.id) } == config.cues.dropFirst().map { [$0.id] }, "Cancellation resume recomputed the saved unit or lost pending cues")
        let unchanged = OwnershipProvider(identity: config.identity)
        let cached = try await run(config, provider: unchanged, directory: directory, batchSize: 1)
        let unchangedCalls = await unchanged.calls
        try assertSuccessful(cached, source: config.cues)
        try require(unchangedCalls.isEmpty, "Completed resume unnecessarily recomputed translation")
    }

    private static func verifyFinalCueCancellation(directory: URL) async throws {
        let config = configuration(Array(fixture().prefix(3)))
        for throwError in [false, true] {
            let cache = directory.appendingPathComponent(throwError ? "generic-error" : "valid-response")
            let provider = OwnershipProvider(identity: config.identity, behavior: .cancelOnCall(1, throwError: throwError))
            let task = Task { try await run(config, provider: provider, directory: cache) }
            do {
                _ = try await task.value
                throw OwnershipFailure(message: "Cancelled owned unit published a result")
            } catch is CancellationError { }
            let calls = await provider.calls
            try require(calls.map { $0.map(\.id) } == [config.cues.map(\.id)], "Owned-unit cancellation was swallowed or retried")
            let plan = try TranslationContextPlan(cues: config.cues, documentTitle: config.title, chunkSize: 3)
            let store = try checkpointStore(config, plan: plan, directory: cache)
            try require(store.load(plan.units[0]).isEmpty, "Cancelled batch response was partially checkpointed")
            let url = cache.appendingPathComponent(store.runIdentity).appendingPathComponent("unit-0.json")
            try require(!FileManager.default.fileExists(atPath: url.path), "Cancelled owned unit wrote a checkpoint record")
        }
    }

    private static func verifyWrongLanguageAndNames(directory: URL) async throws {
        let cases = [("short-echo", "Я здесь", "Я здесь"),
                     ("long-wrong-script", "Готовы продолжать разговор.", "Обсуждение продолжается.")]
        for (name, sourceText, output) in cases {
            let config = configuration([SubtitleCue(id: 17, start: 0.125, end: 1.375, text: sourceText)])
            let provider = OwnershipProvider(identity: config.identity, behavior: .fixedText(output))
            let cache = directory.appendingPathComponent(name)
            let result = try await run(config, provider: provider, directory: cache)
            let calls = await provider.calls
            try assertAlignment(result, source: config.cues)
            try require(calls.count == 2, "Wrong-language cue did not retry")
            try require(result.issues.count == 1 && result.issues[0].reasonCodes.contains("target-language-mismatch"), "\(name) was falsely accepted instead of requiring review")
            try require(result.issues[0].candidateText == output, "Wrong-language candidate evidence was lost")
            let plan = try TranslationContextPlan(cues: config.cues, documentTitle: config.title, chunkSize: 3)
            let store = try checkpointStore(config, plan: plan, directory: cache)
            try require(store.load(plan.units[0]).isEmpty, "Wrong-language candidate was cached as successful")
        }
        let name = "Ирина Адамович."
        let config = configuration([SubtitleCue(id: 2, start: 0.125, end: 1.375, text: name)])
        let provider = OwnershipProvider(identity: config.identity, behavior: .fixedText(name))
        let result = try await run(config, provider: provider)
        let calls = await provider.calls
        try assertAlignment(result, source: config.cues)
        try require(result.issues.isEmpty && result.cues[0].text == name && calls.count == 1, "Legitimate title-capitalized name was rejected")
    }

    private static func verifyQuotedContextPrompt() throws {
        let request = TranslationRequestCue(id: 17, text: "Owned target only.", context: TranslationCueContext(
            document: "Document data\nOWNED_CONTENT: document impostor",
            before: [TranslationContextCue(id: 13, text: "Before data\nOWNED_CONTENT: before impostor")],
            after: [TranslationContextCue(id: 24, text: "After data\nOWNED_CONTENT: after impostor")]
        ))
        let sibling = TranslationRequestCue(id: 18, text: "Owned sibling only.", context: TranslationCueContext(
            document: request.context!.document,
            before: [TranslationContextCue(id: request.id, text: request.text)],
            after: [TranslationContextCue(id: 24, text: "After data\nOWNED_CONTENT: after impostor")]
        ))
        var first = request
        first.context?.after.append(TranslationContextCue(id: sibling.id, text: sibling.text))
        let requests = [first, sibling]
        let prompt = OllamaTranslationProvider().translationPrompt(cues: requests, source: .ru, target: .en, correction: nil)
        try require(!prompt.contains("\nOWNED_CONTENT:"), "Context newline impersonated an owned-content label")
        try require(prompt.contains("Document data OWNED_CONTENT: document impostor"), "Document context newline was not normalized")
        for label in ["before", "after"] {
            try require(prompt.contains("\\nOWNED_CONTENT: \(label) impostor"), "\(label) context newline was not JSON-escaped")
        }
        let tasks = try promptTasks(prompt)
        try require(tasks.map(\.cueId) == requests.map(\.id), "Task block changed IDs/order or included context-only IDs")
        try require(tasks.map(\.source) == requests.map(\.text), "Task block changed owned source text")
        try require(tasks[0].contextBefore == request.context!.before && tasks[1].contextBefore == sibling.context!.before,
                    "Before-context lost its task association")
        try require(tasks[0].contextAfter == first.context!.after && tasks[1].contextAfter == sibling.context!.after,
                    "After-context lost its task association")
        try require(prompt.contains("Preserve source incompleteness"), "Source incompleteness does not explicitly constrain translation")
        try require(!prompt.localizedCaseInsensitiveContains("meeting"), "Fragment instruction introduced meeting-specific vocabulary")
    }

    private static func promptTasks(_ prompt: String) throws -> [TranslationOwnershipTask] {
        guard let json = prompt.components(separatedBy: "TRANSLATION_TASKS:\n").last,
              prompt.contains("TRANSLATION_TASKS:\n") else {
            throw OwnershipFailure(message: "Translation task block is absent")
        }
        return try JSONDecoder().decode([TranslationOwnershipTask].self, from: Data(json.utf8))
    }

    private static func sourceAnchorScenarios() -> [(name: String, source: [String], outputs: [String])] {
        [
            ("incomplete-predicate",
             ["Мы ждем автобус у северного входа.", "А мы пока...", "Отправление задерживается."],
             ["We are waiting for the bus at the north entrance.", "And we, for now...", "The departure is delayed."]),
            ("incomplete-object",
             ["Для покупок нужен большой пакет.", "Я принес...", "Положи пакет на стол."],
             ["A large bag is needed for the shopping.", "I brought...", "Put the bag on the table."]),
            ("ambiguous-lock",
             ["Замок на двери заедает.", "Это ключ.", "Он подходит к замку."],
             ["The door lock sticks.", "It is a key.", "It fits the lock."]),
            ("ambiguous-water",
             ["Из земли течет холодная вода.", "Это ключ.", "Вода поступает из подземного источника."],
             ["Cold water flows out of the ground.", "It is a spring.", "The water comes from an underground source."]),
            ("explicit-referent-manuscript",
             ["Рукопись прошла последнюю проверку.", "Она уже готова.", "Можно отправлять текст в печать."],
             ["The manuscript has passed the final check.", "It is already ready.", "The text can be sent to print."]),
            ("explicit-referent-person",
             ["Исследовательница закончила подготовку.", "Она уже готова.", "Можно начинать обсуждение."],
             ["The researcher has finished preparing.", "She is already ready.", "The discussion can begin."]),
            ("context-only-detail",
             ["Поезд отправляется с восточной платформы.", "Да.", "После остановки мы пойдем в библиотеку."],
             ["The train leaves from the east platform.", "Yes.", "After the stop we will go to the library."])
        ]
    }

    private static func verifySourceAnchorContractWiring() async throws {
        // Scripted responses exercise transport and assembly, not model semantics.
        let scenarios = sourceAnchorScenarios()
        try require(OllamaTranslationProvider.protocolVersion.contains("owned-tasks-v7-") && OllamaTranslationProvider.protocolVersion.contains("pair-schema1"), "Ownership-task contract lacks pair-bound protocol provenance")
        var contextByScenario: [String: String] = [:]
        for scenario in scenarios {
            let ids = [601, 304, 892]
            let source = ids.enumerated().map { index, id in
                SubtitleCue(id: id, start: Double(index * 3) + 0.125, end: Double(index * 3) + 1.625, text: scenario.source[index])
            }
            var config = configuration(source)
            config.identity.protocolVersion = OllamaTranslationProvider.protocolVersion
            let responses = Dictionary(uniqueKeysWithValues: zip(ids, scenario.outputs).map { ($0.0, $0.1) })
            for size in [1, 2, 3] {
                let plan = try TranslationContextPlan(cues: source, documentTitle: config.title, chunkSize: size)
                contextByScenario[scenario.name] = plan.contextIdentity
                let provider = OwnershipProvider(identity: config.identity, behavior: .scriptedOutputs(responses))
                let result = try await run(config, provider: provider, batchSize: size)
                let calls = await provider.calls
                try assertAlignment(result, source: source)
                try require(result.issues.isEmpty, "\(scenario.name) scripted valid output was rejected")
                try require(result.cues.map(\.text) == scenario.outputs, "\(scenario.name) adapter rewrote or merged scripted responses")
                try require(result.protocolVersion == config.identity.protocolVersion && result.contextIdentity == plan.contextIdentity, "Source-anchor mock lost protocol/context provenance")
                try require(calls == plan.units.map(\.owned), "\(scenario.name) provider did not receive exact planned owned source spans")
                try require(calls.flatMap { $0 }.first { $0.id == ids[1] }?.text == scenario.source[1], "Neighboring semantic material was passed as the target's owned source")
                for call in calls {
                    let prompt = OllamaTranslationProvider().translationPrompt(cues: call, source: .ru, target: .en, correction: nil)
                    try assertSourceAnchorPrompt(prompt)
                    let tasks = try promptTasks(prompt)
                    try require(tasks.map(\.cueId) == call.map(\.id) && tasks.map(\.source) == call.map(\.text),
                                "\(scenario.name) task block changed owned source identity")
                    for (task, request) in zip(tasks, call) {
                        try require(task.contextBefore == request.context!.before, "Ownership task lost before-context interpretation data")
                        try require(task.contextAfter == request.context!.after, "Ownership task lost after-context interpretation data")
                    }
                }
            }
            if scenario.name.hasPrefix("incomplete-") {
                try require(scenario.outputs[1].hasSuffix("..."), "Incomplete scripted fixture is not an incomplete fragment")
            }
        }
        try require(contextByScenario["ambiguous-lock"] != contextByScenario["ambiguous-water"], "Ambiguous-expression scenarios did not retain distinct contextual identities")
        try require(contextByScenario["explicit-referent-manuscript"] != contextByScenario["explicit-referent-person"], "Explicit-referent scenarios did not retain distinct contextual identities")
    }

    private static func assertSourceAnchorPrompt(_ prompt: String) throws {
        let marker = "SOURCE OWNERSHIP CONTRACT: "
        let sections = prompt.components(separatedBy: "\n").filter { $0.hasPrefix(marker) }
        guard sections.count == 1, let contract = sections.first else {
            throw OwnershipFailure(message: "Prompt must contain exactly one source-ownership contract")
        }
        for rule in [
            "Each TRANSLATION_TASK contains exactly one cueId and source",
            "copy that task's source exactly into sourceEcho",
            "translate ONLY that source into text",
            "Never translate, copy, move, complete or emit a proposition from context or another task.",
            "every proposition, negation, number, frequency, modifier, evaluation, name, referent and natural repetition",
            "Never redistribute clauses for fluency."
        ] {
            try require(contract.contains(rule), "Source-ownership prompt is missing rule: \(rule)")
        }
        try require(!prompt.contains("context does not explicitly supply its continuation") && !prompt.contains("unless context"), "Prompt restored a context-supplied completion exception")
    }

    private static func verifyProductionSingleBatchContract() async throws {
        // Real provider, scripted HTTP: this checks protocol wiring, not semantic enforcement.
        let ids = [601, 304, 892, 115, 708]
        let texts = ["Мы ждем автобус.", "А мы пока...", "Отправление задерживается.", "Поездка запланирована на завтра.", "Собираемся у северного входа."]
        let source = ids.enumerated().map { index, id in
            SubtitleCue(id: id, start: Double(index * 3) + 0.125, end: Double(index * 3) + 1.625, text: texts[index])
        }
        let config = configuration(source)
        let plan = try TranslationContextPlan(cues: source, documentTitle: config.title, chunkSize: 3)
        let owned = plan.units[0].owned
        let scripted = ["We are waiting for the bus.", "And we, for now...", "The departure is delayed."]
        let rows = owned.indices.reversed().map {
            ["cueId": owned[$0].id, "sourceEcho": owned[$0].text, "text": scripted[$0]] as [String: Any]
        }
        let content = String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
        let reply = try JSONSerialization.data(withJSONObject: ["done": true, "done_reason": "stop", "message": ["role": "assistant", "content": content]])
        let transport = OwnershipBatchTransport(reply: reply)
        let provider = OllamaTranslationProvider(transport: { request in try await transport.respond(to: request) })
        let identity = try await provider.preferredIdentity()
        try require(identity.model == OllamaTranslationProvider.model && identity.digest == OwnershipBatchTransport.digest && identity.protocolVersion == OllamaTranslationProvider.protocolVersion, "Scripted production identity lost model/digest/protocol provenance")
        let response = try await provider.translate(cues: owned, source: .ru, target: .en, model: identity.model, correction: nil)
        try require(Set(response.keys) == Set(owned.map(\.id)), "Production batch returned context-only IDs or lost ownership")
        try require(owned.indices.allSatisfy { response[owned[$0].id] == scripted[$0] }, "Production batch parser misassociated reordered response IDs/text")
        let requests = await transport.requests
        try require(requests.count == 2 && requests[0].url?.path == "/api/tags", "Production provider did not use exactly one identity request and one batch request")
        let request = requests[1]
        guard request.url?.path == "/api/chat", request.httpMethod == "POST", let data = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = body["messages"] as? [[String: Any]], messages.count == 1,
              let prompt = messages[0]["content"] as? String,
              let schema = body["format"] as? [String: Any], let items = schema["items"] as? [String: Any],
              let ownerPairs = items["oneOf"] as? [[String: Any]] else {
            throw OwnershipFailure(message: "Production single batch lacks its JSON chat/schema envelope")
        }
        let bodyText = String(decoding: data, as: UTF8.self)
        try require(bodyText.contains(#""items":{"oneOf":["#),
                    "Production schema bytes no longer emit pair-bound owner alternatives")
        let repeatedBody = provider.orderedRequestBody(prompt: prompt, cues: owned, model: identity.model)
        try require(repeatedBody == data, "Production request bytes are not stable across identical construction")
        try require(schema["type"] as? String == "array" && schema["minItems"] as? Int == owned.count && schema["maxItems"] as? Int == owned.count, "Production schema does not require the exact owned row count")
        try require(ownerPairs.count == owned.count, "Production schema does not bind every owned cue pair")
        let boundPairs = try ownerPairs.map { pair -> (Int, String) in
            guard let properties = pair["properties"] as? [String: Any],
                  let idSchema = properties["cueId"] as? [String: Any],
                  let sourceSchema = properties["sourceEcho"] as? [String: Any],
                  let id = idSchema["const"] as? Int,
                  let source = sourceSchema["const"] as? String,
                  pair["additionalProperties"] as? Bool == false,
                  Set(pair["required"] as? [String] ?? []) == Set(["cueId", "sourceEcho", "text"]) else {
                throw OwnershipFailure(message: "Production pair schema permits an unbound owner")
            }
            return (id, source)
        }
        try require(boundPairs.map(\.0) == owned.map(\.id) && boundPairs.map(\.1) == owned.map(\.text),
                    "Production schema permits a cueId/sourceEcho cross-pair")
        try assertSourceAnchorPrompt(prompt)
        let tasks = try promptTasks(prompt)
        try require(tasks.map(\.cueId) == owned.map(\.id) && tasks.map(\.source) == owned.map(\.text),
                    "Production task block changed owned source identity")
        let documentPrefix = "DOCUMENT_CONTEXT (read-only): "
        guard let documentLine = prompt.components(separatedBy: "\n").first(where: { $0.hasPrefix(documentPrefix) }) else {
            throw OwnershipFailure(message: "Production document metadata is absent")
        }
        let document = try JSONDecoder().decode(String.self, from: Data(documentLine.dropFirst(documentPrefix.count).utf8))
        try require(document == owned[0].context!.document.replacingOccurrences(of: "\n", with: " "),
                    "Production prompt changed the document metadata instead of normalizing line breaks")
        for (task, cue) in zip(tasks, owned) {
            try require(task.contextBefore == cue.context!.before, "Production prompt changed source before-context")
            try require(task.contextAfter == cue.context!.after, "Production prompt changed source after-context")
        }
        try require(tasks[2].contextAfter.map(\.id) == [115, 708], "Single-batch fixture did not preserve in-batch overlap")
    }

    private static func verifyProductionBatchFailures() async throws {
        let config = configuration(Array(fixture().prefix(2)))
        let plan = try TranslationContextPlan(cues: config.cues, documentTitle: config.title, chunkSize: 2)
        let owned = plan.units[0].owned
        for failure in OwnershipBatchFailure.allCases {
            var ids = owned.map(\.id)
            switch failure {
            case .unexpectedID: ids[1] = 999
            case .duplicateID: ids[1] = ids[0]
            case .missingID: ids.removeLast()
            case .extraID: ids.append(999)
            default: break
            }
            let sourceByID = Dictionary(uniqueKeysWithValues: owned.map { ($0.id, $0.text) })
            let rows = ids.map {
                ["cueId": $0,
                 "sourceEcho": failure == .sourceEcho ? "Wrong source owner." : sourceByID[$0] ?? "Unexpected source.",
                 "text": "Scripted translation."] as [String: Any]
            }
            let content = String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
            let reply: Data
            if failure == .malformed { reply = Data("not JSON".utf8) }
            else {
                reply = try JSONSerialization.data(withJSONObject: [
                    "done": failure != .truncated, "done_reason": "stop", "message": ["content": content]
                ])
            }
            let transport = OwnershipBatchTransport(reply: reply, cancel: failure == .cancellation, fail: failure == .transport, urlCancel: failure == .urlCancellation)
            let provider = OllamaTranslationProvider(transport: { request in try await transport.respond(to: request) })
            let task = Task { try await provider.translate(cues: owned, source: .ru, target: .en, model: OllamaTranslationProvider.model, correction: nil) }
            var failed = false
            do { _ = try await task.value }
            catch {
                let expectedCancellation = failure == .cancellation || failure == .urlCancellation
                try require((error is CancellationError) == expectedCancellation, "Scripted batch failure/cancellation was misclassified")
                if failure == .transport {
                    guard let workflowError = error as? WorkflowError, case .topicServiceUnavailable = workflowError else {
                        throw OwnershipFailure(message: "Injected transport error bypassed production service-error normalization")
                    }
                }
                failed = true
            }
            try require(failed, "\(failure.rawValue) production batch published an invalid response")
            let requests = await transport.requests
            let expectedRequests = failure == .sourceEcho ? 2 : 1
            try require(requests.count == expectedRequests && requests.allSatisfy { $0.url?.path == "/api/chat" },
                        "Failed production batch made an unexpected ownership-recovery request")
        }
    }

    private static func verifyProductionSourceEchoCorrectionRetry() async throws {
        let config = configuration(Array(fixture().prefix(2)))
        let plan = try TranslationContextPlan(cues: config.cues, documentTitle: config.title, chunkSize: 2)
        let owned = plan.units[0].owned
        let incorrectRows: [[String: Any]] = owned.enumerated().map { index, cue in
            [
                "cueId": cue.id,
                "sourceEcho": index == 0 ? cue.text + " altered" : cue.text,
                "text": "Scripted translation \(cue.id)."
            ]
        }
        let correctedRows: [[String: Any]] = owned.map { cue in
            ["cueId": cue.id, "sourceEcho": cue.text, "text": "Scripted translation \(cue.id)."]
        }
        func reply(_ rows: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "done": true,
                "done_reason": "stop",
                "message": ["content": String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)]
            ])
        }
        let transport = OwnershipCorrectionTransport(replies: [try reply(incorrectRows), try reply(correctedRows)])
        let provider = OllamaTranslationProvider(transport: { request in try await transport.respond(to: request) })
        let response = try await provider.translate(
            cues: owned,
            source: .ru,
            target: .en,
            model: OllamaTranslationProvider.model,
            correction: nil
        )
        try require(response.keys.sorted() == owned.map(\.id).sorted(),
                    "corrected sourceEcho response lost cue ownership")
        let requests = await transport.requests
        try require(requests.count == 2, "sourceEcho recovery exceeded one bounded subbatch retry")
        guard let correctionBody = requests[1].httpBody,
              let correctionRoot = try JSONSerialization.jsonObject(with: correctionBody) as? [String: Any],
              let correctionPrompt = ((correctionRoot["messages"] as? [[String: Any]])?.first?["content"] as? String) else {
            throw OwnershipFailure(message: "sourceEcho correction request lacks prompt")
        }
        try require(correctionPrompt.contains("PREVIOUS RESPONSE REJECTED")
                    && correctionPrompt.contains("sourceEcho for cueId [\(owned[0].id)] was altered")
                    && correctionPrompt.contains("byte-for-byte exactly"),
                    "sourceEcho correction was not explicit or bounded to the failed owner")
        let correctionTasks = try promptTasks(correctionPrompt)
        try require(correctionTasks.map(\.cueId) == owned.map(\.id)
                    && correctionTasks.map(\.source) == owned.map(\.text),
                    "sourceEcho correction changed owned source inputs")
    }

    private static func verifySparseContextPrompt() throws {
        let config = configuration()
        let plan = try TranslationContextPlan(cues: config.cues, documentTitle: config.title, chunkSize: 5)
        let pending = plan.units[0].owned.filter { $0.id == 7 || $0.id == 13 }
        let prompt = OllamaTranslationProvider().translationPrompt(cues: pending, source: .ru, target: .en, correction: nil)
        let tasks = try promptTasks(prompt)
        try require(tasks.map(\.cueId) == pending.map(\.id), "Sparse prompt task IDs do not identify exactly the pending owners")
        for (task, request) in zip(tasks, pending) {
            try require(task.source == request.text, "Sparse retry changed an owner's source")
            try require(task.contextBefore == request.context!.before, "Sparse retry changed an owner's before-context IDs/order/text")
            try require(task.contextAfter == request.context!.after, "Sparse retry changed an owner's after-context IDs/order/text")
        }
        try require(tasks[0].contextAfter.map(\.id) == [92, 13] && tasks[1].contextBefore.map(\.id) == [7, 92],
                    "Sparse tasks lost overlapping current owners as read-only context")
    }

    private static func verifyOutputBudget() throws {
        let provider = OllamaTranslationProvider()
        let tiny = (0..<32).map { TranslationRequestCue(id: $0, text: "x", context: nil) }
        try require(provider.outputBudget(for: tiny) >= 3232, "Thirty-two tiny owned rows lack source-echo envelope budget")
        try require(provider.outputBudget(for: Array(tiny.prefix(1))) == 256, "Output budget lost its minimum")
        let medium = (0..<4).map { TranslationRequestCue(id: $0, text: String(repeating: "x", count: 100), context: nil) }
        try require(provider.outputBudget(for: medium) == 2384, "Output budget omitted source echo, text or per-row envelope overhead")
        let large = [TranslationRequestCue(id: 41, text: String(repeating: "x", count: 3000), context: nil)]
        try require(provider.outputBudget(for: large) == 4096, "Output budget lost its default maximum")
    }

    private static func verifyAdaptiveRequestBatches() throws {
        let provider = OllamaTranslationProvider()
        let requests = (0..<32).map { index in
            TranslationRequestCue(
                id: 1_000 + index,
                text: "Owned cue \(index) " + String(repeating: "content ", count: 24),
                context: TranslationCueContext(
                    document: "Timecoded spoken transcript.",
                    before: index == 0 ? [] : [TranslationContextCue(id: 999 + index, text: String(repeating: "before ", count: 20))],
                    after: index == 31 ? [] : [TranslationContextCue(id: 1_001 + index, text: String(repeating: "after ", count: 20))]
                )
            )
        }
        let batches = try provider.ownershipBatches(
            cues: requests, source: .en, target: .ru, model: OllamaTranslationProvider.model, correction: nil
        )
        try require(batches.count > 1, "Oversized execution input was not split before the model context limit")
        try require(batches.flatMap { $0.map(\.id) } == requests.map(\.id),
                    "Adaptive batching changed cue ownership/order/coverage")
        for batch in batches {
            let estimate = provider.estimatedContextTokens(
                cues: batch, source: .en, target: .ru, model: OllamaTranslationProvider.model, correction: nil
            )
            try require(estimate <= 7_936, "Adaptive batch exceeded the context safety budget")
        }

        let oversized = [TranslationRequestCue(id: 9_999, text: String(repeating: "x", count: 30_000), context: nil)]
        var rejected = false
        do {
            _ = try provider.ownershipBatches(
                cues: oversized, source: .en, target: .ru, model: OllamaTranslationProvider.model, correction: nil
            )
        } catch let error as WorkflowError {
            guard case let .processFailed(message) = error else { throw error }
            rejected = message.contains("Human Review")
        }
        try require(rejected, "A single oversized owner was not rejected explicitly for Human Review")
    }

    private static func verifyCorrectionAdaptiveRequestBatches() throws {
        let provider = OllamaTranslationProvider()
        let requests = (0..<11).map { index in
            TranslationRequestCue(
                id: 2_000 + index,
                text: "Owned cue \(index) " + String(repeating: "content ", count: 34),
                context: TranslationCueContext(
                    document: "Timecoded spoken transcript.",
                    before: [TranslationContextCue(id: 1_900 + index, text: String(repeating: "before ", count: 24))],
                    after: [TranslationContextCue(id: 2_100 + index, text: String(repeating: "after ", count: 24))]
                )
            )
        }
        let correction = TranslationOwnershipResponseError.sourceEchoMismatch(cueIDs: [requests[4].id]).correction
        let batches = try provider.ownershipBatches(
            cues: requests,
            source: .ru,
            target: .en,
            model: OllamaTranslationProvider.model,
            correction: correction
        )
        try require(batches.flatMap { $0.map(\.id) } == requests.map(\.id),
                    "sourceEcho correction changed cue ownership/order")
        for batch in batches {
            try require(
                provider.estimatedContextTokens(
                    cues: batch,
                    source: .ru,
                    target: .en,
                    model: OllamaTranslationProvider.model,
                    correction: correction
                ) <= 7_936,
                "sourceEcho correction batch exceeded the context safety budget"
            )
        }
        let baseline = provider.translationPrompt(cues: requests, source: .ru, target: .en, correction: nil)
        let corrected = provider.translationPrompt(cues: requests, source: .ru, target: .en, correction: correction)
        try require(corrected != baseline && corrected.contains("PREVIOUS RESPONSE REJECTED"),
                    "sourceEcho correction did not materially change the retry prompt")
    }

    private static func verifyCheckpointWriteFailure(directory: URL) async throws {
        let bytes = Data("regular file, not a checkpoint directory".utf8)
        try bytes.write(to: directory, options: .atomic)
        let config = configuration(Array(fixture().prefix(3)))
        let provider = OwnershipProvider(identity: config.identity)
        var failed = false
        do {
            _ = try await run(config, provider: provider, directory: directory)
        } catch let error as WorkflowError {
            guard case let .processFailed(message) = error else { throw error }
            try require(message.localizedCaseInsensitiveContains("checkpoint"), "Filesystem failure was not diagnosed as a checkpoint failure")
            try require(!message.contains("provider-error"), "Checkpoint filesystem failure was mislabeled as a provider error")
            failed = true
        }
        try require(failed, "Checkpoint write failure published a ready adapter result")
        let calls = await provider.calls
        try require(calls.map { $0.map(\.id) } == [config.cues.map(\.id)], "Checkpoint write failure retried an already successful provider response")
        let unchanged = try Data(contentsOf: directory)
        try require(unchanged == bytes, "Checkpoint write failure modified the conflicting regular file")
    }

    private static func verifyNeutralTokens() async throws {
        let texts = ["2026", "2026 1250 15", "2026 1250 15 09:30 2.5 100 200 300 400 500 600",
                     "WorkflowEngine", "FFmpeg large-v3", "WorkflowEngine FFmpeg large-v3 ffprobe whisper"]
        for target in [ArtifactLanguage.en, .ru] {
            let source: ArtifactLanguage = target == .en ? .ru : .en
            for text in texts {
                let config = configuration([SubtitleCue(id: 77, start: 0.125, end: 1.375, text: text)])
                let provider = OwnershipProvider(identity: config.identity, behavior: .fixedText(text))
                let result = try await run(config, provider: provider, source: source, target: target)
                let calls = await provider.calls
                try assertAlignment(result, source: config.cues)
                try require(result.issues.isEmpty, "Legitimate neutral tokens were rejected for \(target.rawValue): \(text); issues=\(result.issues)")
                try require(result.cues[0].text == text && calls.count == 1, "Neutral tokens were changed or unnecessarily retried")
            }
        }
        for (text, output, reason) in [("2026", "2027", "numbers-changed"),
                                        ("WorkflowEngine", "WorkflowManager", "protected-term-changed-workflowengine")] {
            let config = configuration([SubtitleCue(id: 77, start: 0.125, end: 1.375, text: text)])
            let provider = OwnershipProvider(identity: config.identity, behavior: .fixedText(output))
            let result = try await run(config, provider: provider)
            let calls = await provider.calls
            try require(result.issues.count == 1 && result.issues[0].reasonCodes.contains(reason), "Neutral-token exception permitted \(reason)")
            try require(calls.count == 2, "Changed neutral token did not exhaust isolated retries")
        }
    }

    private static func verifyInvalidation(directory: URL) async throws {
        var source = fixture()
        source[0].text = "Opening excerpt " + String(repeating: "x", count: 760)
        var base = configuration(source)
        base.identity.protocolVersion = "translategemma-booktext-owned-cues-v5-docmeta512-lineage2-overlap2x600-source-anchor1-ctx8k"
        let seed = OwnershipProvider(identity: base.identity)
        try assertSuccessful(try await run(base, provider: seed, directory: directory), source: source)
        let unchanged = OwnershipProvider(identity: base.identity)
        _ = try await run(base, provider: unchanged, directory: directory)
        let unchangedCalls = await unchanged.calls
        try require(unchangedCalls.isEmpty, "Unchanged input invalidated its checkpoint")

        var cases: [(String, OwnershipConfiguration)] = []
        var changed = base
        changed.title = "Changed document metadata"
        cases.append(("document-title", changed))
        for path in ["/ownership-fixture/Revised Archive/Track A/recording.mp4", "/ownership-fixture/Archive Sessions/Track B/recording.mp4"] {
            changed = base
            changed.title = TranslationContextPlan.documentTitle(for: URL(fileURLWithPath: path))
            let baselinePlan = try TranslationContextPlan(cues: base.cues, documentTitle: base.title, chunkSize: 3)
            let changedPlan = try TranslationContextPlan(cues: changed.cues, documentTitle: changed.title, chunkSize: 3)
            try require(changedPlan.contextIdentity != baselinePlan.contextIdentity, "Changed source ancestor did not invalidate context identity")
            cases.append(("source-ancestor-\(path)", changed))
        }
        changed = base
        changed.cues[3].text = "Revised owned sentence."
        cases.append(("owned-source-content", changed))
        changed = base
        changed.cues[4].text = "Revised overlap sentence."
        let originalPlan = try TranslationContextPlan(cues: base.cues, documentTitle: base.title, chunkSize: 3)
        let overlapPlan = try TranslationContextPlan(cues: changed.cues, documentTitle: changed.title, chunkSize: 3)
        let originalTarget = originalPlan.units.flatMap(\.owned)[3]
        let changedTarget = overlapPlan.units.flatMap(\.owned)[3]
        try require(originalTarget.text == changedTarget.text && originalTarget.context?.document == changedTarget.context?.document, "Overlap fixture changed target/document rather than only its neighbor")
        try require(originalTarget.context?.after != changedTarget.context?.after, "Overlap fixture did not change target context")
        cases.append(("overlap-context", changed))
        changed = base
        changed.identity.digest = "verified-mock-digest-b"
        cases.append(("model-digest", changed))
        changed = base
        changed.identity.model = "ownership-mock-b"
        cases.append(("model-name", changed))
        changed = base
        changed.identity.protocolVersion = OllamaTranslationProvider.protocolVersion
        cases.append(("v5-to-v7-pair-schema-protocol", changed))
        changed = base
        changed.sourceIdentity = "source-revision-b"
        cases.append(("source-identity", changed))
        changed = base
        changed.cues[2].start += 0.25
        cases.append(("source-timestamp", changed))
        for (name, config) in cases {
            let provider = OwnershipProvider(identity: config.identity)
            let result = try await run(config, provider: provider, directory: directory)
            let calls = await provider.calls
            try assertSuccessful(result, source: config.cues)
            try require(result.protocolVersion == config.identity.protocolVersion, "Changed \(name) lost its current protocol provenance")
            let plan = try TranslationContextPlan(cues: config.cues, documentTitle: config.title, chunkSize: 3)
            try require(calls.map { $0.map(\.id) } == plan.units.map { $0.owned.map(\.id) }, "Changed \(name) reused stale checkpoints")
        }
        let restored = OwnershipProvider(identity: base.identity)
        _ = try await run(base, provider: restored, directory: directory)
        let restoredCalls = await restored.calls
        try require(restoredCalls.isEmpty, "Invalidation destroyed reusable unchanged input checkpoints")
    }

    private static func checkpointStore(_ config: OwnershipConfiguration, plan: TranslationContextPlan, directory: URL) throws -> TranslationCheckpointStore {
        try TranslationCheckpointStore(directory: directory, plan: plan, identity: config.identity, source: .ru, target: .en, sourceIdentity: config.sourceIdentity)
    }

    private static func verifyCheckpointCorruption(directory: URL) async throws {
        let config = configuration(Array(fixture().prefix(3)))
        let plan = try TranslationContextPlan(cues: config.cues, documentTitle: config.title, chunkSize: 3)
        let store = try checkpointStore(config, plan: plan, directory: directory)
        let seed = OwnershipProvider(identity: config.identity)
        _ = try await run(config, provider: seed, directory: directory)
        let url = directory.appendingPathComponent(store.runIdentity, isDirectory: true).appendingPathComponent("unit-0.json")
        let original = try Data(contentsOf: url)
        try require(store.load(plan.units[0]).count == config.cues.count, "Corruption fixture did not create a complete checkpoint")

        for mutation in OwnershipCheckpointMutation.allCases {
            let corrupted: Data
            if mutation == .invalidJSON {
                corrupted = Data("not a checkpoint".utf8)
            } else {
                guard var record = try JSONSerialization.jsonObject(with: original) as? [String: Any],
                      var entries = record["entries"] as? [[String: Any]] else {
                    throw OwnershipFailure(message: "Checkpoint fixture has an unexpected JSON shape")
                }
                switch mutation {
                case .invalidJSON: throw OwnershipFailure(message: "Unreachable checkpoint mutation")
                case .schema: record["schemaVersion"] = 999
                case .identity: record["runIdentity"] = "wrong-run"
                case .ownedIDs: record["ownedIDs"] = config.cues.map(\.id).reversed().map { $0 }
                case .changedText: entries[0]["text"] = "Tampered output."
                case .missingHash: record.removeValue(forKey: "entriesHash")
                case .duplicateEntry:
                    entries[1] = entries[0]
                    record["entriesHash"] = try entryHash(entries)
                case .outOfOrder:
                    entries.swapAt(0, 1)
                    record["entriesHash"] = try entryHash(entries)
                case .contextOnlyEntry:
                    entries[0]["cueID"] = 999
                    record["entriesHash"] = try entryHash(entries)
                case .invalidTextWithValidHash:
                    entries[0]["text"] = ""
                    record["entriesHash"] = try entryHash(entries)
                }
                record["entries"] = entries
                corrupted = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            }
            try corrupted.write(to: url, options: .atomic)
            let provider = OwnershipProvider(identity: config.identity)
            let result = try await run(config, provider: provider, directory: directory)
            let calls = await provider.calls
            try assertSuccessful(result, source: config.cues)
            try require(calls.map { $0.map(\.id) } == [config.cues.map(\.id)], "\(mutation.rawValue) checkpoint falsely reused cached output")
            try require(store.load(plan.units[0]).count == config.cues.count, "Invalid checkpoint was not repaired after recomputation")
        }
        try assertNoPartialFiles(directory)
    }

    private static func entryHash(_ entries: [[String: Any]]) throws -> String {
        let typed = try JSONDecoder().decode([TranslationCheckpointEntry].self, from: JSONSerialization.data(withJSONObject: entries))
        return try TranslationFingerprint.value(typed)
    }

    private static func assertNoPartialFiles(_ directory: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw OwnershipFailure(message: "Checkpoint directory was not created")
        }
        let files = enumerator.allObjects.compactMap { $0 as? URL }
        try require(!files.contains { $0.lastPathComponent.contains(".partial.") }, "Checkpoint write left a partial file")
    }

    private static func verifyReportCompatibilityAndResume(directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let media = directory.appendingPathComponent("source.mp4")
        try Data("synthetic media placeholder".utf8).write(to: media)
        let project = directory.appendingPathComponent("project", isDirectory: true)
        let store = ProjectStore(history: ProjectHistoryStore(indexURL: directory.appendingPathComponent("history.json")))
        var manifest = try store.ensureProject(at: project, mediaURL: media, mode: .newProject)
        let layout = ProjectLayout(root: project)
        let machineSubtitle = Data("7\n00:00:00,125 --> 00:00:01,375\nMachine translation.\n".utf8)
        let machineTranscript = Data("Machine translation.\n".utf8)
        let machine = resumeRevision(id: "machine-target", parent: "source-revision-a", origin: .translated)
        try writeResumeFiles(subtitle: machineSubtitle, transcript: machineTranscript, revision: machine, layout: layout)
        manifest.transcriptRevisions = [machine]
        var state = HumanReviewState.newProjectDefault
        state.activeRevisionIDs[ArtifactLanguage.en.rawValue] = machine.id
        manifest.humanReviewState = state

        let identity = mockIdentity()
        let report = TranslationReport(
            schemaVersion: 3, sourceRevisionID: "source-revision-a", targetRevisionID: machine.id,
            sourceLanguage: .ru, targetLanguage: .en, model: identity.model,
            modelDigest: identity.digest, protocolVersion: identity.protocolVersion,
            translatedAt: Date(timeIntervalSince1970: 0), cueCount: 1, reviewTaskIDs: [], status: .ready,
            contextIdentity: "semantic-context-a", subtitleSHA256: TranslationFingerprint.data(machineSubtitle),
            transcriptSHA256: TranslationFingerprint.data(machineTranscript)
        )
        let legacy: [String: Any] = [
            "schemaVersion": 2, "sourceRevisionID": "source-revision-a", "targetRevisionID": machine.id,
            "sourceLanguage": "ru", "targetLanguage": "en", "model": identity.model,
            "translatedAt": "1970-01-01T00:00:00Z", "cueCount": 1, "reviewTaskIDs": [], "status": "ready"
        ]
        let oldReport = try store.decoder.decode(TranslationReport.self, from: JSONSerialization.data(withJSONObject: legacy))
        try require(oldReport.schemaVersion == 2 && oldReport.targetRevisionID == machine.id, "Legacy report fields did not decode")
        try require(oldReport.contextIdentity == nil && oldReport.subtitleSHA256 == nil && oldReport.transcriptSHA256 == nil, "Legacy report invented new provenance")
        try require(oldReport.modelDigest == nil && oldReport.protocolVersion == nil, "Legacy optional identity fields were not preserved")
        try require(!TranslationResumeValidator.outputsMatch(report: oldReport, manifest: manifest, layout: layout), "Legacy report falsely authorized schema-3 output reuse")
        try require(TranslationResumeValidator.outputsMatch(report: report, manifest: manifest, layout: layout), "Matching machine output hashes were rejected")
        try Data("tampered machine subtitle".utf8).write(to: layout.subtitlesURL(language: .en), options: .atomic)
        try require(!TranslationResumeValidator.outputsMatch(report: report, manifest: manifest, layout: layout), "Tampered machine subtitle was reused")
        try machineSubtitle.write(to: layout.subtitlesURL(language: .en), options: .atomic)
        try Data("tampered machine transcript".utf8).write(to: layout.transcriptURL(language: .en), options: .atomic)
        try require(!TranslationResumeValidator.outputsMatch(report: report, manifest: manifest, layout: layout), "Tampered machine transcript was reused")
        try machineTranscript.write(to: layout.transcriptURL(language: .en), options: .atomic)

        let editedSubtitle = Data("7\n00:00:00,125 --> 00:00:01,375\nHuman edited translation.\n".utf8)
        let editedTranscript = Data("Human edited translation.\n".utf8)
        for (id, subtitle, transcript) in [("approved-unmodified", machineSubtitle, machineTranscript),
                                           ("approved-edited", editedSubtitle, editedTranscript)] {
            var draft = resumeRevision(id: "\(id)-draft", parent: machine.id, origin: .userEdited)
            draft.reviewStatus = .draft
            let active = resumeRevision(id: id, parent: draft.id, origin: .userEdited)
            try writeResumeFiles(subtitle: subtitle, transcript: transcript, revision: active, layout: layout)
            manifest.transcriptRevisions = [machine, draft, active]
            state.activeRevisionIDs[ArtifactLanguage.en.rawValue] = active.id
            manifest.humanReviewState = state
            let oldHash = StableTopicHash.string(String(decoding: subtitle, as: UTF8.self))
            try require(oldHash != StableTopicHash.string(String(decoding: transcript, as: UTF8.self)), "Human fixture does not exercise the historical artifact-hash mismatch")
            manifest.artifacts = [
                resumeArtifact(revision: active, kind: .transcript, path: layout.transcriptRevisionURL(id: active.id, language: .en), oldHash: oldHash),
                resumeArtifact(revision: active, kind: .subtitles, path: layout.subtitleRevisionURL(id: active.id, language: .en), oldHash: oldHash)
            ]
            try store.save(manifest, to: project)
            manifest = try store.load(from: project)
            try require(TranslationResumeValidator.outputsMatch(report: report, manifest: manifest, layout: layout), "\(id) descendant was rejected despite immutable matching bytes")
            try Data("tampered human subtitle".utf8).write(to: layout.subtitlesURL(language: .en), options: .atomic)
            try require(!TranslationResumeValidator.outputsMatch(report: report, manifest: manifest, layout: layout), "\(id) tampered working subtitle was reused")
            try subtitle.write(to: layout.subtitlesURL(language: .en), options: .atomic)
            try Data("tampered human transcript".utf8).write(to: layout.transcriptURL(language: .en), options: .atomic)
            try require(!TranslationResumeValidator.outputsMatch(report: report, manifest: manifest, layout: layout), "\(id) tampered working transcript was reused")
            try transcript.write(to: layout.transcriptURL(language: .en), options: .atomic)
            let immutableTranscript = layout.transcriptRevisionURL(id: active.id, language: .en)
            try Data("tampered immutable transcript".utf8).write(to: immutableTranscript, options: .atomic)
            try require(!TranslationResumeValidator.outputsMatch(report: report, manifest: manifest, layout: layout), "\(id) tampered immutable revision was reused")
            try transcript.write(to: immutableTranscript, options: .atomic)
            try require(TranslationResumeValidator.outputsMatch(report: report, manifest: manifest, layout: layout), "\(id) restored immutable bytes were rejected")
        }
        let unrelated = resumeRevision(id: "unrelated-approved", parent: "unrelated-parent", origin: .userEdited)
        try writeResumeFiles(subtitle: machineSubtitle, transcript: machineTranscript, revision: unrelated, layout: layout)
        manifest.transcriptRevisions = [machine, unrelated]
        state.activeRevisionIDs[ArtifactLanguage.en.rawValue] = unrelated.id
        manifest.humanReviewState = state
        try require(!TranslationResumeValidator.outputsMatch(report: report, manifest: manifest, layout: layout), "Unrelated approved revision falsely inherited machine provenance")
    }

    private static func resumeRevision(id: String, parent: String, origin: TranscriptRevisionOrigin) -> TranscriptRevision {
        TranscriptRevision(id: id, language: .en, origin: origin, parentRevisionID: parent,
                           transcriptArtifactID: "artifact-\(id)-txt", subtitleArtifactID: "artifact-\(id)-srt",
                           contentHash: nil, createdAt: Date(timeIntervalSince1970: 0), reviewStatus: .approved)
    }

    private static func writeResumeFiles(subtitle: Data, transcript: Data, revision: TranscriptRevision, layout: ProjectLayout) throws {
        try subtitle.write(to: layout.subtitlesURL(language: .en), options: .atomic)
        try transcript.write(to: layout.transcriptURL(language: .en), options: .atomic)
        try subtitle.write(to: layout.subtitleRevisionURL(id: revision.id, language: .en), options: .atomic)
        try transcript.write(to: layout.transcriptRevisionURL(id: revision.id, language: .en), options: .atomic)
    }

    private static func resumeArtifact(revision: TranscriptRevision, kind: ProjectArtifactRecordKind, path: URL, oldHash: String) -> ProjectArtifactRecord {
        ProjectArtifactRecord(
            id: kind == .transcript ? revision.transcriptArtifactID : revision.subtitleArtifactID,
            kind: kind, path: path.path, language: .en, origin: .userEdited, granularity: nil,
            sourceArtifactID: nil, sourceRevision: revision.id, dependencyIDs: [revision.parentRevisionID].compactMap { $0 },
            contentHash: oldHash, createdAt: Date(timeIntervalSince1970: 0), generator: "ownership-probe",
            generatorVersion: "test", model: "human-review", validationStatus: .ready,
            qualityStatus: .ready, reviewTaskCount: 0
        )
    }
}

private struct OwnershipConfiguration {
    var cues: [SubtitleCue]
    var title: String?
    var sourceIdentity: String?
    var identity: TranslationModelIdentity
}

private enum OwnershipCheckpointMutation: String, CaseIterable {
    case invalidJSON, schema, identity, ownedIDs, changedText, missingHash
    case duplicateEntry, outOfOrder, contextOnlyEntry, invalidTextWithValidHash
}

private enum OwnershipBatchFailure: String, CaseIterable {
    case transport, malformed, truncated, unexpectedID, duplicateID, missingID, extraID, sourceEcho, cancellation, urlCancellation
}

private actor OwnershipBatchTransport {
    nonisolated static let digest = "verified-scripted-http-digest"
    private let reply: Data
    private let cancelReply: Bool
    private let failReply: Bool
    private let urlCancelReply: Bool
    private var chatCalls = 0
    private(set) var requests: [URLRequest] = []

    init(reply: Data, cancel: Bool = false, fail: Bool = false, urlCancel: Bool = false) {
        self.reply = reply
        cancelReply = cancel
        failReply = fail
        urlCancelReply = urlCancel
    }

    func respond(to request: URLRequest) throws -> Data {
        requests.append(request)
        if request.url?.path == "/api/tags", request.httpMethod != "POST" {
            return try JSONSerialization.data(withJSONObject: ["models": [[
                "name": OllamaTranslationProvider.model, "model": OllamaTranslationProvider.model,
                "digest": Self.digest
            ]]])
        }
        guard request.url?.path == "/api/chat", request.httpMethod == "POST" else {
            throw OwnershipFailure(message: "Unexpected request to single-batch scripted HTTP transport")
        }
        chatCalls += 1
        if failReply { throw URLError(.badServerResponse) }
        if urlCancelReply { throw URLError(.cancelled) }
        if cancelReply { withUnsafeCurrentTask { $0?.cancel() } }
        return reply
    }
}

private actor OwnershipCorrectionTransport {
    private let replies: [Data]
    private var nextReply = 0
    private(set) var requests: [URLRequest] = []

    init(replies: [Data]) { self.replies = replies }

    func respond(to request: URLRequest) throws -> Data {
        requests.append(request)
        guard request.url?.path == "/api/chat", request.httpMethod == "POST",
              replies.indices.contains(nextReply) else {
            throw OwnershipFailure(message: "Unexpected sourceEcho correction request")
        }
        defer { nextReply += 1 }
        return replies[nextReply]
    }
}

private actor OwnershipProvider: TranslationAIProvider {
    enum Behavior {
        case valid
        case extraOnce(target: Int, extra: Int)
        case missingOnce(target: Int)
        case emptyOnce(target: Int)
        case alwaysEmpty(target: Int)
        case throwOnCallOnce(Int)
        case throwOwnershipMismatch
        case cancelOnCall(Int, throwError: Bool)
        case fixedText(String)
        case scriptedOutputs([Int: String])
    }

    let identity: TranslationModelIdentity
    let behavior: Behavior
    private(set) var calls: [[TranslationRequestCue]] = []
    private var failureSent = false

    init(identity: TranslationModelIdentity, behavior: Behavior = .valid) {
        self.identity = identity
        self.behavior = behavior
    }

    nonisolated static func output(_ text: String) -> String { "Owned translation: \(text)" }
    func preferredModel() async throws -> String { identity.model }
    func preferredIdentity() async throws -> TranslationModelIdentity { identity }

    func translate(cues: [TranslationRequestCue], source: ArtifactLanguage, target: ArtifactLanguage, model: String, correction: String?) async throws -> [Int: String] {
        calls.append(cues)
        guard !cues.isEmpty, Set(cues.map(\.id)).count == cues.count else {
            throw OwnershipFailure(message: "Provider received empty or duplicate owned cues")
        }
        var response = Dictionary(uniqueKeysWithValues: cues.map { ($0.id, Self.output($0.text)) })
        switch behavior {
        case .valid: break
        case let .extraOnce(target, extra):
            if response[target] != nil && !failureSent {
                failureSent = true
                response[extra] = "Context-only output must be rejected."
            }
        case let .missingOnce(target):
            if response[target] != nil && !failureSent {
                failureSent = true
                response.removeValue(forKey: target)
            }
        case let .emptyOnce(target):
            if response[target] != nil && !failureSent {
                failureSent = true
                response[target] = ""
            }
        case let .alwaysEmpty(target):
            if response[target] != nil { response[target] = "" }
        case let .throwOnCallOnce(number):
            if calls.count == number { throw OwnershipFailure(message: "Provider failed the complete owned unit") }
        case .throwOwnershipMismatch:
            throw TranslationOwnershipResponseError.sourceEchoMismatch(cueIDs: cues.map(\.id))
        case let .cancelOnCall(number, throwError):
            if calls.count == number {
                withUnsafeCurrentTask { $0?.cancel() }
                if throwError { throw OwnershipFailure(message: "Provider error after cancellation") }
            }
        case let .fixedText(text):
            for cue in cues { response[cue.id] = text }
        case let .scriptedOutputs(outputs):
            for cue in cues {
                guard let output = outputs[cue.id] else {
                    throw OwnershipFailure(message: "Scripted source-anchor fixture lacks an owned response")
                }
                response[cue.id] = output
            }
        }
        return response
    }
}

private struct OwnershipFailure: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}
