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
        // E-books: an EPUB is read as one HTML page, and writing one cuts the document into chapters.
        if from == .epub {
            let page = try await EPUB.asHTMLRequest(request)
            if request.to == .pdf {
                // Loading the page from disk is what lets the web engine show the book's pictures.
                try await WebPDF.render(html: "", baseURL: page.originalDir, output: output, file: page.input)
            } else if request.to == .html {
                // The joined page already carries its pictures and styling, so it is the result.
                try FileManager.default.copyItem(at: page.input, to: output)
            } else {
                try await convert(page, output: output)
            }
            return
        }
        if request.to == .epub {
            try await EPUB.write(request, from: from, input: input, output: output)
            return
        }
        if from == .pdf {
            if request.to == .docx {
                try await PDFToWord.convert(request, output: output)
                return
            }
            // A PDF made from Markdown with math carries that Markdown, formulas and all.
            if request.to == .md, let markdown = MathMarkdown.embeddedMarkdown(in: input) {
                try markdown.write(to: output, atomically: true, encoding: .utf8)
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
            let collector = MathCollector()
            let mode: Markdown.MathOutput = [.html, .pdf].contains(request.to) ? .mathML : request.to == .docx ? .placeholders(collector) : .tex
            // A long document takes a moment to translate; keep it off the main thread.
            let html = await Task.detached(priority: .utility) { Markdown.$mathOutput.withValue(mode) { Markdown.html(from: markdown) } }.value
            if request.to == .txt {
                try plainText(fromHTML: html, baseURL: request.originalDir).write(to: output, atomically: true, encoding: .utf8)
            } else {
                try await write(html: html, title: request.title, request: request, output: output)
            }
            if request.to == .pdf, html.contains("<math ") {
                MathMarkdown.embed(markdown: markdown, in: output)
            }
            if !collector.items.isEmpty || !collector.tables.isEmpty {
                try await WordMath.insert(collector.items, tables: collector.tables, into: output, workDir: request.workDir)
            }
        case .html:
            let html = try readText(input)
            if request.to == .pdf {
                try await WebPDF.render(html: html, baseURL: request.originalDir, output: output)
            } else if request.to == .md {
                let prepared = MathMarkdown.prepare(html: html)
                let markdown = try Markdown.markdown(from: attributed(html: prepared?.html ?? html, baseURL: request.originalDir))
                try MathMarkdown.restore(markdown, items: prepared?.items ?? []).write(to: output, atomically: true, encoding: .utf8)
            } else {
                try await write(text: attributed(html: html, baseURL: request.originalDir), request: request, output: output)
            }
        case .txt:
            let text = try readText(input)
            if request.to == .md {
                try text.write(to: output, atomically: true, encoding: .utf8)
            } else {
                let paragraphs = text.components(separatedBy: "\n\n").map { "<p>\(escapeHTML($0).replacingOccurrences(of: "\n", with: "<br>"))</p>" }
                try await write(html: paragraphs.joined(separator: "\n"), title: request.title, request: request, output: output)
            }
        case .docx where request.to == .odt:
            try await WordToODT.convert(input, output: output, workDir: request.workDir)
        case .docx where request.to == .md:
            // Word equations come through as LaTeX, and tables as tables.
            let prepared = try await MathMarkdown.prepare(docx: input, workDir: request.workDir)
            let text = try NSAttributedString(url: prepared?.url ?? input, options: [:], documentAttributes: nil)
            try MathMarkdown.restore(Markdown.markdown(from: text), docx: prepared).write(to: output, atomically: true, encoding: .utf8)
        default:
            let text = try NSAttributedString(url: input, options: [:], documentAttributes: nil)
            try await write(text: text, request: request, output: output)
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
            try await write(text: attributed(html: htmlPage(body: body, title: title), baseURL: request.originalDir), request: request, output: output)
        }
    }

    private static func write(text: NSAttributedString, request: Converter.Request, output: URL) async throws {
        let type: NSAttributedString.DocumentType
        switch request.to {
        case .txt: return try text.string.write(to: output, atomically: true, encoding: .utf8)
        case .md: return try Markdown.markdown(from: text).write(to: output, atomically: true, encoding: .utf8)
        case .pdf: return try renderPDF(text, output: output)
        case .docx: type = .officeOpenXML
        case .doc: type = .docFormat
        case .rtf: type = .rtf
        case .odt: return try await ODTWriter.write(text, output: output, workDir: request.workDir)   // Keeps the pictures
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
            text = try await background { try await TextRecognition.text(inPDF: input) }
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
    /// Math ($…$, $$…$$, \(…\), \[…\]) becomes MathML for web pages and PDFs, a marker that's later
    /// replaced with a Word equation for .docx, and stays as LaTeX source in formats that can't show math.
    enum MathOutput: Sendable { case mathML, tex, placeholders(MathCollector) }
    @TaskLocal static var mathOutput: MathOutput = .mathML

    static func math(_ tex: String, display: Bool) -> String {
        switch mathOutput {
        case .mathML: TeXMath.mathML(tex, display: display)
        case .tex: escapeHTML(display ? "$$\(tex)$$" : "$\(tex)$")
        case .placeholders(let collector): collector.add(tex, display: display)
        }
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
            if let match = trimmed.wholeMatch(of: headingRegex) {
                let level = match.1.count
                out.append("<h\(level)>\(inline(String(match.2)))</h\(level)>")
                lines.removeFirst(); continue
            }
            // Horizontal rule
            if trimmed.wholeMatch(of: ruleRegex) != nil {
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
                if t.isEmpty || (t.hasPrefix("#") && t.wholeMatch(of: headingRegex) != nil) || t.hasPrefix(">") || t.hasPrefix("```") || (listMarker(next) != nil && !paragraph.isEmpty) { break }
                if !paragraph.isEmpty, t.wholeMatch(of: equalsRegex) != nil || t.wholeMatch(of: dashesRegex) != nil {
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
        guard let match = line.prefixMatch(of: listMarkerRegex) else { return nil }
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
            if let task = text.prefixMatch(of: taskRegex) {
                checkbox = task.1 == " " ? "☐ " : "☑ "
                text = String(text[task.range.upperBound...])
            }
            items.append("<li>\(checkbox)\(inline(text))\(nested)</li>")
        }
        return "<\(tag)>\(items.joined())</\(tag)>"
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).wholeMatch(of: tableSeparatorRegex) != nil
    }

    private static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row.removeLast() }
        guard row.contains("\\|") || row.contains("$") || row.contains("`") else {
            return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        // A bar inside math ($\left| x \right|$) or escaped (\|) doesn't end the cell.
        let chars = Array(row)
        var cells: [String] = [], cell = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "|" {
                cell.append("|"); i += 2; continue
            }
            if c == "`", let end = chars[(i + 1)...].firstIndex(of: "`") {
                // Like GitHub, an escaped bar in code is a bar.
                cell += String(chars[i...end]).replacingOccurrences(of: "\\|", with: "|"); i = end + 1; continue
            }
            if c == "$", let end = mathEnd(chars, from: i) {
                cell += String(chars[i..<end]); i = end; continue
            }
            if c == "|" { cells.append(cell); cell = ""; i += 1; continue }
            cell.append(c); i += 1
        }
        cells.append(cell)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Where math starting with the "$" at `start` ends, using the same rules as `inlineRegex`
    /// (so "$5 | $10" is two prices, not math).
    private static func mathEnd(_ chars: [Character], from start: Int) -> Int? {
        if start > 0, chars[start - 1] == "\\" || chars[start - 1].isLetter || chars[start - 1].isNumber { return nil }
        let isDisplay = start + 1 < chars.count && chars[start + 1] == "$"
        let open = start + (isDisplay ? 2 : 1)
        guard open < chars.count, !chars[open].isWhitespace else { return nil }
        var j = open
        while j < chars.count {
            if chars[j] == "$" {
                if isDisplay {
                    if j + 1 < chars.count, chars[j + 1] == "$" { return j + 2 }
                } else {
                    guard !chars[j - 1].isWhitespace else { return nil }
                    let next = j + 1 < chars.count ? chars[j + 1] : " "
                    return next.isLetter || next.isNumber || next == "_" || next == "$" ? nil : j + 1
                }
            }
            j += 1
        }
        return nil
    }

    private static func table(_ lines: inout ArraySlice<String>) -> String {
        let header = cells(lines.removeFirst())
        lines.removeFirst()
        // macOS's Word writer drops tables, so for .docx the table is left as a marker and added afterwards.
        if case .placeholders(let collector) = mathOutput {
            var rows = [header.map(inline)]
            while let line = lines.first, line.contains("|"), !line.trimmingCharacters(in: .whitespaces).isEmpty {
                rows.append(cells(line).map(inline))
                lines.removeFirst()
            }
            return "<p>\(collector.addTable(rows))</p>"
        }
        var html = "<table><thead><tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>"
        while let line = lines.first, line.contains("|"), !line.trimmingCharacters(in: .whitespaces).isEmpty {
            html += "<tr>" + cells(line).map { "<td>\(inline($0))</td>" }.joined() + "</tr>"
            lines.removeFirst()
        }
        return html + "</tbody></table>"
    }

    // Compiled once: Swift builds a regex literal from its pattern each time the code runs, which dominated big files.
    // A heading can hold a line-break character (from a soft break in a Word title, say); "." has to match it, or the line never parses.
    private static let headingRegex = /(#{1,6})\s+(.*?)\s*#*/.dotMatchesNewlines()
    private static let ruleRegex = /([-*_])(\s*\1){2,}/
    private static let equalsRegex = /=+/
    private static let dashesRegex = /-+/
    private static let listMarkerRegex = /( *)([-*+]|\d{1,9}[.)])( +|$)/
    private static let taskRegex = #/\[([ xX])\] /#
    private static let tableSeparatorRegex = /\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?/
    private static let imageRegex = /!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;[^)]*&quot;)?\)/
    private static let linkRegex = /\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;[^)]*&quot;)?\)/
    private static let autolinkRegex = /&lt;(https?:\/\/[^\s&]+)&gt;/
    private static let exportListMarker = /\t?([•◦▪▫‣⁃–*-]|\d{1,3}[.)]?|[a-zA-Z][.)]|[ivxIVX]{1,4}[.)])\t/
    private static let markerPrefix = /\t?[^\t]{0,8}\t/
    private static let markdownSpecials = /([\\`*_\[\]])/
    private static let inlineRegex = try! NSRegularExpression(pattern: #"(`+)(.+?)\1|\$\$(.+?)\$\$|\\\((.+?)\\\)|(?<![\\$\w])\$(?=\S)([^$\n]+?)(?<=\S)\$(?![\w$])"#)
    private static let emphasis: [(regex: NSRegularExpression, template: String)] = [
        (#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, "<strong>$2</strong>"),
        (#"\*(?=\S)(.+?)(?<=\S)\*"#, "<em>$1</em>"),
        (#"(?<![\w])_(?=\S)(.+?)(?<=\S)_(?![\w])"#, "<em>$1</em>"),
        (#"~~(?=\S)(.+?)(?<=\S)~~"#, "<del>$1</del>"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// Inline formatting. Code spans and math are set aside first so nothing inside them is touched.
    /// A lone "$" (a price) isn't math: math needs no space just inside the dollar signs.
    static func inline(_ text: String) -> String {
        let string = text as NSString
        var result = "", last = 0
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : string.substring(with: range)
        }
        for match in inlineRegex.matches(in: text, range: NSRange(location: 0, length: string.length)) {
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

    /// Swift's own regexes can't look behind, so emphasis uses Foundation's.
    private static func spans(_ text: String) -> String {
        var s = escapeHTML(text)
        s = s.replacing(imageRegex) { "<img src=\"\($0.2)\" alt=\"\($0.1)\">" }
        s = s.replacing(linkRegex) { "<a href=\"\($0.2)\">\($0.1)</a>" }
        s = s.replacing(autolinkRegex) { "<a href=\"\($0.1)\">\($0.1)</a>" }
        for (regex, template) in emphasis {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
        }
        return s
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
            var lines = rowNumbers.map { r in
                "| " + (0..<width).map { c in
                    let cell = current.rows[r]?[c] ?? ""
                    // Header cells are bold anyway.
                    let isWhollyBold = r == rowNumbers.first && cell.hasPrefix("**") && cell.hasSuffix("**") && cell.count > 4
                        && !cell.dropFirst(2).dropLast(2).contains("**")
                    return isWhollyBold ? String(cell.dropFirst(2).dropLast(2)) : cell
                }.joined(separator: " | ") + " |"
            }
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
            if let marker = raw.prefixMatch(of: exportListMarker) {
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
        guard let marker = raw.prefixMatch(of: markerPrefix) else { return range }
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
            piece = piece.replacing(markdownSpecials) { "\\" + $0.1 }

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

/// Collects the math found while translating Markdown for Word, leaving a marker in its place.
nonisolated final class MathCollector: @unchecked Sendable {
    private(set) var items: [(tex: String, display: Bool)] = []
    private(set) var tables: [[[String]]] = []     // Rows of cells, each cell inline HTML; the first row is the header
    func addTable(_ rows: [[String]]) -> String {
        tables.append(rows)
        return "ZZTABLE\(tables.count - 1)ZZ"
    }
    func add(_ tex: String, display: Bool) -> String {
        items.append((tex, display))
        return "ZZMATH\(items.count - 1)ZZ"
    }
}

/// Swaps the math markers in a .docx for real Word equations.
nonisolated enum WordMath {
    static func insert(_ items: [(tex: String, display: Bool)], tables: [[[String]]] = [], into docx: URL, workDir: URL) async throws {
        let package = workDir.appending(path: "docx-math")
        try await Tools.run("/usr/bin/unzip", ["-q", "-o", docx.path, "-d", package.path])
        let documentURL = package.appending(path: "word/document.xml")
        var xml = try String(contentsOf: documentURL, encoding: .utf8)
        if !xml.contains("xmlns:m=\""), let root = xml.range(of: "<w:document ") {
            xml.replaceSubrange(root, with: #"<w:document xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math" "#)
        }

        // Tables first: a formula in a cell is a math marker in its text, replaced below like any other.
        if !tables.isEmpty {
            let paragraph = try NSRegularExpression(pattern: #"<w:p\b(?:(?!</w:p>).)*?ZZTABLE(\d+)ZZ(?:(?!</w:p>).)*?</w:p>"#, options: .dotMatchesLineSeparators)
            let string = xml as NSString
            var result = "", last = 0
            for match in paragraph.matches(in: xml, range: NSRange(location: 0, length: string.length)) {
                result += string.substring(with: NSRange(location: last, length: match.range.location - last))
                let index = Int(string.substring(with: match.range(at: 1))) ?? .max
                let marker = string.substring(with: match.range)
                // The cells use the font of the text around them.
                let font = marker.firstMatch(of: /<w:rFonts[^>]*\/>/).map { String($0.output) } ?? ""
                result += index < tables.count ? WordTable.xml(tables[index], font: font) : marker
                last = match.range.location + match.range.length
            }
            xml = result + string.substring(from: last)
        }

        // Each run (<w:r>) that holds a marker is split into text runs and equations.
        let runPattern = try NSRegularExpression(pattern: #"<w:r(?:\s[^>]*)?>(?:(?!</w:r>).)*?ZZMATH\d+ZZ(?:(?!</w:r>).)*?</w:r>"#, options: .dotMatchesLineSeparators)
        let markerPattern = try NSRegularExpression(pattern: #"ZZMATH(\d+)ZZ"#)
        let string = xml as NSString
        var result = ""
        var last = 0
        for match in runPattern.matches(in: xml, range: NSRange(location: 0, length: string.length)) {
            result += string.substring(with: NSRange(location: last, length: match.range.location - last))
            let run = string.substring(with: match.range)
            let properties = run.firstMatch(of: /<w:rPr>.*?<\/w:rPr>/.dotMatchesNewlines()).map { String($0.output) } ?? ""
            let text = run.matches(of: /<w:t(?:\s[^>]*)?>(.*?)<\/w:t>/.dotMatchesNewlines()).map { String($0.output.1) }.joined()
            let textString = text as NSString
            var position = 0
            for marker in markerPattern.matches(in: text, range: NSRange(location: 0, length: textString.length)) {
                let before = textString.substring(with: NSRange(location: position, length: marker.range.location - position))
                if !before.isEmpty { result += #"<w:r>\#(properties)<w:t xml:space="preserve">\#(before)</w:t></w:r>"# }
                if let index = Int(textString.substring(with: marker.range(at: 1))), index < items.count {
                    let item = items[index]
                    result += MathOMML.omml(fromMathML: TeXMath.mathML(item.tex, display: item.display), display: item.display)
                }
                position = marker.range.location + marker.range.length
            }
            let after = textString.substring(from: position)
            if !after.isEmpty { result += #"<w:r>\#(properties)<w:t xml:space="preserve">\#(after)</w:t></w:r>"# }
            last = match.range.location + match.range.length
        }
        result += string.substring(from: last)
        try result.write(to: documentURL, atomically: true, encoding: .utf8)

        try FileManager.default.removeItem(at: docx)
        try await Tools.run("/usr/bin/zip", ["-q", "-X", "-r", docx.path, "."], currentDirectory: package)
    }
}

/// A Markdown table as a Word table: thin borders, columns sharing the page width, a bold header row
/// that repeats on each page. Cells hold inline HTML (bold, italic, code, struck, links as text).
nonisolated enum WordTable {
    static func xml(_ rows: [[String]], font: String = "") -> String {
        let width = rows.map(\.count).max() ?? 0
        guard width > 0 else { return "" }
        let column = 9360 / width     // 6.5" of text width, in twentieths of a point
        let border = #"w:val="single" w:sz="4" w:space="0" w:color="A0A0A0""#
        var xml = #"<w:tbl><w:tblPr><w:tblW w:w="\#(column * width)" w:type="dxa"/><w:tblBorders>"#
        xml += ["top", "left", "bottom", "right", "insideH", "insideV"].map { "<w:\($0) \(border)/>" }.joined()
        xml += #"</w:tblBorders><w:tblLayout w:type="fixed"/><w:tblCellMar><w:left w:w="80" w:type="dxa"/><w:right w:w="80" w:type="dxa"/></w:tblCellMar></w:tblPr><w:tblGrid>"#
        xml += String(repeating: #"<w:gridCol w:w="\#(column)"/>"#, count: width) + "</w:tblGrid>"
        for (r, row) in rows.enumerated() {
            xml += r == 0 ? "<w:tr><w:trPr><w:tblHeader/></w:trPr>" : "<w:tr>"
            for c in 0..<width {
                let content = c < row.count ? runs(row[c], bold: r == 0, font: font) : ""
                xml += #"<w:tc><w:tcPr><w:tcW w:w="\#(column)" w:type="dxa"/></w:tcPr><w:p><w:pPr><w:spacing w:before="40" w:after="40"/></w:pPr>\#(content)</w:p></w:tc>"#
            }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl>"
    }

    private static let token = /<(\/?)([a-zA-Z]+)[^>]*>|[^<]+/

    /// Inline HTML as Word runs. Its text is already escaped for XML.
    static func runs(_ html: String, bold: Bool, font: String = "") -> String {
        var out = ""
        var strong = 0, em = 0, code = 0, del = 0
        for match in html.matches(of: token) {
            guard let name = match.output.2 else {
                let text = String(match.output.0)
                var properties = ""
                properties += code > 0 ? #"<w:rFonts w:ascii="Menlo" w:hAnsi="Menlo" w:cs="Menlo"/>"# : font
                if bold || strong > 0 { properties += "<w:b/>" }
                if em > 0 { properties += "<w:i/>" }
                if del > 0 { properties += "<w:strike/>" }
                if code > 0 { properties += #"<w:sz w:val="19"/>"# }
                out += "<w:r>" + (properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>") + #"<w:t xml:space="preserve">\#(text)</w:t></w:r>"#
                continue
            }
            let step = match.output.1 == "/" ? -1 : 1
            switch name.lowercased() {
            case "strong", "b": strong = max(0, strong + step)
            case "em", "i": em = max(0, em + step)
            case "code": code = max(0, code + step)
            case "del", "s": del = max(0, del + step)
            default: break
            }
        }
        return out
    }
}
