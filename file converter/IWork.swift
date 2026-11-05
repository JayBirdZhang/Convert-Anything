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

        // The app is quit afterwards only if it wasn't already open and no other documents are open in it.
        let script = """
        on run argv
            set inputFile to POSIX file (item 1 of argv)
            set outputFile to POSIX file (item 2 of argv)
            set wasRunning to application id "\(id)" is running
            tell application id "\(id)"
                set theDocument to missing value
                try
                    set theDocument to open inputFile
                    get name of theDocument
                on error
                    -- Some versions return an unusable reference from "open": use the front document,
                    -- once the import has finished.
                    set theDocument to missing value
                end try
                if theDocument is missing value then
                    repeat 100 times
                        if (count of documents) > 0 then exit repeat
                        delay 0.2
                    end repeat
                    set theDocument to front document
                end if
                try
                    export theDocument to outputFile as \(format.rawValue)
                on error message number code
                    close theDocument saving no
                    error message number code
                end try
                close theDocument saving no
                if not wasRunning and (count of documents) is 0 then quit
            end tell
        end run
        """
        do {
            try await Tools.run("/usr/bin/osascript", ["-e", script, input.path, output.path])
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
