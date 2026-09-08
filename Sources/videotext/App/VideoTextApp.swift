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
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1_240, height: 820)
        .windowResizability(.contentMinSize)
    }
}
