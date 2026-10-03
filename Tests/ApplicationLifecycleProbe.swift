import AppKit

@MainActor
final class ProbeTerminationHandler: ApplicationTerminationHandling {
    let markerURL: URL

    init(markerURL: URL) {
        self.markerURL = markerURL
    }

    func cancelForApplicationTermination() {
        try? Data("cancelled\n".utf8).write(to: markerURL, options: .atomic)
    }

    func prepareForApplicationTermination() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
        let handle = try? FileHandle(forWritingTo: markerURL)
        _ = try? handle?.seekToEnd()
        try? handle?.write(contentsOf: Data("services-unloaded\n".utf8))
        try? handle?.close()
    }
}

@main
@MainActor
struct ApplicationLifecycleProbe {
    static func main() {
        let application = NSApplication.shared
        let delegate = VideoTextAppDelegate()
        let markerURL = (URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path, isDirectory: true))
            .appendingPathComponent("videotext-lifecycle-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: markerURL) }
        let handler = ProbeTerminationHandler(markerURL: markerURL)
        delegate.terminationHandler = handler
        guard delegate.applicationShouldTerminateAfterLastWindowClosed(application) else {
            fputs("APPLICATION_LIFECYCLE_PROBE_FAIL: закрытие последнего окна не завершает приложение\n", stderr)
            exit(1)
        }
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.makeKeyAndOrderFront(nil)
        application.finishLaunching()

        let terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: application,
            queue: .main
        ) { _ in
            let marker = (try? String(contentsOf: markerURL, encoding: .utf8)) ?? ""
            guard marker == "cancelled\nservices-unloaded\n" else {
                fputs("APPLICATION_LIFECYCLE_PROBE_FAIL: очистка сервисов не завершена до выхода\n", stderr)
                exit(1)
            }
            print("APPLICATION_LIFECYCLE_PROBE_PASS")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            window.close()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            fputs("APPLICATION_LIFECYCLE_PROBE_FAIL: процесс остался после закрытия окна\n", stderr)
            exit(1)
        }
        withExtendedLifetime((terminationObserver, handler)) {
            application.run()
        }
    }
}
