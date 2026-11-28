import Foundation

/// Converts one file without the folder watcher, for Shortcuts and the command line.
///
/// It runs the same engine as a rename, with the same settings (quality, every page, editable slides), but it
/// stays out of the menu: no history row, no notification and no rename-back undo. The original is left
/// alone unless `replaceOriginal` is set, and then it goes to the Trash, so it can still be put back.
///
/// The result is made in a private folder and moved straight to its final name. That matters because
/// another copy of the app may be watching the folder: a file renamed inside a watched folder is a
/// conversion request, a file moved in from elsewhere isn't.
enum HeadlessConversion {
    enum Destination {
        /// Next to the input, named after it ("photo.heic" → "photo.jpg", or "photo 2.jpg" if that's taken).
        /// `fileExtension` is the extension as typed (jpg or jpeg); by default the usual one.
        case format(Format, fileExtension: String? = nil)
        /// Exactly this file; its extension says the format. A folder of page images goes next to it,
        /// named after it without the extension.
        case file(URL)
    }

    nonisolated struct Options {
        var replaceOriginal = false
        /// With `.file`, replace a file that's already there instead of failing.
        var overwrite = false
        var quality = Settings.quality
        var allPages = Settings.allPages
        var editableSlides = Settings.editableSlides
    }

    /// Everything about a conversion that can be decided without converting, so callers can report a
    /// bad request (unknown file, impossible pair) before any work starts.
    struct Plan {
        let input: URL
        let from: Format
        let to: Format
        let route: Converter.Route
        let output: URL
        let outputExtension: String
    }

    enum Failure: LocalizedError {
        case missingInput(URL)
        case unreadable(URL)
        case unknownFormat(String)
        case sameFormat(URL, Format)
        case unsupported(String)
        case exists(URL)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missingInput(let url): "There's no file at \(url.path)."
            case .unreadable(let url): "Convert Anything can't read \(url.lastPathComponent)."
            case .unknownFormat(let ext): "Convert Anything doesn't know the format \"\(ext)\"."
            case .sameFormat(let url, let format): "\(url.lastPathComponent) is already \(format.displayName)."
            case .unsupported(let message): message
            case .exists(let url): "\(url.path) already exists."
            case .failed(let message): message
            }
        }

        /// A problem with what was asked for rather than with converting it.
        var isUsage: Bool {
            switch self {
            case .unknownFormat, .sameFormat, .unsupported, .exists: true
            default: false
            }
        }
    }

    /// Converts `input` and returns where the result went: a file, or a folder when every page became an image.
    @discardableResult
    static func convert(_ input: URL, to destination: Destination, options: Options = Options()) async throws -> URL {
        try await run(plan(input, to: destination, options: options), options: options)
    }

    static func plan(_ input: URL, to destination: Destination, options: Options = Options()) throws -> Plan {
        let fileManager = FileManager.default
        let input = input.standardizedFileURL
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: input.path, isDirectory: &isFolder), !isFolder.boolValue else {
            throw Failure.missingInput(input)
        }
        guard let from = sourceFormat(of: input) else { throw Failure.unreadable(input) }

        let to: Format, output: URL, typed: String
        switch destination {
        case .format(let format, let ext):
            to = format
            typed = (ext ?? preferredExtension(format)).lowercased()
            let name = input.deletingPathExtension().lastPathComponent
            output = uniqueURL(input.deletingLastPathComponent().appending(path: "\(name).\(typed)"))
        case .file(let url):
            typed = url.pathExtension.lowercased()
            guard let format = Format(fileExtension: typed) else { throw Failure.unknownFormat(url.pathExtension) }
            to = format
            output = url.standardizedFileURL
            if fileManager.fileExists(atPath: output.path) && !options.overwrite { throw Failure.exists(output) }
        }
        guard from != to else { throw Failure.sameFormat(input, to) }
        guard let route = Converter.route(from: from, to: to) else {
            throw Failure.unsupported(UnsupportedConversion.message(from: from, to: to, originalExtension: input.pathExtension))
        }
        return Plan(input: input, from: from, to: to, route: route, output: output, outputExtension: typed)
    }

    static func run(_ plan: Plan, options: Options = Options()) async throws -> URL {
        let lane = Converter.isHeavy(from: plan.from, to: plan.to) ? heavyLane : lightLane
        await lane.acquire()
        defer { lane.release() }

        let fileManager = FileManager.default
        let workDir = fileManager.temporaryDirectory.appending(path: "ConvertAnything/\(UUID().uuidString)")
        activeWorkDirs.insert(workDir)
        defer {
            try? fileManager.removeItem(at: workDir)
            activeWorkDirs.remove(workDir)
        }
        try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)

        // Work on a private copy (an instant clone on APFS), as a rename does.
        let input = workDir.appending(path: "input.\(plan.from.rawValue)")
        try fileManager.copyItem(at: plan.input, to: input)
        let request = Converter.Request(
            input: input, from: plan.from, to: plan.to, workDir: workDir,
            title: plan.output.deletingPathExtension().lastPathComponent,
            originalDir: plan.input.deletingLastPathComponent(),
            allPages: options.allPages,
            outputExtension: plan.outputExtension,
            editableSlides: options.editableSlides,
            quality: options.quality)
        let result = try await Converter.convert(request) { _ in }

        var isFolder: ObjCBool = false
        fileManager.fileExists(atPath: result.path, isDirectory: &isFolder)
        let destination = isFolder.boolValue ? uniqueURL(plan.output.deletingPathExtension()) : plan.output
        if !isFolder.boolValue, options.overwrite, fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: result, to: destination)

        if options.replaceOriginal {
            do {
                try fileManager.trashItem(at: plan.input, resultingItemURL: nil)
            } catch {
                throw Failure.failed("Converted to \(destination.path), but couldn't move the original to the Trash: \(error.localizedDescription)")
            }
        }
        return destination
    }

    // MARK: Formats

    /// What's inside the file decides its format, not its extension, as for a rename. Nil when it isn't
    /// something the converter reads.
    nonisolated static func sourceFormat(of url: URL) -> Format? {
        let claimed = Format(fileExtension: url.pathExtension)
        switch Sniffer.detect(url, claimed: claimed) {
        case .format(let detected): return detected
        case .text:
            if claimed == .json || (claimed == nil && Sniffer.looksLikeJSON(url)) { return .json }
            return claimed?.isPlainText == true ? claimed : .txt
        case .iWork: return claimed?.isIWork == true ? claimed : nil
        case .unknown: return nil
        }
    }

    /// Every format a file of `format` can become, in declaration order.
    static func targets(from format: Format) -> [Format] {
        Format.allCases.filter { Converter.route(from: format, to: $0) != nil }
    }

    /// Every format anything can become.
    static var allTargets: [Format] {
        let sources = Format.allCases
        return Format.allCases.filter { to in sources.contains { Converter.route(from: $0, to: to) != nil } }
    }

    /// The extension a new file gets when only the format was named.
    nonisolated static func preferredExtension(_ format: Format) -> String {
        format == .jpeg ? "jpg" : format.rawValue
    }

    // MARK: Plumbing

    /// Work folders of conversions still running, so the command line can clean up when it's interrupted.
    private(set) static var activeWorkDirs: Set<URL> = []

    // Like the app's own lanes: video and the iWork apps one at a time, the rest a few at a time.
    // (They're per process: a conversion here and a rename in a running app can still overlap.)
    private static let heavyLane = Lane(limit: 1)
    private static let lightLane = Lane(limit: max(2, ProcessInfo.processInfo.activeProcessorCount / 2))

    /// The app's settings, read straight from its defaults so they apply without the app running.
    nonisolated private enum Settings {
        static var quality: Quality { UserDefaults.standard.string(forKey: "quality").flatMap(Quality.init) ?? .balanced }
        static var allPages: Bool { UserDefaults.standard.object(forKey: "exportAllPages") as? Bool ?? true }
        static var editableSlides: Bool { UserDefaults.standard.object(forKey: "editableSlides") as? Bool ?? true }
    }

    /// "photo.jpg", then "photo 2.jpg", "photo 3.jpg"… (or "deck", "deck 2"… for a folder).
    private static func uniqueURL(_ url: URL) -> URL {
        let folder = url.deletingLastPathComponent(), ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var candidate = url
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}
