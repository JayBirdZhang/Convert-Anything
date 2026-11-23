import Foundation

/// Reads a .docx straight from its XML into clean HTML: headings from Word's own styles (what macOS's text
/// system loses), lists, tables, links, bold/italic and the pictures, which stay as files next to the document.
/// Used for e-books, where chapters come from the headings. A Word file with no heading styles falls back to
/// treating big text as headings, which is how files written by other programs usually mark them.
nonisolated struct WordToHTML {
    /// The unzipped .docx; image paths in the result are relative to it.
    let folder: URL

    private struct Style {
        var name = ""
        var basedOn: String?
        var outline: Int?
        var list: (id: String, level: Int)?
    }

    private struct Paragraph {
        var html = ""
        var heading: Int?
        var list: (level: Int, ordered: Bool)?
        var characters = 0
        var size = 0            // Largest font size in the paragraph, in half points
    }

    private enum Block { case paragraph(Paragraph), table(String) }

    private var styles: [String: Style] = [:]
    private var bulletFormats: [String: [Int: Bool]] = [:]     // abstract list id → level → is it numbered?
    private var listAbstract: [String: String] = [:]           // list id → abstract list id
    private var relationships: [String: String] = [:]          // relationship id → target
    private var defaultSize = 22

    private static let spaceMarker = "\u{E000}"

    init(folder: URL) { self.folder = folder }

    /// The document body as HTML.
    mutating func html() throws -> String {
        let word = folder.appending(path: "word")
        let documentURL = word.appending(path: "document.xml")
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            throw ConversionError.failed("Couldn't read this Word file.")
        }
        readStyles(word.appending(path: "styles.xml"))
        readNumbering(word.appending(path: "numbering.xml"))
        readRelationships(word.appending(path: "_rels/document.xml.rels"))

        // The XML reader throws away text that is only spaces, but Word puts the space between two words in a
        // run of its own. A marker character keeps those runs alive until they're read.
        guard let xml = try? String(contentsOf: documentURL, encoding: .utf8),
              let document = try? XMLDocument(xmlString: xml.replacing(/(<w:t\b[^>]*>)(\s+)(<\/w:t>)/) { "\($0.1)\(Self.spaceMarker)\($0.2)\($0.3)" },
                                              options: [.nodeLoadExternalEntitiesNever]),
              let body = document.rootElement()?.elements(forName: "w:body").first else {
            throw ConversionError.failed("Couldn't read this Word file.")
        }
        let blocks = blocks(in: body)
        // Without real heading styles, large text stands in for them.
        let hasStyledHeadings = blocks.contains { if case .paragraph(let p) = $0 { p.heading != nil } else { false } }
        return render(blocks, guessHeadings: !hasStyledHeadings)
    }

    // MARK: Reading the supporting parts

    private mutating func readStyles(_ url: URL) {
        guard let root = (try? XMLDocument(contentsOf: url, options: []))?.rootElement() else { return }
        if let size = root.elements(forName: "w:docDefaults").first?.elements(forName: "w:rPrDefault").first?
            .elements(forName: "w:rPr").first?.elements(forName: "w:sz").first.flatMap({ Int(Self.value($0)) }) {
            defaultSize = size
        }
        for element in root.elements(forName: "w:style") {
            guard let id = element.attribute(forName: "w:styleId")?.stringValue else { continue }
            var style = Style()
            style.name = element.elements(forName: "w:name").first.map(Self.value)?.lowercased() ?? ""
            style.basedOn = element.elements(forName: "w:basedOn").first.map(Self.value)
            if let properties = element.elements(forName: "w:pPr").first {
                style.outline = properties.elements(forName: "w:outlineLvl").first.flatMap { Int(Self.value($0)) }
                if let numbering = properties.elements(forName: "w:numPr").first,
                   let listID = numbering.elements(forName: "w:numId").first.map(Self.value) {
                    style.list = (listID, numbering.elements(forName: "w:ilvl").first.flatMap { Int(Self.value($0)) } ?? 0)
                }
            }
            if style.name == "normal", let size = element.elements(forName: "w:rPr").first?
                .elements(forName: "w:sz").first.flatMap({ Int(Self.value($0)) }) {
                defaultSize = size
            }
            styles[id] = style
        }
    }

    private mutating func readNumbering(_ url: URL) {
        guard let root = (try? XMLDocument(contentsOf: url, options: []))?.rootElement() else { return }
        for abstract in root.elements(forName: "w:abstractNum") {
            guard let id = abstract.attribute(forName: "w:abstractNumId")?.stringValue else { continue }
            for level in abstract.elements(forName: "w:lvl") {
                let index = Int(level.attribute(forName: "w:ilvl")?.stringValue ?? "") ?? 0
                let format = level.elements(forName: "w:numFmt").first.map(Self.value) ?? "decimal"
                bulletFormats[id, default: [:]][index] = format != "bullet" && format != "none"
            }
        }
        for number in root.elements(forName: "w:num") {
            if let id = number.attribute(forName: "w:numId")?.stringValue,
               let abstract = number.elements(forName: "w:abstractNumId").first.map(Self.value) {
                listAbstract[id] = abstract
            }
        }
    }

    private mutating func readRelationships(_ url: URL) {
        guard let root = (try? XMLDocument(contentsOf: url, options: []))?.rootElement() else { return }
        for element in root.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            if let id = element.attribute(forName: "Id")?.stringValue, let target = element.attribute(forName: "Target")?.stringValue {
                relationships[id] = target
            }
        }
    }

    private static func value(_ element: XMLElement) -> String {
        element.attribute(forName: "w:val")?.stringValue ?? ""
    }

    // MARK: Blocks

    private func blocks(in container: XMLElement) -> [Block] {
        var result: [Block] = []
        for child in container.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            switch child.name {
            case "w:p":
                if let paragraph = paragraph(child) { result.append(.paragraph(paragraph)) }
            case "w:tbl":
                result.append(.table(table(child)))
            case "w:sdt":   // A content control wraps ordinary paragraphs
                if let content = child.elements(forName: "w:sdtContent").first { result += blocks(in: content) }
            case "w:ins", "w:customXml", "w:smartTag":
                result += blocks(in: child)
            default:
                break
            }
        }
        return result
    }

    private func paragraph(_ element: XMLElement) -> Paragraph? {
        var paragraph = Paragraph()
        var styleID: String?
        var numbering: (id: String, level: Int)?
        if let properties = element.elements(forName: "w:pPr").first {
            styleID = properties.elements(forName: "w:pStyle").first.map(Self.value)
            if let numPr = properties.elements(forName: "w:numPr").first,
               let id = numPr.elements(forName: "w:numId").first.map(Self.value) {
                numbering = (id, numPr.elements(forName: "w:ilvl").first.flatMap { Int(Self.value($0)) } ?? 0)
            }
        }
        // Word generates its own table of contents; the e-book makes a new one from the headings.
        if let styleID, inherited(styleID, { $0.name.isEmpty ? nil : $0.name })?.hasPrefix("toc") == true { return nil }

        if numbering == nil, let styleID, let fromStyle = inherited(styleID, { $0.list }) { numbering = fromStyle }
        if let styleID { paragraph.heading = headingLevel(styleID) }
        if let numbering, numbering.id != "0" {
            let abstract = listAbstract[numbering.id]
            let ordered = abstract.flatMap { bulletFormats[$0]?[numbering.level] } ?? false
            paragraph.list = (min(numbering.level, 8), ordered)
        }

        var plain = 0, size = 0
        paragraph.html = inline(element, characters: &plain, size: &size)
        paragraph.characters = plain
        paragraph.size = size == 0 ? defaultSize : size
        // Files from programs that type the bullet as text instead of using a list.
        if paragraph.list == nil, let bullet = paragraph.html.prefixMatch(of: /[•◦▪▫‣⁃]\s+/) {
            paragraph.html = String(paragraph.html[bullet.range.upperBound...])
            paragraph.list = (0, false)
        }
        let hasPicture = paragraph.html.contains("<img")
        guard plain > 0 || hasPicture else { return nil }     // Blank paragraphs are just spacing
        return paragraph
    }

    /// Looks a property up the style's "based on" chain.
    private func inherited<T>(_ id: String, _ get: (Style) -> T?) -> T? {
        var current: String? = id
        for _ in 0..<8 {
            guard let key = current, let style = styles[key] else { return nil }
            if let value = get(style) { return value }
            current = style.basedOn
        }
        return nil
    }

    private func headingLevel(_ id: String) -> Int? {
        var current: String? = id
        for _ in 0..<8 {
            guard let key = current, let style = styles[key] else { return nil }
            if style.name == "title" { return 1 }
            if let number = style.name.wholeMatch(of: /heading ?([1-9])/)?.1 { return Int(number) }
            if let outline = style.outline, outline < 9 { return outline + 1 }
            current = style.basedOn
        }
        return nil
    }

    // MARK: Inline content

    /// The runs of a paragraph (or a link inside one) as HTML. `characters` counts the visible letters and
    /// `size` keeps the largest font size seen.
    private func inline(_ container: XMLElement, characters: inout Int, size: inout Int) -> String {
        var out = ""
        var pending = ""                 // Text with the same formatting as `pendingFormat`, not yet wrapped
        var pendingFormat = ""

        func flush() {
            guard !pending.isEmpty else { return }
            out += wrap(pending, pendingFormat)
            pending = ""
        }
        func add(_ text: String, format: String) {
            if format != pendingFormat { flush(); pendingFormat = format }
            pending += text
        }

        for child in container.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            switch child.name {
            case "w:r":
                var format = ""
                if let properties = child.elements(forName: "w:rPr").first {
                    func on(_ name: String) -> Bool {
                        guard let flag = properties.elements(forName: name).first else { return false }
                        return !["0", "false", "none"].contains(Self.value(flag))
                    }
                    if on("w:b") { format += "b" }
                    if on("w:i") { format += "i" }
                    if on("w:u") { format += "u" }
                    if on("w:strike") || on("w:dstrike") { format += "s" }
                    switch properties.elements(forName: "w:vertAlign").first.map(Self.value) {
                    case "superscript": format += "^"
                    case "subscript": format += "_"
                    default: break
                    }
                    if let styleName = properties.elements(forName: "w:rStyle").first.map(Self.value) {
                        if styleName == "Strong" && !format.contains("b") { format += "b" }
                        if styleName == "Emphasis" && !format.contains("i") { format += "i" }
                    }
                    if let runSize = properties.elements(forName: "w:sz").first.flatMap({ Int(Self.value($0)) }) { size = max(size, runSize) }
                }
                for part in child.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                    switch part.name {
                    case "w:t":
                        let text = (part.stringValue ?? "").replacingOccurrences(of: Self.spaceMarker, with: "")
                        characters += text.filter { !$0.isWhitespace }.count
                        add(escapeHTML(text), format: format)
                    case "w:tab": add(" ", format: format)
                    case "w:noBreakHyphen": add("\u{2011}", format: format)
                    case "w:br", "w:cr":
                        let type = part.attribute(forName: "w:type")?.stringValue
                        if type != "page" && type != "column" { add("<br/>", format: "") }
                    case "w:drawing", "w:pict", "mc:AlternateContent":
                        flush()
                        out += pictures(in: part)
                    default: break
                    }
                }
            case "w:hyperlink":
                flush()
                let link = inline(child, characters: &characters, size: &size)
                if let id = child.attribute(forName: "r:id")?.stringValue, let target = relationships[id],
                   !target.lowercased().hasPrefix("javascript:") {
                    out += "<a href=\"\(escapeHTML(target))\">\(link)</a>"
                } else {
                    out += link     // A jump inside the document, which an e-book can't follow
                }
            case "w:ins", "w:smartTag", "w:fldSimple", "w:customXml", "w:sdt":
                flush()
                let inner = child.name == "w:sdt" ? child.elements(forName: "w:sdtContent").first ?? child : child
                out += inline(inner, characters: &characters, size: &size)
            default:
                break
            }
        }
        flush()
        return out
    }

    private func wrap(_ text: String, _ format: String) -> String {
        guard !format.isEmpty else { return text }
        var result = text
        for (flag, tag) in [("b", "strong"), ("i", "em"), ("u", "u"), ("s", "s"), ("^", "sup"), ("_", "sub")] where format.contains(flag) {
            result = "<\(tag)>\(result)</\(tag)>"
        }
        return result
    }

    /// Image tags for the pictures inside a drawing. Word often stores a drawing twice (modern and fallback).
    private func pictures(in element: XMLElement) -> String {
        var found: [(id: String, alt: String)] = []
        var alt = ""
        func search(_ node: XMLElement) {
            if node.name == "wp:docPr", let description = node.attribute(forName: "descr")?.stringValue { alt = description }
            if node.name == "mc:AlternateContent" {
                // The first choice that has a picture is enough.
                for option in node.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                    let before = found.count
                    search(option)
                    if found.count > before { return }
                }
                return
            }
            if node.name == "a:blip", let id = node.attribute(forName: "r:embed")?.stringValue { found.append((id, alt)) }
            else if node.name == "v:imagedata", let id = node.attribute(forName: "r:id")?.stringValue { found.append((id, alt)) }
            if node.name == "w:txbxContent" { return }
            for child in node.children?.compactMap({ $0 as? XMLElement }) ?? [] { search(child) }
        }
        search(element)
        return found.compactMap { id, alt in
            guard var target = relationships[id] else { return nil }
            target = target.hasPrefix("/") ? String(target.dropFirst()) : "word/" + target
            return "<img src=\"\(escapeHTML(target))\" alt=\"\(escapeHTML(alt))\"/>"
        }.joined()
    }

    // MARK: Tables

    private func table(_ element: XMLElement) -> String {
        var html = "<table>"
        for row in element.elements(forName: "w:tr") {
            let isHeader = row.elements(forName: "w:trPr").first?.elements(forName: "w:tblHeader").first != nil
            let tag = isHeader ? "th" : "td"
            html += "<tr>"
            for cell in row.elements(forName: "w:tc") {
                var attributes = ""
                if let span = cell.elements(forName: "w:tcPr").first?.elements(forName: "w:gridSpan").first.flatMap({ Int(Self.value($0)) }), span > 1 {
                    attributes = " colspan=\"\(span)\""
                }
                // Headings inside a cell would only be bold text, so they're left as paragraphs.
                html += "<\(tag)\(attributes)>\(render(blocks(in: cell), guessHeadings: false, allowHeadings: false))</\(tag)>"
            }
            html += "</tr>"
        }
        return html + "</table>"
    }

    // MARK: Output

    private func render(_ blocks: [Block], guessHeadings: Bool, allowHeadings: Bool = true) -> String {
        // Body text is the most common size; paragraphs well above it are headings.
        var bodySize = defaultSize
        if guessHeadings {
            var counts: [Int: Int] = [:]
            for case .paragraph(let p) in blocks { counts[p.size, default: 0] += p.characters }
            bodySize = counts.max { $0.value < $1.value }?.key ?? defaultSize
        }

        var out = ""
        var open: [(tag: String, itemOpen: Bool)] = []
        func closeLists(to depth: Int) {
            while open.count > depth {
                let list = open.removeLast()
                out += (list.itemOpen ? "</li>" : "") + "</\(list.tag)>"
            }
        }

        for block in blocks {
            switch block {
            case .table(let html):
                closeLists(to: 0)
                out += html + "\n"
            case .paragraph(let p):
                if let list = p.list {
                    let tag = list.ordered ? "ol" : "ul"
                    closeLists(to: list.level + 1)
                    if open.count == list.level + 1, open[list.level].tag != tag { closeLists(to: list.level) }
                    while open.count < list.level + 1 {
                        if let last = open.indices.last, !open[last].itemOpen { out += "<li>"; open[last].itemOpen = true }
                        out += "<\(tag)>"
                        open.append((tag, false))
                    }
                    if open[list.level].itemOpen { out += "</li>" }
                    out += "<li>\(p.html)"
                    open[list.level].itemOpen = true
                    continue
                }
                closeLists(to: 0)
                var level = allowHeadings ? p.heading : nil
                if level == nil, guessHeadings, allowHeadings, p.characters <= 120 {
                    let ratio = Double(p.size) / Double(max(bodySize, 1))
                    level = ratio >= 1.7 ? 1 : ratio >= 1.4 ? 2 : ratio >= 1.2 ? 3 : nil
                }
                if let level {
                    out += "<h\(min(level, 6))>\(p.html)</h\(min(level, 6))>\n"
                } else {
                    out += "<p>\(p.html)</p>\n"
                }
            }
        }
        closeLists(to: 0)
        return out
    }
}
