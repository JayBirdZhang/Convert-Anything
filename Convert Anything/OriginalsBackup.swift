import Foundation

/// With "Keep for 3 days", replaced originals go in a hidden folder of the app's own instead of the Trash, so Undo
/// still works without filling the Trash. It's in Application Support rather than Caches because the system may
/// empty Caches at any time, which would quietly break Undo. Each original sits in a folder of its own,
/// `Originals/<UUID>/notes.md`. The folder's date says when it was kept; the file keeps its own dates for the restore.
nonisolated enum OriginalsBackup {
    static let keepFor: TimeInterval = 3 * 24 * 60 * 60
    static let goneMessage = "The original was kept for 3 days and has since been deleted."

    static let folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: Bundle.main.bundleIdentifier ?? "ConvertAnything").appending(path: "Originals")

    /// Moves `file` in under `name` and returns where it is now. That's a rename on the same volume (the file is the
    /// app's working copy in the temporary folder, so it almost always is), and a copy otherwise.
    static func keep(_ file: URL, named name: String) throws -> URL {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            // Like the Trash, nothing here belongs in Time Machine.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = folder
            try? url.setResourceValues(values)
        }
        let box = folder.appending(path: UUID().uuidString)
        try fileManager.createDirectory(at: box, withIntermediateDirectories: false)
        let kept = box.appending(path: name)
        do {
            try fileManager.moveItem(at: file, to: kept)
        } catch {
            try? fileManager.removeItem(at: box)
            throw error
        }
        return kept
    }

    static func contains(_ url: URL) -> Bool {
        url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path
    }

    /// True when `url` is a kept original that's gone. One older than 3 days is deleted first, even if the
    /// cleanup hasn't got to it yet, so Undo never depends on when that last ran.
    static func isGone(_ url: URL) -> Bool {
        guard contains(url) else { return false }
        let box = url.deletingLastPathComponent()
        if let date = try? box.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(date) > keepFor {
            try? FileManager.default.removeItem(at: box)
        }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    /// After a restore, removes the folder the original was kept in (empty by then).
    static func discardFolder(of url: URL) {
        guard contains(url) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Deletes everything kept longer than 3 days, whichever setting is on now.
    static func removeExpired() {
        let fileManager = FileManager.default
        guard let boxes = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                               options: .skipsHiddenFiles) else { return }
        for box in boxes {
            guard let date = try? box.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Date().timeIntervalSince(date) > keepFor else { continue }
            try? fileManager.removeItem(at: box)
        }
    }
}
