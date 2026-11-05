import AppKit

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

    /// Exports `input` to `output`. Numbers' CSV export of a file with several tables makes a folder
    /// of CSV files; the returned URL is whatever was written.
    @discardableResult
    static func export(_ input: URL, with app: App, as format: ExportFormat, to output: URL) async throws -> URL {
        guard let id = app.installedID else { throw ConversionError.missingApp(app.rawValue) }

        // A uniquely named copy, so the script can find its own document by name (never one you have open),
        // and wait for it: large files take a while to import, and "open" returns before they're ready.
        // The app is quit afterwards only if it wasn't open before.
        let token = "Convert Everything \(UUID().uuidString.prefix(8))"
        let copy = input.deletingLastPathComponent().appending(path: "\(token).\(input.pathExtension)")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: input, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        let script = """
        on run argv
            set inputFile to POSIX file (item 1 of argv)
            set outputFile to POSIX file (item 2 of argv)
            set baseName to item 3 of argv
            set fullName to item 4 of argv
            set wasRunning to application id "\(id)" is running
            tell application id "\(id)" to open inputFile
            set theDocument to missing value
            repeat 360 times
                try
                    tell application id "\(id)" to set theDocument to document baseName
                    tell application id "\(id)" to get name of theDocument
                    exit repeat
                on error
                    try
                        tell application id "\(id)" to set theDocument to document fullName
                        tell application id "\(id)" to get name of theDocument
                        exit repeat
                    on error
                        set theDocument to missing value
                        delay 0.25
                    end try
                end try
            end repeat
            if theDocument is missing value then
                if not wasRunning then tell application id "\(id)" to quit
                error "\(app.rawValue) didn't open the file. If \(app.rawValue) is showing a message or asking for permission, answer it and try again."
            end if
            with timeout of 900 seconds
                tell application id "\(id)"
                    export theDocument to outputFile as \(format.rawValue)
                    close theDocument saving no
                end tell
            end timeout
            if not wasRunning then tell application id "\(id)" to quit
        end run
        """
        do {
            try await Tools.run("/usr/bin/osascript", ["-e", script, copy.path, output.path, token, copy.lastPathComponent])
        } catch ConversionError.failed(let message) where message.contains("-1743") {
            throw ConversionError.failed("Convert Everything isn't allowed to use \(app.rawValue). Turn it on in System Settings → Privacy & Security → Automation.")
        } catch ConversionError.failed(let message) where message.contains("-1712") {
            throw ConversionError.failed("\(app.rawValue) took too long to respond.")
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: output.path) { return output }
        // Some exports add their own extension or make a folder next to the requested name.
        let siblings = (try? fileManager.contentsOfDirectory(at: output.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        if let match = siblings.first(where: { $0.deletingPathExtension().lastPathComponent == output.deletingPathExtension().lastPathComponent && $0 != input }) {
            return match
        }
        throw ConversionError.failed("\(app.rawValue) couldn't export this file.")
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
