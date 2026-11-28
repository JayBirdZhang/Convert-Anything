import AppIntents
import Foundation
import UniformTypeIdentifiers

/// Shortcuts' "Convert File" action. It runs inside the app (launching it in the background when it isn't
/// running) and converts with `HeadlessConversion`, so it's the same engine and settings as a rename, without
/// a history row or notification.
struct ConvertFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert File"
    static let description = IntentDescription("Converts files to another format on this Mac, with Convert Anything's settings for quality and pages. The converted files are saved next to the originals.")

    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.item"], inputConnectionBehavior: .connectToPreviousIntentResult)
    var files: [IntentFile]

    @Parameter(title: "Format")
    var format: TargetFormat

    @Parameter(title: "Replace Original", description: "Move the original to the Trash once it's converted.", default: false)
    var replaceOriginal: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$files) to \(\.$format)") {
            \.$replaceOriginal
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        // Quits afterwards if the app was started just for this (BackgroundLaunch.swift).
        await MainActor.run { BackgroundLaunch.shared.actionStarted() }
        var results: [IntentFile] = []
        do {
            for file in files {
                results += try await convert(file, to: format.format, replacingOriginal: replaceOriginal)
            }
        } catch {
            await MainActor.run { BackgroundLaunch.shared.actionFinished() }
            throw error
        }
        await MainActor.run { BackgroundLaunch.shared.actionFinished() }
        return .result(value: results)
    }

    private func convert(_ file: IntentFile, to format: Format, replacingOriginal: Bool) async throws -> [IntentFile] {
        var options = HeadlessConversion.Options()
        options.replaceOriginal = replacingOriginal
        do {
            if let url = file.fileURL {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return Self.files(at: try await HeadlessConversion.convert(url, to: .format(format), options: options))
            }
            // A file that only exists in the shortcut (from another action) has no folder to go back to: it's
            // converted in a private folder and handed back as data.
            let folder = FileManager.default.temporaryDirectory.appending(path: "ConvertAnything/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let input = folder.appending(path: file.filename.isEmpty ? "file" : file.filename)
            try file.data.write(to: input)
            options.replaceOriginal = false
            let output = try await HeadlessConversion.convert(input, to: .format(format), options: options)
            return try Self.files(at: output).map { converted in
                let url = converted.fileURL!
                return IntentFile(data: try Data(contentsOf: url), filename: url.lastPathComponent,
                                  type: UTType(filenameExtension: url.pathExtension))
            }
        } catch {
            throw IntentError(message: "\(file.filename): \(error.localizedDescription)")
        }
    }

    /// The converted file, or each page image when every page became its own file.
    private static func files(at url: URL) -> [IntentFile] {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else {
            return [IntentFile(fileURL: url)]
        }
        let pages = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return pages.filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { IntentFile(fileURL: $0) }
    }
}

nonisolated struct IntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// A format to convert to. It's an entity rather than a fixed enum so the list comes from the converter itself
/// (it can't drift from what really converts) and, when the files are already chosen, shows only what they
/// can all become.
nonisolated struct TargetFormat: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Format"
    static let defaultQuery = TargetFormatQuery()

    let id: String   // Format.rawValue
    var format: Format { Format(rawValue: id) ?? .pdf }

    init(_ format: Format) { id = format.rawValue }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(format.displayName)", subtitle: ".\(HeadlessConversion.preferredExtension(format))")
    }
}

nonisolated struct TargetFormatQuery: EntityStringQuery {
    @IntentParameterDependency<ConvertFileIntent>(\.$files) var intent

    func entities(for identifiers: [String]) async throws -> [TargetFormat] {
        identifiers.compactMap(Format.init(rawValue:)).map(TargetFormat.init)
    }

    func entities(matching string: String) async throws -> [TargetFormat] {
        let query = string.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return try await suggestedEntities().filter {
            $0.id.hasPrefix(query) || HeadlessConversion.preferredExtension($0.format).hasPrefix(query)
                || $0.format.displayName.lowercased().hasPrefix(query)
        }
    }

    func suggestedEntities() async throws -> [TargetFormat] {
        let sources = (intent?.files ?? []).compactMap { $0.fileURL.flatMap(HeadlessConversion.sourceFormat) }
        return await MainActor.run {
            guard !sources.isEmpty else { return HeadlessConversion.allTargets.map(TargetFormat.init) }
            // Only what every chosen file can become.
            let common = sources.dropFirst().reduce(HeadlessConversion.targets(from: sources[0])) { targets, source in
                let more = HeadlessConversion.targets(from: source)
                return targets.filter(more.contains)
            }
            return common.map(TargetFormat.init)
        }
    }
}
