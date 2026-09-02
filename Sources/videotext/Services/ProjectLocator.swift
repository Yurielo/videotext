import Foundation

struct ProjectLocator {
    func resolve(_ selection: URL) throws -> URL {
        let selection = selection.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: selection.path, isDirectory: &isDirectory) else {
            throw WorkflowError.missingProjectManifest
        }

        if !isDirectory.boolValue {
            if let root = projectRoot(forManifest: selection) { return root }
            throw WorkflowError.missingProjectManifest
        }

        if isProjectRoot(selection) { return selection }
        if ["Support files", "Video", "Texts"].contains(selection.lastPathComponent) {
            let parent = selection.deletingLastPathComponent()
            if isProjectRoot(parent) { return parent }
        }

        var roots = Set<String>()
        guard let enumerator = FileManager.default.enumerator(
            at: selection,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw WorkflowError.missingProjectManifest
        }

        for case let url as URL in enumerator {
            if enumerator.level > 3 {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard url.lastPathComponent == "manifest.json",
                  let root = projectRoot(forManifest: url) else { continue }
            roots.insert(root.standardizedFileURL.path)
        }

        if roots.count == 1, let path = roots.first {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if roots.count > 1 { throw WorkflowError.multipleProjectsFound(roots.count) }
        throw WorkflowError.missingProjectManifest
    }

    private func projectRoot(forManifest url: URL) -> URL? {
        guard url.lastPathComponent == "manifest.json",
              url.deletingLastPathComponent().lastPathComponent == "Support files" else { return nil }
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        return isProjectRoot(root) ? root : nil
    }

    private func isProjectRoot(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: ProjectLayout(root: url).manifestURL.path)
    }
}
