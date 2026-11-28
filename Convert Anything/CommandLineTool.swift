import AppKit
import SwiftUI   // For MyApp.main()

/// The app's real entry point. Launched with command-line arguments it converts one file and exits, before
/// any of the menu-bar app is set up (no window, no folder watching, no update check). Otherwise it's the app.
@main enum Entry {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if CommandLineTool.handles(arguments) { CommandLineTool.run(arguments) }
        MyApp.main()
    }
}

/// `convert-anything <input> <output-or-format>`, run by the app's own executable (see `Entry`), so there's
/// no second copy of the converter. It runs as its own process next to a running app: it never touches the
/// app's history, undo records or settings, and the running app ignores the files it writes.
enum CommandLineTool {
    nonisolated static let name = "convert-anything"

    private enum Exit: Int32 {
        case success = 0
        case failed = 1   // The conversion itself went wrong, or the input is missing or unreadable
        case usage = 2    // Bad arguments, an unknown format, or a conversion that can't be done
    }

    private static let flags: Set<String> = ["-h", "--help", "--list-formats", "--version", "-f", "--force", "--replace", "--quality"]

    /// The installed command (see `CommandLineInstaller`) starts with this, so typing just `convert-anything`
    /// prints help instead of starting a second copy of the menu-bar app.
    nonisolated static let marker = "--cli"

    /// Arguments that ask for the command line. macOS and Xcode pass their own (-NSDocumentRevisionsDebugMode
    /// YES, -AppleLanguages …), always with a single dash, so a file, a double-dash option or -h/-f counts.
    static func handles(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        return !first.hasPrefix("-") || first.hasPrefix("--") || flags.contains(first)
    }

    static func run(_ arguments: [String]) -> Never {
        let arguments = arguments.first == marker ? Array(arguments.dropFirst()) : arguments
        var positional: [String] = []
        var options = HeadlessConversion.Options()
        var listFormats = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            switch argument {
            case "-h", "--help": print(usage); exit(Exit.success.rawValue)
            case "--version": print(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"); exit(0)
            case "--list-formats": listFormats = true
            case "-f", "--force": options.overwrite = true
            case "--replace": options.replaceOriginal = true
            case "--quality":
                guard index < arguments.count, let quality = Quality(rawValue: arguments[index]) else {
                    fail("--quality takes best, balanced or small.", .usage)
                }
                options.quality = quality
                index += 1
            case "--": positional += arguments[index...]; index = arguments.count
            default:
                if argument.hasPrefix("-") && argument.count > 1 { fail("Unknown option \(argument).", .usage) }
                positional.append(argument)
            }
        }

        if listFormats {
            guard positional.count <= 1 else { fail("--list-formats takes at most one file.", .usage) }
            listTargets(of: positional.first)
        }
        guard positional.count == 2 else {
            if positional.isEmpty { FileHandle.standardError.write(Data(usage.utf8)); exit(Exit.usage.rawValue) }
            fail("Expected an input file and an output file or format. See \(name) --help.", .usage)
        }

        let input = URL(fileURLWithPath: positional[0])
        let destination: HeadlessConversion.Destination
        do {
            destination = try parseDestination(positional[1])
        } catch {
            fail(error.localizedDescription + " Run \(name) --list-formats to see them all.", .usage)
        }

        let plan: HeadlessConversion.Plan
        do {
            plan = try HeadlessConversion.plan(input, to: destination, options: options)
        } catch let failure as HeadlessConversion.Failure {
            var message = failure.localizedDescription
            if case .exists = failure { message += " Use --force to replace it." }
            fail(message, failure.isUsage ? .usage : .failed)
        } catch {
            fail(error.localizedDescription, .failed)
        }

        // Documents are laid out in an invisible window (WebKit, AppKit's text system) and Keynote, Numbers and
        // Pages are driven by Apple events; both want an application object. Pictures, PDFs and media don't,
        // and skip the cost of connecting to the window server.
        if ![.image, .imageToPDF, .pdfToImage, .media].contains(plan.route) {
            NSApplication.shared.setActivationPolicy(.prohibited)
        }
        cleanUpOnInterrupt()

        Task {
            do {
                let output = try await HeadlessConversion.run(plan, options: options)
                print(output.resolvingSymlinksInPath().path)
                exit(Exit.success.rawValue)
            } catch {
                fail(error.localizedDescription, .failed)
            }
        }
        // Main-actor work (the converter's coordination, WebKit, Apple events) needs the main run loop.
        while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
    }

    /// A path (has a slash or a file name with an extension) or a bare format such as "jpg" or ".pdf".
    private static func parseDestination(_ argument: String) throws -> HeadlessConversion.Destination {
        let ext = (argument as NSString).pathExtension
        if argument.contains("/") || (!ext.isEmpty && !argument.hasPrefix(".")) {
            return .file(URL(fileURLWithPath: argument))
        }
        let typed = argument.hasPrefix(".") ? String(argument.dropFirst()) : argument
        guard let format = Format(fileExtension: typed) else { throw HeadlessConversion.Failure.unknownFormat(typed) }
        return .format(format, fileExtension: typed.lowercased())
    }

    /// With a file: the formats it can become, one per line. Without: every format and what it can become.
    private static func listTargets(of path: String?) -> Never {
        if let path {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { fail(HeadlessConversion.Failure.missingInput(url).localizedDescription, .failed) }
            guard let format = HeadlessConversion.sourceFormat(of: url) else { fail(HeadlessConversion.Failure.unreadable(url).localizedDescription, .failed) }
            for target in HeadlessConversion.targets(from: format) { print(HeadlessConversion.preferredExtension(target)) }
            exit(Exit.success.rawValue)
        }
        let kinds: [(Format.Kind, String)] = [(.image, "Images"), (.document, "Documents"), (.spreadsheet, "Spreadsheets"),
                                              (.audio, "Audio"), (.video, "Video")]
        for (kind, title) in kinds {
            print(title)
            for format in Format.allCases where format.kind == kind {
                let targets = HeadlessConversion.targets(from: format).map(HeadlessConversion.preferredExtension)
                let name = HeadlessConversion.preferredExtension(format)
                print("  " + name.padding(toLength: 8, withPad: " ", startingAt: 0)
                      + (targets.isEmpty ? "(read only as part of other conversions)" : "→ " + targets.joined(separator: " ")))
            }
        }
        exit(Exit.success.rawValue)
    }

    private static var usage: String {
        """
        Usage: \(name) [options] <input> <output-file | format>

        Converts a file with Convert Anything's engine and prints where the result went.
          \(name) photo.heic jpg           → photo.jpg next to photo.heic
          \(name) notes.md ~/Desktop/notes.docx

        The result's format comes from the output file's extension, or from a format name (jpg, pdf, mp3…).
        Quality, every-page export and editable slides follow the app's settings.

        Options:
          --quality best|balanced|small   Override the Quality setting
          --replace                       Move the original to the Trash after converting
          -f, --force                     Replace an existing output file
          --list-formats [file]           List the formats, or the ones this file can become
          --version                       Print the version
          -h, --help                      Show this help

        Exit status: 0 converted, 1 the conversion failed, 2 bad arguments or a conversion that can't be done.

        """
    }

    private static func fail(_ message: String, _ status: Exit) -> Never {
        FileHandle.standardError.write(Data("\(name): \(message)\n".utf8))
        exit(status.rawValue)
    }

    /// Ctrl-C removes the half-finished work folder before quitting.
    private static func cleanUpOnInterrupt() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    HeadlessConversion.activeWorkDirs.forEach { try? FileManager.default.removeItem(at: $0) }
                }
                exit(128 + sig)
            }
            source.resume()
            signalSources.append(source)
        }
    }
    private static var signalSources: [DispatchSourceSignal] = []
}
