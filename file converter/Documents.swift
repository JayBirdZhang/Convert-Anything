import AppKit
import PDFKit

/// Text documents with macOS's own text system, which reads and writes Word (.docx and .doc), RTF,
/// OpenDocument and HTML. Markdown is translated to HTML on the way in and written back from the
/// formatted text on the way out. Pages makes Word → PDF look exactly like the original when it's installed.
enum DocumentConversion {
    static func convert(_ request: Converter.Request, output: URL) async throws {
        var input = request.input
        var from = request.from

        // Word → PDF keeps its exact layout (headers, columns, page breaks) when Pages lays it out.
        if request.to == .pdf, [.docx, .doc, .rtf, .pages].contains(from), IWork.isInstalled(.pages) {
            try await IWork.export(input, with: .pages, as: .pdf, to: output)
            return
        }
        if from == .pages {
            let docx = request.workDir.appending(path: "from-pages.docx")
            input = try await IWork.export(input, with: .pages, as: .word, to: docx)
            from = .docx
        }
        if from == .pdf {
            if request.to == .docx {
                try await PDFToWord.convert(request, output: output)
                return
            }
            let text = try await DocumentConversion.extractPDFText(input)
            if request.to == .txt || request.to == .md {
                try text.write(to: output, atomically: true, encoding: .utf8)
                return
            }
            let paragraphs = text.components(separatedBy: "\n\n").map { "<p>\(escapeHTML($0).replacingOccurrences(of: "\n", with: "<br>"))</p>" }
            try await write(html: paragraphs.joined(separator: "\n"), title: request.title, request: request, output: output)
            return
        }

        // Markdown and HTML sources keep their HTML structure, which reads better than a round trip.
        switch from {
        case .md:
            let markdown = try readText(input)
            let showsMath = request.to == .html || request.to == .pdf
            let html = Markdown.$mathAsMathML.withValue(showsMath) { Markdown.html(from: markdown) }
            if request.to == .txt {
                try plainText(fromHTML: html, baseURL: request.originalDir).write(to: output, atomically: true, encoding: .utf8)
            } else {
                try await write(html: html, title: request.title, request: request, output: output)
            }
        case .html:
            let html = try readText(input)
            if request.to == .pdf {
                try await WebPDF.render(html: html, baseURL: request.originalDir, output: output)
            } else if request.to == .md {
                try Markdown.markdown(from: attributed(html: html, baseURL: request.originalDir)).write(to: output, atomically: true, encoding: .utf8)
            } else {
                try write(text: attributed(html: html, baseURL: request.originalDir), request: request, output: output)
            }
        case .txt:
            let text = try readText(input)
            if request.to == .md {
                try text.write(to: output, atomically: true, encoding: .utf8)
            } else {
                let paragraphs = text.components(separatedBy: "\n\n").map { "<p>\(escapeHTML($0).replacingOccurrences(of: "\n", with: "<br>"))</p>" }
                try await write(html: paragraphs.joined(separator: "\n"), title: request.title, request: request, output: output)
            }
        default:
            let text = try NSAttributedString(url: input, options: [:], documentAttributes: nil)
            try write(text: text, request: request, output: output)
        }
    }

    // MARK: Writing

    /// Writes HTML content in the target format. HTML targets get a complete, styled page.
    private static func write(html body: String, title: String, request: Converter.Request, output: URL) async throws {
        switch request.to {
        case .html:
            try htmlPage(body: body, title: title).write(to: output, atomically: true, encoding: .utf8)
        case .pdf:
            try await WebPDF.render(html: htmlPage(body: body, title: title), baseURL: request.originalDir, output: output)
        default:
            try write(text: attributed(html: htmlPage(body: body, title: title), baseURL: request.originalDir), request: request, output: output)
        }
    }

    private static func write(text: NSAttributedString, request: Converter.Request, output: URL) throws {
        let type: NSAttributedString.DocumentType
        switch request.to {
        case .txt: return try text.string.write(to: output, atomically: true, encoding: .utf8)
        case .md: return try Markdown.markdown(from: text).write(to: output, atomically: true, encoding: .utf8)
        case .pdf: return try renderPDF(text, output: output)
        case .docx: type = .officeOpenXML
        case .doc: type = .docFormat
        case .rtf: type = .rtf
        case .odt: type = .openDocument
        case .html: type = .html
        default: throw ConversionError.unsupported(request.from, request.to)
        }
        var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        if type == .html { attributes[.title] = request.title }
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes)
        try data.write(to: output)
    }

    private static func htmlPage(body: String, title: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(escapeHTML(title))</title>
        <style>
        body { font-family: -apple-system, Helvetica, sans-serif; font-size: 11pt; line-height: 1.4; max-width: 46em; margin: 2em auto; padding: 0 1em; }
        pre, code { font-family: Menlo, monospace; font-size: 9.5pt; }
        pre { background: #f5f5f5; padding: 0.6em; }
        blockquote { color: #555; border-left: 3px solid #ddd; margin-left: 0; padding-left: 1em; }
        table { border-collapse: collapse; } td, th { border: 1px solid #ccc; padding: 3px 6px; }
        img { max-width: 100%; }
        pre { white-space: pre-wrap; }
        * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
        p.math { text-align: center; margin: 0.8em 0; }
        math { font-size: 1.1em; }
        h1, h2, h3 { line-height: 1.2; }
        @media print { body { margin: 0; max-width: none; padding: 0; } h1, h2, h3 { break-after: avoid; } pre, table, img { break-inside: avoid; } }
        </style></head>
        <body>
        \(body)
        </body></html>
        """
    }

    // MARK: Reading

    static func attributed(html: String, baseURL: URL) throws -> NSAttributedString {
        try NSAttributedString(data: Data(html.utf8),
                               options: [.documentType: NSAttributedString.DocumentType.html,
                                         .characterEncoding: String.Encoding.utf8.rawValue,
                                         .baseURL: baseURL],
                               documentAttributes: nil)
    }

    private static func plainText(fromHTML body: String, baseURL: URL) throws -> String {
        try attributed(html: "<meta charset=\"utf-8\">" + body, baseURL: baseURL).string
    }

    private static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
            throw ConversionError.failed("Couldn't read this text file.")
        }
        return text
    }

    static func extractPDFText(_ input: URL) async throws -> String {
        var text = await Task.detached(priority: .utility) {
            PDFDocument(url: input)?.string ?? ""
        }.value
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A scan: read the text off the page images instead.
            text = try await Task.detached(priority: .utility) { try TextRecognition.text(inPDF: input) }.value
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.failed("No text could be found in this PDF.")
        }
        return text
    }

    /// Lays the text out on US Letter pages with AppKit's text system and prints it to a PDF file.
    static func renderPDF(_ text: NSAttributedString, output: URL) throws {
        let printInfo = NSPrintInfo()
        printInfo.paperSize = NSSize(width: 612, height: 792)
        printInfo.topMargin = 54
        printInfo.bottomMargin = 54
        printInfo.leftMargin = 54
        printInfo.rightMargin = 54
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isVerticallyCentered = false
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 612 - 108, height: 100))
        textView.textStorage?.setAttributedString(text)
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
            let height = layoutManager.usedRect(for: container).height
            textView.frame.size.height = ceil(height) + 20
        }

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw ConversionError.failed("Couldn't create the PDF.") }
    }
}

nonisolated func escapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

// MARK: - Markdown

/// A compact Markdown reader and writer covering what people actually use: headings, paragraphs,
/// bold/italic/strikethrough, code, links, images, block quotes, nested lists, tables and rules.
nonisolated enum Markdown {
    /// Math ($…$, $$…$$, \(…\), \[…\]) becomes MathML for web pages and PDFs; other formats can't show
    /// MathML, so there it stays as the LaTeX source.
    @TaskLocal static var mathAsMathML = true

    static func math(_ tex: String, display: Bool) -> String {
        mathAsMathML ? TeXMath.mathML(tex, display: display) : escapeHTML(display ? "$$\(tex)$$" : "$\(tex)$")
    }

    // MARK: Markdown → HTML

    static func html(from markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ")
            .components(separatedBy: "\n")
        return blocks(lines[...]).joined(separator: "\n")
    }

    private static func blocks(_ input: ArraySlice<String>) -> [String] {
        var out: [String] = []
        var lines = input
        while let line = lines.first {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { lines.removeFirst(); continue }

            // Display math: $$ … $$ or \[ … \], on one line or several
            if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") {
                let close = trimmed.hasPrefix("$$") ? "$$" : "\\]"
                var body = String(trimmed.dropFirst(2))
                lines.removeFirst()
                if let end = body.range(of: close) {
                    body = String(body[..<end.lowerBound])
                } else {
                    var parts = [body]
                    while let next = lines.first {
                        lines.removeFirst()
                        if let end = next.range(of: close) { parts.append(String(next[..<end.lowerBound])); break }
                        parts.append(next)
                    }
                    body = parts.joined(separator: "\n")
                }
                out.append("<p class=\"math\">\(math(body, display: true))</p>")
                continue
            }
            // Fenced code
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                lines.removeFirst()
                var code: [String] = []
                while let next = lines.first, !next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(next); lines.removeFirst()
                }
                if !lines.isEmpty { lines.removeFirst() }
                out.append("<pre><code>\(escapeHTML(code.joined(separator: "\n")))</code></pre>")
                continue
            }
            // Heading
            if let match = trimmed.wholeMatch(of: /(#{1,6})\s+(.*?)\s*#*/) {
                let level = match.1.count
                out.append("<h\(level)>\(inline(String(match.2)))</h\(level)>")
                lines.removeFirst(); continue
            }
            // Horizontal rule
            if trimmed.wholeMatch(of: /([-*_])(\s*\1){2,}/) != nil {
                out.append("<hr>"); lines.removeFirst(); continue
            }
            // Block quote
            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var content = next.trimmingCharacters(in: .whitespaces).dropFirst()
                    if content.first == " " { content = content.dropFirst() }
                    quoted.append(String(content)); lines.removeFirst()
                }
                out.append("<blockquote>\(blocks(quoted[...]).joined(separator: "\n"))</blockquote>")
                continue
            }
            // List
            if listMarker(line) != nil {
                out.append(list(&lines))
                continue
            }
            // Table: a row of cells followed by a |---|---| line
            if line.contains("|"), lines.count > 1, isTableSeparator(lines[lines.startIndex + 1]) {
                out.append(table(&lines))
                continue
            }
            // Paragraph, possibly a setext heading (underlined with === or ---)
            var paragraph: [String] = []
            while let next = lines.first {
                let t = next.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") || t.hasPrefix(">") || t.hasPrefix("```") || (listMarker(next) != nil && !paragraph.isEmpty) { break }
                if !paragraph.isEmpty, t.wholeMatch(of: /=+/) != nil || t.wholeMatch(of: /-+/) != nil {
                    let level = t.hasPrefix("=") ? 1 : 2
                    out.append("<h\(level)>\(inline(paragraph.joined(separator: " ")))</h\(level)>")
                    paragraph = []
                    lines.removeFirst()
                    break
                }
                paragraph.append(next); lines.removeFirst()
            }
            if !paragraph.isEmpty {
                let html = paragraph.enumerated().map { index, text in
                    let breaks = index < paragraph.count - 1 && (text.hasSuffix("  ") || text.hasSuffix("\\"))
                    let content = inline(text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\\")))
                    return content + (breaks ? "<br>" : "")
                }.joined(separator: "\n")
                out.append("<p>\(html)</p>")
            }
        }
        return out
    }

    /// The indent, whether it's numbered, and where the item's text starts.
    private static func listMarker(_ line: String) -> (indent: Int, ordered: Bool, contentStart: Int)? {
        guard let match = line.prefixMatch(of: /( *)([-*+]|\d{1,9}[.)])( +|$)/) else { return nil }
        let indent = match.1.count
        let ordered = match.2.first?.isNumber == true
        return (indent, ordered, line.distance(from: line.startIndex, to: match.range.upperBound))
    }

    private static func list(_ lines: inout ArraySlice<String>) -> String {
        guard let first = lines.first, let marker = listMarker(first) else { return "" }
        let tag = marker.ordered ? "ol" : "ul"
        var items: [String] = []
        while let line = lines.first {
            // A numbered list right after a bulleted one (or the reverse) starts a new list.
            guard let item = listMarker(line), item.indent == marker.indent, item.ordered == marker.ordered else {
                if line.trimmingCharacters(in: .whitespaces).isEmpty, let next = lines.dropFirst().first,
                   let following = listMarker(next),
                   following.indent > marker.indent || (following.indent == marker.indent && following.ordered == marker.ordered) {
                    lines.removeFirst(); continue
                }
                break
            }
            lines.removeFirst()
            var content = [String(line.dropFirst(item.contentStart))]
            var nested = ""
            // Continuation lines and nested lists are indented further.
            while let next = lines.first {
                if let sub = listMarker(next), sub.indent > marker.indent {
                    nested += list(&lines)
                } else if !next.trimmingCharacters(in: .whitespaces).isEmpty, listMarker(next) == nil,
                          next.prefix(while: { $0 == " " }).count > marker.indent {
                    content.append(next.trimmingCharacters(in: .whitespaces)); lines.removeFirst()
                } else { break }
            }
            var text = content.joined(separator: " ")
            var checkbox = ""
            if let task = text.prefixMatch(of: #/\[([ xX])\] /#) {
                checkbox = task.1 == " " ? "☐ " : "☑ "
                text = String(text[task.range.upperBound...])
            }
            items.append("<li>\(checkbox)\(inline(text))\(nested)</li>")
        }
        return "<\(tag)>\(items.joined())</\(tag)>"
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).wholeMatch(of: /\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?/) != nil
    }

    private static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func table(_ lines: inout ArraySlice<String>) -> String {
        let header = cells(lines.removeFirst())
        lines.removeFirst()
        var html = "<table><thead><tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>"
        while let line = lines.first, line.contains("|"), !line.trimmingCharacters(in: .whitespaces).isEmpty {
            html += "<tr>" + cells(line).map { "<td>\(inline($0))</td>" }.joined() + "</tr>"
            lines.removeFirst()
        }
        return html + "</tbody></table>"
    }

    /// Inline formatting. Code spans and math are set aside first so nothing inside them is touched.
    /// A lone "$" (a price) isn't math: math needs no space just inside the dollar signs.
    static func inline(_ text: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"(`+)(.+?)\1|\$\$(.+?)\$\$|\\\((.+?)\\\)|(?<![\\$\w])\$(?=\S)([^$\n]+?)(?<=\S)\$(?![\w$])"#)
        let string = text as NSString
        var result = "", last = 0
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : string.substring(with: range)
        }
        for match in regex.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            result += spans(string.substring(with: NSRange(location: last, length: match.range.location - last)))
            if let code = group(match, 2) {
                result += "<code>\(escapeHTML(code.trimmingCharacters(in: .whitespaces)))</code>"
            } else if let display = group(match, 3) {
                result += math(display, display: true)
            } else if let tex = group(match, 4) ?? group(match, 5) {
                result += math(tex, display: false)
            }
            last = match.range.location + match.range.length
        }
        return result + spans(string.substring(from: last))
    }

    private static func spans(_ text: String) -> String {
        var s = escapeHTML(text)
        s = s.replacing(/!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;[^)]*&quot;)?\)/) { "<img src=\"\($0.2)\" alt=\"\($0.1)\">" }
        s = s.replacing(/\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;[^)]*&quot;)?\)/) { "<a href=\"\($0.2)\">\($0.1)</a>" }
        s = s.replacing(/&lt;(https?:\/\/[^\s&]+)&gt;/) { "<a href=\"\($0.1)\">\($0.1)</a>" }
        s = replace(s, #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, "<strong>$2</strong>")
        s = replace(s, #"\*(?=\S)(.+?)(?<=\S)\*"#, "<em>$1</em>")
        s = replace(s, #"(?<![\w])_(?=\S)(.+?)(?<=\S)_(?![\w])"#, "<em>$1</em>")
        s = replace(s, #"~~(?=\S)(.+?)(?<=\S)~~"#, "<del>$1</del>")
        return s
    }

    /// Swift's own regexes can't look behind, so emphasis uses Foundation's.
    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    // MARK: Formatted text → Markdown

    static func markdown(from text: NSAttributedString) -> String {
        let string = text.string as NSString
        let bodySize = commonFontSize(text)
        var blocks: [String] = []
        var listLines: [String] = []
        var codeLines: [String] = []
        var table: (id: ObjectIdentifier, rows: [Int: [Int: String]])?

        func flushList() { if !listLines.isEmpty { blocks.append(listLines.joined(separator: "\n")); listLines = [] } }
        func flushCode() { if !codeLines.isEmpty { blocks.append("```\n" + codeLines.joined(separator: "\n") + "\n```"); codeLines = [] } }
        func flushTable() {
            guard let current = table else { return }
            table = nil
            let rowNumbers = current.rows.keys.sorted()
            let width = current.rows.values.map { ($0.keys.max() ?? 0) + 1 }.max() ?? 0
            guard width > 0 else { return }
            var lines = rowNumbers.map { r in "| " + (0..<width).map { current.rows[r]?[$0] ?? "" }.joined(separator: " | ") + " |" }
            lines.insert("|" + String(repeating: " --- |", count: width), at: 1)
            blocks.append(lines.joined(separator: "\n"))
        }

        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { _, range, _, _ in
            guard range.length > 0 else { return }
            let attributes = text.attributes(at: range.location, effectiveRange: nil)
            let style = attributes[.paragraphStyle] as? NSParagraphStyle

            // Table cells carry their row and column.
            if let cell = style?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).last {
                let id = ObjectIdentifier(cell.table)
                if table?.id != id { flushList(); flushCode(); flushTable(); table = (id, [:]) }
                let content = inlineMarkdown(text, range: range).replacingOccurrences(of: "|", with: "\\|")
                let existing = table?.rows[cell.startingRow]?[cell.startingColumn]
                table?.rows[cell.startingRow, default: [:]][cell.startingColumn] = existing.map { $0 + " " + content } ?? content
                return
            }
            flushTable()

            let font = attributes[.font] as? NSFont
            let raw = string.substring(with: range)
            if let font, font.isFixedPitch, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                flushList()
                codeLines.append(raw)
                return
            }
            flushCode()

            if let lists = style?.textLists, let list = lists.last {
                // Imported list paragraphs start with their marker, e.g. "\t•\t".
                let content = inlineMarkdown(text, range: afterMarker(raw, range))
                let ordered = list.markerFormat.rawValue.contains("decimal") || list.markerFormat.rawValue.contains("alpha")
                    || list.markerFormat.rawValue.contains("roman")
                listLines.append(String(repeating: "    ", count: lists.count - 1) + (ordered ? "1. " : "- ") + content)
                return
            }
            // Word files read by macOS lose their list structure but keep the marker: "\t1\tOne", "\t•\tOne".
            if let marker = raw.prefixMatch(of: /\t?([•◦▪▫‣⁃–*-]|\d{1,3}[.)]?|[a-zA-Z][.)]|[ivxIVX]{1,4}[.)])\t/) {
                let ordered = marker.1.first.map { $0.isNumber || $0.isLetter } ?? false
                let level = max(0, Int(((style?.headIndent ?? 36) / 36).rounded()) - 1)
                let content = inlineMarkdown(text, range: afterMarker(raw, range))
                listLines.append(String(repeating: "    ", count: level) + (ordered ? "1. " : "- ") + content)
                return
            }
            flushList()

            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            if let size = font?.pointSize, let level = headingLevel(size: size, body: bodySize, bold: font.map(isBold) ?? false) {
                blocks.append(String(repeating: "#", count: level) + " " + trimmed)
            } else {
                blocks.append(inlineMarkdown(text, range: range))
            }
        }
        flushList(); flushCode(); flushTable()
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// The part of a list paragraph after its "\t•\t" or "\t1.\t" marker.
    private static func afterMarker(_ raw: String, _ range: NSRange) -> NSRange {
        guard let marker = raw.prefixMatch(of: /\t?[^\t]{0,8}\t/) else { return range }
        let length = (String(raw[marker.range]) as NSString).length
        return NSRange(location: range.location + length, length: max(0, range.length - length))
    }

    private static func headingLevel(size: CGFloat, body: CGFloat, bold: Bool) -> Int? {
        let ratio = size / max(body, 1)
        if ratio >= 1.7 { return 1 }
        if ratio >= 1.4 { return 2 }
        if ratio >= 1.2 { return 3 }
        if ratio >= 1.05 && bold { return 4 }
        return nil
    }

    private static func commonFontSize(_ text: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let font = value as? NSFont { counts[font.pointSize, default: 0] += range.length }
        }
        return counts.max { $0.value < $1.value }?.key ?? 12
    }

    private static func isBold(_ font: NSFont) -> Bool { font.fontDescriptor.symbolicTraits.contains(.bold) }

    private static func inlineMarkdown(_ text: NSAttributedString, range: NSRange) -> String {
        var result = ""
        text.enumerateAttributes(in: range) { attributes, subrange, _ in
            var piece = (text.string as NSString).substring(with: subrange)
            piece = piece.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\u{2028}", with: "  \n")
            guard !piece.trimmingCharacters(in: .whitespaces).isEmpty else { result += piece; return }
            piece = piece.replacing(/([\\`*_\[\]])/) { "\\" + $0.1 }

            let leading = String(piece.prefix { $0 == " " }), trailing = String(piece.reversed().prefix { $0 == " " })
            var core = piece.trimmingCharacters(in: .whitespaces)
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if font.isFixedPitch { core = "`" + core.replacingOccurrences(of: "\\", with: "") + "`" }
                else {
                    if traits.contains(.italic) { core = "*" + core + "*" }
                    if traits.contains(.bold) { core = "**" + core + "**" }
                }
            }
            if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { core = "~~" + core + "~~" }
            if let link = attributes[.link] {
                let url = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                if !url.isEmpty { core = "[\(core)](\(url))" }
            }
            result += leading + core + trailing
        }
        // Adjacent runs with the same style ("**a****b**") read better merged.
        return result.replacingOccurrences(of: "****", with: "").replacingOccurrences(of: "**  **", with: " ")
    }
}
