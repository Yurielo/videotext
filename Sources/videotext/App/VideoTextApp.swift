import SwiftUI

@main
struct VideoTextApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1_240, height: 820)
        .windowResizability(.contentMinSize)
    }
}
