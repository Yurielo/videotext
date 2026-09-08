import AppKit
import SwiftUI

enum LayoutProbeError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

@main
@MainActor
struct LayoutProbe {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw LayoutProbeError.failed("Использование: videotext-layout-probe <output.png>")
            }
            let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
            let rootView = ZStack {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
                ContentView(model: WorkflowViewModel())
            }
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.appearance = NSAppearance(named: .aqua)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.appearance = NSAppearance(named: .aqua)
            window.backgroundColor = .windowBackgroundColor
            window.isOpaque = true
            window.contentView = hostingView
            window.setContentSize(NSSize(width: 980, height: 680))
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<10 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            hostingView.layoutSubtreeIfNeeded()

            let size = window.contentLayoutRect.size
            guard abs(size.width - 980) < 1, abs(size.height - 680) < 1 else {
                throw LayoutProbeError.failed("окно изменило контрольный размер: \(size.width)x\(size.height)")
            }
            guard let image = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
                throw LayoutProbeError.failed("не удалось создать bitmap окна")
            }
            hostingView.cacheDisplay(in: hostingView.bounds, to: image)
            guard let data = image.representation(using: .png, properties: [:]) else {
                throw LayoutProbeError.failed("не удалось создать PNG окна")
            }
            try data.write(to: outputURL, options: .atomic)
            window.orderOut(nil)
            print("LAYOUT PASS: 980x680; \(outputURL.path)")
        } catch {
            fputs("LAYOUT FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
