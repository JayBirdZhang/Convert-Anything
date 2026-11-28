import Foundation
import ImageIO
import UniformTypeIdentifiers

// The real app's Format.swift is compiled as is. This file supplies the two things it and the routing
// need from elsewhere in the app, plus a copy of Converter.route (Converter.swift pulls in every engine).

nonisolated enum ImageWriters {
    private static let identifiers = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
    static func supports(_ format: Format) -> Bool {
        guard let type = UTType(filenameExtension: format.rawValue) else { return false }
        return identifiers.contains(type.identifier)
    }
}

enum Subtitles { static let directTargets: [Format] = [.txt, .md, .srt, .vtt] }

extension Format {
    var preferredExtension: String { self == .jpeg ? "jpg" : rawValue }
}

/// Copied from Converter.route in Converter.swift (1.5). Only says whether a pair converts.
enum Routes {
    static let documentSources: [Format] = [.md, .txt, .html, .docx, .doc, .rtf, .odt, .pages, .pdf, .epub]
    static let documentTargets: [Format] = [.md, .txt, .html, .docx, .doc, .rtf, .odt, .pdf, .epub]

    static func converts(_ from: Format, _ to: Format) -> Bool {
        guard from != to, !to.isIWork, to.isWritable else { return false }
        let subtitles: [Format] = [.srt, .vtt]
        if [.audio, .video].contains(from.kind) && (to == .txt || subtitles.contains(to)) { return true }
        if subtitles.contains(from) { return Subtitles.directTargets.contains(to) || documentTargets.contains(to) }
        if from.isSlides { return to == .pdf || to.kind == .image || to == .pptx }
        if to.isSlides { return to == .pptx && (from == .pdf || from.kind == .image) }
        if from.kind == .spreadsheet || to.kind == .spreadsheet {
            guard from.kind == .spreadsheet else { return false }
            if to.kind == .image { return true }
            let targets: [Format] = from == .json ? [.pdf, .csv, .xlsx] : [.pdf, .csv, .xlsx, .json]
            return targets.contains(to)
        }
        switch (from.kind, to.kind) {
        case (.image, .image): return true
        case (.image, .document) where to == .pdf: return true
        case (.image, .document) where from != .svg && [.txt, .md, .docx, .html, .rtf, .odt].contains(to): return true
        case (.document, .image) where from == .pdf: return true
        case (.document, .image) where documentSources.contains(from): return true
        case (.document, .document) where documentSources.contains(from) && documentTargets.contains(to): return true
        case (.audio, .audio), (.video, .audio): return ![.ogg, .opus].contains(to)
        case (.video, .video): return true
        case (.video, .image) where to != .ico && to != .avif: return true
        case (.image, .video) where from == .gif: return true
        default: return false
        }
    }

    static func targets(of from: Format) -> [Format] { Format.allCases.filter { converts(from, $0) } }
}

/// A drop tile: one format, "Combine into PDF", or "More…".
enum Tile: Hashable {
    case format(Format)
    case combine
    case more

    /// What's stored as the remembered choice.
    var memoryValue: String? {
        switch self {
        case .format(let f): f.rawValue
        case .combine: "combine"
        case .more: nil
        }
    }
}

/// What the menu offers for a set of dragged files.
struct DropPlan: Equatable {
    var tiles: [Tile] = []          // Up to 4 formats, then Combine (all images), then More
    var all: [Format] = []          // Every common target, for the More… chips
    var canCombine = false
    var remembered: Tile?           // The last choice for these source types, shown first and highlighted
    var message: String?            // Set instead of tiles when nothing can be offered
    var memoryKey = ""

    static let tileCount = 4

    /// Hand-picked "most likely" order per kind (the user chose this over the app's popularity order).
    static func preferred(for f: Format) -> [Format] {
        if f == .pdf { return [.docx, .png, .jpeg, .txt, .pptx] }
        if f.isSlides { return [.pdf, .png, .jpeg, .pptx] }
        switch f.kind {
        case .image: return [.jpeg, .png, .pdf, .heic, .webp, .gif, .tiff]
        case .video: return [.mp4, .mov, .mp3, .gif, .m4a]
        case .audio: return [.mp3, .m4a, .wav, .txt]
        case .spreadsheet: return [.csv, .xlsx, .pdf, .json]
        case .document: return [.pdf, .md, .txt, .html, .docx]
        }
    }

    /// The real app's popularity order (UnsupportedConversion.popular), used to fill up after the hand-picked ones.
    static let popular: [Format] = [
        .pdf, .docx, .pptx, .txt, .md, .rtf, .html, .odt, .doc,
        .png, .jpeg, .heic, .webp, .gif, .tiff, .bmp, .avif, .ico,
        .xlsx, .csv,
        .m4a, .mp3, .wav, .flac, .aac, .aiff, .opus, .ogg,
        .mp4, .mov, .m4v,
    ]

    static func make(for urls: [URL], memory: [String: String]) -> DropPlan {
        var plan = DropPlan()
        guard !urls.isEmpty else { plan.message = "Nothing to convert"; return plan }
        var sources: [Format] = []
        for url in urls {
            if url.hasDirectoryPath { plan.message = "Can't convert folders"; return plan }
            let ext = url.pathExtension.lowercased()
            guard let f = Format(fileExtension: ext), !Routes.targets(of: f).isEmpty else {
                plan.message = ext.isEmpty ? "Can't convert files without an extension" : "Can't convert .\(ext) files"
                return plan
            }
            sources.append(f)
        }

        var common = Set(Routes.targets(of: sources[0]))
        for s in sources.dropFirst() { common.formIntersection(Routes.targets(of: s)) }
        plan.canCombine = urls.count > 1 && sources.allSatisfy { $0.kind == .image }
        let order = preferred(for: sources[0]) + popular + Format.allCases
        var seen = Set<Format>()
        plan.all = order.filter { common.contains($0) && seen.insert($0).inserted }
        guard !plan.all.isEmpty || plan.canCombine else {
            plan.message = "These files have no format in common"
            return plan
        }

        plan.memoryKey = Set(sources.map(\.rawValue)).sorted().joined(separator: "+")
        if let value = memory[plan.memoryKey] {
            if value == "combine", plan.canCombine { plan.remembered = .combine }
            else if let f = Format(rawValue: value), plan.all.contains(f) { plan.remembered = .format(f) }
        }

        var formats = plan.all
        if case .format(let f)? = plan.remembered { formats.removeAll { $0 == f }; formats.insert(f, at: 0) }
        plan.tiles = formats.prefix(tileCount).map(Tile.format)
        if plan.canCombine {
            if plan.remembered == .combine { plan.tiles.insert(.combine, at: 0) } else { plan.tiles.append(.combine) }
        }
        if plan.all.count > tileCount { plan.tiles.append(.more) }
        return plan
    }
}

extension Format {
    /// Tile subtitle: the format's name, or "Transcript" when speech becomes text.
    func tileName(from source: Format?) -> String {
        if self == .txt, let source, [.audio, .video].contains(source.kind) { return "Transcript" }
        return displayName == "plain text" ? "Plain text" : displayName
    }
}
