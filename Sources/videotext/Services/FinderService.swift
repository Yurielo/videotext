import Foundation
import AppKit

struct FinderService {
    func openProject(_ projectURL: URL, preferredOutput: URL? = nil) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkflowError.cannotOpenProjectFolder
        }

        if let preferredOutput, FileManager.default.fileExists(atPath: preferredOutput.path) {
            NSWorkspace.shared.activateFileViewerSelecting([preferredOutput])
            return
        }
        guard NSWorkspace.shared.open(projectURL) else {
            throw WorkflowError.cannotOpenProjectFolder
        }
    }
}
