import AppKit
import OSLog

/// Uses Keynote, Numbers and Pages (free Apple apps) to convert Office and iWork files: the app asks
/// them, through AppleScript, to open the file, export it and close it again without saving.
/// macOS asks once for permission ("Convert Anything wants to control Keynote").
nonisolated enum IWork {
    enum App: String {
        case keynote = "Keynote", numbers = "Numbers", pages = "Pages"

        /// The App Store versions and the newer "Creator Studio" versions use different identifiers.
        var bundleIDs: [String] {
            switch self {
            case .keynote: ["com.apple.iWork.Keynote", "com.apple.Keynote"]
            case .numbers: ["com.apple.iWork.Numbers", "com.apple.Numbers"]
            case .pages: ["com.apple.iWork.Pages", "com.apple.Pages"]
            }
        }

        var installedID: String? {
            bundleIDs.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        }
    }

    /// Export formats as AppleScript names them in each app's dictionary.
    enum ExportFormat: String {
        case pdf = "PDF"
        case powerPoint = "Microsoft PowerPoint"
        case excel = "Microsoft Excel"
        case csv = "CSV"
        case word = "Microsoft Word"
    }

    static func isInstalled(_ app: App) -> Bool { app.installedID != nil }

    /// Set by the app: tells you when Keynote, Numbers or Pages is waiting for you (title, message).
    nonisolated(unsafe) static var needsAttention: (@Sendable (String, String) -> Void)?

    /// Exports `input` to `output`. Numbers' CSV export of a file with several tables makes a folder
    /// of CSV files; the returned URL is whatever was written.
    ///
    /// When the app isn't open it's started hidden, so it never comes to the front, and it's kept for
    /// half a minute afterwards so a batch of files doesn't start it again for each one. An app you
    /// already have open is used as it is and left open.
    @discardableResult
    static func export(_ input: URL, with app: App, as format: ExportFormat, to output: URL,
                       openTimeout: Int = 90, totalTimeout: Int = 300) async throws -> URL {
        guard let id = app.installedID else { throw ConversionError.missingApp(app.rawValue) }

        // A uniquely named copy, so the script can find its own document by name (never one you have open).
        let token = "Convert Anything \(UUID().uuidString.prefix(8))"
        let copy = input.deletingLastPathComponent().appending(path: "\(token).\(input.pathExtension)")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: input, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        let ours = await HiddenApps.shared.acquire(id)

        // The first question ("how many documents?") is only answered once the app has finished starting.
        // Asking it to open a file before that leaves it holding a document nothing can reach, so the
        // script waits for that answer first. `open` normally hands back the document; when it doesn't,
        // the document is looked up by name.
        let script = """
        on run argv
            set inputFile to POSIX file (item 1 of argv)
            set outputFile to POSIX file (item 2 of argv)
            set baseName to item 3 of argv
            set fullName to item 4 of argv
            set ready to false
            repeat \(openTimeout * 4) times
                try
                    with timeout of 10 seconds
                        tell application id "\(id)" to count documents
                    end timeout
                    set ready to true
                    exit repeat
                on error message number code
                    if code is -1743 then error message number code
                    delay 0.25
                end try
            end repeat
            if not ready then error "NOT_READY"
            set theDocument to missing value
            try
                with timeout of \(openTimeout) seconds
                    tell application id "\(id)"
                        set theDocument to open inputFile
                        get name of theDocument
                    end tell
                end timeout
            on error
                set theDocument to missing value
            end try
            if theDocument is missing value then
                repeat 120 times
                    repeat with candidate in {baseName, fullName}
                        try
                            with timeout of 5 seconds
                                tell application id "\(id)"
                                    set theDocument to document (candidate as text)
                                    get name of theDocument
                                end tell
                            end timeout
                            exit repeat
                        on error
                            set theDocument to missing value
                        end try
                    end repeat
                    if theDocument is not missing value then exit repeat
                    delay 0.25
                end repeat
            end if
            if theDocument is missing value then error "OPEN_TIMEOUT"
            with timeout of \(totalTimeout) seconds
                tell application id "\(id)"
                    export theDocument to outputFile as \(format.rawValue)
                    close theDocument saving no
                end tell
            end timeout
        end run
        """
        // Still nothing after half a minute: the app is probably showing a window that needs you.
        // Bring it forward and say so.
        let watcher = Task {
            try await Task.sleep(for: .seconds(30))
            HiddenApps.shared.forget(id)
            await MainActor.run {
                for running in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
                    running.unhide()
                    running.activate()
                }
            }
            IWork.needsAttention?("\(app.rawValue) is waiting for you",
                                  "If \(app.rawValue) is showing a message about this file, close it to finish converting.")
        }
        defer { watcher.cancel() }

        do {
            _ = try await withTimeout(seconds: openTimeout * 2 + totalTimeout + 60) {
                try await Tools.run("/usr/bin/osascript", ["-e", script, copy.path, output.path, token, copy.lastPathComponent])
            }
        } catch {
            // Cleaning up must still happen when the conversion was cancelled, so it runs in its own task.
            let cancelled = (error as? ConversionError)?.isCancellation == true
            let windows = await Task.detached { () -> String in
                let windows = cancelled ? "" : await windowNames(id)
                await closeDocuments(id, token: token)
                if ours { await HiddenApps.shared.discard(id) }
                return windows
            }.value
            switch error {
            case ConversionError.cancelled:
                throw error
            case ConversionError.failed(let message) where message.contains("-1743"):
                throw ConversionError.failed("Convert Anything isn't allowed to use \(app.rawValue). Turn it on in System Settings → Privacy & Security → Automation.")
            default:
                log.error("\(app.rawValue, privacy: .public) export failed: \(String(describing: error), privacy: .public); windows: \(windows, privacy: .public)")
                throw ConversionError.failed("\(app.rawValue) didn't respond\(windows.isEmpty ? "" : " (it was showing: \(windows))"). If it shows a message, close it and try again.")
            }
        }
        if ours { HiddenApps.shared.release(id) }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: output.path) { return output }
        // Some exports add their own extension or make a folder next to the requested name.
        let siblings = (try? fileManager.contentsOfDirectory(at: output.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        if let match = siblings.first(where: { $0.deletingPathExtension().lastPathComponent == output.deletingPathExtension().lastPathComponent && $0 != input }) {
            return match
        }
        throw ConversionError.failed("\(app.rawValue) couldn't export this file.")
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ConvertAnything", category: "iwork")

    /// Closes our document if it's still open.
    private static func closeDocuments(_ id: String, token: String) async {
        await runBriefly("""
        with timeout of 10 seconds
            tell application id "\(id)" to close (every document whose name starts with "\(token)") saving no
        end timeout
        """)
    }

    /// Quits the app unless it has a document open (then somebody is using it).
    fileprivate static func quitIfEmpty(_ id: String) async {
        await runBriefly("""
        with timeout of 10 seconds
            tell application id "\(id)"
                if (count documents) is 0 then quit
            end tell
        end timeout
        """)
    }

    /// The titles of the app's windows (a sheet or prompt shows up here), for diagnosing a stuck export.
    private static func windowNames(_ id: String) async -> String {
        await runBriefly(#"with timeout of 5 seconds\#ntell application id "\#(id)" to get name of every window\#nend timeout"#)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private static func runBriefly(_ script: String) async -> String {
        (try? await withTimeout(seconds: 20) { try await Tools.run("/usr/bin/osascript", ["-e", script]) }) ?? ""
    }

    /// Runs `work`, cancelling it (which stops its process) if it takes longer than `seconds`.
    static func withTimeout<T: Sendable>(seconds: Int, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); return nil }
            guard let first = try await group.next() else { throw ConversionError.failed("Timed out.") }
            group.cancelAll()
            guard let value = first else { throw ConversionError.failed("Timed out.") }
            return value
        }
    }
}

/// Keynote, Numbers and Pages when this app started them itself, in the background. Opening a document
/// makes an app show its windows, so while we have one it's hidden again the moment it un-hides. They
/// stay open for a little while after an export, then quit. Once you bring one forward it's yours: it's
/// no longer hidden or quit from here.
nonisolated private final class HiddenApps: @unchecked Sendable {
    static let shared = HiddenApps()
    private static let idleTime: Duration = .seconds(30)

    private struct Entry {
        let app: NSRunningApplication
        let keeper: Task<Void, Never>
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var idleQuits: [String: Task<Void, Never>] = [:]

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            forget(id, pid: app.processIdentifier)
        }
        // Don't leave hidden apps behind when Convert Anything quits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [self] _ in
            for entry in lock.withLock({ Array(entries.values) }) { entry.app.terminate() }
        }
    }

    /// Makes sure the app is running, starting it hidden when it isn't. True when it's one we started
    /// (now or for an earlier file) that you haven't brought forward since.
    func acquire(_ id: String) async -> Bool {
        // An idle quit that has already begun is allowed to finish, so the app isn't caught half closed.
        let pending = lock.withLock { idleQuits.removeValue(forKey: id) }
        pending?.cancel()
        await pending?.value

        if let known = lock.withLock({ entries[id] }) {
            if !known.app.isTerminated { return true }
            forget(id)
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return false }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        // Only for this launch: don't reopen the windows from last time, and skip the "may look different"
        // warnings, which nobody would see while the app is hidden. Your own settings aren't changed.
        configuration.arguments = ["-TMADoNotShowDocumentWarnings", "YES", "-ApplePersistenceIgnoreState", "YES"]
        guard let app = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration) else { return false }
        let keeper = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled, !app.isTerminated {
                if !app.isHidden, !app.isActive { app.hide() }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        lock.withLock { entries[id] = Entry(app: app, keeper: keeper) }
        return true
    }

    /// The app is yours from now on (you brought it forward, or it needs you to look at it).
    func forget(_ id: String, pid: pid_t? = nil) {
        let entry = lock.withLock { () -> Entry? in
            guard let entry = entries[id], pid == nil || entry.app.processIdentifier == pid else { return nil }
            entries[id] = nil
            return entry
        }
        entry?.keeper.cancel()
    }

    /// After a successful export: quit the app if nothing else has needed it for a while.
    func release(_ id: String) {
        let task = Task.detached(priority: .utility) { [self] in
            try? await Task.sleep(for: Self.idleTime)
            guard !Task.isCancelled, let entry = take(id) else { return }
            await quit(entry.app, id: id, force: false)
        }
        lock.withLock { idleQuits[id] = task }
    }

    /// After a failed export: quit the app now, by force if it's stuck in the background, so it can't
    /// hold up the next file. One you've brought forward is only quit if it has nothing open.
    func discard(_ id: String) async {
        if let entry = take(id) {
            await quit(entry.app, id: id, force: true)
        } else {
            await IWork.quitIfEmpty(id)
        }
    }

    private func take(_ id: String) -> Entry? {
        let entry = lock.withLock { entries.removeValue(forKey: id) }
        entry?.keeper.cancel()
        return entry
    }

    private func quit(_ app: NSRunningApplication, id: String, force: Bool) async {
        await IWork.quitIfEmpty(id)
        for _ in 0..<30 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(100)) }
        if force, !app.isTerminated, !app.isActive { app.forceTerminate() }
    }
}

/// PowerPoint → PDF without any app: macOS's Quick Look (the spacebar preview) can lay out every slide of a
/// presentation as a web page. That page is printed with one slide per PDF page, at the slides' own size.
enum QuickLookSlides {
    static func renderPDF(_ input: URL, workDir: URL, output: URL) async throws {
        let folder = workDir.appending(path: "quicklook")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await Tools.run("/usr/bin/qlmanage", ["-p", "-o", folder.path, input.path])
        let preview = folder.appending(path: input.lastPathComponent + ".qlpreview")
        let page = preview.appending(path: "Preview.html")
        guard var html = try? String(contentsOf: page, encoding: .utf8), html.contains("class=\"slide") else {
            throw ConversionError.failed("Quick Look couldn't read this presentation.")
        }

        // The slide size, from Quick Look's own style sheet ("div.slide, div.loading-slide { width: 720; height: 405;}").
        var size = CGSize(width: 720, height: 405)
        if let match = html.firstMatch(of: /div\.slide, div\.loading-slide \{ width: ([\d.]+); height: ([\d.]+);/),
           let width = Double(match.1), let height = Double(match.2), width > 0, height > 0 {
            size = CGSize(width: width, height: height)
        }
        let printStyle = """
        <style>
        @page { margin: 0; }
        html, body { margin: 0 !important; padding: 0 !important; background: white !important; }
        /* Printing turns 96 web pixels into 72 points; scale up so a 720-pixel slide fills a 720-point page. */
        body { zoom: 1.3333; }
        div.slide { margin: 0 !important; -webkit-box-shadow: none !important; break-after: page; page-break-after: always; }
        div.loading-slide { display: none !important; }
        * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
        </style>
        """
        if let head = html.range(of: "</head>") { html.replaceSubrange(head, with: printStyle + "</head>") } else { html = printStyle + html }
        let printable = preview.appending(path: "Print.html")
        try html.write(to: printable, atomically: true, encoding: .utf8)
        try await WebPDF.render(html: "", baseURL: preview, output: output, page: size, margin: 0, file: printable)
    }
}
