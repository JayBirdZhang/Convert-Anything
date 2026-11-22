import Foundation

/// Where a converted file's original went, so renaming the file back (or pressing ⌘Z in Finder,
/// which does that rename) brings the original back instead of converting again.
nonisolated struct UndoRecord: Codable, Equatable {
    var converted: String   // The converted file's path, e.g. …/notes.docx
    var original: String    // Its path before the rename, e.g. …/notes.md
    var trashed: String     // Where the original is in the Trash
    var date: Date
}

/// Kept in a small file so undo still works after the app restarts.
final class UndoStore {
    private(set) var records: [UndoRecord] = []
    private let url: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Convert Anything")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        url = support.appending(path: "undo.json")
        if let data = try? Data(contentsOf: url) {
            records = (try? JSONDecoder().decode([UndoRecord].self, from: data)) ?? []
        }
    }

    func add(_ record: UndoRecord) {
        records.removeAll { $0.converted == record.converted }
        records.insert(record, at: 0)
        records = Array(records.prefix(300))
        save()
    }

    /// The record for a rename from `converted` back to `original`, if its original is still in the Trash.
    func match(converted: String, original: String) -> UndoRecord? {
        records.first {
            $0.converted == converted && $0.original == original && FileManager.default.fileExists(atPath: $0.trashed)
        }
    }

    func remove(converted: String) {
        records.removeAll { $0.converted == converted }
        save()
    }

    private func save() {
        try? JSONEncoder().encode(records).write(to: url, options: .atomic)
    }
}
