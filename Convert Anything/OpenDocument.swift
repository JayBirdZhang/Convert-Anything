import AppKit

/// OpenDocument spreadsheets (.ods) are a zip whose content.xml holds every sheet. Only the cells are read;
/// the rest of the app's spreadsheet code (CSV, JSON and Excel writers) takes it from there.
nonisolated enum OpenDocumentSheets {
    static func read(_ contentXML: URL) throws -> [Spreadsheets.Sheet] {
        guard let data = try? Data(contentsOf: contentXML) else { throw ConversionError.failed("Couldn't read this spreadsheet.") }
        return ODSParser(data).sheets
    }
}

/// Reads the cells of every sheet. LibreOffice pads sheets to their full size with "repeated" empty cells and
/// rows (16,384 columns by a million rows), so empty runs are only counted and become real cells or rows when
/// something comes after them.
nonisolated private final class ODSParser: NSObject, XMLParserDelegate {
    var sheets: [Spreadsheets.Sheet] = []
    private var rows: [[String]] = []
    private var row: [String] = []
    private var emptyRows = 0, emptyCells = 0
    private var rowRepeat = 1, cellRepeat = 1
    private var cell = "", cellValue: String?, paragraphs = 0
    private var inCell = false, inParagraph = false, skipDepth = 0
    private var currentName = ""

    init(_ data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if skipDepth > 0 { skipDepth += 1; return }
        switch name {
        case "table:table":
            rows = []; emptyRows = 0
            currentName = attributes["table:name"] ?? "Sheet\(sheets.count + 1)"
        case "table:table-row":
            row = []; emptyCells = 0
            rowRepeat = attributes["table:number-rows-repeated"].flatMap(Int.init) ?? 1
        case "table:table-cell", "table:covered-table-cell":
            inCell = true
            cell = ""; paragraphs = 0
            cellRepeat = attributes["table:number-columns-repeated"].flatMap(Int.init) ?? 1
            cellValue = Self.value(attributes)
        case "office:annotation":   // A comment on the cell, not its content
            skipDepth = 1
        case "text:p" where inCell, "text:h" where inCell:
            if paragraphs > 0 { cell += "\n" }
            paragraphs += 1
            inParagraph = true
        case "text:s" where inParagraph:
            cell += String(repeating: " ", count: attributes["text:c"].flatMap(Int.init) ?? 1)
        case "text:tab" where inParagraph: cell += "\t"
        case "text:line-break" where inParagraph: cell += "\n"
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if skipDepth == 0 && inParagraph { cell += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if skipDepth > 0 { skipDepth -= 1; return }
        switch name {
        case "text:p", "text:h": inParagraph = false
        case "table:table-cell", "table:covered-table-cell":
            inCell = false
            let text = cellValue ?? cell
            if text.isEmpty {
                emptyCells += cellRepeat
            } else {
                if emptyCells > 0 { row += repeatElement("", count: emptyCells); emptyCells = 0 }
                row += repeatElement(text, count: min(cellRepeat, 16_384))
            }
        case "table:table-row":
            if row.isEmpty {
                emptyRows += rowRepeat
            } else {
                if emptyRows > 0 { rows += repeatElement([], count: emptyRows); emptyRows = 0 }
                rows += repeatElement(row, count: min(rowRepeat, 1_048_576))
            }
        case "table:table":
            sheets.append(Spreadsheets.Sheet(name: currentName, rows: rows))
        default: break
        }
    }

    /// The cell's value as the Excel reader would show it: plain numbers, ISO dates, TRUE/FALSE. Text cells
    /// (and anything unexpected) use their displayed text instead.
    private static func value(_ attributes: [String: String]) -> String? {
        switch attributes["office:value-type"] {
        case "float", "percentage", "currency":
            guard let text = attributes["office:value"], let number = Double(text) else { return nil }
            if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
            return String(format: "%.15g", number)
        case "boolean":
            return attributes["office:boolean-value"] == "true" ? "TRUE" : "FALSE"
        case "date":
            // "2024-03-01" or "2024-03-01T14:30:00.123"; midnight reads as just the date, like Excel's reader.
            guard let text = attributes["office:date-value"] else { return nil }
            let parts = text.split(separator: "T", maxSplits: 1)
            guard parts.count == 2 else { return text }
            let time = parts[1].prefix(8)
            return time == "00:00:00" ? String(parts[0]) : "\(parts[0]) \(time)"
        case "time":
            // "PT14H30M00S" (hours can run past 24 for durations).
            guard let text = attributes["office:time-value"],
                  let match = text.wholeMatch(of: /-?PT(\d+)H(\d+)M(\d+)(?:[.,]\d+)?S/) else { return nil }
            func two(_ part: Substring) -> String { part.count < 2 ? "0" + part : String(part) }
            return "\(two(match.1)):\(two(match.2)):\(two(match.3))"
        default:
            return nil
        }
    }
}

extension OpenDocumentSheets {
    /// Every sheet of the .ods as an Excel workbook, written without Numbers. Returns `output`.
    @discardableResult
    static func writeXLSX(_ request: Converter.Request, output: URL) async throws -> URL {
        let sheets = try await Spreadsheets.sheets(of: request)
        let parts = try await background { sheets.map { (name: $0.name, xml: Spreadsheets.sheetXML($0.rows)) } }
        try await Spreadsheets.writeXLSX(sheets: parts, request: request, output: output)
        return output
    }
}

// MARK: - Writing .odt with pictures

/// macOS's text system writes .odt with tables and styles but silently leaves out every picture. Pictures are
/// swapped for marker text before writing, then put into the package as draw:frame elements with their files.
nonisolated enum ODTWriter {
    struct Picture {
        var data: Data
        var fileExtension: String
        var size: CGSize      // Points
    }

    static func marker(_ index: Int) -> String { "ZZODTPIC\(index)ZZ" }

    /// `pictures` are already in `text` as markers (Word pictures); attachments in `text` are added to them.
    static func write(_ text: NSAttributedString, pictures given: [Picture] = [], output: URL, workDir: URL) async throws {
        var pictures = given
        let copy = NSMutableAttributedString(attributedString: text)
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length), options: .reverse) { value, range, _ in
            guard let attachment = value as? NSTextAttachment, let picture = picture(attachment) else { return }
            var attributes = text.attributes(at: range.location, effectiveRange: nil)
            attributes[.attachment] = nil
            copy.replaceCharacters(in: range, with: NSAttributedString(string: marker(pictures.count), attributes: attributes))
            pictures.append(picture)
        }
        let data = try copy.data(from: NSRange(location: 0, length: copy.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.openDocument])
        guard !pictures.isEmpty else { return try data.write(to: output) }

        let package = workDir.appending(path: "odt-out")
        let plain = workDir.appending(path: "plain.odt")
        try data.write(to: plain)
        try await Tools.run("/usr/bin/unzip", ["-q", "-o", plain.path, "-d", package.path])
        let contentURL = package.appending(path: "content.xml"), manifestURL = package.appending(path: "META-INF/manifest.xml")
        var content = try String(contentsOf: contentURL, encoding: .utf8)
        var manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        // The frame needs the drawing, link and SVG namespaces on the root element.
        let namespaces = [("draw", "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"), ("xlink", "http://www.w3.org/1999/xlink"),
                          ("svg", "urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0")]
        if let root = content.range(of: "<office:document-content") {
            let missing = namespaces.filter { !content.contains("xmlns:\($0.0)=") }.map { " xmlns:\($0.0)=\"\($0.1)\"" }.joined()
            content.insert(contentsOf: missing, at: root.upperBound)
        }
        let pictureFolder = package.appending(path: "Pictures")
        try FileManager.default.createDirectory(at: pictureFolder, withIntermediateDirectories: true)
        var entries = ""
        for (index, picture) in pictures.enumerated() {
            let path = "Pictures/picture\(index + 1).\(picture.fileExtension)"
            try picture.data.write(to: package.appending(path: path))
            let type = picture.fileExtension == "jpg" ? "image/jpeg" : "image/\(picture.fileExtension)"
            entries += #"<manifest:file-entry manifest:full-path="\#(path)" manifest:media-type="\#(type)"/>"#
            let frame = #"<draw:frame draw:name="Picture \#(index + 1)" text:anchor-type="as-char" svg:width="\#(points(picture.size.width))" svg:height="\#(points(picture.size.height))" draw:z-index="\#(index)"><draw:image xlink:href="\#(path)" xlink:type="simple" xlink:show="embed" xlink:actuate="onLoad"/></draw:frame>"#
            content = content.replacingOccurrences(of: marker(index), with: frame)
        }
        if let end = manifest.range(of: "</manifest:manifest>") { manifest.insert(contentsOf: entries, at: end.lowerBound) }
        try content.write(to: contentURL, atomically: true, encoding: .utf8)
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)

        // The "mimetype" entry has to come first, uncompressed, for other apps to recognise the file.
        try? FileManager.default.removeItem(at: output)
        try await Tools.run("/usr/bin/zip", ["-q", "-X", "-0", output.path, "mimetype"], currentDirectory: package)
        try await Tools.run("/usr/bin/zip", ["-q", "-X", "-D", "-r", output.path, ".", "-x", "mimetype"], currentDirectory: package)
    }

    private static func points(_ value: CGFloat) -> String { String(format: "%.2fpt", Double(value)) }

    /// The picture's file and its shown size. Formats other apps may not read become PNG.
    private static func picture(_ attachment: NSTextAttachment) -> Picture? {
        var data = attachment.fileWrapper?.regularFileContents ?? attachment.contents
        var image: NSImage? = attachment.image
        if data == nil, let fileImage = image { data = fileImage.tiffRepresentation }
        guard var bytes = data else { return nil }
        var type = imageType(bytes)
        if type == nil {
            guard let bitmap = NSBitmapImageRep(data: bytes), let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
            bytes = png; type = "png"
        }
        if image == nil { image = NSImage(data: bytes) }
        var size = attachment.bounds.size
        if size.width <= 0 || size.height <= 0 { size = image?.size ?? CGSize(width: 200, height: 150) }
        return Picture(data: bytes, fileExtension: type!, size: fitted(size))
    }

    /// PNG, JPEG and GIF go in as they are.
    static func imageType(_ data: Data) -> String? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: Array("GIF8".utf8)) { return "gif" }
        return nil
    }

    /// No wider than a page's text (6.5 inches), keeping the proportions.
    static func fitted(_ size: CGSize) -> CGSize {
        let maxWidth: CGFloat = 468
        return size.width > maxWidth ? CGSize(width: maxWidth, height: size.height * maxWidth / size.width) : size
    }
}

// MARK: - Word → .odt

/// The text system reads a Word file's fonts and paragraph styles well but drops its tables and pictures.
/// Before it reads the file, tables become marker paragraphs (and HTML, which the text system does read as tables)
/// and pictures become marker text; afterwards both are put back in place.
enum WordToODT {   // On the main actor: the text system reads HTML there
    static func convert(_ docx: URL, output: URL, workDir: URL) async throws {
        let folder = workDir.appending(path: "docx")
        try await Tools.run("/usr/bin/unzip", ["-q", "-o", docx.path, "-d", folder.path])
        let documentURL = folder.appending(path: "word/document.xml")
        var xml = try String(contentsOf: documentURL, encoding: .utf8)
        let hasPictures = xml.contains("<w:drawing") || xml.contains("<w:pict"), hasTables = xml.contains("<w:tbl")
        guard hasPictures || hasTables else {
            return try await ODTWriter.write(NSAttributedString(url: docx, options: [:], documentAttributes: nil), output: output, workDir: workDir)
        }

        // Pictures: a drawing (or the alternate-content wrapper holding a drawing and its fallback) becomes marker text.
        var pictures: [ODTWriter.Picture] = []
        if hasPictures, let open = try? Regex(#"<(mc:AlternateContent|w:drawing|w:pict)\b[^>]*>"#) {
            let relationships = Self.relationships(folder.appending(path: "word/_rels/document.xml.rels"))
            xml = MathMarkdown.replaceBalanced(open, in: xml) { element in
                guard let id = element.firstMatch(of: /<a:blip\b[^>]*\br:embed="([^"]+)"/)?.output.1
                        ?? element.firstMatch(of: /<v:imagedata\b[^>]*\br:id="([^"]+)"/)?.output.1,
                      let target = relationships[String(id)],
                      let data = try? Data(contentsOf: folder.appending(path: target.hasPrefix("/") ? String(target.dropFirst()) : "word/" + target))
                else { return nil }
                var bytes = data
                var type = ODTWriter.imageType(data)
                if type == nil {   // EMF, TIFF, BMP…: PNG reads everywhere
                    guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return nil }
                    bytes = png; type = "png"
                }
                var size = CGSize.zero
                if let extent = element.firstMatch(of: /<wp:extent\b[^>]*\bcx="(\d+)"[^>]*\bcy="(\d+)"/),
                   let cx = Double(extent.output.1), let cy = Double(extent.output.2) {
                    size = CGSize(width: cx / 12_700, height: cy / 12_700)   // EMU → points
                } else if let image = NSImage(data: bytes) {
                    size = image.size
                }
                pictures.append(ODTWriter.Picture(data: bytes, fileExtension: type!, size: ODTWriter.fitted(size)))
                return #"<w:t xml:space="preserve">\#(ODTWriter.marker(pictures.count - 1))</w:t>"#
            }
        }

        // Tables: their HTML first (pictures in cells are markers by now), then a marker paragraph in their place.
        var tables: [String] = []
        if hasTables, let open = try? Regex(#"<(w:tbl)\b[^>]*>"#) {
            var reader = WordToHTML(folder: folder)
            tables = try reader.tables(in: xml)
            var index = 0
            xml = MathMarkdown.replaceBalanced(open, in: xml) { _ in
                defer { index += 1 }
                return #"<w:p><w:r><w:t>ZZODTTABLE\#(index)ZZ</w:t></w:r></w:p>"#
            }
        }
        try xml.write(to: documentURL, atomically: true, encoding: .utf8)
        let prepared = workDir.appending(path: "prepared.docx")
        try await Tools.run("/usr/bin/zip", ["-q", "-X", "-r", prepared.path, "."], currentDirectory: folder)
        let text = NSMutableAttributedString(attributedString: try NSAttributedString(url: prepared, options: [:], documentAttributes: nil))

        // Back to front, so earlier ranges stay put.
        let string = text.string as NSString
        let markers = try NSRegularExpression(pattern: #"ZZODTTABLE(\d+)ZZ\n?"#)
        for match in markers.matches(in: text.string, range: NSRange(location: 0, length: string.length)).reversed() {
            guard let index = Int(string.substring(with: match.range(at: 1))), index < tables.count else { continue }
            let font = text.attribute(.font, at: match.range.location, effectiveRange: nil) as? NSFont
            let css = "body { font-family: '\(font?.familyName ?? "Helvetica")'; font-size: \(Int(font?.pointSize ?? 12))pt; }"
                + " table { border-collapse: collapse; } td, th { border: 1px solid #999; padding: 2px 5px; vertical-align: top; }"
            let html = "<!doctype html><html><head><meta charset=\"utf-8\"><style>\(css)</style></head><body>\(tables[index])</body></html>"
            guard let table = try? DocumentConversion.attributed(html: html, baseURL: folder) else { continue }
            text.replaceCharacters(in: match.range, with: table)
        }
        try await ODTWriter.write(text, pictures: pictures, output: output, workDir: workDir)
    }

    private static func relationships(_ url: URL) -> [String: String] {
        guard let xml = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for match in xml.matches(of: /<Relationship\b[^>]*>/) {
            let tag = match.output
            if let id = tag.firstMatch(of: /\bId="([^"]+)"/)?.output.1, let target = tag.firstMatch(of: /\bTarget="([^"]+)"/)?.output.1 {
                result[String(id)] = String(target)
            }
        }
        return result
    }
}
