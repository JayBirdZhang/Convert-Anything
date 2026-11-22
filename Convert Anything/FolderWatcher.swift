import CoreServices
import Foundation

/// Watches folders with FSEvents and reports renames: the same file (by inode) getting a new name in the same folder.
///
/// FSEvents reports a rename as two events, one for the old path and one for the new, which can arrive
/// in either order and even in different batches. They're paired up by file ID.
final class FolderWatcher {
    var onRename: ((_ from: URL, _ to: URL) -> Void)?

    private var stream: FSEventStreamRef?
    private var unpaired: [UInt64: (path: String, exists: Bool, time: Date)] = [:]

    func watch(_ paths: [String]) {
        stop()
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let entries = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [[String: Any]] ?? []
            var events: [(String, FSEventStreamEventFlags, UInt64?)] = []
            for (index, entry) in entries.prefix(count).enumerated() {
                guard let path = entry[kFSEventStreamEventExtendedDataPathKey] as? String else { continue }
                let fileID = (entry[kFSEventStreamEventExtendedFileIDKey] as? NSNumber)?.uint64Value
                events.append((path, eventFlags[index], fileID))
            }
            MainActor.assumeIsolated { watcher.handle(events) }
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagUseExtendedData
                // Our own renames and file swaps never trigger a conversion.
                | kFSEventStreamCreateFlagIgnoreSelf)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        unpaired.removeAll()
    }

    private func handle(_ events: [(path: String, flags: FSEventStreamEventFlags, fileID: UInt64?)]) {
        let now = Date()
        unpaired = unpaired.filter { now.timeIntervalSince($0.value.time) < 5 }

        for event in events {
            guard event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0,
                  event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0,
                  let fileID = event.fileID else { continue }
            let exists = FileManager.default.fileExists(atPath: event.path)

            guard let other = unpaired[fileID], other.exists != exists else {
                unpaired[fileID] = (event.path, exists, now)
                continue
            }
            unpaired[fileID] = nil
            let from = URL(fileURLWithPath: exists ? other.path : event.path)
            let to = URL(fileURLWithPath: exists ? event.path : other.path)
            // A move to another folder (including the Trash) isn't a rename.
            guard from != to, from.deletingLastPathComponent() == to.deletingLastPathComponent() else { continue }
            onRename?(from, to)
        }
    }
}
