import AppKit
import Observation
import ServiceManagement
import UserNotifications

@Observable final class Job: Identifiable {
    enum State: Equatable {
        case waiting
        case converting(progress: Double?)
        case done
        case failed(String)
        case cancelled
        case undone
    }

    let id = UUID()
    let originalURL: URL    // Where the file was before the rename, e.g. notes.md
    let fileURL: URL        // The renamed file, which ends up holding the converted result, e.g. notes.docx
    let from: Format
    let to: Format
    let started = Date()
    var state: State = .waiting
    var originalInTrash: URL?
    var resultURL: URL?     // The converted file, or a folder of images when every page was exported
    var pageCount: Int?
    var task: Task<Void, Never>?

    init(originalURL: URL, fileURL: URL, from: Format, to: Format) {
        self.originalURL = originalURL
        self.fileURL = fileURL
        self.from = from
        self.to = to
    }

    var isActive: Bool {
        switch state {
        case .waiting, .converting: true
        default: false
        }
    }
}

@Observable final class AppModel {
    var watchedFolders: [String] {
        didSet { defaults.set(watchedFolders, forKey: Keys.watchedFolders); restartWatcher() }
    }
    var isWatching: Bool {
        didSet { defaults.set(!isWatching, forKey: Keys.paused); restartWatcher() }
    }
    var moveOriginalsToTrash: Bool {
        didSet { defaults.set(moveOriginalsToTrash, forKey: Keys.trashOriginals) }
    }
    var showNotifications: Bool {
        didSet { defaults.set(showNotifications, forKey: Keys.notifications) }
    }
    var exportAllPages: Bool {
        didSet { defaults.set(exportAllPages, forKey: Keys.allPages) }
    }
    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private(set) var jobs: [Job] = []

    var hasActiveJobs: Bool { jobs.contains(where: \.isActive) }

    /// Average progress of running conversions that report it, for the menu-bar ring.
    var activeProgress: Double? {
        let values = jobs.compactMap { job -> Double? in
            if case .converting(let progress?) = job.state { progress } else { nil }
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private let defaults = UserDefaults.standard
    private let watcher = FolderWatcher()
    private let heavyLane = SerialLane()
    private var askedForNotifications = false
    private let notificationDelegate = NotificationDelegate()

    private enum Keys {
        static let watchedFolders = "watchedFolders"
        static let paused = "paused"
        static let trashOriginals = "moveOriginalsToTrash"
        static let notifications = "showNotifications"
        static let allPages = "exportAllPages"
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultFolders = ["Desktop", "Documents", "Downloads"].map { home.appending(path: $0).path }
        watchedFolders = defaults.stringArray(forKey: Keys.watchedFolders) ?? defaultFolders
        isWatching = !defaults.bool(forKey: Keys.paused)
        moveOriginalsToTrash = defaults.object(forKey: Keys.trashOriginals) as? Bool ?? true
        showNotifications = defaults.object(forKey: Keys.notifications) as? Bool ?? true
        exportAllPages = defaults.object(forKey: Keys.allPages) as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled

        UNUserNotificationCenter.current().delegate = notificationDelegate
        watcher.onRename = { [weak self] from, to in self?.handleRename(from: from, to: to) }
        restartWatcher()
    }

    private func restartWatcher() {
        watcher.watch(isWatching ? watchedFolders : [])
    }

    // MARK: Deciding whether a rename is a conversion request

    private func handleRename(from oldURL: URL, to newURL: URL) {
        let name = newURL.lastPathComponent
        guard !name.hasPrefix("."), !name.hasPrefix("~$"),
              let oldFormat = Format(fileExtension: oldURL.pathExtension),
              let newFormat = Format(fileExtension: newURL.pathExtension),
              oldFormat != newFormat else { return }   // Includes harmless renames like .jpg → .jpeg

        // What's actually inside the file decides the source format, not the old extension.
        let source: Format
        switch Sniffer.detect(newURL) {
        case .format(let detected):
            source = detected
        case .text:
            source = oldFormat.isPlainText ? oldFormat : .txt
        case .unknown:
            return   // Not something we understand; leave it alone.
        }
        // Already in the new format: the rename just fixed a wrong extension.
        guard source != newFormat else { return }

        let job = Job(originalURL: oldURL, fileURL: newURL, from: source, to: newFormat)
        jobs.insert(job, at: 0)
        trimHistory()

        guard Converter.route(from: source, to: newFormat) != nil else {
            revertRename(job)
            fail(job, ConversionError.unsupported(source, newFormat).localizedDescription)
            return
        }
        job.task = Task { await run(job) }
    }

    // MARK: Running a conversion

    private func run(_ job: Job) async {
        let heavy = Converter.isHeavy(from: job.from, to: job.to)
        if heavy { await heavyLane.acquire() }
        defer { if heavy { heavyLane.release() } }

        let fileManager = FileManager.default
        let workDir = fileManager.temporaryDirectory.appending(path: "FileConverter/\(job.id.uuidString)")
        defer { try? fileManager.removeItem(at: workDir) }

        do {
            try Task.checkCancellation()
            job.state = .converting(progress: nil)
            try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)

            // Work on a private copy (an instant clone on APFS) so the user's file is untouched until the end.
            let input = workDir.appending(path: "input.\(job.from.rawValue)")
            try fileManager.copyItem(at: job.fileURL, to: input)

            let request = Converter.Request(
                input: input, from: job.from, to: job.to, workDir: workDir,
                title: job.fileURL.deletingPathExtension().lastPathComponent,
                originalDir: job.fileURL.deletingLastPathComponent(),
                allPages: exportAllPages,
                outputExtension: job.fileURL.pathExtension.lowercased())
            let output = try await Converter.convert(request) { progress in
                Task { @MainActor in
                    if job.isActive { job.state = .converting(progress: progress) }
                }
            }
            try Task.checkCancellation()

            guard fileManager.fileExists(atPath: job.fileURL.path) else {
                throw ConversionError.failed("The file was moved or deleted while converting.")
            }

            if moveOriginalsToTrash {
                // Trash the original under its original name, so it's easy to recognize.
                let backup = workDir.appending(path: job.originalURL.lastPathComponent)
                try fileManager.moveItem(at: input, to: backup)
                var trashed: NSURL?
                try fileManager.trashItem(at: backup, resultingItemURL: &trashed)
                job.originalInTrash = trashed as URL?
            }

            var isFolder: ObjCBool = false
            if fileManager.fileExists(atPath: output.path, isDirectory: &isFolder), isFolder.boolValue {
                // Every page became its own image: they go in a folder named after the file, which replaces it.
                // The renamed file still holds the original contents, which are already backed up.
                let folder = uniqueURL(job.fileURL.deletingPathExtension())
                try fileManager.moveItem(at: output, to: folder)
                try fileManager.removeItem(at: job.fileURL)
                job.resultURL = folder
                job.pageCount = try fileManager.contentsOfDirectory(atPath: folder.path).count
            } else {
                do {
                    _ = try fileManager.replaceItemAt(job.fileURL, withItemAt: output)
                } catch {
                    // replaceItemAt needs both files on the same disk; fall back to delete + move.
                    try fileManager.removeItem(at: job.fileURL)
                    try fileManager.moveItem(at: output, to: job.fileURL)
                }
                job.resultURL = job.fileURL
            }

            job.state = .done
            if let result = job.resultURL {
                let detail = job.pageCount.map { " · \($0) images" } ?? ""
                notify("Converted \(result.lastPathComponent)", body: "\(job.from.displayName) → \(job.to.displayName)\(detail)",
                       reveal: result)
            }
        } catch is CancellationError {
            revertRename(job)
            job.state = .cancelled
        } catch ConversionError.cancelled {
            revertRename(job)
            job.state = .cancelled
        } catch {
            revertRename(job)
            fail(job, error.localizedDescription)
        }
    }

    private func fail(_ job: Job, _ message: String) {
        job.state = .failed(message)
        notify("Couldn't convert \(job.fileURL.lastPathComponent)", body: message)
    }

    /// Puts the old name back so the file's extension matches its contents again.
    private func revertRename(_ job: Job) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: job.fileURL.path),
              !fileManager.fileExists(atPath: job.originalURL.path) else { return }
        try? fileManager.moveItem(at: job.fileURL, to: job.originalURL)
    }

    // MARK: Actions from the menu

    func cancel(_ job: Job) {
        job.task?.cancel()
    }

    /// Trashes the converted file and brings the original back from the Trash.
    func undo(_ job: Job) {
        guard job.state == .done, let trashed = job.originalInTrash else { return }
        let fileManager = FileManager.default
        do {
            guard !fileManager.fileExists(atPath: job.originalURL.path) else {
                throw ConversionError.failed("A file named \(job.originalURL.lastPathComponent) already exists.")
            }
            try fileManager.moveItem(at: trashed, to: job.originalURL)
            let result = job.resultURL ?? job.fileURL
            if fileManager.fileExists(atPath: result.path) {
                try fileManager.trashItem(at: result, resultingItemURL: nil)
            }
            job.state = .undone
        } catch {
            notify("Couldn't undo", body: error.localizedDescription)
        }
    }

    func reveal(_ job: Job) {
        let url = job.state == .done ? job.resultURL ?? job.fileURL : job.originalURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let new = panel.urls.map(\.path).filter { !watchedFolders.contains($0) }
        watchedFolders += new
    }

    func removeFolder(_ path: String) {
        watchedFolders.removeAll { $0 == path }
    }

    /// "deck", then "deck 2", "deck 3"… if that name is taken.
    private func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent) \(number)")
            number += 1
        }
        return candidate
    }

    private func trimHistory() {
        var finished = 0
        jobs.removeAll { job in
            guard !job.isActive else { return false }
            finished += 1
            return finished > 20
        }
    }

    // MARK: Notifications

    private func notify(_ title: String, body: String, reveal: URL? = nil) {
        guard showNotifications else { return }
        let center = UNUserNotificationCenter.current()
        if !askedForNotifications {
            askedForNotifications = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let reveal { content.userInfo = ["reveal": reveal.path] }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Shows banners even while the app's menu is open, and opens the file in Finder when one is clicked.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let path = response.notification.request.content.userInfo["reveal"] as? String else { return }
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }
}

/// Lets one task through at a time; the rest wait their turn in order.
final class SerialLane {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}
