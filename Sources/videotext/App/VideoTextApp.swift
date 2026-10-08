import SwiftUI

@main
struct VideoTextApp: App {
    @NSApplicationDelegateAdaptor(VideoTextAppDelegate.self) private var appDelegate
    @StateObject private var model = WorkflowViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear {
                    appDelegate.terminationHandler = model
                    ReleaseTestBootstrap.runIfRequested(model: model)
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1_240, height: 820)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
private enum ReleaseTestBootstrap {
    static func runIfRequested(model: WorkflowViewModel) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VIDEOTEXT_RELEASE_TEST_MODE"] == "1" else { return }
        if let projectPath = environment["VIDEOTEXT_RELEASE_TEST_PROJECT"] {
            model.openProject(URL(fileURLWithPath: projectPath, isDirectory: true))
            return
        }
        guard let mediaPath = environment["VIDEOTEXT_RELEASE_TEST_MEDIA"] else { return }
        model.selectMedia(URL(fileURLWithPath: mediaPath))
        model.selectedOperations = [.transcribe]
        model.sourceHumanReviewEnabled = false
        model.topicHumanReviewEnabled = false
        model.fillerAnalysisBeforeReview = false
        model.run()
    }
}
