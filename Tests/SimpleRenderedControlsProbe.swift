import AppKit
import SwiftUI

private struct RenderedProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

// SwiftUI's rendered AccessibilityNode objects implement modern AX selectors
// without necessarily declaring NSAccessibilityProtocol conformance.
@MainActor
private struct RenderedAXElement {
    let object: NSObject

    private var modern: NSAccessibilityProtocol? { object as? NSAccessibilityProtocol }

    private func objectValue(_ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private func boolValue(_ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector),
              let implementation = object.method(for: selector) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> ObjCBool
        let getter = unsafeBitCast(implementation, to: Getter.self)
        return getter(object, selector).boolValue
    }

    var selectorDiagnostics: String {
        ["accessibilityChildren", "accessibilityIdentifier", "accessibilityRole",
         "accessibilityLabel", "accessibilityTitle", "accessibilityValue",
         "accessibilityFrame", "isAccessibilityEnabled", "accessibilityPerformPress"]
            .map { "\($0)=\(object.responds(to: NSSelectorFromString($0)))" }
            .joined(separator: ",")
    }

    func accessibilityChildren() -> [Any]? {
        if let modern { return modern.accessibilityChildren() }
        return objectValue("accessibilityChildren") as? [Any]
    }

    func accessibilityIdentifier() -> String? {
        if let modern { return modern.accessibilityIdentifier() }
        return objectValue("accessibilityIdentifier") as? String
    }

    func accessibilityRole() -> NSAccessibility.Role? {
        if let modern { return modern.accessibilityRole() }
        let value = objectValue("accessibilityRole")
        if let role = value as? NSAccessibility.Role { return role }
        return (value as? String).map { NSAccessibility.Role(rawValue: $0) }
    }

    func accessibilityLabel() -> String? {
        let label = modern?.accessibilityLabel() ?? objectValue("accessibilityLabel") as? String
        return label?.isEmpty == false ? label : accessibilityTitle()
    }

    func accessibilityTitle() -> String? {
        if let modern { return modern.accessibilityTitle() }
        return objectValue("accessibilityTitle") as? String
    }

    func accessibilityValue() -> Any? {
        if let modern { return modern.accessibilityValue() }
        return objectValue("accessibilityValue")
    }

    func accessibilityFrame() -> NSRect {
        if let modern { return modern.accessibilityFrame() }
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector),
              let implementation = object.method(for: selector) else { return .zero }
        // A typed C function preserves the native struct-return ABI for NSRect.
        typealias Getter = @convention(c) (AnyObject, Selector) -> NSRect
        let getter = unsafeBitCast(implementation, to: Getter.self)
        return getter(object, selector)
    }

    func isAccessibilityEnabled() -> Bool {
        if let modern { return modern.isAccessibilityEnabled() }
        return boolValue("isAccessibilityEnabled")
    }

    func accessibilityPerformPress() -> Bool {
        if let modern { return modern.accessibilityPerformPress() }
        return boolValue("accessibilityPerformPress")
    }
}

@main
@MainActor
struct SimpleRenderedControlsProbe {
    static func main() {
        do {
            try run()
            print("SIMPLE_RENDERED_CONTROLS_PROBE_PASS")
        } catch {
            fputs("SIMPLE_RENDERED_CONTROLS_PROBE_FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw RenderedProbeFailure(message: message) }
    }

    private static func run() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("simple-rendered-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let environment = ProcessInfo.processInfo.environment
        let retainedRoot = environment["VIDEOTEXT_UI_FIXTURE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let media = scratch.appendingPathComponent("source.mp4")
        if let path = environment["VIDEOTEXT_UI_FIXTURE_MEDIA"] {
            try fm.copyItem(at: URL(fileURLWithPath: path), to: media)
        } else {
            try require(retainedRoot == nil, "Retained Candidate fixture requires VIDEOTEXT_UI_FIXTURE_MEDIA with real short media")
            // No media player or cue editor is opened by this controls-only probe.
            try Data("controls-only fixture; not real media".utf8).write(to: media)
        }
        if let root = retainedRoot {
            let marker = root.appendingPathComponent("issue17-fixture.json")
            if fm.fileExists(atPath: root.path) {
                try require(fm.fileExists(atPath: marker.path), "Refusing to overwrite an existing unowned fixture directory")
                for source in [ArtifactLanguage.ru, .en] {
                    let project = root.appendingPathComponent("\(source.rawValue)-source")
                    let manifest = try ProjectStore().load(from: project)
                    try require(manifest.humanReviewState?.pendingCheckpoint == nil, "Retained fixture has an unfinished review; preserve and inspect it")
                    try require(manifest.activeTranscriptRevision(for: source)?.reviewStatus == .approved, "Retained fixture source is not approved")
                    try require(manifest.activeTranscriptRevision(for: source.translationTarget)?.reviewStatus == .approved, "Retained fixture translation is not approved")
                }
                print("RETAINED_FIXTURE_REUSED: \(root.path)")
            } else {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                let retainedMedia = root.appendingPathComponent("source.mp4")
                try fm.copyItem(at: media, to: retainedMedia)
                for source in [ArtifactLanguage.ru, .en] {
                    _ = try makeProject(root.appendingPathComponent("\(source.rawValue)-source"), media: retainedMedia, source: source)
                }
                let record: [String: Any] = ["schemaVersion": 1, "purpose": "Issue17 approved native UI fixture", "mediaPath": retainedMedia.path]
                try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: marker)
                print("RETAINED_FIXTURE_CREATED: \(root.path)")
            }
            print("CANDIDATE_PROJECT: \(root.appendingPathComponent("ru-source").path)")
        }
        if CommandLine.arguments.contains("--prepare-fixture") {
            try require(retainedRoot != nil, "--prepare-fixture requires VIDEOTEXT_UI_FIXTURE_ROOT")
            return
        }
        try verifyTranscriptionPresentation()
        try verifyTranslationPresentation()
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        NSApplication.shared.accessibilitySetValue(
            NSNumber(value: true),
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
        try verifyCreationControls(project: scratch.appendingPathComponent("new-source"), media: media)
        try verifyTopicControls(project: scratch.appendingPathComponent("topics"), media: media)
        try verifyTranslationControls(project: scratch.appendingPathComponent("translation"), media: media)
        try verifyMixedTopicVariantReopen(project: scratch.appendingPathComponent("mixed-topics"), media: media)
        // Each Source/Translation scenario has its own project. Source review can
        // legitimately invalidate downstream artifacts; the retained fixture is untouched.
        for source in [ArtifactLanguage.ru, .en] {
            for translation in [false, true] {
                let name = "\(source.rawValue)-\(translation ? "translation" : "source")"
                let project = scratch.appendingPathComponent(name)
                _ = try makeProject(project, media: media, source: source)
                try verify(project: project, source: source, translation: translation, evidence: retainedRoot, name: name)
            }
        }
    }

    private static func makeProject(_ project: URL, media: URL, source: ArtifactLanguage) throws -> ProjectManifest {
        let store = ProjectStore()
        var manifest = try store.ensureProject(at: project, mediaURL: media, mode: .newProject)
        let layout = ProjectLayout(root: project)
        manifest.durationSeconds = 4
        manifest.languageProfile = LanguageProfile(
            detected: source == .ru ? .ru : .en, effective: source, confidence: 1, method: "fixture",
            model: nil, modelVersion: nil, sampleRanges: [], manuallyOverridden: false, detectedAt: Date()
        )
        manifest.transcriptRevisions = []
        var active: [String: String] = [:]
        for language in [source, source.translationTarget] {
            let id = "approved-\(language.rawValue)"
            let cues = [
                SubtitleCue(id: 1, start: 0, end: 2, text: "\(language.rawValue.uppercased()) first approved cue."),
                SubtitleCue(id: 2, start: 2, end: 4, text: "\(language.rawValue.uppercased()) second approved cue.")
            ]
            let text = cues.map(\.text).joined(separator: "\n\n") + "\n"
            try SRTService().writePreservingIDs(cues, to: layout.subtitlesURL(language: language))
            try text.write(to: layout.transcriptURL(language: language), atomically: true, encoding: .utf8)
            if language == source {
                try SRTService().writePreservingIDs(cues, to: layout.fullSRTURL)
                try text.write(to: layout.transcriptURL, atomically: true, encoding: .utf8)
            }
            for revisionID in [id, "decoy-newer-\(language.rawValue)"] {
                let subtitle = layout.subtitleRevisionURL(id: revisionID, language: language)
                try FileManager.default.createDirectory(at: subtitle.deletingLastPathComponent(), withIntermediateDirectories: true)
                try SRTService().writePreservingIDs(cues, to: subtitle)
                try text.write(to: layout.transcriptRevisionURL(id: revisionID, language: language), atomically: true, encoding: .utf8)
                manifest.transcriptRevisions?.append(TranscriptRevision(
                    id: revisionID, language: language, origin: language == source ? .machineGenerated : .translated,
                    parentRevisionID: language == source ? nil : "approved-\(source.rawValue)",
                    transcriptArtifactID: "\(revisionID)-txt", subtitleArtifactID: "\(revisionID)-srt",
                    contentHash: StableTopicHash.string(try String(contentsOf: subtitle, encoding: .utf8)),
                    createdAt: Date(), reviewStatus: revisionID == id ? .approved : .pending
                ))
            }
            active[language.rawValue] = id
        }
        manifest.humanReviewState = HumanReviewState(
            sourceReviewEnabled: true, translationReviewEnabled: true, fillerAnalysisBeforeReview: false,
            activeRevisionIDs: active, draftRevisionIDs: [:], pendingCheckpoint: nil
        )
        let topics = TopicsFile(
            adapter: TopicAlgorithmIdentity.hybridAdapter, createdAt: Date(), sourceSRT: layout.fullSRTURL.path,
            sourceSignature: StableTopicHash.string(try String(contentsOf: layout.fullSRTURL, encoding: .utf8)),
            topics: [TopicSegment(id: "topic-1", title: "Approved fixture topic", start: 0, end: 4,
                summary: "Two approved cues.", keywords: ["fixture"], confidence: 1,
                boundaryReason: "Start of fixture", cueIds: [1, 2])]
        )
        try TopicFileService().save(topics, projectURL: project, language: source, granularity: .normal, updateLegacyFiles: true)
        let topic = TopicRevision(
            id: "approved-topics", language: source, granularity: .normal, parentRevisionID: nil,
            jsonPath: layout.topicsURL(language: source, granularity: .normal).path,
            textPath: layout.topicsTextURL(language: source, granularity: .normal).path,
            contentHash: StableTopicHash.string("fixture-topics"), status: .approved, createdAt: Date()
        )
        manifest.topicRevisions = [topic]
        manifest.topicReviewState = TopicReviewState(enabled: true, activeRevisionIDs: [topic.variantKey: topic.id], pendingCheckpoint: nil)
        manifest.workflow = ProjectWorkflowState(status: .completed, progress: 1, mode: .resumeProject, operations: [:], lastError: nil)
        try store.save(manifest, to: project)
        return manifest
    }

    private static func tree(_ root: Any) -> [RenderedAXElement] {
        var result: [RenderedAXElement] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ item: Any) {
            guard let object = item as? NSObject else {
                print("AX_UNSUPPORTED_NODE \(type(of: item))")
                return
            }
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            let element = RenderedAXElement(object: object)
            result.append(element)
            for child in element.accessibilityChildren() ?? [] { visit(child) }
        }
        visit((root as? RenderedAXElement)?.object ?? root)
        return result
    }

    private static func nodes(_ window: NSWindow) -> [RenderedAXElement] {
        var seen = Set<ObjectIdentifier>()
        return ([window] + window.sheets).flatMap { tree($0) }.filter {
            seen.insert(ObjectIdentifier($0.object)).inserted
        }
    }

    private static func element(_ id: String, in window: NSWindow) throws -> RenderedAXElement {
        let found = nodes(window).filter { $0.accessibilityIdentifier() == id }
        if found.count != 1 {
            print("AX_DIAGNOSTIC windowChildren=\(window.accessibilityChildren()?.count ?? -1) hostChildren=\(window.contentView?.accessibilityChildren()?.count ?? -1)")
            for node in nodes(window) {
                print("AX_NODE \(type(of: node.object)) protocol=\(node.object is NSAccessibilityProtocol) id=\(node.accessibilityIdentifier() ?? "nil") role=\(node.accessibilityRole()?.rawValue ?? "nil") label=\(node.accessibilityLabel() ?? "nil") children=\(node.accessibilityChildren()?.count ?? -1) responds={\(node.selectorDiagnostics)}")
            }
            for child in window.contentView?.accessibilityChildren() ?? [] {
                print("HOST_RAW_CHILD \(type(of: child)) protocol=\(child is NSAccessibilityProtocol)")
            }
        }
        try require(found.count == 1, "Rendered AX element \(id): expected 1, found \(found.count)")
        let item = found[0]
        try require(item.accessibilityFrame().width > 0 && item.accessibilityFrame().height > 0, "\(id) has an empty rendered frame")
        return item
    }

    private static func settle(_ window: NSWindow) {
        for _ in 0..<12 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private static func press(_ id: String, in window: NSWindow) throws {
        let control = try element(id, in: window)
        try require(control.isAccessibilityEnabled(), "Rendered \(id) is disabled")
        try require(control.accessibilityPerformPress(), "Rendered \(id) did not perform AX press")
        settle(window)
    }

    private static func clickRenderedSegment(_ segment: RenderedAXElement, in window: NSWindow) throws {
        let frame = segment.accessibilityFrame()
        let screenPoint = NSPoint(x: frame.midX, y: frame.midY)
        try require(segment.isAccessibilityEnabled() && frame.width > 0 && frame.height > 0
            && window.frame.contains(screenPoint), "Rendered segment has no enabled in-window mouse target")
        let location = window.convertPoint(fromScreen: screenPoint)
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                  timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
                  eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
                  timestamp: timestamp + 0.01, windowNumber: window.windowNumber, context: nil,
                  eventNumber: 2, clickCount: 1, pressure: 0) else {
            throw RenderedProbeFailure(message: "Could not construct native segment mouse events")
        }
        print("NATIVE_LANGUAGE_CLICK screen=\(screenPoint) window=\(location) key=\(window.isKeyWindow)")
        // Native controls can synchronously track until mouse-up inside mouseDown.
        // Queue the release first so dispatch cannot block waiting for the test.
        NSApplication.shared.postEvent(up, atStart: true)
        NSApplication.shared.sendEvent(down)
        if let release = NSApplication.shared.nextEvent(matching: .leftMouseUp, until: .distantPast,
                                                        inMode: .default, dequeue: true) {
            NSApplication.shared.sendEvent(release)
        }
        settle(window)
    }

    private static func assertSimple(_ window: NSWindow) throws {
        let picker = try element("simple.modePicker", in: window)
        let simpleSelected = tree(picker).contains {
            $0.accessibilityLabel() == "Простой" && ($0.accessibilityValue() as? NSNumber)?.intValue == 1
        }
        let value = picker.accessibilityValue() as? String
        try require(simpleSelected || value == "Простой" || value == "simple", "Global mode is not rendered as selected Simple")
    }

    private static func verifyTranscriptionPresentation() throws {
        let project = URL(fileURLWithPath: "/private/tmp/simple-transcription-presentation")
        let other = project.appendingPathComponent("other")
        let start = Date(timeIntervalSince1970: 100)
        let source = HumanReviewCheckpoint(kind: .sourceTranscript, language: .ru, revisionID: "new-source",
            pendingOperations: [.validateTimeline], createdAt: start.addingTimeInterval(1))
        var flow = SimpleTranscriptionPresentation()
        flow.begin(projectURL: project, language: "ru", now: start)
        try require(flow.observe(projectURL: project, mode: .simple, isRunning: false, checkpoint: source) == nil,
            "A checkpoint without the explicit run's running edge must not open review")
        try require(flow.observe(projectURL: project, mode: .simple, isRunning: true, checkpoint: source) == nil,
            "Review must wait until processing finishes")
        try require(flow.suppressesReviewAlert(title: "Требуется Human Review", projectURL: project, checkpoint: source),
            "The competing source review alert must be suppressed before running becomes false")
        try require(!flow.suppressesReviewAlert(title: "Ошибка обработки", projectURL: project, checkpoint: source),
            "A real failure alert must remain visible")
        var translated = source
        translated.kind = .translatedTranscript
        try require(!flow.suppressesReviewAlert(title: "Требуется Human Review", projectURL: project, checkpoint: translated),
            "Translation review must not be suppressed by source intent")
        try require(flow.observe(projectURL: project, mode: .simple, isRunning: false, checkpoint: source) == source,
            "Checkpoint-before-finish sequence did not open the exact source review")
        try require(flow.observe(projectURL: project, mode: .simple, isRunning: false, checkpoint: source) == nil,
            "Closing review must not cause an automatic reopen")

        flow.begin(projectURL: project, language: "auto", now: start)
        _ = flow.observe(projectURL: project, mode: .simple, isRunning: true, checkpoint: nil)
        try require(flow.observe(projectURL: project, mode: .simple, isRunning: false, checkpoint: nil) == nil,
            "Finishing without a checkpoint must not invent review readiness")
        var english = source
        english.language = .en
        try require(flow.observe(projectURL: project, mode: .simple, isRunning: false, checkpoint: english) == english,
            "Finish-before-checkpoint sequence or Auto language failed")

        flow.begin(projectURL: project, language: "ru", now: start)
        _ = flow.observe(projectURL: project, mode: .simple, isRunning: true, checkpoint: nil)
        try require(flow.observe(projectURL: project, mode: .simple, isRunning: false, checkpoint: english) == nil,
            "A different-language checkpoint satisfied explicit RU intent")
        var stale = source
        stale.createdAt = start.addingTimeInterval(-1)
        try require(flow.observe(projectURL: project, mode: .simple, isRunning: false, checkpoint: stale) == nil,
            "A previous run's checkpoint satisfied new source intent")
        _ = flow.observe(projectURL: project, mode: .simple, isRunning: true, checkpoint: nil)
        try require(flow.observe(projectURL: project, mode: .simple, isRunning: false, checkpoint: source) == nil,
            "An unrelated later run inherited the previous intent")

        for mode in [ProjectPresentationMode.simple, .advanced] {
            flow.begin(projectURL: project, language: "ru", now: start)
            _ = flow.observe(projectURL: project, mode: .simple, isRunning: true, checkpoint: nil)
            let destination = mode == .simple ? other : project
            _ = flow.observe(projectURL: destination, mode: mode, isRunning: false, checkpoint: source)
            try require(flow.observe(projectURL: project, mode: .simple, isRunning: false, checkpoint: source) == nil,
                "Project/mode switch must invalidate auto-review intent")
        }
        flow.begin(projectURL: project, language: "ru", now: start)
        _ = flow.observe(projectURL: project, mode: .simple, isRunning: true, checkpoint: nil)
        _ = flow.observe(projectURL: project, mode: .simple, isRunning: false, checkpoint: nil, failedOrStopped: true)
        try require(flow.observe(projectURL: project, mode: .simple, isRunning: false, checkpoint: source) == nil,
            "An error/cancellation must not later auto-open review")
        let raw = AppAlert(title: "Ошибка обработки", message: "/internal/manifest.json: CLI runtime failure")
        let readable = flow.sourceRunAlert(raw, projectURL: project)
        try require(readable.id == raw.id && readable.title == "Не удалось создать расшифровку"
            && !readable.message.contains("manifest") && !readable.message.contains("CLI")
            && raw.message.contains("/internal/manifest.json"), "Simple error rendering lost diagnostics or leaked internal details")
        try require(flow.sourceRunAlert(raw, projectURL: other).message == raw.message,
            "Source error rendering changed another project's alert")
        let stopped = flow.sourceRunAlert(AppAlert(title: "Обработка остановлена", message: "internal details"), projectURL: project)
        try require(stopped.message.contains("не завершена"), "Cancellation was represented as successful transcription")
        try require(SimpleTranscriptionPresentation.stage(operation: .createManifest, isStopping: false) == "Проверяем исходный файл",
            "A technical stage name leaked into Simple progress")
        try require(SimpleTranscriptionPresentation.stage(operation: .topicTimecoding, isStopping: false) == "Создаём темы",
            "Topic timecoding did not render its actual Simple progress stage")
        try require(SimpleTranscriptionPresentation.fraction(.nan) == 0
            && SimpleTranscriptionPresentation.fraction(2) == 1
            && SimpleTranscriptionPresentation.fraction(-1) == 0, "Simple progress must remain finite and within 0...1")
        print("SIMPLE_TRANSCRIPTION_PRESENTATION_CONTRACT_PASS")
    }

    private static func verifyTranslationPresentation() throws {
        let project = URL(fileURLWithPath: "/private/tmp/simple-translation-presentation")
        let other = project.appendingPathComponent("other")
        let start = Date(timeIntervalSince1970: 100)
        let translated = HumanReviewCheckpoint(kind: .translatedTranscript, language: .en, revisionID: "new-translation",
            pendingOperations: [], createdAt: start.addingTimeInterval(1))
        let source = HumanReviewCheckpoint(kind: .sourceTranscript, language: .ru, revisionID: "new-source",
            pendingOperations: [], createdAt: start.addingTimeInterval(1))
        var flow = SimpleTranslationPresentation()
        flow.begin(projectURL: project, target: .en, now: start)
        try require(flow.observe(projectURL: project, mode: .simple, isRunning: false, checkpoint: translated) == nil,
            "Translation review must wait for the explicit run's completion")
        try require(flow.observe(projectURL: project, mode: .simple, isRunning: true, checkpoint: translated) == nil,
            "Translation review opened while the translation was still running")
        try require(flow.suppressesReviewAlert(title: "Требуется Human Review", projectURL: project, checkpoint: translated),
            "The competing translation review alert must be suppressed for the Simple flow")
        try require(!flow.suppressesReviewAlert(title: "Требуется Human Review", projectURL: project, checkpoint: source),
            "Source review must not be claimed by a translation intent")
        try require(flow.observe(projectURL: project, mode: .simple, isRunning: false, checkpoint: translated) == translated,
            "Completed translation did not open the existing Translation Human Review")
        try require(flow.observe(projectURL: project, mode: .simple, isRunning: false, checkpoint: translated) == nil,
            "Closing Translation Human Review caused a false automatic success/reopen")

        flow.begin(projectURL: project, target: .en, now: start)
        _ = flow.observe(projectURL: project, mode: .simple, isRunning: true, checkpoint: nil)
        let failedTranslation = AppAlert(title: "Перевод не выполнен", message: "internal translation diagnostics")
        let readableFailure = flow.translationRunAlert(failedTranslation, projectURL: project)
        try require(readableFailure.title == "Не удалось создать перевод" && !readableFailure.message.contains("internal"),
            "Active translation failure is not rendered as a user-facing translation error")
        _ = flow.observe(projectURL: project, mode: .simple, isRunning: false, checkpoint: nil, failedOrStopped: true)
        try require(flow.observe(projectURL: project, mode: .simple, isRunning: false, checkpoint: translated) == nil,
            "A stopped translation later claimed a successful review")
        let unrelated = AppAlert(title: "Ошибка обработки", message: "Topic diagnostics")
        let sameProjectAlert = flow.translationRunAlert(unrelated, projectURL: project)
        try require(sameProjectAlert.id == unrelated.id && sameProjectAlert.title == unrelated.title
                    && sameProjectAlert.message == unrelated.message,
            "A terminated translation relabeled a later unrelated Simple error")
        let otherProjectAlert = flow.translationRunAlert(unrelated, projectURL: other)
        try require(otherProjectAlert.id == unrelated.id && otherProjectAlert.title == unrelated.title
                    && otherProjectAlert.message == unrelated.message,
            "Translation error rendering changed another project")
        print("SIMPLE_TRANSLATION_PRESENTATION_CONTRACT_PASS")
    }

    private static func renderedText(_ node: RenderedAXElement) -> String {
        tree(node).flatMap { [$0.accessibilityLabel(), $0.accessibilityValue() as? String].compactMap { $0 } }
            .joined(separator: " ")
    }

    private static func assertSourceRowFits(_ section: String, window: NSWindow) throws {
        let row = try element("simple.\(section).transcription.row", in: window).accessibilityFrame()
        try require(row.minX >= window.frame.minX && row.maxX <= window.frame.maxX,
            "Rendered source row exceeds the 980-point window")
        for action in ["create", "language", "projectLanguage", "open", "correct"] {
            for control in nodes(window).filter({ $0.accessibilityIdentifier() == "simple.\(section).transcription.\(action)" }) {
                let frame = control.accessibilityFrame()
                try require(frame.width > 0 && frame.height > 0 && frame.minX >= row.minX - 2 && frame.maxX <= row.maxX + 2,
                    "Rendered source \(action) is clipped or outside its row")
            }
        }
    }

    private static func assertTranslationRowFits(_ section: String, window: NSWindow) throws {
        let row = try element("simple.\(section).translation.row", in: window).accessibilityFrame()
        try require(row.minX >= window.frame.minX && row.maxX <= window.frame.maxX,
            "Rendered translation row exceeds the 980-point window")
        for action in ["create", "open", "correct"] {
            for control in nodes(window).filter({ $0.accessibilityIdentifier() == "simple.\(section).translation.\(action)" }) {
                let frame = control.accessibilityFrame()
                try require(frame.width > 0 && frame.height > 0 && frame.minX >= row.minX - 2 && frame.maxX <= row.maxX + 2,
                    "Rendered translation \(action) is clipped or outside its row")
            }
        }
    }

    private static func verifyCreationControls(project: URL, media: URL) throws {
        _ = try ProjectStore().ensureProject(at: project, mediaURL: media, mode: .newProject)
        let model = WorkflowViewModel()
        model.projectURL = project
        model.mediaURL = media
        model.sourceHumanReviewEnabled = false
        model.loadDetectedResults()
        let advancedOperations = model.selectedOperations
        let host = NSHostingView(rootView: ContentView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        settle(window)
        try assertSimple(window)
        try require(!model.isRunning && model.whisperLanguage == "ru", "Opening new media must not start processing or change default RU")
        let create = try element("simple.ready.transcription.create", in: window)
        try require(create.accessibilityRole() == .button && create.accessibilityLabel() == "Создать расшифровку"
            && create.isAccessibilityEnabled() == model.canStartSimpleTranscription, "Missing transcript has no truthful rendered creation action")
        try require(!nodes(window).contains { ["simple.ready.transcription.open", "simple.ready.transcription.correct"].contains($0.accessibilityIdentifier() ?? "") },
            "Missing transcript exposes Open/Correct alongside creation")
        try press("simple.goal.textContent", in: window)
        let topicsUnavailable = try element("simple.textContent.topics.unavailable", in: window)
        try require(renderedText(topicsUnavailable).contains("утвердите расшифровку"),
            "Topics without an approved transcript did not explain why they are unavailable")
        try require(!element("simple.textContent.topics.create", in: window).isAccessibilityEnabled(),
            "Topics without an approved transcript exposed an enabled creation action")
        try assertSourceRowFits("ready", window: window)
        for (label, language) in [("EN", "en"), ("Авто", "auto")] {
            let picker = try element("simple.ready.transcription.language", in: window)
            let descendants = tree(picker)
            print("AX_LANGUAGE_PICKER option=\(label) binding=\(model.whisperLanguage) nodes=\(descendants.count) running=\(model.isRunning) sourcePending=\(model.humanReviewCheckpoint != nil) topicsPending=\(model.topicReviewCheckpoint != nil)")
            for node in descendants.prefix(16) {
                print("AX_LANGUAGE_NODE type=\(type(of: node.object)) protocol=\(node.object is NSAccessibilityProtocol) role=\(node.accessibilityRole()?.rawValue ?? "nil") label=\(node.accessibilityLabel() ?? "nil") title=\(node.accessibilityTitle() ?? "nil") value=\(String(describing: node.accessibilityValue())) enabled=\(node.isAccessibilityEnabled()) frame=\(node.accessibilityFrame()) responds={\(node.selectorDiagnostics)}")
            }
            let options = descendants.filter { $0.accessibilityRole() == .radioButton && $0.accessibilityLabel() == label }
            try require(options.count == 1, "Rendered language option \(label): expected one AX radio button, found \(options.count)")
            let option = options[0]
            try require(picker.isAccessibilityEnabled() && option.isAccessibilityEnabled(), "Rendered language option \(label) is disabled")
            let frame = option.accessibilityFrame()
            try require(frame.width > 0 && frame.height > 0, "Rendered language option \(label) has an empty hit target")
            let performed = option.accessibilityPerformPress()
            print("AX_LANGUAGE_PRESS option=\(label) performed=\(performed)")
            if !performed {
                // NSAccessibilitySegment may expose press without forwarding it
                // to its NSSegmentedControl. Exercise the actual mouse hit target.
                try clickRenderedSegment(option, in: window)
            }
            settle(window)
            print("AX_LANGUAGE_BINDING option=\(label) expected=\(language) actual=\(model.whisperLanguage)")
            try require(model.whisperLanguage == language, "Simple picker did not update the existing language binding")
            let updatedPicker = try element("simple.ready.transcription.language", in: window)
            let selected = tree(updatedPicker).filter {
                $0.accessibilityRole() == .radioButton && $0.accessibilityLabel() == label
            }
            try require(selected.count == 1 && (selected[0].accessibilityValue() as? NSNumber)?.intValue == 1,
                "Rendered language option \(label) was not selected after the UI action")
        }
        _ = try element("simple.textContent.transcription.create", in: window)
        try assertSourceRowFits("textContent", window: window)
        try assertSimple(window)
        model.progress = WorkflowProgress(operation: .transcribe, operationFraction: 0.2, overallFraction: 0.1,
            elapsed: 1, estimatedTotal: nil, remaining: nil, isIndeterminate: true)
        model.isRunning = true
        settle(window)
        try require(!element("simple.ready.transcription.create", in: window).isAccessibilityEnabled()
            && !element("simple.ready.transcription.language", in: window).isAccessibilityEnabled(), "Running source controls allow a second start/language change")
        try require(renderedText(element("simple.progress.stage", in: window)).contains("Создаём расшифровку"), "Actual Simple progress did not render the transcription stage")
        try require(element("simple.progress.stop", in: window).isAccessibilityEnabled(), "Simple stop is missing during processing")
        model.isStopping = true
        settle(window)
        try require(!element("simple.progress.stop", in: window).isAccessibilityEnabled()
            && renderedText(element("simple.progress.stage", in: window)).contains("Останавливаем"), "Simple stopping state is incorrect")
        model.isRunning = false
        model.isStopping = false
        model.status = "Остановлено"
        settle(window)
        try require(renderedText(element("simple.project.status", in: window)).contains("остановлена")
            && element("simple.ready.transcription.create", in: window).isAccessibilityEnabled() == model.canStartSimpleTranscription,
            "Cancellation must retain an honest status and retry action")
        model.status = "Ошибка"
        settle(window)
        try require(renderedText(element("simple.project.status", in: window)).contains("Требуется внимание"), "Error was rendered as a ready project")
        _ = try element("simple.ready.transcription.create", in: window)
        try require(model.selectedOperations == advancedOperations && !model.sourceHumanReviewEnabled,
            "Simple presentation rewrote Advanced settings")
        try assertSimple(window)

        // A cancelled new-project run may already have reusable SRT and a fixed
        // language. A stale Advanced picker value must not become the retry intent.
        let store = ProjectStore()
        var manifest = try store.load(from: project)
        manifest.languageProfile = LanguageProfile(
            detected: .ru, effective: .ru, confidence: 1, method: "fixture",
            model: nil, modelVersion: nil, sampleRanges: [], manuallyOverridden: false, detectedAt: Date()
        )
        try store.save(manifest, to: project)
        try SRTService().writePreservingIDs(
            [SubtitleCue(id: 1, start: 0, end: 2, text: "Persisted source cue.")],
            to: ProjectLayout(root: project).fullSRTURL
        )
        for reopened in [false, true] {
            if reopened { model.openProject(project) }
            model.status = "Остановлено"
            model.whisperLanguage = "en"
            model.loadDetectedResults()
            settle(window)
            if reopened {
                try press("simple.goal.textContent", in: window)
            }
            _ = try element("simple.textContent.panel", in: window)
            try assertSimple(window)
            try require(model.simpleTranscriptionLockedLanguage == .ru && model.simpleTranscriptionLanguage == "ru",
                "Persisted RU did not override stale EN for same-session/reopened retry")
            for section in ["ready", "textContent"] {
                try require(!nodes(window).contains { $0.accessibilityIdentifier() == "simple.\(section).transcription.language" },
                    "Locked project rendered an editable language picker")
                let language = try element("simple.\(section).transcription.projectLanguage", in: window)
                try require(renderedText(language).contains("Язык проекта: Русский"),
                    "Locked project did not render its actual language in friendly terms")
                try require(element("simple.\(section).transcription.create", in: window).isAccessibilityEnabled()
                    == model.canStartSimpleTranscription, "Locked retry lost its rendered creation action")
                try assertSourceRowFits(section, window: window)
            }
            let start = Date(timeIntervalSince1970: 100)
            let checkpoint = HumanReviewCheckpoint(kind: .sourceTranscript, language: .ru, revisionID: "resumed-source",
                pendingOperations: [.validateTimeline], createdAt: start.addingTimeInterval(1))
            var flow = SimpleTranscriptionPresentation()
            flow.begin(projectURL: project, language: model.simpleTranscriptionLanguage, now: start)
            _ = flow.observe(projectURL: project, mode: .simple, isRunning: true, checkpoint: nil)
            try require(flow.observe(projectURL: project, mode: .simple, isRunning: false, checkpoint: checkpoint) == checkpoint,
                "Effective retry language rejected the persisted source checkpoint")
            try require(!model.isRunning && model.whisperLanguage == "en", "Language presentation started work or rewrote Advanced binding")
            try assertSimple(window)
        }
        print("SIMPLE_TRANSCRIPTION_RENDERED_CONTROLS_PASS: creation/language/progress/stop/retry/locked-resume; 980x680; no processing invoked")
    }

    private static func verifyTopicControls(project: URL, media: URL) throws {
        _ = try makeProject(project, media: media, source: .ru)
        let model = WorkflowViewModel()
        model.projectURL = project
        model.mediaURL = media
        model.loadDetectedResults()
        let host = NSHostingView(rootView: ContentView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        settle(window)

        try assertSimple(window)
        try press("simple.goal.textContent", in: window)
        _ = try element("simple.textContent.topics.open", in: window)
        try require(!nodes(window).contains {
            ["simple.textContent.topics.create", "simple.textContent.topics.correct"].contains($0.accessibilityIdentifier() ?? "")
        }, "Existing ready topics must only offer opening their TXT result in Simple")
        let readyText = nodes(window)
            .flatMap { [$0.accessibilityLabel(), $0.accessibilityValue() as? String].compactMap { $0 } }
            .joined(separator: " ")
        try require(!readyText.contains("topics.ru.normal.txt"),
            "Simple rendered a technical topics filename instead of user-facing text")

        let reopened = WorkflowViewModel()
        reopened.openProject(project)
        let reopenedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        reopenedWindow.isReleasedWhenClosed = false
        reopenedWindow.contentView = NSHostingView(rootView: ContentView(model: reopened))
        reopenedWindow.makeKeyAndOrderFront(nil)
        settle(reopenedWindow)
        try press("simple.goal.textContent", in: reopenedWindow)
        _ = try element("simple.textContent.topics.open", in: reopenedWindow)
        try require(!reopened.isRunning && !nodes(reopenedWindow).contains {
            $0.accessibilityIdentifier() == "simple.textContent.topics.create"
        }, "Reopening ready topics exposed regeneration in Simple")
        reopenedWindow.close()

        try removeTopics(from: project, media: media)
        model.loadDetectedResults()
        settle(window)

        let create = try element("simple.textContent.topics.create", in: window)
        try require(create.accessibilityRole() == .button && create.accessibilityLabel() == "Создать темы"
            && create.isAccessibilityEnabled() == model.canCreateTopicsFromAcceptedTranscript,
            "Approved transcript with missing topics has no truthful rendered creation action")
        try require(!nodes(window).contains { $0.accessibilityIdentifier() == "simple.textContent.topics.granularity" },
            "Simple rendered an unnecessary topic granularity choice")
        try require(!nodes(window).contains { $0.accessibilityIdentifier() == "simple.textContent.topics.correct" },
            "Simple must not render topic correction controls")

        model.progress = WorkflowProgress(operation: .topicTimecoding, operationFraction: 0.2, overallFraction: 0.1,
            elapsed: 1, estimatedTotal: nil, remaining: nil, isIndeterminate: true)
        model.isRunning = true
        settle(window)
        try require(renderedText(element("simple.progress.stage", in: window)).contains("Создаём темы"),
            "Simple progress did not render the active topic timecoding stage")
        try require(element("simple.progress.stop", in: window).isAccessibilityEnabled(),
            "Simple topics processing did not reuse the existing stop action")
        try require(!element("simple.textContent.topics.create", in: window).isAccessibilityEnabled(),
            "Simple exposed duplicate topic creation while processing")
        model.isStopping = true
        settle(window)
        try require(renderedText(element("simple.progress.stage", in: window)).contains("Останавливаем обработку")
            && !element("simple.progress.stop", in: window).isAccessibilityEnabled(),
            "Simple topics stop state did not disable repeated cancellation")
        model.isStopping = false
        model.isRunning = false
        model.progress = .idle
        settle(window)

        var manifest = try ProjectStore().load(from: project)
        let pendingID = "pending-topics"
        let layout = ProjectLayout(root: project)
        let pending = TopicRevision(
            id: pendingID, language: .ru, granularity: .normal, parentRevisionID: nil,
            jsonPath: layout.topicsURL(language: .ru, granularity: .normal).path,
            textPath: layout.topicsTextURL(language: .ru, granularity: .normal).path,
            contentHash: StableTopicHash.string("pending-topics"), status: .pending, createdAt: Date()
        )
        manifest.topicRevisions = [pending]
        manifest.topicReviewState = TopicReviewState(
            enabled: true,
            activeRevisionIDs: [:],
            pendingCheckpoint: TopicReviewCheckpoint(
                revisionIDs: [pending.variantKey: pendingID], pendingOperations: [], createdAt: Date()
            )
        )
        try ProjectStore().save(manifest, to: project)
        model.loadDetectedResults()
        settle(window)

        let handoff = try element("simple.textContent.topics.advancedHandoff", in: window)
        try require(renderedText(handoff).contains("расширенном режиме"),
            "Pending topic review did not render the Advanced-only handoff")
        try require(!nodes(window).contains { ["simple.textContent.topics.create", "simple.textContent.topics.correct"].contains($0.accessibilityIdentifier() ?? "") },
            "Pending topic review exposed a Simple creation or correction control")
        let topicRow = try element("simple.textContent.topics.row", in: window)
        try require(!tree(topicRow).contains { $0.accessibilityRole() == .button && $0.accessibilityLabel() == "Исправить" },
            "Pending topic review exposed an unidentified Simple correction control")
        try assertSimple(window)
        print("RENDERED_TOPIC_CONTROLS_PASS: create CTA, no unnecessary choice, no Simple correction, Advanced handoff")
    }

    private static func verifyTranslationControls(project: URL, media: URL) throws {
        let store = ProjectStore()
        let sourceOnly = project.appendingPathComponent("source-unapproved")
        var missingManifest = try store.ensureProject(at: sourceOnly, mediaURL: media, mode: .newProject)
        missingManifest.languageProfile = LanguageProfile(
            detected: .ru, effective: .ru, confidence: 1, method: "fixture",
            model: nil, modelVersion: nil, sampleRanges: [], manuallyOverridden: false, detectedAt: Date()
        )
        try store.save(missingManifest, to: sourceOnly)
        let unapprovedModel = WorkflowViewModel()
        unapprovedModel.projectURL = sourceOnly
        unapprovedModel.mediaURL = media
        unapprovedModel.loadDetectedResults()
        let unapprovedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        unapprovedWindow.isReleasedWhenClosed = false
        unapprovedWindow.contentView = NSHostingView(rootView: ContentView(model: unapprovedModel))
        unapprovedWindow.makeKeyAndOrderFront(nil)
        defer { unapprovedWindow.close() }
        settle(unapprovedWindow)
        try press("simple.goal.textContent", in: unapprovedWindow)
        let unavailable = try element("simple.textContent.translation.unavailable", in: unapprovedWindow)
        try require(renderedText(unavailable).contains("Сначала утвердите расшифровку"),
            "Unapproved source did not explain why translation is unavailable")
        try require(!element("simple.textContent.translation.create", in: unapprovedWindow).isAccessibilityEnabled(),
            "Unapproved source exposed an enabled translation creation action")

        let accepted = project.appendingPathComponent("source-approved")
        _ = try makeProject(accepted, media: media, source: .ru)
        try removeTranslation(from: accepted)
        let model = WorkflowViewModel()
        model.projectURL = accepted
        model.mediaURL = media
        model.loadDetectedResults()
        let advancedOperations = model.selectedOperations
        let advancedTranslationReview = model.translationHumanReviewEnabled
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        settle(window)
        try press("simple.goal.textContent", in: window)
        let create = try element("simple.textContent.translation.create", in: window)
        try require(create.accessibilityRole() == .button && create.accessibilityLabel() == "Создать перевод"
            && create.isAccessibilityEnabled() == model.canTranslate,
            "Approved source has no truthful rendered Simple translation creation action")
        try require(!nodes(window).contains { $0.accessibilityIdentifier() == "simple.textContent.translation.language" },
            "Simple rendered a translation language picker despite the existing fixed pipeline direction")
        try require(!nodes(window).contains {
            ["simple.textContent.translation.open", "simple.textContent.translation.correct"].contains($0.accessibilityIdentifier() ?? "")
        }, "Missing translation claimed a ready result or review before generation")
        try assertTranslationRowFits("textContent", window: window)

        model.progress = WorkflowProgress(operation: .translateTranscript, operationFraction: 0.2, overallFraction: 0.1,
            elapsed: 1, estimatedTotal: nil, remaining: nil, isIndeterminate: true)
        model.isRunning = true
        settle(window)
        try require(renderedText(element("simple.progress.stage", in: window)).contains("Создаём перевод"),
            "Simple progress did not render the active translation stage")
        try require(element("simple.progress.stop", in: window).isAccessibilityEnabled(),
            "Simple translation processing did not reuse the existing stop action")
        try require(!element("simple.textContent.translation.create", in: window).isAccessibilityEnabled(),
            "Simple exposed duplicate translation creation while processing")
        model.isStopping = true
        settle(window)
        try require(renderedText(element("simple.progress.stage", in: window)).contains("Останавливаем обработку")
            && !element("simple.progress.stop", in: window).isAccessibilityEnabled(),
            "Simple translation stop state allowed repeated cancellation")
        model.isStopping = false
        model.isRunning = false
        model.progress = .idle

        var manifest = try store.load(from: accepted)
        let layout = ProjectLayout(root: accepted)
        let pendingCues = [
            SubtitleCue(id: 1, start: 0, end: 2, text: "Pending translated cue one."),
            SubtitleCue(id: 2, start: 2, end: 4, text: "Pending translated cue two.")
        ]
        try SRTService().writePreservingIDs(pendingCues, to: layout.subtitlesURL(language: .en))
        try pendingCues.map(\.text).joined(separator: "\n\n").write(
            to: layout.transcriptURL(language: .en), atomically: true, encoding: .utf8
        )
        let sourceRevisionID = manifest.activeTranscriptRevision(for: .ru)?.id
        let pendingRevision = TranscriptRevision(
            id: "pending-translation", language: .en, origin: .translated,
            parentRevisionID: sourceRevisionID,
            transcriptArtifactID: "pending-translation-txt", subtitleArtifactID: "pending-translation-srt",
            contentHash: StableTopicHash.string("pending-translation"), createdAt: Date(), reviewStatus: .pending
        )
        manifest.transcriptRevisions?.append(pendingRevision)
        let checkpoint = HumanReviewCheckpoint(kind: .translatedTranscript, language: .en, revisionID: "pending-translation",
            pendingOperations: [], createdAt: Date())
        manifest.humanReviewState?.pendingCheckpoint = checkpoint
        manifest.workflow?.status = .awaitingReview
        try store.save(manifest, to: accepted)
        model.loadDetectedResults()
        settle(window)
        try require(!nodes(window).contains { $0.accessibilityIdentifier() == "simple.textContent.translation.open" },
            "Translation appeared ready before Translation Human Review accepted it")
        try require(!nodes(window).contains { $0.accessibilityIdentifier() == "simple.textContent.translation.create" },
            "Pending Translation Human Review exposed a second creation action")
        let correct = try element("simple.textContent.translation.correct", in: window)
        try require(correct.isAccessibilityEnabled(), "Pending translation did not expose the existing Translation Human Review")
        try require(model.selectedOperations == advancedOperations && model.translationHumanReviewEnabled == advancedTranslationReview,
            "Simple translation presentation rewrote Advanced selections or review preferences")
        print("RENDERED_TRANSLATION_CONTROLS_PASS: disabled-until-approved, CTA, fixed direction, progress/stop, review-before-ready")
    }

    private static func removeTopics(from project: URL, media: URL) throws {
        _ = try makeProject(project, media: media, source: .ru)
        let store = ProjectStore()
        var manifest = try store.load(from: project)
        manifest.topicRevisions = []
        manifest.topicReviewState = .newProjectDefault
        manifest.artifacts = manifest.artifacts?.filter { $0.kind != .topics }
        try store.save(manifest, to: project)
        let topicsDirectory = ProjectLayout(root: project).topicsDirectory
        if FileManager.default.fileExists(atPath: topicsDirectory.path) {
            try FileManager.default.removeItem(at: topicsDirectory)
        }
    }

    private static func removeTranslation(from project: URL) throws {
        let store = ProjectStore()
        var manifest = try store.load(from: project)
        guard let source = manifest.languageProfile?.effective else {
            throw RenderedProbeFailure(message: "Translation fixture has no source language")
        }
        let target = source.translationTarget
        manifest.transcriptRevisions?.removeAll { $0.language == target }
        if var review = manifest.humanReviewState {
            review.activeRevisionIDs[target.rawValue] = nil
            review.draftRevisionIDs[target.rawValue] = nil
            review.pendingCheckpoint = nil
            manifest.humanReviewState = review
        }
        manifest.artifacts = manifest.artifacts?.filter {
            !($0.language == target && ($0.kind == .transcript || $0.kind == .subtitles))
        }
        try store.save(manifest, to: project)
        let layout = ProjectLayout(root: project)
        for url in [layout.transcriptURL(language: target), layout.subtitlesURL(language: target)]
            where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func verifyMixedTopicVariantReopen(project: URL, media: URL) throws {
        var manifest = try makeProject(project, media: media, source: .ru)
        let layout = ProjectLayout(root: project)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var coarseFile = try decoder.decode(TopicsFile.self,
            from: Data(contentsOf: layout.topicsURL(language: .ru, granularity: .normal)))
        coarseFile.granularity = .coarse
        try TopicFileService().save(coarseFile, projectURL: project, language: .ru,
            granularity: .coarse, updateLegacyFiles: false)
        let coarseRevision = TopicRevision(
            id: "approved-coarse", language: .ru, granularity: .coarse, parentRevisionID: nil,
            jsonPath: layout.topicsURL(language: .ru, granularity: .coarse).path,
            textPath: layout.topicsTextURL(language: .ru, granularity: .coarse).path,
            contentHash: StableTopicHash.string("fixture-coarse"), status: .approved, createdAt: Date()
        )
        var revisions = manifest.topicRevisions ?? []
        try require(!revisions.isEmpty, "Mixed topic fixture has no normal revision")
        revisions[0].status = .pending
        revisions.append(coarseRevision)
        manifest.topicRevisions = revisions
        manifest.topicReviewState?.activeRevisionIDs = [coarseRevision.variantKey: coarseRevision.id]
        try ProjectStore().save(manifest, to: project)

        let model = WorkflowViewModel()
        model.openProject(project)
        try require(model.topicGranularity == .normal,
            "Mixed fixture did not reopen on the legacy normal topic variant")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        settle(window)
        try assertSimple(window)
        try press("simple.goal.textContent", in: window)
        let title = try element("simple.textContent.topics.title", in: window)
        try require(renderedText(title).contains("Крупный"),
            "Simple did not select the approved coarse topic variant on reopen")
        _ = try element("simple.textContent.topics.open", in: window)
        try require(!model.isRunning && model.topicGranularity == .normal && !nodes(window).contains {
            ["simple.textContent.topics.create", "simple.textContent.topics.correct"].contains($0.accessibilityIdentifier() ?? "")
        }, "Mixed-variant reopen offered regeneration or changed Advanced topic selection")
        print("MIXED_TOPIC_VARIANT_REOPEN_PASS: ready coarse TXT, no regeneration, Advanced selection preserved")
    }

    private static func verify(project: URL, source: ArtifactLanguage, translation: Bool, evidence: URL?, name: String) throws {
        let model = WorkflowViewModel()
        model.projectURL = project
        model.mediaURL = URL(fileURLWithPath: try ProjectStore().load(from: project).sourceMediaPath)
        model.artifactLanguage = source
        model.loadDetectedResults()
        let host = NSHostingView(rootView: ContentView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        settle(window)
        try assertSimple(window)
        try assertControls("ready", window: window)
        try assertSourceRowFits("ready", window: window)
        try require(!nodes(window).contains { $0.accessibilityIdentifier() == "simple.ready.transcription.create" },
            "Approved source must offer Open/Correct instead of creation")
        try press("simple.goal.textContent", in: window)
        _ = try element("simple.textContent.panel", in: window)
        try assertSimple(window)
        try assertControls("textContent", window: window)
        try assertSourceRowFits("textContent", window: window)
        if let evidence {
            let directory = evidence.appendingPathComponent("rendered-\(name)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let records = nodes(window).map { node -> [String: Any] in
                let frame = node.accessibilityFrame()
                return ["id": node.accessibilityIdentifier() ?? "", "label": node.accessibilityLabel() ?? "",
                    "role": node.accessibilityRole()?.rawValue ?? "", "enabled": node.isAccessibilityEnabled(),
                    "frame": [frame.minX, frame.minY, frame.width, frame.height]]
            }
            try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("ax.json"))
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: directory.appendingPathComponent("expanded.png"))
                }
            }
            print("RENDERED_EVIDENCE: \(directory.path)")
        }
        let target = translation ? "translation" : "source"
        let artifact = translation ? "translation" : "transcription"
        let language = translation ? source.translationTarget : source
        try press("simple.textContent.\(artifact).correct", in: window)
        _ = try element("simple.review.\(target).sheet", in: window)
        let checkpoint = try ProjectStore().load(from: project).humanReviewState?.pendingCheckpoint
        try require(checkpoint?.language == language && checkpoint?.revisionID == "approved-\(language.rawValue)"
            && checkpoint?.kind == (translation ? .translatedTranscript : .sourceTranscript)
            && checkpoint?.pendingOperations.isEmpty == true, "Wrong approved review checkpoint for \(name)")
        try require(model.reviewCues.count == 2 && model.reviewCues[0].start == 0 && model.reviewCues[0].end == 2
            && model.reviewCues[0].text.hasPrefix(language.rawValue.uppercased()), "Wrong language/timed cues inside rendered review")
        try assertSimple(window)
        try press("humanReview.issuesOnly", in: window)
        try require((element("humanReview.issuesOnly", in: window).accessibilityValue() as? NSNumber)?.intValue == 1,
            "Rendered review filter was not enabled by its actual control")
        try press("simple.review.\(target).close", in: window)
        _ = try element("simple.textContent.panel", in: window)
        try assertSimple(window)
        let unrelated = translation ? "transcription" : "translation"
        try require(!element("simple.textContent.\(unrelated).correct", in: window).isAccessibilityEnabled(), "Unrelated language Correct must be disabled during pending review")
        try press("simple.textContent.\(artifact).correct", in: window)
        _ = try element("simple.review.\(target).sheet", in: window)
        try require((element("humanReview.issuesOnly", in: window).accessibilityValue() as? NSNumber)?.intValue == 0,
            "Reopening rendered review retained the previous issues-only filter")
        try require(try ProjectStore().load(from: project).humanReviewState?.pendingCheckpoint == checkpoint, "Reopen changed persisted pending checkpoint")
        try press("simple.review.\(target).close", in: window)
        _ = try element("simple.textContent.panel", in: window)
        try assertSimple(window)
        print("RENDERED_SCENARIO_PASS: \(name); approved controls, exact revision/language, same pending reopen, Simple expanded")
    }

    private static func assertControls(_ section: String, window: NSWindow) throws {
        for artifact in ["transcription", "translation"] {
            let button = try element("simple.\(section).\(artifact).correct", in: window)
            try require(button.accessibilityRole() == .button && button.accessibilityLabel() == "Исправить"
                && button.isAccessibilityEnabled(), "\(section) \(artifact) Correct is not an enabled rendered button")
            _ = try element("simple.\(section).\(artifact).open", in: window)
        }
        _ = try element("simple.\(section).topics.row", in: window)
        _ = try element("simple.\(section).topics.open", in: window)
        try require(!nodes(window).contains { $0.accessibilityIdentifier() == "simple.\(section).topics.correct" }, "Rendered Topics correction must be absent")
        let topicRow = try element("simple.\(section).topics.row", in: window)
        try require(!tree(topicRow).contains { $0.accessibilityRole() == .button && $0.accessibilityLabel() == "Исправить" }, "Unidentified Correct button was rendered in Topics row")
    }
}
