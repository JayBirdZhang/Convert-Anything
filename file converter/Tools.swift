import Foundation

nonisolated enum ConversionError: LocalizedError {
    case unsupported(Format, Format)
    case missingTool(String, brewPackage: String)
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupported(let from, let to):
            "Can't convert \(from.displayName) to \(to.displayName)."
        case .missingTool(let tool, let package):
            "\(tool) isn't installed. Run “brew install \(package)” in Terminal."
        case .failed(let message):
            message
        case .cancelled:
            "Cancelled."
        }
    }
}

/// Finds and runs the command-line converters (sips/textutil ship with macOS;
/// pandoc, ffmpeg and cwebp come from Homebrew).
nonisolated enum Tools {
    /// Apps launched from Finder don't inherit the Terminal's PATH, so check Homebrew's folders explicitly.
    static func path(for name: String) -> String? {
        let envPath = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] + envPath
        return dirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func require(_ name: String, brewPackage: String? = nil) throws -> String {
        guard let path = path(for: name) else {
            throw ConversionError.missingTool(name, brewPackage: brewPackage ?? name)
        }
        return path
    }

    /// Runs a tool at low priority and returns its stdout. Cancelling the calling task terminates the process.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String], currentDirectory: URL? = nil, onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let box = ProcessBox()
        let process = box.process
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.qualityOfService = .utility
        process.standardInput = FileHandle.nullDevice

        let output = OutputCollector(onLine: onLine)
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { output.appendOut($0.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { output.appendErr($0.availableData) }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        output.appendOut(stdout.fileHandleForReading.readDataToEndOfFile())
        output.appendErr(stderr.fileHandleForReading.readDataToEndOfFile())

        if Task.isCancelled { throw ConversionError.cancelled }
        guard process.terminationStatus == 0 else {
            let name = URL(fileURLWithPath: tool).lastPathComponent
            throw ConversionError.failed("\(name) failed: \(output.lastErrorLines)")
        }
        return output.stdoutString
    }
}

nonisolated private final class ProcessBox: @unchecked Sendable {
    let process = Process()
}

nonisolated private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var partialLine = ""
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func appendOut(_ data: Data) {
        guard !data.isEmpty else { return }
        var lines: [String] = []
        lock.withLock {
            out.append(data)
            guard onLine != nil else { return }
            partialLine += String(decoding: data, as: UTF8.self)
            var parts = partialLine.components(separatedBy: "\n")
            partialLine = parts.removeLast()
            lines = parts
        }
        lines.forEach { onLine?($0) }
    }

    func appendErr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock { err.append(data) }
    }

    var stdoutString: String { lock.withLock { String(decoding: out, as: UTF8.self) } }

    var lastErrorLines: String {
        lock.withLock {
            String(decoding: err, as: UTF8.self)
                .split(separator: "\n").suffix(3).joined(separator: " ")
        }
    }
}
