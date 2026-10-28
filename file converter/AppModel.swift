import AppKit
import Observation
import OSLog
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

/// Renames that arrive together for the same folder and target format, such as a Finder batch rename.
/// A single rename is a batch of one.
@Observable final class Batch: Identifiable {
    let id = UUID()
    let folder: URL
    let to: Format
    var jobs: [Job] = []
    var lastAdded = Date()
    var summarized = false      // Its notification has been sent; later renames start a new batch

    init(folder: URL, to: Format) {
        self.folder = folder
        self.to = to
    }

    var isActive: Bool { jobs.contains(where: \.isActive) }
    var finishedCount: Int { jobs.count(where: { !$0.isActive }) }

    /// Fraction of the batch's work that's done, counting each file's own progress.
    var progress: Double {
        guard !jobs.isEmpty else { return 0 }
        let total = jobs.reduce(0.0) { sum, job in
            switch job.state {
            case .waiting: sum
            case .converting(let progress): sum + (progress ?? 0)
            default: sum + 1
            }
        }
        return total / Double(jobs.count)
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
    var editableSlides: Bool {
        didSet { defaults.set(editableSlides, forKey: Keys.editableSlides) }
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

    /// Newest first.
    private(set) var batches: [Batch] = []

    var jobs: [Job] { batches.flatMap(\.jobs) }
    var hasActiveJobs: Bool { batches.contains(where: \.isActive) }

    /// Drives the breathing dot in the menu-bar icon. Only ticks while something is converting.
    private(set) var pulsePhase: Double = 0
    private var pulseTask: Task<Void, Never>?

    /// Overall progress for the menu-bar ring: a single file's own progress (nil when it doesn't report any),
    /// or, with several files on the go, how much of all of them is done.
    var activeProgress: Double? {
        let running = batches.filter(\.isActive)
        let jobs = running.flatMap(\.jobs)
        if jobs.count == 1 {
            if case .converting(let progress) = jobs[0].state { return progress }
            return nil
        }
        guard !jobs.isEmpty else { return nil }
        return running.reduce(0.0) { $0 + $1.progress * Double($1.jobs.count) } / Double(jobs.count)
    }

    /// How long after a rename another one still joins the same batch.
    private static let batchWindow: TimeInterval = 2

    private let defaults = UserDefaults.standard
    private let watcher = FolderWatcher()
    // Video and LibreOffice jobs run one at a time; everything else a few at a time, so a big batch
    // doesn't start dozens of converters at once.
    private let heavyLane = Lane(limit: 1)
    private let lightLane = Lane(limit: max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ConvertEverything", category: "conversion")
    private var askedForNotifications = false
    private let notificationDelegate = NotificationDelegate()

    private enum Keys {
        static let watchedFolders = "watchedFolders"
        static let paused = "paused"
        static let trashOriginals = "moveOriginalsToTrash"
        static let notifications = "showNotifications"
        static let allPages = "exportAllPages"
        static let editableSlides = "editableSlides"
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultFolders = ["Desktop", "Documents", "Downloads"].map { home.appending(path: $0).path }
        watchedFolders = defaults.stringArray(forKey: Keys.watchedFolders) ?? defaultFolders
        isWatching = !defaults.bool(forKey: Keys.paused)
        moveOriginalsToTrash = defaults.object(forKey: Keys.trashOriginals) as? Bool ?? true
        showNotifications = defaults.object(forKey: Keys.notifications) as? Bool ?? true
        exportAllPages = defaults.object(forKey: Keys.allPages) as? Bool ?? true
        editableSlides = defaults.object(forKey: Keys.editableSlides) as? Bool ?? true
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
        let folder = newURL.deletingLastPathComponent()
        let batch: Batch
        if let open = batches.first(where: {
            $0.folder == folder && $0.to == newFormat && !$0.summarized && Date().timeIntervalSince($0.lastAdded) < Self.batchWindow
        }) {
            batch = open
        } else {
            batch = Batch(folder: folder, to: newFormat)
            batches.insert(batch, at: 0)
            trimHistory()
        }
        batch.jobs.append(job)
        batch.lastAdded = Date()

        guard Converter.route(from: source, to: newFormat) != nil else {
            revertRename(job)
            job.state = .failed(ConversionError.unsupported(source, newFormat).localizedDescription)
            summarizeWhenFinished(batch)
            return
        }
        job.task = Task { await run(job) }
        updatePulse()
    }

    // MARK: Running a conversion

    private func run(_ job: Job) async {
        defer {
            updatePulse()
            if let batch = batches.first(where: { $0.jobs.contains { $0 === job } }) { summarizeWhenFinished(batch) }
        }
        let lane = Converter.isHeavy(from: job.from, to: job.to) ? heavyLane : lightLane
        await lane.acquire()
        defer { lane.release() }

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
                outputExtension: job.fileURL.pathExtension.lowercased(),
                editableSlides: editableSlides)
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
        } catch is CancellationError {
            revertRename(job)
            job.state = .cancelled
        } catch ConversionError.cancelled {
            revertRename(job)
            job.state = .cancelled
        } catch {
            revertRename(job)
            job.state = .failed(error.localizedDescription)
        }
    }

    private func updatePulse() {
        if hasActiveJobs, pulseTask == nil {
            pulseTask = Task {
                // About 12 frames a second, one breath every 1.6 seconds.
                while !Task.isCancelled {
                    pulsePhase += 2 * .pi / 19
                    try? await Task.sleep(for: .milliseconds(84))
                }
            }
        } else if !hasActiveJobs {
            pulseTask?.cancel()
            pulseTask = nil
            pulsePhase = 0
        }
    }

    /// Sends one notification for the whole batch once all its files are finished and no more renames
    /// are arriving for it.
    private func summarizeWhenFinished(_ batch: Batch) {
        guard !batch.isActive, !batch.summarized else { return }
        Task {
            let wait = batch.lastAdded.addingTimeInterval(Self.batchWindow).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !batch.isActive, !batch.summarized,
                  Date().timeIntervalSince(batch.lastAdded) >= Self.batchWindow else { return }
            batch.summarized = true
            summarize(batch)
        }
    }

    private func summarize(_ batch: Batch) {
        let done = batch.jobs.filter { $0.state == .done }
        let failed = batch.jobs.compactMap { job -> (Job, String)? in
            if case .failed(let message) = job.state { (job, message) } else { nil }
        }
        log.notice("Batch to \(batch.to.rawValue, privacy: .public) finished: \(done.count) converted, \(failed.count) failed, \(batch.jobs.count) total")

        if batch.jobs.count == 1, let job = batch.jobs.first {
            if job.state == .done, let result = job.resultURL {
                let detail = job.pageCount.map { " · \($0) images" } ?? ""
                notify("Converted \(result.lastPathComponent)", body: "\(job.from.displayName) → \(job.to.displayName)\(detail)",
                       reveal: [result])
            } else if let (job, message) = failed.first {
                notify("Couldn't convert \(job.originalURL.lastPathComponent)", body: message)
            }
            return
        }

        let target = batch.to.displayName
        if failed.isEmpty {
            guard !done.isEmpty else { return }   // Everything was cancelled
            notify("Converted \(done.count) files to \(target)", body: "In \(batch.folder.lastPathComponent)",
                   reveal: done.compactMap(\.resultURL))
        } else if done.isEmpty {
            notify("Couldn't convert \(failed.count) files to \(target)", body: failed[0].1)
        } else {
            let names = failed.prefix(3).map { $0.0.originalURL.lastPathComponent }.joined(separator: ", ")
            let more = failed.count > 3 ? " and \(failed.count - 3) more" : ""
            notify("Converted \(done.count) of \(done.count + failed.count) files to \(target)",
                   body: "Not converted: \(names)\(more)", reveal: done.compactMap(\.resultURL))
        }
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

    func cancel(_ batch: Batch) {
        batch.jobs.filter(\.isActive).forEach { $0.task?.cancel() }
    }

    func undoAll(_ batch: Batch) {
        batch.jobs.filter { $0.state == .done && $0.originalInTrash != nil }.forEach(undo)
    }

    /// Selects the converted files in Finder, or the folder if none were converted.
    func reveal(_ batch: Batch) {
        let results = batch.jobs.filter { $0.state == .done }.compactMap(\.resultURL)
        NSWorkspace.shared.activateFileViewerSelecting(results.isEmpty ? [batch.folder] : results)
    }

    func clearFinished() {
        batches.removeAll { !$0.isActive }
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

    /// Keeps the 20 most recent finished batches (a batch counts once, however many files it has).
    private func trimHistory() {
        var finished = 0
        batches.removeAll { batch in
            guard !batch.isActive else { return false }
            finished += 1
            return finished > 20
        }
    }

    // MARK: Notifications

    private func notify(_ title: String, body: String, reveal: [URL] = []) {
        guard showNotifications else { return }
        let center = UNUserNotificationCenter.current()
        if !askedForNotifications {
            askedForNotifications = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if !reveal.isEmpty { content.userInfo = ["reveal": reveal.map(\.path)] }
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
        guard let paths = response.notification.request.content.userInfo["reveal"] as? [String] else { return }
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
        }
    }
}

/// Lets up to `limit` tasks through at once; the rest wait their turn in order.
final class Lane {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        guard running >= limit else { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }   // The releasing task hands over its slot
    }

    func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }
}
