import AppKit

@MainActor
final class VideoTextAppDelegate: NSObject, NSApplicationDelegate {
    weak var terminationHandler: ApplicationTerminationHandling?
    private var terminationInProgress = false
    private var terminationReplySent = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let terminationHandler else { return .terminateNow }
        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true
        terminationHandler.cancelForApplicationTermination()

        Task { [weak self] in
            await terminationHandler.prepareForApplicationTermination()
            self?.finishTermination(sender)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.finishTermination(sender)
        }
        return .terminateLater
    }

    private func finishTermination(_ sender: NSApplication) {
        guard !terminationReplySent else { return }
        terminationReplySent = true
        sender.reply(toApplicationShouldTerminate: true)
    }
}
