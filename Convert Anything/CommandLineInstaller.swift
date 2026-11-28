import AppKit
import SwiftUI

/// Puts `convert-anything` on the PATH in /usr/local/bin, which every Mac's shells search without setup. That
/// folder belongs to the system, so macOS asks for an administrator's password unless it's already writable.
///
/// The command is a two-line shell script that runs the app's own executable. (A symlink would be simpler, but
/// macOS then can't tell which app bundle the executable belongs to, and conversions that need the app's
/// resources fail.) It follows app updates; moving the app breaks it until it's installed again.
enum CommandLineInstaller {
    static let shim = URL(fileURLWithPath: "/usr/local/bin/\(CommandLineTool.name)")
    private static let marker = "# Added by Convert Anything"

    enum State: Equatable {
        case notInstalled
        case installed
        case otherCopy   // Ours, but for a copy of the app somewhere else
        case foreign     // Something else by that name
    }

    static var state: State {
        guard FileManager.default.fileExists(atPath: shim.path) else { return .notInstalled }
        guard let script = try? String(contentsOf: shim, encoding: .utf8), script.contains(marker) else { return .foreign }
        return script == expectedScript ? .installed : .otherCopy
    }

    private static var executable: URL { Bundle.main.executableURL! }

    private static var expectedScript: String {
        let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "#!/bin/sh\n\(marker) (Settings → Command-line tool). It runs the app's converter.\nexec \(quoted) \(CommandLineTool.marker) \"$@\"\n"
    }

    static func install() async throws {
        // Opened straight from a download, macOS runs the app from a random read-only location that disappears.
        guard !executable.path.contains("/AppTranslocation/") else {
            throw ConversionError.failed("Move Convert Anything to your Applications folder first, then install the command.")
        }
        guard state != .foreign else { throw ConversionError.failed("\(shim.path) already exists and isn't Convert Anything's.") }
        let script = FileManager.default.temporaryDirectory.appending(path: "\(CommandLineTool.name)-\(UUID().uuidString)")
        try expectedScript.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        try await run("/bin/mkdir -p /usr/local/bin && /usr/bin/install -m 755 \"$1\" \"$2\"", script.path, shim.path)
    }

    static func uninstall() async throws {
        guard [.installed, .otherCopy].contains(state) else { return }
        try await run("/bin/rm -f \"$1\"", shim.path)
    }

    /// Runs a shell command (paths passed as $1, $2, never spliced into it), as an administrator only when
    /// /usr/local/bin can't be written to as the user.
    private static func run(_ script: String, _ arguments: String...) async throws {
        let writable = FileManager.default.isWritableFile(atPath: shim.deletingLastPathComponent().path)
        try await background {
            let process = Process()
            if writable {
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", script, "sh"] + arguments
            } else {
                // AppleScript's own password prompt. The command and paths go in as arguments and are quoted there.
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = [
                    "-e", "on run argv",
                    "-e", "set command to \"/bin/sh -c \" & quoted form of item 1 of argv & \" sh\"",
                    "-e", "repeat with value in rest of argv",
                    "-e", "set command to command & \" \" & quoted form of (contents of value)",
                    "-e", "end repeat",
                    "-e", "do shell script command with prompt \"Convert Anything wants to change the \(CommandLineTool.name) command.\" with administrator privileges",
                    "-e", "end run",
                    script,
                ] + arguments
            }
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if message.contains("-128") { throw ConversionError.cancelled }   // The password prompt was cancelled
                throw ConversionError.failed(message.isEmpty ? "Couldn't change /usr/local/bin." : message)
            }
        }
    }
}

/// The Settings row: installs or removes the command, and says how to use it.
struct CommandLineToolRow: View {
    @State private var state = CommandLineInstaller.state
    @State private var error: String?
    @State private var working = false

    var body: some View {
        SettingRow("Command-line tool", detail: detail,
                   help: "Converts from Terminal: \(CommandLineTool.name) photo.heic jpg. Run \(CommandLineTool.name) --help for more.") {
            Button(state == .installed ? "Remove" : "Install…") {
                Task { await toggle() }
            }
            .disabled(working)
        }
        .onAppear { state = CommandLineInstaller.state }
    }

    private var detail: String {
        if let error { return error }
        switch state {
        case .installed: return "\(CommandLineTool.name) in Terminal"
        case .notInstalled: return "Adds \(CommandLineTool.name) to Terminal"
        case .otherCopy: return "Runs another copy of the app. Install again to use this one."
        case .foreign: return "\(CommandLineInstaller.shim.path) is taken by something else"
        }
    }

    private func toggle() async {
        working = true
        defer { working = false; state = CommandLineInstaller.state }
        do {
            if state == .installed { try await CommandLineInstaller.uninstall() } else { try await CommandLineInstaller.install() }
            error = nil
        } catch ConversionError.cancelled {
            error = nil
        } catch {
            self.error = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
