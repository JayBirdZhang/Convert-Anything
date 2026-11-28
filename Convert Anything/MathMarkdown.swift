import Foundation
import PDFKit

/// Keeps math as LaTeX when Word, HTML and PDF files become Markdown. Each equation is swapped for a
/// marker before macOS's text system reads the file (it would drop or garble it), and the marker is
/// replaced with `$…$` / `$$…$$` in the finished Markdown.
nonisolated enum MathMarkdown {
    struct Item: Sendable { var tex: String; var display: Bool }

    static func marker(_ index: Int) -> String { "ZZTEX\(index)ZZ" }

    /// Replaces the markers in finished Markdown with LaTeX.
    static func restore(_ markdown: String, items: [Item]) -> String {
        guard !items.isEmpty else { return markdown }
        let lines = markdown.components(separatedBy: "\n").map { line -> String in
            guard line.contains("ZZTEX") else { return line }
            let inTable = line.hasPrefix("|")
            return line.replacing(/ZZTEX(\d+)ZZ/) { match in
                guard let index = Int(match.output.1), index < items.count else { return String(match.output.0) }
                var tex = clean(items[index].tex)
                if inTable {
                    // A bar would end the table cell.
                    tex = tex.replacingOccurrences(of: "\\|", with: "\\Vert ").replacingOccurrences(of: "|", with: "\\vert ")
                        .trimmingCharacters(in: .whitespaces)
                }
                guard !tex.isEmpty else { return "" }
                return items[index].display ? "$$\(tex)$$" : "$\(tex)$"
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One line, no `\displaystyle` wrapper (Wikipedia's annotations have one), no stray spaces inside the dollars.
    private static func clean(_ tex: String) -> String {
        var tex = tex.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        for style in ["\\displaystyle", "\\textstyle"] {
            if tex.hasPrefix("{" + style), tex.hasSuffix("}") {
                tex = String(tex.dropFirst(style.count + 1).dropLast())
            }
            if tex.hasPrefix(style) { tex = String(tex.dropFirst(style.count)) }
            tex = tex.trimmingCharacters(in: .whitespaces)
        }
        return tex
    }

    // MARK: Word

    struct PreparedDocx { var url: URL; var items: [Item]; var tables: [String] }

    /// When the .docx has equations or tables, a copy with each one replaced by a marker. macOS's Word
    /// reader drops equations and flattens tables into loose paragraphs, so both are read here instead.
    /// Nil when it has neither, which costs a single read of document.xml.
    static func prepare(docx: URL, workDir: URL) async throws -> PreparedDocx? {
        let xml = try await Tools.run("/usr/bin/unzip", ["-p", docx.path, "word/document.xml"])
        let hasMath = xml.contains("<m:oMath"), hasTables = xml.contains("<w:tbl>") || xml.contains("<w:tbl ")
        guard hasMath || hasTables else { return nil }

        var items: [Item] = []
        var tables: [String] = []
        let paragraphPattern = try NSRegularExpression(pattern: #"<m:oMathPara(?:\s[^>]*)?>.*?</m:oMathPara>"#, options: .dotMatchesLineSeparators)
        let mathPattern = try NSRegularExpression(pattern: #"<m:oMath(?:\s[^>]*)?>.*?</m:oMath>"#, options: .dotMatchesLineSeparators)
        func run(_ text: String) -> String { #"<w:r><w:t xml:space="preserve">\#(text)</w:t></w:r>"# }

        // Display equations (their own paragraph) first; each line in one becomes its own $$…$$.
        var result = !hasMath ? xml : replace(paragraphPattern, in: xml) { para in
            let lines = matches(mathPattern, in: para).map { snippet -> String in
                items.append(Item(tex: MathTeX.tex(fromOMML: snippet), display: true))
                return marker(items.count - 1)
            }
            return run(lines.joined(separator: " "))
        }
        if hasMath {
            result = replace(mathPattern, in: result) { snippet in
                items.append(Item(tex: MathTeX.tex(fromOMML: snippet), display: false))
                return run(marker(items.count - 1))
            }
        }
        // Tables after math, so a formula in a cell is already a marker in its text.
        if hasTables, let open = try? Regex(#"<(w:tbl)\b[^>]*>"#) {
            result = replaceBalanced(open, in: result) { table in
                tables.append(markdownTable(fromWord: table))
                return "<w:p>" + run(tableMarker(tables.count - 1)) + "</w:p>"
            }
        }

        // Update only document.xml in a copy of the package.
        let stage = workDir.appending(path: "docx-tex")
        let copy = workDir.appending(path: "with-markers.docx")
        try? FileManager.default.removeItem(at: stage)
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.createDirectory(at: stage.appending(path: "word"), withIntermediateDirectories: true)
        try result.write(to: stage.appending(path: "word/document.xml"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: docx, to: copy)
        try await Tools.run("/usr/bin/zip", ["-q", copy.path, "word/document.xml"], currentDirectory: stage)
        return PreparedDocx(url: copy, items: items, tables: tables)
    }

    static func tableMarker(_ index: Int) -> String { "ZZTABLE\(index)ZZ" }

    /// Puts the tables and then the math back into Markdown made from a prepared .docx.
    static func restore(_ markdown: String, docx: PreparedDocx?) -> String {
        guard let docx else { return markdown }
        var markdown = markdown
        if !docx.tables.isEmpty {
            markdown = markdown.components(separatedBy: "\n").map { line in
                guard line.hasPrefix("ZZTABLE"), let match = line.wholeMatch(of: /ZZTABLE(\d+)ZZ\s*/),
                      let index = Int(match.output.1), index < docx.tables.count else { return line }
                return docx.tables[index]
            }.joined(separator: "\n")
        }
        return restore(markdown, items: docx.items)
    }

    private static let tokenPattern = try! NSRegularExpression(pattern: #"<(/?)([A-Za-z][\w:.-]*)([^>]*?)(/?)>|[^<]+"#)
    private static let wordMarkdownSpecials = /([\\`*_\[\]|])/

    /// A Word table (<w:tbl>…</w:tbl>) as a Markdown table. The first row is the header; merged cells
    /// leave the cells they cover empty; a table inside a cell becomes that cell's text.
    static func markdownTable(fromWord xml: Substring) -> String {
        var rows: [[String]] = []
        var row: [String] = [], paragraphs: [String] = [], paragraph = "", runText = ""
        var depth = 0, span = 1
        var inRun = false, inText = false, bold = false, italic = false, code = false

        func on(_ attributes: String) -> Bool {
            guard let value = attributes.firstMatch(of: /w:val\s*=\s*"([^"]*)"/)?.output.1 else { return true }
            return !["0", "false", "off", "none"].contains(value.lowercased())
        }
        func endRun() {
            let text = decodeXML(runText)
            runText = ""
            if code, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                paragraph += "`" + text.replacingOccurrences(of: "|", with: "\\|") + "`"
                return
            }
            var piece = text.replacing(wordMarkdownSpecials) { "\\" + $0.1 }
            let core = piece.trimmingCharacters(in: .whitespaces)
            // The header row is bold anyway.
            if !core.isEmpty, (bold && !rows.isEmpty) || italic {
                let mark = bold && italic && !rows.isEmpty ? "***" : bold && !rows.isEmpty ? "**" : "*"
                let leading = piece.prefix { $0 == " " }, trailing = String(piece.reversed().prefix { $0 == " " })
                piece = leading + mark + core + mark + trailing
            }
            paragraph += piece
        }

        let string = String(xml) as NSString
        for match in tokenPattern.matches(in: string as String, range: NSRange(location: 0, length: string.length)) {
            guard match.range(at: 2).location != NSNotFound else {
                if inText { runText += string.substring(with: match.range) }
                continue
            }
            let closing = match.range(at: 1).length > 0, selfClosing = match.range(at: 4).length > 0
            let name = string.substring(with: match.range(at: 2))
            let attributes = string.substring(with: match.range(at: 3))
            switch (name, closing) {
            case ("w:tbl", false): depth += 1
            case ("w:tbl", true): depth -= 1
            case ("w:tr", false) where depth == 1: row = []
            case ("w:tr", true) where depth == 1: rows.append(row)
            case ("w:tc", false) where depth == 1: paragraphs = []; span = 1
            case ("w:tc", true) where depth == 1:
                row.append(paragraphs.joined(separator: " "))
                if span > 1 { row += Array(repeating: "", count: span - 1) }
            case ("w:gridSpan", false) where depth == 1:
                span = attributes.firstMatch(of: /w:val\s*=\s*"(\d+)"/).flatMap { Int($0.output.1) } ?? 1
            case ("w:p", false): if !selfClosing { paragraph = "" }
            case ("w:p", true):
                let text = paragraph.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { paragraphs.append(text) }
            case ("w:r", false): if !selfClosing { inRun = true; bold = false; italic = false; code = false; runText = "" }
            case ("w:rFonts", false) where inRun:
                let font = attributes.lowercased()
                code = ["menlo", "courier", "consolas", "monaco", "mono"].contains { font.contains($0) }
            case ("w:r", true): if inRun { endRun() }; inRun = false
            case ("w:b", false) where inRun: bold = on(attributes)
            case ("w:i", false) where inRun: italic = on(attributes)
            case ("w:t", false): inText = !selfClosing
            case ("w:t", true): inText = false
            case ("w:tab", false), ("w:br", false), ("w:cr", false): if inRun { runText += " " }
            default: break
            }
        }

        let width = rows.map(\.count).max() ?? 0
        guard width > 0 else { return "" }
        // Adjacent runs with the same style ("**a****b**") read better merged.
        func line(_ cells: [String]) -> String {
            let cells = cells + Array(repeating: "", count: width - cells.count)
            return "| " + cells.map { $0.replacingOccurrences(of: "****", with: "") }.joined(separator: " | ") + " |"
        }
        var lines = rows.map(line)
        lines.insert("|" + String(repeating: " --- |", count: width), at: 1)
        return lines.joined(separator: "\n")
    }

    private static func decodeXML(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacing(/&#(x?)([0-9A-Fa-f]+);/) { match in
                UInt32(match.output.2, radix: match.output.1.isEmpty ? 10 : 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
            }
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: HTML

    private static let containerClasses = ["katex", "mwe-math-element"]
    private static let mathJaxRenderClasses = ["MathJax_Preview", "MathJax", "MathJax_Display", "MathJax_SVG", "MathJax_SVG_Display",
                                               "MathJax_CHTML", "MathJax_MathML", "MJX_Assistive_MathML"]

    /// The page with each formula replaced by a marker, or nil when it has none.
    /// Handles plain MathML, KaTeX and Wikipedia (MathML plus a drawn copy), and MathJax 2 and 3.
    static func prepare(html: String) -> (html: String, items: [Item])? {
        let lower = html.lowercased()
        let hasMathML = lower.contains("<math"), hasScriptTeX = lower.contains("math/tex")
        guard hasMathML || hasScriptTeX else { return nil }
        var html = html
        var items: [Item] = []
        func add(_ tex: String, display: Bool) -> String {
            items.append(Item(tex: tex, display: display))
            return marker(items.count - 1)
        }

        // MathJax 2 keeps the TeX in a script; the drawn copies next to it go.
        if hasScriptTeX {
            for name in mathJaxRenderClasses { html = removeElements(withClass: name, in: html) }
            let script = /(?i)<script[^>]*type\s*=\s*["']math\/tex(;\s*mode\s*=\s*display)?["'][^>]*>(.*?)<\/script>/.dotMatchesNewlines()
            html = html.replacing(script) { add(String($0.output.2), display: $0.output.1 != nil) }
        }
        guard hasMathML else { return items.isEmpty ? nil : (html, items) }

        // A formula inside a wrapper that also draws it (KaTeX, Wikipedia) replaces the whole wrapper.
        let mathRegex = /(?i)<math\b([^>]*)>.*?<\/math\s*>/.dotMatchesNewlines()
        func mathItem(_ element: Substring, attributes: Substring) -> String {
            let attrs = attributes.lowercased()
            let display = attrs.contains("display=\"block\"") || attrs.contains("display='block'") || attrs.contains("mode=\"display\"")
            return add(MathTeX.tex(fromMathML: String(element)), display: display)
        }
        for name in containerClasses {
            html = replaceElements(withClass: name, in: html) { element in
                guard let math = element.firstMatch(of: mathRegex) else { return nil }
                return mathItem(math.output.0, attributes: math.output.1)
            }
        }
        // MathJax 3 puts an accessible MathML copy in its container.
        html = replaceElements(tag: "mjx-container", in: html) { element in
            guard let math = element.firstMatch(of: mathRegex) else { return "" }
            let display = element.prefix(200).contains("display=\"true\"")
            return add(MathTeX.tex(fromMathML: String(math.output.0)), display: display)
        }
        html = html.replacing(mathRegex) { mathItem($0.output.0, attributes: $0.output.1) }
        return items.isEmpty ? nil : (html, items)
    }

    // MARK: PDFs made from Markdown

    /// A PDF made from Markdown with math carries its source, so turning it back into Markdown gives the
    /// formulas exactly. The fingerprint of the page text tells whether the PDF was changed since.
    private static let sourceKey = PDFDocumentAttribute(rawValue: "ConvertAnythingMarkdown")
    private static let fingerprintKey = PDFDocumentAttribute(rawValue: "ConvertAnythingTextFingerprint")

    static func embed(markdown: String, in pdf: URL) {
        guard let document = PDFDocument(url: pdf) else { return }
        // Comments aren't on the page, so they don't travel with it.
        let source = markdown.replacing(/<!--.*?-->/.dotMatchesNewlines(), with: "")
        var attributes = document.documentAttributes ?? [:]
        attributes[sourceKey] = source
        attributes[fingerprintKey] = fingerprint(document.string ?? "")
        document.documentAttributes = attributes
        let temporary = pdf.deletingLastPathComponent().appending(path: ".source-\(UUID().uuidString).pdf")
        guard document.write(to: temporary) else { return }
        _ = try? FileManager.default.replaceItemAt(pdf, withItemAt: temporary)
    }

    /// The Markdown a PDF was made from, if it carries it and its text hasn't changed since.
    static func embeddedMarkdown(in pdf: URL) -> String? {
        // The document's info dictionary is read without touching its pages.
        guard let cg = CGPDFDocument(pdf as CFURL), let info = cg.info,
              let source = string(info, sourceKey.rawValue), let stored = string(info, fingerprintKey.rawValue),
              let text = PDFDocument(url: pdf)?.string, fingerprint(text) == stored else { return nil }
        return source
    }

    private static func string(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, key, &value), let value else { return nil }
        return CGPDFStringCopyTextString(value) as String?
    }

    /// FNV-1a over the text without whitespace (Swift's own hashing changes between launches).
    private static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 where byte > 0x20 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    // MARK: Helpers

    private static func matches(_ regex: NSRegularExpression, in text: String) -> [String] {
        let string = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: string.length)).map { string.substring(with: $0.range) }
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with transform: (String) -> String) -> String {
        let string = text as NSString
        var result = "", last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            result += string.substring(with: NSRange(location: last, length: match.range.location - last))
            result += transform(string.substring(with: match.range))
            last = match.range.location + match.range.length
        }
        return result + string.substring(from: last)
    }

    private static func removeElements(withClass name: String, in html: String) -> String {
        replaceElements(withClass: name, in: html) { _ in "" }
    }

    /// Elements (span/div/img…) whose class list includes `name`, found with their matching close tag.
    /// `transform` returning nil keeps the element.
    private static func replaceElements(withClass name: String, in html: String, transform: (Substring) -> String?) -> String {
        guard html.contains(name) else { return html }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let open = try? Regex(#"(?i)<([a-z][a-z0-9-]*)\b[^>]*\bclass\s*=\s*["'](?:[^"']*\s)?"# + escaped + #"(?:\s[^"']*)?["'][^>]*>"#) else { return html }
        return replaceBalanced(open, in: html, transform: transform)
    }

    private static func replaceElements(tag: String, in html: String, transform: (Substring) -> String?) -> String {
        guard html.range(of: "<" + tag, options: .caseInsensitive) != nil,
              let open = try? Regex("(?i)<(" + tag + #")\b[^>]*>"#) else { return html }
        return replaceBalanced(open, in: html, transform: transform)
    }

    private static let voidTags: Set<String> = ["img", "br", "hr", "input", "meta", "link", "source", "wbr"]

    static func replaceBalanced(_ open: Regex<AnyRegexOutput>, in html: String, transform: (Substring) -> String?) -> String {
        var result = ""
        var position = html.startIndex
        while let match = html[position...].firstMatch(of: open) {
            let tag = (match.output[1].substring.map(String.init) ?? "").lowercased()
            var end = match.range.upperBound
            if !voidTags.contains(tag), !html[match.range].hasSuffix("/>") {
                end = closingEnd(of: tag, in: html, from: match.range.upperBound) ?? html.endIndex
            }
            let element = html[match.range.lowerBound..<end]
            result += html[position..<match.range.lowerBound]
            result += transform(element) ?? String(element)
            position = end
        }
        return result + html[position...]
    }

    /// Where the element opened just before `start` closes, counting nested elements with the same tag.
    private static func closingEnd(of tag: String, in html: String, from start: String.Index) -> String.Index? {
        var depth = 1
        var index = start
        let openToken = "<" + tag, closeToken = "</" + tag
        while let next = html[index...].range(of: "<") {
            let rest = html[next.lowerBound...]
            if rest.prefix(closeToken.count).lowercased() == closeToken,
               let after = rest.dropFirst(closeToken.count).first, after == ">" || after.isWhitespace {
                depth -= 1
                guard let close = rest.range(of: ">") else { return nil }
                if depth == 0 { return close.upperBound }
                index = close.upperBound
            } else if rest.prefix(openToken.count).lowercased() == openToken,
                      let after = rest.dropFirst(openToken.count).first, after == " " || after == ">" || after == "\n" || after == "\t" {
                depth += 1
                index = html.index(after: next.lowerBound)
            } else {
                index = html.index(after: next.lowerBound)
            }
        }
        return nil
    }
}
