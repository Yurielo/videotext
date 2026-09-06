import AppKit

@main
struct ApplicationLifecycleProbe {
    static func main() {
        let application = NSApplication.shared
        let delegate = VideoTextAppDelegate()
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
            print("APPLICATION_LIFECYCLE_PROBE_PASS")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            window.close()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            fputs("APPLICATION_LIFECYCLE_PROBE_FAIL: процесс остался после закрытия окна\n", stderr)
            exit(1)
        }
        withExtendedLifetime(terminationObserver) {
            application.run()
        }
    }
}
