import AppKit

/// Shows files in Finder, and copes with files that are no longer where the history says.
enum FinderReveal {
    /// Selects the files that are still there. When none are (moved, renamed or trashed since), opens the
    /// nearest folder that still exists, `folder` if given, so the click still takes you somewhere useful.
    /// Returns whether any of the files were found.
    @discardableResult
    static func show(_ urls: [URL], in folder: URL? = nil) -> Bool {
        let fileManager = FileManager.default
        let found = urls.filter { fileManager.fileExists(atPath: $0.path) }
        if !found.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(found)
            return true
        }
        var nearest = folder ?? urls.first?.deletingLastPathComponent()
        while let candidate = nearest, !fileManager.fileExists(atPath: candidate.path) {
            nearest = candidate.deletingLastPathComponent()
        }
        if let nearest { NSWorkspace.shared.open(nearest) }
        return false
    }
}
