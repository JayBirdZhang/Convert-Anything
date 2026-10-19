import Foundation

nonisolated enum Format: String, CaseIterable, Sendable {
    // Images
    case png, jpeg, heic, tiff, gif, bmp, webp, avif, ico
    // Documents
    case pdf, md, txt, html, docx, doc, rtf, odt, epub, tex
    // Audio
    case mp3, wav, m4a, aac, flac, ogg, opus, aiff
    // Video
    case mp4, mov, m4v, mkv, webm, avi

    enum Kind { case image, document, audio, video }

    init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "jpg", "jpeg", "jpe": self = .jpeg
        case "tif", "tiff": self = .tiff
        case "heif", "heic": self = .heic
        case "htm", "html": self = .html
        case "markdown", "md": self = .md
        case "text", "txt": self = .txt
        case "aif", "aiff": self = .aiff
        case "latex", "tex": self = .tex
        default:
            guard let format = Format(rawValue: ext.lowercased()) else { return nil }
            self = format
        }
    }

    var kind: Kind {
        switch self {
        case .png, .jpeg, .heic, .tiff, .gif, .bmp, .webp, .avif, .ico: .image
        case .pdf, .md, .txt, .html, .docx, .doc, .rtf, .odt, .epub, .tex: .document
        case .mp3, .wav, .m4a, .aac, .flac, .ogg, .opus, .aiff: .audio
        case .mp4, .mov, .m4v, .mkv, .webm, .avi: .video
        }
    }

    /// Plain-text formats can't be told apart by their bytes, so for these
    /// we trust the file's old extension instead.
    var isPlainText: Bool { [.md, .txt, .html, .tex].contains(self) }

    var displayName: String {
        switch self {
        case .jpeg: "JPEG"
        case .md: "Markdown"
        case .txt: "plain text"
        default: rawValue.uppercased()
        }
    }
}

/// Identifies what a file really contains by reading its first bytes,
/// regardless of what its extension claims.
nonisolated enum Sniffer {
    enum Result: Equatable {
        case format(Format)
        case text      // Valid UTF-8 with no recognizable markup
        case unknown
    }

    static func detect(_ url: URL) -> Result {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4096)) ?? Data()
        guard !data.isEmpty else { return .unknown }
        let b = [UInt8](data)

        func at(_ offset: Int, _ ascii: String) -> Bool {
            let bytes = Array(ascii.utf8)
            return b.count >= offset + bytes.count && Array(b[offset..<offset + bytes.count]) == bytes
        }

        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .format(.png) }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return .format(.jpeg) }
        if at(0, "GIF8") { return .format(.gif) }
        if at(0, "BM") && b.count > 14 { return .format(.bmp) }
        if b.starts(with: [0x49, 0x49, 0x2A, 0x00]) || b.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return .format(.tiff) }
        if b.starts(with: [0x00, 0x00, 0x01, 0x00]) { return .format(.ico) }
        if at(0, "%PDF") { return .format(.pdf) }
        if at(0, "{\\rtf") { return .format(.rtf) }
        if b.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { return .format(.doc) }
        if at(0, "fLaC") { return .format(.flac) }
        if at(0, "FORM") && (at(8, "AIFF") || at(8, "AIFC")) { return .format(.aiff) }
        if at(0, "RIFF") {
            if at(8, "WEBP") { return .format(.webp) }
            if at(8, "WAVE") { return .format(.wav) }
            if at(8, "AVI ") { return .format(.avi) }
        }
        if at(0, "OggS") { return .format(data.range(of: Data("OpusHead".utf8)) != nil ? .opus : .ogg) }
        if b.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            return .format(data.range(of: Data("webm".utf8)) != nil ? .webm : .mkv)
        }
        if at(4, "ftyp") && b.count >= 12 {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            switch brand {
            case "qt  ": return .format(.mov)
            case "M4A ", "M4B ": return .format(.m4a)
            case "M4V ", "M4VH", "M4VP": return .format(.m4v)
            case "heic", "heix", "heim", "heis", "mif1", "msf1": return .format(.heic)
            case "avif", "avis": return .format(.avif)
            default: return .format(.mp4)
            }
        }
        if at(0, "ID3") { return .format(.mp3) }
        if b.count > 1 && b[0] == 0xFF {
            if b[1] & 0xF6 == 0xF0 { return .format(.aac) }   // ADTS
            if b[1] & 0xE0 == 0xE0 { return .format(.mp3) }   // MPEG audio frame sync
        }
        if at(0, "PK\u{03}\u{04}") { return detectZip(b) }

        // Text: no NUL bytes and valid UTF-8 (allowing a character cut off at the 4 KB boundary).
        if !b.contains(0), String(data: data, encoding: .utf8) != nil || String(data: data.dropLast(3), encoding: .utf8) != nil {
            let head = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if head.hasPrefix("<!doctype html") || head.hasPrefix("<html") { return .format(.html) }
            return .text
        }
        return .unknown
    }

    /// docx, odt and epub are all zip archives; tell them apart by their first entries.
    private static func detectZip(_ b: [UInt8]) -> Result {
        let text = String(decoding: b, as: UTF8.self)
        if text.contains("application/epub+zip") { return .format(.epub) }
        if text.contains("application/vnd.oasis.opendocument.text") { return .format(.odt) }
        if text.contains("word/") || text.contains("[Content_Types].xml") { return .format(.docx) }
        return .unknown
    }
}
