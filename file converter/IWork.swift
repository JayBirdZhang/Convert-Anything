import AppKit
import OSLog

/// Uses Keynote, Numbers and Pages (free Apple apps) to convert Office and iWork files: the app asks
/// them, through AppleScript, to open the file, export it and close it again without saving.
/// macOS asks once for permission ("Convert Everything wants to control Keynote").
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
    /// The app is started hidden in the background (when it isn't already open) so it never becomes the
    /// active app: the subscription versions show prompts when they come to the front, and those can stop
    /// the export. Every step has a time limit, and on a timeout the names of the app's windows are logged
    /// so whatever was in the way can be seen.
    @discardableResult
    static func export(_ input: URL, with app: App, as format: ExportFormat, to output: URL,
                       openTimeout: Int = 180, totalTimeout: Int = 300) async throws -> URL {
        guard let id = app.installedID else { throw ConversionError.missingApp(app.rawValue) }

        // A uniquely named copy, so the script can find its own document by name (never one you have open).
        let token = "Convert Everything \(UUID().uuidString.prefix(8))"
        let copy = input.deletingLastPathComponent().appending(path: "\(token).\(input.pathExtension)")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: input, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
        if !wasRunning { await launchHidden(id) }

        let script = """
        on run argv
            set inputFile to POSIX file (item 1 of argv)
            set outputFile to POSIX file (item 2 of argv)
            set baseName to item 3 of argv
            set fullName to item 4 of argv
            try
                with timeout of 30 seconds
                    tell application id "\(id)" to open inputFile
                end timeout
            end try
            set theDocument to missing value
            repeat \(openTimeout * 4) times
                try
                    with timeout of 5 seconds
                        tell application id "\(id)" to set theDocument to document baseName
                        tell application id "\(id)" to get name of theDocument
                    end timeout
                    exit repeat
                on error
                    try
                        with timeout of 5 seconds
                            tell application id "\(id)" to set theDocument to document fullName
                            tell application id "\(id)" to get name of theDocument
                        end timeout
                        exit repeat
                    on error
                        set theDocument to missing value
                        delay 0.25
                    end try
                end try
            end repeat
            if theDocument is missing value then error "OPEN_TIMEOUT"
            with timeout of \(totalTimeout) seconds
                tell application id "\(id)"
                    export theDocument to outputFile as \(format.rawValue)
                    close theDocument saving no
                end tell
            end timeout
        end run
        """
        // If the app hasn't got the document ready after a while, it's usually showing a window that needs
        // you (Keynote's "may look different" warnings, which stop it from answering). Bring it forward and ask.
        let watcher = Task {
            try await Task.sleep(for: .seconds(15))
            await MainActor.run {
                for running in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
                    running.unhide()
                    running.activate()
                }
            }
            IWork.needsAttention?("\(app.rawValue) is waiting for you",
                                  "If \(app.rawValue) shows a window saying the file may look different, close it to finish converting.")
        }
        defer { watcher.cancel() }

        do {
            try await withTimeout(seconds: openTimeout + totalTimeout + 60) {
                try await Tools.run("/usr/bin/osascript", ["-e", script, copy.path, output.path, token, copy.lastPathComponent])
            }
        } catch ConversionError.failed(let message) where message.contains("-1743") {
            await cleanUp(id, token: token, quit: !wasRunning)
            throw ConversionError.failed("Convert Everything isn't allowed to use \(app.rawValue). Turn it on in System Settings → Privacy & Security → Automation.")
        } catch ConversionError.cancelled {
            await cleanUp(id, token: token, quit: !wasRunning)
            throw ConversionError.cancelled
        } catch {
            let windows = await windowNames(id)
            log.error("\(app.rawValue, privacy: .public) export failed: \(String(describing: error), privacy: .public); windows: \(windows, privacy: .public)")
            await cleanUp(id, token: token, quit: !wasRunning)
            throw ConversionError.failed("\(app.rawValue) didn't respond\(windows.isEmpty ? "" : " (it was showing: \(windows))"). If it shows a warning window, close it and try again.")
        }
        if !wasRunning { await cleanUp(id, token: token, quit: true) }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: output.path) { return output }
        // Some exports add their own extension or make a folder next to the requested name.
        let siblings = (try? fileManager.contentsOfDirectory(at: output.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        if let match = siblings.first(where: { $0.deletingPathExtension().lastPathComponent == output.deletingPathExtension().lastPathComponent && $0 != input }) {
            return match
        }
        throw ConversionError.failed("\(app.rawValue) couldn't export this file.")
    }

    private static let log = Logger(subsystem: "io.github.jaybirdzhang.ConvertEverything", category: "iwork")

    /// Starts the app without bringing it to the front, and waits until it's ready for AppleScript.
    private static func launchHidden(_ id: String) async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        // Only for this launch: skip the "may look different" warnings window. While it's open the app
        // stops answering AppleScript, so the export would never start. Your own setting isn't changed.
        configuration.arguments = ["-TMADoNotShowDocumentWarnings", "YES"]
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        try? await Task.sleep(for: .seconds(2))
    }

    /// Closes our document if it's still open, and quits the app when we started it.
    private static func cleanUp(_ id: String, token: String, quit: Bool) async {
        let script = """
        with timeout of 10 seconds
            tell application id "\(id)"
                try
                    close (every document whose name starts with "\(token)") saving no
                end try
                \(quit ? "quit saving no" : "")
            end tell
        end timeout
        """
        _ = try? await withTimeout(seconds: 20) { try await Tools.run("/usr/bin/osascript", ["-e", script]) }
    }

    /// The titles of the app's windows (a sheet or prompt shows up here), for diagnosing a stuck export.
    private static func windowNames(_ id: String) async -> String {
        let script = #"with timeout of 5 seconds\#ntell application id "\#(id)" to get name of every window\#nend timeout"#
        return ((try? await withTimeout(seconds: 10) { try await Tools.run("/usr/bin/osascript", ["-e", script]) }) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
