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
        if let modern { return modern.accessibilityLabel() }
        let label = objectValue("accessibilityLabel") as? String
        return label?.isEmpty == false ? label : objectValue("accessibilityTitle") as? String
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
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        NSApplication.shared.accessibilitySetValue(
            NSNumber(value: true),
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
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

    private static func assertSimple(_ window: NSWindow) throws {
        let picker = try element("simple.modePicker", in: window)
        let simpleSelected = tree(picker).contains {
            $0.accessibilityLabel() == "Простой" && ($0.accessibilityValue() as? NSNumber)?.intValue == 1
        }
        let value = picker.accessibilityValue() as? String
        try require(simpleSelected || value == "Простой" || value == "simple", "Global mode is not rendered as selected Simple")
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
        try press("simple.goal.textContent", in: window)
        _ = try element("simple.textContent.panel", in: window)
        try assertSimple(window)
        try assertControls("textContent", window: window)
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
        try press("simple.review.\(target).close", in: window)
        _ = try element("simple.textContent.panel", in: window)
        try assertSimple(window)
        let unrelated = translation ? "transcription" : "translation"
        try require(!element("simple.textContent.\(unrelated).correct", in: window).isAccessibilityEnabled(), "Unrelated language Correct must be disabled during pending review")
        try press("simple.textContent.\(artifact).correct", in: window)
        _ = try element("simple.review.\(target).sheet", in: window)
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
