import AppKit
import SwiftUI
import AVFoundation

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

    private static func makeFixtureVideo(at url: URL, durationSeconds: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 16,
                AVVideoHeightKey: 16
            ]
        )
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 16,
            kCVPixelBufferHeightKey as String: 16
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )
        guard writer.canAdd(input) else {
            throw RenderedProbeFailure(message: "Could not create local media fixture")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw RenderedProbeFailure(message: "Could not start local media fixture writer")
        }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(durationSeconds * 30) {
            while !input.isReadyForMoreMediaData {
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(
                kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
                attributes as CFDictionary, &buffer
            ) == kCVReturnSuccess, let buffer else {
                throw RenderedProbeFailure(message: "Could not allocate local media fixture frame")
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                base.assumingMemoryBound(to: UInt8.self).initialize(
                    repeating: 0,
                    count: CVPixelBufferGetDataSize(buffer)
                )
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw RenderedProbeFailure(message: "Could not append local media fixture frame")
            }
        }
        input.markAsFinished()
        let completion = DispatchSemaphore(value: 0)
        writer.finishWriting { completion.signal() }
        guard completion.wait(timeout: .now() + 10) == .success, writer.status == .completed else {
            throw RenderedProbeFailure(message: "Could not finish local media fixture")
        }
    }

    private static func measuredDuration(of mediaURL: URL) -> TimeInterval? {
        let duration = AVURLAsset(url: mediaURL).duration.seconds
        return duration.isFinite && duration > 0 ? duration : nil
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
            try makeFixtureVideo(at: media, durationSeconds: 5)
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
        try verifySourceSubtitledVideoControls(project: scratch.appendingPathComponent("subtitled-video"), media: media)
        try verifySimpleCutRangeControls(project: scratch.appendingPathComponent("simple-cut-range"), media: media)
        try verifySimpleTopicCutControls(project: scratch.appendingPathComponent("simple-topic-cut"), media: media)
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
        guard let duration = measuredDuration(of: media) else {
            throw RenderedProbeFailure(message: "Fixture media has no readable duration")
        }
        manifest.durationSeconds = duration
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
        let whisper: [String: Any] = [
            "result": ["language": source.rawValue],
            "transcription": [["tokens": [["text": " approved", "offsets": ["from": 0, "to": 500]]]]]
        ]
        try JSONSerialization.data(withJSONObject: whisper, options: [.sortedKeys])
            .write(to: layout.whisperJSONURL, options: .atomic)
        let topics = TopicsFile(
            adapter: TopicAlgorithmIdentity.hybridAdapter, createdAt: Date(), sourceSRT: layout.fullSRTURL.path,
            sourceSignature: StableTopicHash.string(try String(contentsOf: layout.fullSRTURL, encoding: .utf8)),
            topics: [TopicSegment(id: "topic-1", title: "Approved fixture topic", start: 0, end: 4,
                summary: "Two approved cues.", keywords: ["fixture"], confidence: 1,
                boundaryReason: "Start of fixture", cueIds: [1, 2])]
        )
        try TopicFileService().save(topics, projectURL: project, language: source, granularity: .normal, updateLegacyFiles: true)
        let topicRevisionID = "approved-topics"
        let approvedTopicsURL = layout.topicRevisionJSONURL(id: topicRevisionID)
        let approvedTopicsTextURL = layout.topicRevisionTextURL(id: topicRevisionID)
        try FileManager.default.createDirectory(at: approvedTopicsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: layout.topicsURL(language: source, granularity: .normal))
            .write(to: approvedTopicsURL, options: .atomic)
        try Data(contentsOf: layout.topicsTextURL(language: source, granularity: .normal))
            .write(to: approvedTopicsTextURL, options: .atomic)
        let topic = TopicRevision(
            id: topicRevisionID, language: source, granularity: .normal, parentRevisionID: nil,
            jsonPath: approvedTopicsURL.path,
            textPath: approvedTopicsTextURL.path,
            contentHash: StableTopicHash.string(try String(contentsOf: approvedTopicsURL, encoding: .utf8)),
            status: .approved, createdAt: Date()
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

    private static func selectSubtitledVideoSource(
        translated: Bool,
        targetLanguage: ArtifactLanguage,
        in window: NSWindow
    ) throws {
        let picker = try element("simple.subtitledVideo.source", in: window)
        let label = translated ? "Переведённые (\(targetLanguage.rawValue.uppercased()))" : "Исходные"
        guard let option = tree(picker).first(where: { $0.accessibilityLabel() == label }) else {
            throw RenderedProbeFailure(message: "Simple subtitle source picker has no rendered \(label) option")
        }
        let performed = option.accessibilityPerformPress()
        if !performed {
            try clickRenderedSegment(option, in: window)
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
        let staleTarget = project.appendingPathComponent("translation-stale")
        _ = try makeProject(staleTarget, media: media, source: .ru)
        let staleLayout = ProjectLayout(root: staleTarget)
        try "1\n00:00:00,000 --> 00:00:02,000\nStale target subtitles\n".write(
            to: staleLayout.subtitlesURL(language: .en), atomically: true, encoding: .utf8
        )
        let staleModel = WorkflowViewModel()
        staleModel.openProject(staleTarget)
        let staleWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        staleWindow.isReleasedWhenClosed = false
        staleWindow.contentView = NSHostingView(rootView: ContentView(model: staleModel))
        staleWindow.makeKeyAndOrderFront(nil)
        defer { staleWindow.close() }
        settle(staleWindow)
        try press("simple.goal.subtitledVideo", in: staleWindow)
        _ = try element("simple.subtitledVideo.translation.unavailable", in: staleWindow)
        try require(staleModel.simpleApprovedTranslatedSubtitleTarget == nil
            && staleModel.simpleTranslatedSubtitleWorkflowRequest == nil
            && !nodes(staleWindow).contains { $0.accessibilityIdentifier() == "simple.subtitledVideo.source" },
            "Stale target SRT exposed a translated subtitle selection or request")
        let staleOperations = (try store.load(from: staleTarget)).workflow?.operations ?? [:]
        try require(staleOperations[WorkflowOperation.transcribe.rawValue] == nil
            && staleOperations[WorkflowOperation.topicTimecoding.rawValue] == nil
            && staleOperations[WorkflowOperation.translateTranscript.rawValue] == nil,
            "Fail-closed target provenance validation started ASR, topics, or translation")

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

    private static func verifySourceSubtitledVideoControls(project: URL, media: URL) throws {
        let store = ProjectStore()
        let sourceOnly = project.appendingPathComponent("source-unapproved")
        var missingManifest = try store.ensureProject(at: sourceOnly, mediaURL: media, mode: .newProject)
        missingManifest.languageProfile = LanguageProfile(
            detected: .ru, effective: .ru, confidence: 1, method: "fixture",
            model: nil, modelVersion: nil, sampleRanges: [], manuallyOverridden: false, detectedAt: Date()
        )
        try store.save(missingManifest, to: sourceOnly)
        let unapproved = WorkflowViewModel()
        unapproved.projectURL = sourceOnly
        unapproved.mediaURL = media
        unapproved.loadDetectedResults()
        let unapprovedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        unapprovedWindow.isReleasedWhenClosed = false
        unapprovedWindow.contentView = NSHostingView(rootView: ContentView(model: unapproved))
        unapprovedWindow.makeKeyAndOrderFront(nil)
        defer { unapprovedWindow.close() }
        settle(unapprovedWindow)
        try press("simple.goal.subtitledVideo", in: unapprovedWindow)
        let unavailable = try element("simple.subtitledVideo.availability", in: unapprovedWindow)
        try require(renderedText(unavailable).contains("утвердите исходную расшифровку"),
            "Unapproved source did not explain why subtitle rendering is unavailable")
        try require(!element("simple.subtitledVideo.create", in: unapprovedWindow).isAccessibilityEnabled(),
            "Unapproved source exposed enabled subtitle rendering")

        let accepted = project.appendingPathComponent("source-approved")
        _ = try makeProject(accepted, media: media, source: .ru)
        let model = WorkflowViewModel()
        model.projectURL = accepted
        model.mediaURL = media
        model.selectedOperations = [.transcribe, .topicTimecoding]
        model.subtitleSource = .approvedTranslation(.en)
        model.subtitleStyle = SubtitleStyleSettings(
            textColorHex: "#FFFFFF", outlineColorHex: "#000000", fontName: "Helvetica", fontSize: 26,
            outlineWidth: 3, position: .bottom, backgroundOpacity: 0.3
        )
        let advancedOperations = model.selectedOperations
        let advancedSubtitleSource = model.subtitleSource
        let advancedSubtitleStyle = model.subtitleStyle
        model.loadDetectedResults()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        settle(window)
        try press("simple.goal.subtitledVideo", in: window)
        let create = try element("simple.subtitledVideo.create", in: window)
        try require(create.accessibilityRole() == .button
            && create.accessibilityLabel() == "Создать видео с субтитрами"
            && create.isAccessibilityEnabled(),
            "Approved source and canonical SRT have no truthful Simple subtitle-render CTA")
        try require(renderedText(try element("simple.subtitledVideo.availability", in: window))
            .contains("утверждённые исходные субтитры"),
            "Simple subtitle render did not disclose the accepted source input")
        guard let request = model.simpleSourceSubtitleWorkflowRequest else {
            throw RenderedProbeFailure(message: "Approved source did not expose the Simple subtitle workflow request")
        }
        try require(request.operations == [.burnSubtitles]
            && request.subtitleSource == .source
            && request.subtitleStyle == .standard
            && request.language == .ru
            && request.approvedRevisionID == "approved-ru",
            "Simple subtitle adapter request is not exactly source-only burnSubtitles with standard style and approved provenance")
        try require(model.selectedOperations == advancedOperations
            && model.subtitleSource == advancedSubtitleSource
            && model.subtitleStyle == advancedSubtitleStyle,
            "Opening Simple subtitle render rewrote Advanced selections")
        try require(nodes(window).contains { $0.accessibilityIdentifier() == "simple.subtitledVideo.source" },
            "An approved translated target did not expose the Simple subtitle-source choice")
        try selectSubtitledVideoSource(translated: true, targetLanguage: .en, in: window)
        let translatedCreate = try element("simple.subtitledVideo.translation.create", in: window)
        try require(translatedCreate.accessibilityRole() == .button
            && translatedCreate.accessibilityLabel() == "Создать видео с субтитрами"
            && translatedCreate.isAccessibilityEnabled(),
            "Approved target translation has no truthful Simple subtitle-render CTA")
        try require(renderedText(try element("simple.subtitledVideo.translation.availability", in: window))
            .contains("утверждённые переведённые субтитры EN"),
            "Simple target subtitle render did not disclose the approved translated input")
        guard let translatedRequest = model.simpleTranslatedSubtitleWorkflowRequest else {
            throw RenderedProbeFailure(message: "Approved translated target did not expose the Simple subtitle workflow request")
        }
        try require(translatedRequest.operations == [.burnSubtitles]
            && translatedRequest.subtitleSource == .approvedTranslation(.en)
            && translatedRequest.subtitleStyle == .standard
            && translatedRequest.sourceLanguage == .ru
            && translatedRequest.sourceApprovedRevisionID == "approved-ru"
            && translatedRequest.targetLanguage == .en,
            "Simple translated subtitle request is not exactly approved-target burnSubtitles with standard style and source reuse provenance")
        try require(model.selectedOperations == advancedOperations
            && model.subtitleSource == advancedSubtitleSource
            && model.subtitleStyle == advancedSubtitleStyle,
            "Selecting Simple translated subtitles rewrote Advanced selections")
        try selectSubtitledVideoSource(translated: false, targetLanguage: .en, in: window)

        // Press the real rendered CTA on a separate fixture, then cancel in the
        // same main-actor turn. The controlled ProcessController proves that
        // activation enters the existing workflow without launching any tool.
        let activationProject = project.appendingPathComponent("activation")
        _ = try makeProject(activationProject, media: media, source: .ru)
        let activationHistory = ProjectHistoryStore(indexURL: project.appendingPathComponent("activation-history.json"))
        let activationStore = ProjectStore(history: activationHistory)
        let activationController = ProcessController()
        let activationEngine = WorkflowEngine(store: activationStore, controller: activationController)
        let activation = WorkflowViewModel(
            engine: activationEngine,
            store: activationStore,
            historyStore: activationHistory
        )
        activation.openProject(activationProject)
        activation.selectedOperations = [.transcribe, .topicTimecoding]
        activation.subtitleSource = .approvedTranslation(.en)
        activation.subtitleStyle = advancedSubtitleStyle
        let activationWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        activationWindow.isReleasedWhenClosed = false
        activationWindow.contentView = NSHostingView(rootView: ContentView(model: activation))
        activationWindow.makeKeyAndOrderFront(nil)
        defer { activationWindow.close() }
        settle(activationWindow)
        let activationCreate = try element("simple.goal.subtitledVideo", in: activationWindow)
        try require(activationCreate.accessibilityPerformPress(), "Simple subtitle goal did not open its rendered panel")
        settle(activationWindow)
        let activationButton = try element("simple.subtitledVideo.create", in: activationWindow)
        try require(activationButton.isAccessibilityEnabled() && activationButton.accessibilityPerformPress(),
            "Simple subtitle CTA did not activate")
        try require(activation.isRunning && !activation.isStopping,
            "Simple subtitle CTA did not enter the existing workflow")
        try require(activation.selectedOperations == [.transcribe, .topicTimecoding]
            && activation.subtitleSource == .approvedTranslation(.en)
            && activation.subtitleStyle == advancedSubtitleStyle,
            "Simple subtitle CTA did not restore Advanced presentation choices after capturing its fixed request")
        activation.stop()
        try require(activation.isStopping, "Simple subtitle CTA did not reuse the existing cancellation path")
        for _ in 0..<200 where activation.isRunning {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        try require(!activation.isRunning && activation.status == "Остановлено",
            "Immediate Simple subtitle cancellation did not finish through the existing workflow lifecycle: running=\(activation.isRunning), status=\(activation.status), launches=\(activationController.launchedExecutables)")
        try require(activationController.launchedExecutables.isEmpty,
            "Immediate subtitle CTA cancellation launched external processing: \(activationController.launchedExecutables)")
        let activationOperations = (try activationStore.load(from: activationProject)).workflow?.operations ?? [:]
        try require(activationOperations[WorkflowOperation.transcribe.rawValue] == nil
            && activationOperations[WorkflowOperation.topicTimecoding.rawValue] == nil,
            "Simple subtitle CTA started ASR or topics before cancellation")

        let translatedActivationProject = project.appendingPathComponent("translated-activation")
        _ = try makeProject(translatedActivationProject, media: media, source: .ru)
        let translatedActivationLayout = ProjectLayout(root: translatedActivationProject)
        try FileManager.default.createDirectory(at: translatedActivationLayout.subtitledVideoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("existing source video".utf8).write(to: translatedActivationLayout.subtitledVideoURL)
        try store.registerOutput(kind: "subtitled-video", url: translatedActivationLayout.subtitledVideoURL, in: translatedActivationProject)
        let translatedActivationHistory = ProjectHistoryStore(indexURL: project.appendingPathComponent("translated-activation-history.json"))
        let translatedActivationStore = ProjectStore(history: translatedActivationHistory)
        let translatedActivationController = ProcessController()
        let translatedActivation = WorkflowViewModel(
            engine: WorkflowEngine(store: translatedActivationStore, controller: translatedActivationController),
            store: translatedActivationStore,
            historyStore: translatedActivationHistory
        )
        translatedActivation.openProject(translatedActivationProject)
        translatedActivation.selectedOperations = [.transcribe, .topicTimecoding]
        translatedActivation.subtitleSource = .source
        translatedActivation.subtitleStyle = advancedSubtitleStyle
        let translatedActivationWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        translatedActivationWindow.isReleasedWhenClosed = false
        translatedActivationWindow.contentView = NSHostingView(rootView: ContentView(model: translatedActivation))
        translatedActivationWindow.makeKeyAndOrderFront(nil)
        defer { translatedActivationWindow.close() }
        settle(translatedActivationWindow)
        try press("simple.goal.subtitledVideo", in: translatedActivationWindow)
        try selectSubtitledVideoSource(translated: true, targetLanguage: .en, in: translatedActivationWindow)
        let translatedActivationButton = try element("simple.subtitledVideo.translation.create", in: translatedActivationWindow)
        try require(translatedActivationButton.isAccessibilityEnabled() && translatedActivationButton.accessibilityPerformPress(),
            "Simple approved-target subtitle CTA did not activate")
        try require(translatedActivation.isRunning && !translatedActivation.isStopping,
            "Simple approved-target subtitle CTA did not enter the existing workflow")
        try require(translatedActivation.selectedOperations == [.transcribe, .topicTimecoding]
            && translatedActivation.subtitleSource == .source
            && translatedActivation.subtitleStyle == advancedSubtitleStyle,
            "Simple approved-target subtitle CTA did not preserve Advanced presentation choices")
        translatedActivation.stop()
        for _ in 0..<200 where translatedActivation.isRunning {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        try require(!translatedActivation.isRunning && translatedActivation.status == "Остановлено"
            && translatedActivationController.launchedExecutables.isEmpty,
            "Immediate approved-target subtitle cancellation bypassed the existing lifecycle")
        let translatedActivationOperations = (try translatedActivationStore.load(from: translatedActivationProject)).workflow?.operations ?? [:]
        try require(translatedActivationOperations[WorkflowOperation.transcribe.rawValue] == nil
            && translatedActivationOperations[WorkflowOperation.topicTimecoding.rawValue] == nil
            && translatedActivationOperations[WorkflowOperation.translateTranscript.rawValue] == nil,
            "Simple approved-target subtitle CTA started ASR, topics, or translation")
        try require(try Data(contentsOf: translatedActivationLayout.subtitledVideoURL) == Data("existing source video".utf8)
            && !FileManager.default.fileExists(atPath: translatedActivationLayout.subtitledVideoURL(language: .en).path),
            "Launching an approved-target subtitle render changed the existing source result or created a target result before render")

        // A Simple action can fail during an accepted-transcript prerequisite
        // before burnSubtitles becomes the active progress operation. Its actual
        // action error must remain visible without inferring success from progress.
        activation.status = "Ошибка"
        activation.progress = WorkflowProgress(operation: nil, operationFraction: 0, overallFraction: 0,
            elapsed: 0, estimatedTotal: nil, remaining: nil, isIndeterminate: false)
        settle(activationWindow)
        _ = try element("simple.subtitledVideo.error", in: activationWindow)
        try require(element("simple.subtitledVideo.create", in: activationWindow).isAccessibilityEnabled(),
            "Simple prerequisite failure did not retain a truthful retry action")

        let layout = ProjectLayout(root: accepted)
        try "1\n00:00:00,000 --> 00:00:02,000\nПодменённые субтитры\n".write(
            to: layout.subtitlesURL(language: .ru), atomically: true, encoding: .utf8
        )
        model.loadDetectedResults()
        settle(window)
        try require(!element("simple.subtitledVideo.create", in: window).isAccessibilityEnabled(),
            "A source SRT that diverges from the approved revision was accepted")
        try require(!model.canCreateSourceSubtitledVideoFromAcceptedTranscript
            && model.simpleSourceSubtitleWorkflowRequest == nil,
            "Divergent source SRT still exposed a reusable accepted-transcript request")
        try require(renderedText(try element("simple.subtitledVideo.availability", in: window))
            .contains("подготовьте исходные субтитры"), "Divergent source SRT did not fail closed in Simple")
        let divergentOperations = (try store.load(from: accepted)).workflow?.operations ?? [:]
        try require(divergentOperations[WorkflowOperation.transcribe.rawValue] == nil
            && divergentOperations[WorkflowOperation.topicTimecoding.rawValue] == nil,
            "Fail-closed source provenance validation started ASR or topics")
        let approvedBytes = try Data(contentsOf: layout.subtitleRevisionURL(id: "approved-ru", language: .ru))
        try approvedBytes.write(to: layout.subtitlesURL(language: .ru), options: .atomic)
        model.loadDetectedResults()
        settle(window)
        try require(element("simple.subtitledVideo.create", in: window).isAccessibilityEnabled(),
            "Restored canonical source SRT did not restore the Simple subtitle-render CTA")

        model.progress = WorkflowProgress(operation: .burnSubtitles, operationFraction: 0.2, overallFraction: 0.1,
            elapsed: 1, estimatedTotal: nil, remaining: nil, isIndeterminate: true)
        model.isRunning = true
        settle(window)
        try require(renderedText(try element("simple.progress.stage", in: window)).contains("Создаём видео с субтитрами"),
            "Simple progress did not render the active subtitle render stage")
        try require(element("simple.progress.stop", in: window).isAccessibilityEnabled(),
            "Simple subtitle render did not reuse the existing stop action")
        try require(!element("simple.subtitledVideo.create", in: window).isAccessibilityEnabled(),
            "Simple exposed a duplicate subtitle render while processing")
        model.isStopping = true
        settle(window)
        try require(!element("simple.progress.stop", in: window).isAccessibilityEnabled()
            && renderedText(try element("simple.progress.stage", in: window)).contains("Останавливаем обработку"),
            "Simple subtitle render stop state allowed repeated cancellation")
        model.isStopping = false
        model.isRunning = false
        model.status = "Ошибка"
        settle(window)
        try require(element("simple.subtitledVideo.create", in: window).isAccessibilityEnabled(),
            "Subtitle render failure did not preserve an honest retry action")

        try FileManager.default.createDirectory(at: layout.subtitledVideoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("ready video".utf8).write(to: layout.subtitledVideoURL)
        try store.registerOutput(kind: "subtitled-video", url: layout.subtitledVideoURL, in: accepted)
        model.status = "Завершено"
        model.loadDetectedResults()
        let rediscovered = model.outputs.map { "\($0.kind):\($0.path)" }.joined(separator: ", ")
        try require(model.outputs.contains {
            $0.kind == "subtitled-video"
        }, "Registered source subtitled output was not rediscovered: \(rediscovered)")
        settle(window)
        _ = try element("simple.subtitledVideo.open", in: window)
        try require(!nodes(window).contains { $0.accessibilityIdentifier() == "simple.subtitledVideo.create" },
            "Existing source subtitled video exposed a duplicate render CTA")
        try FileManager.default.createDirectory(at: layout.subtitledVideoURL(language: .en).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("ready target video".utf8).write(to: layout.subtitledVideoURL(language: .en))
        try store.registerOutput(kind: "subtitled-video-en", url: layout.subtitledVideoURL(language: .en), in: accepted)
        model.loadDetectedResults()
        try selectSubtitledVideoSource(translated: true, targetLanguage: .en, in: window)
        _ = try element("simple.subtitledVideo.translation.open", in: window)
        try require(!nodes(window).contains { $0.accessibilityIdentifier() == "simple.subtitledVideo.translation.create" },
            "Existing translated subtitled video exposed a duplicate render CTA")

        let reopened = WorkflowViewModel()
        reopened.openProject(accepted)
        let reopenedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        reopenedWindow.isReleasedWhenClosed = false
        reopenedWindow.contentView = NSHostingView(rootView: ContentView(model: reopened))
        reopenedWindow.makeKeyAndOrderFront(nil)
        defer { reopenedWindow.close() }
        settle(reopenedWindow)
        try press("simple.goal.subtitledVideo", in: reopenedWindow)
        _ = try element("simple.subtitledVideo.open", in: reopenedWindow)
        try require(!reopened.isRunning && !nodes(reopenedWindow).contains {
            $0.accessibilityIdentifier() == "simple.subtitledVideo.create"
        }, "Reopening a completed source subtitled video exposed regeneration")
        try selectSubtitledVideoSource(translated: true, targetLanguage: .en, in: reopenedWindow)
        _ = try element("simple.subtitledVideo.translation.open", in: reopenedWindow)
        try require(!reopened.isRunning && !nodes(reopenedWindow).contains {
            $0.accessibilityIdentifier() == "simple.subtitledVideo.translation.create"
        }, "Reopening a completed translated subtitled video exposed regeneration")
        print("RENDERED_SOURCE_SUBTITLED_VIDEO_CONTROLS_PASS: source and approved target requests, progress/stop/error, source preservation, target open/reopen")
    }

    private static func verifySimpleCutRangeControls(project: URL, media: URL) throws {
        _ = try makeProject(project, media: media, source: .ru)
        let store = ProjectStore()
        let layout = ProjectLayout(root: project)

        let model = WorkflowViewModel()
        model.openProject(project)
        model.selectedOperations = [.transcribe, .topicTimecoding]
        model.rangeStartText = "00:00:01.000"
        model.rangeEndText = "00:00:03.000"
        model.fragmentName = "Advanced fragment name"
        model.burnFragmentSubtitles = true
        model.subtitleSource = .approvedTranslation(.en)
        model.subtitleStyle = SubtitleStyleSettings(
            textColorHex: "#FF00FF", outlineColorHex: "#000000", fontName: "Georgia", fontSize: 31,
            outlineWidth: 4, position: .top, backgroundOpacity: 0.6
        )
        let advancedOperations = model.selectedOperations
        let advancedStart = model.rangeStartText
        let advancedEnd = model.rangeEndText
        let advancedName = model.fragmentName
        let advancedBurn = model.burnFragmentSubtitles
        let advancedSource = model.subtitleSource
        let advancedStyle = model.subtitleStyle

        guard let zeroRequest = model.simpleCutRangeWorkflowRequest(
            startText: "00:00:00", endText: "00:00:02"
        ) else {
            throw RenderedProbeFailure(message: "Approved source did not expose a Simple zero-start cut request")
        }
        try require(zeroRequest.operations == [.cutRange]
            && zeroRequest.start == 0 && zeroRequest.end == 2
            && zeroRequest.fragmentName == "Фрагмент"
            && !zeroRequest.burnFragmentSubtitles
            && zeroRequest.subtitleSource == .source
            && zeroRequest.subtitleStyle == .standard
            && zeroRequest.language == .ru
            && zeroRequest.approvedRevisionID == "approved-ru",
            "Simple cut request is not the fixed source-only cutRange request")
        guard let actualDuration = measuredDuration(of: media) else {
            throw RenderedProbeFailure(message: "Simple cut fixture has no actual source duration")
        }
        let originalManifest = try store.load(from: project)
        var overstatedManifest = originalManifest
        overstatedManifest.durationSeconds = actualDuration + 10
        try store.save(overstatedManifest, to: project)
        let beyondActual = String(format: "%.3f", actualDuration + 1)
        try require(
            model.simpleCutRangeWorkflowRequest(startText: "00:00:00", endText: beyondActual) == nil
                && !model.simpleCutRangeAvailability(startText: "00:00:00", endText: beyondActual).canCreate,
            "Overstated manifest duration exposed a Simple cut request beyond actual media"
        )
        let blockedOperations = (try store.load(from: project)).workflow?.operations ?? [:]
        try require(blockedOperations[WorkflowOperation.cutRange.rawValue] == nil,
            "Actual-duration preflight started cutRange for an invalid range")
        try store.save(originalManifest, to: project)
        for invalid in [
            ("00:00:02", "00:00:02"),
            ("00:00:03", "00:00:02"),
            ("-1", "00:00:02"),
            ("wrong", "00:00:02"),
            ("00:00:00", String(format: "%.3f", actualDuration + 1))
        ] {
            try require(model.simpleCutRangeWorkflowRequest(startText: invalid.0, endText: invalid.1) == nil
                && !model.simpleCutRangeAvailability(startText: invalid.0, endText: invalid.1).canCreate,
                "Invalid Simple range \(invalid.0)-\(invalid.1) exposed a request")
        }
        try require(model.selectedOperations == advancedOperations
            && model.rangeStartText == advancedStart && model.rangeEndText == advancedEnd
            && model.fragmentName == advancedName && model.burnFragmentSubtitles == advancedBurn
            && model.subtitleSource == advancedSource && model.subtitleStyle == advancedStyle,
            "Inspecting Simple cut ranges rewrote Advanced cut controls")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        settle(window)
        try press("simple.goal.fragment", in: window)
        _ = try element("simple.fragment.panel", in: window)
        let startField = try element("simple.fragment.start", in: window)
        let endField = try element("simple.fragment.end", in: window)
        try require(startField.accessibilityLabel() == "Начало фрагмента"
            && endField.accessibilityLabel() == "Конец фрагмента",
            "Simple cut panel did not render human-readable start/end fields")
        try require(renderedText(try element("simple.fragment.availability", in: window))
            .contains("утверждёнными исходными субтитрами"),
            "Simple cut panel did not disclose its accepted source prerequisite")
        let create = try element("simple.fragment.create", in: window)
        try require(create.accessibilityRole() == .button
            && create.accessibilityLabel() == "Создать фрагмент" && create.isAccessibilityEnabled(),
            "Simple zero-start range has no enabled rendered create action")

        let activationProject = project.appendingPathComponent("activation")
        _ = try makeProject(activationProject, media: media, source: .ru)
        let activationHistory = ProjectHistoryStore(indexURL: project.appendingPathComponent("activation-history.json"))
        let activationStore = ProjectStore(history: activationHistory)
        let activationController = ProcessController()
        let activation = WorkflowViewModel(
            engine: WorkflowEngine(store: activationStore, controller: activationController),
            store: activationStore,
            historyStore: activationHistory
        )
        activation.openProject(activationProject)
        activation.selectedOperations = advancedOperations
        activation.rangeStartText = advancedStart
        activation.rangeEndText = advancedEnd
        activation.fragmentName = advancedName
        activation.burnFragmentSubtitles = advancedBurn
        activation.subtitleSource = advancedSource
        activation.subtitleStyle = advancedStyle
        let activationWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        activationWindow.isReleasedWhenClosed = false
        activationWindow.contentView = NSHostingView(rootView: ContentView(model: activation))
        activationWindow.makeKeyAndOrderFront(nil)
        defer { activationWindow.close() }
        settle(activationWindow)
        try press("simple.goal.fragment", in: activationWindow)
        let activationCreate = try element("simple.fragment.create", in: activationWindow)
        try require(activationCreate.isAccessibilityEnabled() && activationCreate.accessibilityPerformPress(),
            "Simple cut CTA did not activate")
        try require(activation.isRunning && !activation.isStopping,
            "Simple cut CTA did not enter the shared workflow")
        try require(activation.selectedOperations == advancedOperations
            && activation.rangeStartText == advancedStart && activation.rangeEndText == advancedEnd
            && activation.fragmentName == advancedName && activation.burnFragmentSubtitles == advancedBurn
            && activation.subtitleSource == advancedSource && activation.subtitleStyle == advancedStyle,
            "Simple cut CTA rewrote Advanced cut controls")
        activation.stop()
        try require(activation.isStopping, "Simple cut CTA did not reuse the shared Stop action")
        for _ in 0..<200 where activation.isRunning {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        try require(!activation.isRunning && activation.status == "Остановлено"
            && activationController.launchedExecutables.isEmpty,
            "Immediate Simple cut cancellation bypassed shared lifecycle")
        let activationOperations = (try activationStore.load(from: activationProject)).workflow?.operations ?? [:]
        let forbiddenOperations = [
            WorkflowOperation.transcribe, .topicTimecoding, .translateTranscript,
            .burnSubtitles, .burnFragmentSubtitles, .cutTopic, .renderFragment
        ]
        try require(forbiddenOperations.allSatisfy { activationOperations[$0.rawValue] == nil },
            "Simple cut started an operation outside cutRange: \(activationOperations.keys.sorted())")
        try require(!nodes(activationWindow).contains { $0.accessibilityIdentifier() == "simple.fragment.ready" },
            "Cancelled Simple cut displayed a false ready result")

        model.progress = WorkflowProgress(operation: .cutRange, operationFraction: 0.3, overallFraction: 0.3,
            elapsed: 1, estimatedTotal: nil, remaining: nil, isIndeterminate: true)
        model.isRunning = true
        settle(window)
        try require(renderedText(try element("simple.progress.stage", in: window)).contains("Создаём фрагмент"),
            "Simple cut did not render the shared cutRange progress stage")
        try require(element("simple.progress.stop", in: window).isAccessibilityEnabled(),
            "Simple cut progress did not render Stop")
        try require(!element("simple.fragment.create", in: window).isAccessibilityEnabled(),
            "Simple cut exposed duplicate create while running")
        model.isStopping = true
        settle(window)
        try require(!element("simple.progress.stop", in: window).isAccessibilityEnabled()
            && renderedText(try element("simple.progress.stage", in: window)).contains("Останавливаем обработку"),
            "Simple cut allowed repeated cancellation")
        model.isStopping = false
        model.isRunning = false
        model.status = "Ошибка"
        settle(window)
        try require(element("simple.fragment.create", in: window).isAccessibilityEnabled(),
            "Simple cut failure did not retain an honest retry action")

        let fullVideo = layout.subtitledVideoURL
        try FileManager.default.createDirectory(at: fullVideo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("existing full video".utf8).write(to: fullVideo)
        try store.registerOutput(kind: "subtitled-video", url: fullVideo, in: project)
        let fragment = layout.fragmentVideoURL(kind: "simple-cut")
        try FileManager.default.createDirectory(at: fragment.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("ready fragment".utf8).write(to: fragment)
        try store.registerOutput(kind: "fragment-video", url: fragment, in: project)
        model.status = "Завершено"
        let persistedOutputs = try store.load(from: project).outputs
        let preservedFullVideo = try Data(contentsOf: fullVideo) == Data("existing full video".utf8)
        try require(persistedOutputs.contains { $0.kind == "subtitled-video" && $0.path == fullVideo.path }
            && persistedOutputs.contains { $0.kind == "fragment-video" && $0.path == fragment.path }
            && preservedFullVideo,
            "Registering the cut result displaced an existing full-video result")
        model.loadDetectedResults()
        try require(model.outputs.contains { $0.kind == "fragment-video" },
            "Registered cut result was not rediscovered")
        settle(window)
        _ = try element("simple.fragment.ready", in: window)
        _ = try element("simple.fragment.open", in: window)

        let reopened = WorkflowViewModel()
        reopened.openProject(project)
        let reopenedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        reopenedWindow.isReleasedWhenClosed = false
        reopenedWindow.contentView = NSHostingView(rootView: ContentView(model: reopened))
        reopenedWindow.makeKeyAndOrderFront(nil)
        defer { reopenedWindow.close() }
        settle(reopenedWindow)
        try press("simple.goal.fragment", in: reopenedWindow)
        _ = try element("simple.fragment.ready", in: reopenedWindow)
        _ = try element("simple.fragment.open", in: reopenedWindow)
        try require(!reopened.isRunning, "Reopening a completed Simple cut started a duplicate render")
        print("RENDERED_SIMPLE_CUT_RANGE_CONTROLS_PASS: valid/invalid ranges, fixed request, stop, result/open/reopen, full-video and Advanced preservation")
    }

    private static func verifySimpleTopicCutControls(project: URL, media: URL) throws {
        let unavailableProject = project.appendingPathComponent("unavailable")
        try removeTopics(from: unavailableProject, media: media)
        let unavailable = WorkflowViewModel()
        unavailable.openProject(unavailableProject)
        let unavailableWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        unavailableWindow.isReleasedWhenClosed = false
        unavailableWindow.contentView = NSHostingView(rootView: ContentView(model: unavailable))
        unavailableWindow.makeKeyAndOrderFront(nil)
        defer { unavailableWindow.close() }
        settle(unavailableWindow)
        try press("simple.goal.fragment", in: unavailableWindow)
        _ = try element("simple.fragment.topic.unavailable", in: unavailableWindow)
        try require(!element("simple.fragment.topic.create", in: unavailableWindow).isAccessibilityEnabled(),
            "Simple topic cut exposed a create action without an approved topic snapshot")

        _ = try makeProject(project, media: media, source: .ru)
        let store = ProjectStore()
        let layout = ProjectLayout(root: project)
        let model = WorkflowViewModel()
        model.openProject(project)
        model.selectedOperations = [.transcribe, .topicTimecoding]
        model.selectedTopicID = "advanced-topic"
        model.artifactLanguage = .en
        model.topicGranularity = .detailed
        let advancedOperations = model.selectedOperations
        let advancedTopicID = model.selectedTopicID
        let advancedLanguage = model.artifactLanguage
        let advancedGranularity = model.topicGranularity

        let options = model.simpleApprovedTopicOptions
        try require(options.count == 1
            && options[0].id == "topic-1"
            && options[0].title == "Approved fixture topic"
            && options[0].start == 0 && options[0].end == 4,
            "Simple topic picker did not expose exactly the approved immutable topic range")
        guard let request = model.simpleTopicCutWorkflowRequest(topicID: options[0].id) else {
            throw RenderedProbeFailure(message: "Approved Simple topic did not expose a cut request")
        }
        try require(request.operations == [.cutTopic]
            && request.topicID == options[0].id
            && request.language == .ru && request.granularity == .normal
            && request.topicRevisionID == "approved-topics"
            && request.approvedRevisionID == "approved-ru"
            && request.subtitleSource == .source && request.subtitleStyle == .standard,
            "Simple topic cut request is not the fixed approved source-only cutTopic request")
        try require(model.simpleTopicCutWorkflowRequest(topicID: "missing-topic") == nil
            && !model.simpleTopicCutAvailability(topicID: "missing-topic").canCreate,
            "Unknown topic exposed a Simple cut request")
        try require(model.selectedOperations == advancedOperations
            && model.selectedTopicID == advancedTopicID
            && model.artifactLanguage == advancedLanguage
            && model.topicGranularity == advancedGranularity,
            "Inspecting Simple topic choices rewrote Advanced bindings")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        settle(window)
        try press("simple.goal.fragment", in: window)
        _ = try element("simple.fragment.topic.picker", in: window)
        try require(element("simple.fragment.topic.create", in: window).isAccessibilityEnabled()
            && renderedText(try element("simple.fragment.topic.availability", in: window)).contains("Выберите тему, чтобы создать фрагмент")
            && !nodes(window).contains { $0.accessibilityIdentifier() == "simple.fragment.topic.validation" },
            "Simple topic selection showed validation before an attempted Create")
        try press("simple.fragment.topic.create", in: window)
        try require(renderedText(try element("simple.fragment.topic.validation", in: window)).contains("Выберите утверждённую тему"),
            "Simple topic Create without selection did not show local validation")
        var selectionValidation = SimpleTopicFragmentValidation()
        try require(!selectionValidation.showsSelectionError
            && !selectionValidation.beginCreate(selectedTopicID: nil)
            && selectionValidation.showsSelectionError,
            "Missing topic selection did not become local validation after Create")
        selectionValidation.didSelectTopic()
        try require(!selectionValidation.showsSelectionError
            && selectionValidation.beginCreate(selectedTopicID: options[0].id)
            && !selectionValidation.showsSelectionError,
            "Selecting an approved topic did not clear local validation")
        try require(model.simpleTopicCutAvailability(topicID: options[0].id).canCreate,
            "Explicit approved topic was not eligible for Simple creation")
        try require(model.startSimpleTopicCutFromAcceptedTranscript(topicID: options[0].id),
            "Simple topic adapter did not activate the shared cutTopic workflow")
        try require(model.isRunning && !model.isStopping,
            "Simple topic create action did not enter the shared workflow")
        try require(model.selectedOperations == advancedOperations
            && model.selectedTopicID == advancedTopicID
            && model.artifactLanguage == advancedLanguage
            && model.topicGranularity == advancedGranularity,
            "Simple topic create action rewrote Advanced bindings")
        model.stop()
        try require(model.isStopping, "Simple topic cut did not reuse the shared Stop action")
        for _ in 0..<200 where model.isRunning {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        try require(!model.isRunning && model.status == "Остановлено",
            "Simple topic cancellation bypassed shared lifecycle")
        let operationRecords = (try store.load(from: project)).workflow?.operations ?? [:]
        let forbidden = [
            WorkflowOperation.transcribe, .topicTimecoding, .translateTranscript,
            .burnSubtitles, .burnFragmentSubtitles, .cutRange, .renderFragment
        ]
        try require(forbidden.allSatisfy { operationRecords[$0.rawValue] == nil },
            "Simple topic cut started an operation outside cutTopic: \(operationRecords.keys.sorted())")
        try require(!nodes(window).contains { $0.accessibilityIdentifier() == "simple.fragment.topic.ready" },
            "Cancelled Simple topic cut displayed a false ready result")

        model.progress = WorkflowProgress(operation: .cutTopic, operationFraction: 0.3, overallFraction: 0.3,
            elapsed: 1, estimatedTotal: nil, remaining: nil, isIndeterminate: true)
        model.isRunning = true
        settle(window)
        try require(renderedText(try element("simple.progress.stage", in: window)).contains("Создаём фрагмент")
            && element("simple.progress.stop", in: window).isAccessibilityEnabled()
            && !element("simple.fragment.topic.create", in: window).isAccessibilityEnabled(),
            "Simple topic cut did not show shared progress and duplicate-create protection")
        model.isStopping = true
        settle(window)
        try require(!element("simple.progress.stop", in: window).isAccessibilityEnabled()
            && renderedText(try element("simple.progress.stage", in: window)).contains("Останавливаем обработку"),
            "Simple topic cut allowed repeated cancellation")
        model.isStopping = false
        model.isRunning = false

        let fragment = layout.fragmentVideoURL(kind: "simple-topic")
        try FileManager.default.createDirectory(at: fragment.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("ready topic fragment".utf8).write(to: fragment)
        try store.registerOutput(kind: "fragment-video", url: fragment, in: project)
        model.status = "Завершено"
        model.loadDetectedResults()
        settle(window)
        _ = try element("simple.fragment.topic.ready", in: window)
        _ = try element("simple.fragment.topic.open", in: window)

        let reopened = WorkflowViewModel()
        reopened.openProject(project)
        let reopenedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        reopenedWindow.isReleasedWhenClosed = false
        reopenedWindow.contentView = NSHostingView(rootView: ContentView(model: reopened))
        reopenedWindow.makeKeyAndOrderFront(nil)
        defer { reopenedWindow.close() }
        settle(reopenedWindow)
        try press("simple.goal.fragment", in: reopenedWindow)
        _ = try element("simple.fragment.topic.ready", in: reopenedWindow)
        _ = try element("simple.fragment.topic.open", in: reopenedWindow)
        try press("simple.fragment.topic.create", in: reopenedWindow)
        _ = try element("simple.fragment.topic.validation", in: reopenedWindow)
        _ = try element("simple.fragment.topic.ready", in: reopenedWindow)
        try require(!reopened.isRunning, "Reopening a completed Simple topic cut started duplicate processing")
        print("RENDERED_SIMPLE_TOPIC_CUT_CONTROLS_PASS: unavailable, local validation, explicit approved selection, fixed request, progress/stop, result/open/reopen, Advanced preservation")
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
