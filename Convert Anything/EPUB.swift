import AppKit

/// E-books. An EPUB is a zip of web pages, so reading one means stitching its chapters into a single HTML
/// page that the existing HTML conversions take from there, and writing one means cleaning a document's HTML
/// into XHTML, cutting it into chapters at its headings, and zipping that up with a table of contents.
nonisolated enum EPUB {
    // MARK: - EPUB → HTML

    /// Unpacks the book and joins its chapters, in reading order, into one HTML page next to it. Returns a
    /// request for converting that page, so the book can go anywhere an HTML file can.
    static func asHTMLRequest(_ request: Converter.Request) async throws -> Converter.Request {
        let folder = request.workDir.appending(path: "epub")
        do {
            try await Tools.run("/usr/bin/unzip", ["-q", "-o", request.input.path, "-d", folder.path])
        } catch ConversionError.cancelled {
            throw ConversionError.cancelled
        } catch {
            // unzip complains about harmless oddities; the book is fine as long as its index came out.
            guard FileManager.default.fileExists(atPath: folder.appending(path: "META-INF/container.xml").path) else {
                throw ConversionError.failed("Couldn't open this EPUB.")
            }
        }
        let title = request.title
        // Plain text and Markdown have no pictures, which would only show up as stray placeholder characters.
        let dropsPictures = request.to == .txt || request.to == .md
        // An HTML file has no folder to keep the pictures in, so they travel inside the page.
        let embedsPictures = request.to == .html
        let html = try await background { try joinChapters(in: folder, title: title, dropsPictures: dropsPictures, embedsPictures: embedsPictures) }
        let page = request.workDir.appending(path: "book.html")
        try html.write(to: page, atomically: true, encoding: .utf8)

        var joined = Converter.Request(input: page, from: .html, to: request.to, workDir: request.workDir,
                                       title: request.title, originalDir: request.workDir)
        joined.allPages = request.allPages
        joined.outputExtension = request.outputExtension
        joined.quality = request.quality
        return joined
    }

    private static let drmMessage = "This EPUB is protected by DRM, so it can't be converted. Only DRM-free books work."

    /// Books sold with copy protection encrypt their chapters. Fonts are often "obfuscated" even in free
    /// books, which doesn't matter here.
    private static func rejectProtectedBook(in folder: URL) throws {
        let url = folder.appending(path: "META-INF/encryption.xml")
        guard let document = try? XMLDocument(contentsOf: url, options: [.nodeLoadExternalEntitiesNever]) else { return }
        for node in (try? document.nodes(forXPath: "//*[local-name()='EncryptedData']")) ?? [] {
            let algorithm = (try? node.nodes(forXPath: ".//*[local-name()='EncryptionMethod']/@Algorithm"))?.first?.stringValue ?? ""
            let path = ((try? node.nodes(forXPath: ".//*[local-name()='CipherReference']/@URI"))?.first?.stringValue ?? "").lowercased()
            let isFont = algorithm == "http://www.idpf.org/2008/embedding" || algorithm == "http://ns.adobe.com/pdf/enc#RC"
                || [".ttf", ".otf", ".woff", ".woff2"].contains { path.hasSuffix($0) }
            if !isFont { throw ConversionError.failed(drmMessage) }
        }
    }

    /// A file inside the book, or nil when the path points outside it.
    private static func file(_ reference: String, in directory: URL, within folder: URL) -> URL? {
        let path = reference.split(whereSeparator: { $0 == "#" || $0 == "?" }).first.map(String.init) ?? ""
        guard !path.isEmpty else { return nil }
        let url = directory.appending(path: path.removingPercentEncoding ?? path).standardizedFileURL
        return url.path.hasPrefix(folder.standardizedFileURL.path + "/") ? url : nil
    }

    private static func joinChapters(in folder: URL, title: String, dropsPictures: Bool, embedsPictures: Bool) throws -> String {
        try rejectProtectedBook(in: folder)
        guard let container = try? XMLDocument(contentsOf: folder.appending(path: "META-INF/container.xml"), options: [.nodeLoadExternalEntitiesNever]),
              let rootPath = (try? container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path"))?.first?.stringValue,
              let opfURL = file(rootPath, in: folder, within: folder),
              let opf = try? XMLDocument(contentsOf: opfURL, options: [.nodeLoadExternalEntitiesNever]) else {
            throw ConversionError.failed("Couldn't read this EPUB.")
        }
        let opfDirectory = opfURL.deletingLastPathComponent()

        var manifest: [String: String] = [:]    // item id → href
        for case let item as XMLElement in (try? opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']")) ?? [] {
            if let id = item.attribute(forName: "id")?.stringValue, let href = item.attribute(forName: "href")?.stringValue { manifest[id] = href }
        }
        var chapters: [URL] = []
        for case let itemref as XMLElement in (try? opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']")) ?? [] {
            if let id = itemref.attribute(forName: "idref")?.stringValue, let href = manifest[id],
               let url = file(href, in: opfDirectory, within: folder), !chapters.contains(url) { chapters.append(url) }
        }
        guard !chapters.isEmpty else { throw ConversionError.failed("This EPUB has no readable text.") }
        let chapterNumbers = Dictionary(uniqueKeysWithValues: chapters.enumerated().map { ($1.path, $0) })

        var styles = ""
        var seenStyles = Set<String>()
        var body = ""
        for (number, url) in chapters.enumerated() {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else { continue }
            var (head, content) = split(text)
            if dropsPictures {
                content = content.replacing(/<svg\b.*?<\/svg>/.dotMatchesNewlines(), with: "").replacing(/<img\b[^>]*>/.ignoresCase(), with: "")
                head = ""
            }
            styles += stylesheets(in: head, directory: url.deletingLastPathComponent(), folder: folder, seen: &seenStyles)
            body += "<div class=\"epub-doc\" id=\"c\(number)\">\n"
                + rewriteLinks(in: expandEmptyTags(content), directory: url.deletingLastPathComponent(), folder: folder,
                               chapter: number, chapterNumbers: chapterNumbers, embedsPictures: embedsPictures)
                + "\n</div>\n"
        }
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(escapeHTML(title))</title>
        <style>
        \(styles)
        .epub-doc { page-break-before: always; break-before: page; }
        .epub-doc:first-child { page-break-before: auto; break-before: auto; }
        img, svg { max-width: 100%; height: auto; }
        </style></head>
        <body>
        \(body)
        </body></html>
        """
    }

    /// The part of an XHTML file before its <body> and what's inside the body.
    private static func split(_ text: String) -> (head: String, body: String) {
        guard let open = text.range(of: "<body", options: .caseInsensitive),
              let openEnd = text.range(of: ">", range: open.upperBound..<text.endIndex) else { return ("", text) }
        let close = text.range(of: "</body>", options: [.caseInsensitive, .backwards]) ?? (text.endIndex..<text.endIndex)
        let end = max(close.lowerBound, openEnd.upperBound)
        return (String(text[..<open.lowerBound]), String(text[openEnd.upperBound..<end]))
    }

    /// The book's own styling, so the page looks like the book. Page-level rules (@page, fonts) are dropped.
    private static func stylesheets(in head: String, directory: URL, folder: URL, seen: inout Set<String>) -> String {
        var result = ""
        for match in head.matches(of: /<link\b[^>]*>/.ignoresCase()) {
            let tag = String(match.output)
            guard tag.lowercased().contains("stylesheet"),
                  let href = tag.firstMatch(of: /href\s*=\s*["']([^"']+)["']/.ignoresCase())?.1,
                  let url = file(String(href), in: directory, within: folder), seen.insert(url.path).inserted,
                  let css = try? String(contentsOf: url, encoding: .utf8) else { continue }
            result += cleanedCSS(css) + "\n"
        }
        for match in head.matches(of: /<style\b[^>]*>(.*?)<\/style>/.ignoresCase().dotMatchesNewlines()) {
            result += cleanedCSS(String(match.output.1)) + "\n"
        }
        return result
    }

    private static func cleanedCSS(_ css: String) -> String {
        css.replacing(/@(font-face|page)[^{}]*\{[^{}]*\}/.ignoresCase().dotMatchesNewlines(), with: "")
            .replacing(/@(import|namespace)[^;]*;/.ignoresCase(), with: "")
            .replacing(/<\/style/.ignoresCase(), with: "")
    }

    fileprivate static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]

    /// XHTML writes empty elements as <a id="x"/>, which HTML takes as an opening tag and wraps everything after it.
    private static func expandEmptyTags(_ text: String) -> String {
        guard text.contains("/>") else { return text }
        return text.replacing(/<([A-Za-z][A-Za-z0-9:-]*)((?:\s[^<>]*?)?)\s*\/>/) { match in
            let name = String(match.1)
            if voidElements.contains(name.lowercased()) { return String(match.0) }
            return "<\(name)\(match.2)></\(name)>"
        }
    }

    /// Makes one chapter's ids and links work once all chapters share a page: ids are prefixed with the chapter
    /// number, links to other chapters become links within the page, and image paths point into the unzipped book.
    private static let attributePattern = try! NSRegularExpression(pattern: #"(\s)(srcset|src|href|xlink:href|id|name)\s*=\s*("[^"]*"|'[^']*')"#)

    /// The picture as a data: address, so the page doesn't depend on files next to it.
    private static func embeddedPicture(_ url: URL) -> String? {
        let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "svg": "image/svg+xml", "webp": "image/webp"]
        guard let type = types[url.pathExtension.lowercased()], let data = try? Data(contentsOf: url) else { return nil }
        return "data:\(type);base64," + data.base64EncodedString()
    }

    private static func rewriteLinks(in text: String, directory: URL, folder: URL, chapter: Int, chapterNumbers: [String: Int], embedsPictures: Bool) -> String {
        let string = text as NSString
        var result = ""
        var last = 0
        for match in attributePattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            result += string.substring(with: NSRange(location: last, length: match.range.location - last))
            last = match.range.location + match.range.length
            let name = string.substring(with: match.range(at: 2))
            let quoted = string.substring(with: match.range(at: 3))
            let value = String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "&amp;", with: "&")
            let space = string.substring(with: match.range(at: 1))

            func attribute(_ newValue: String) -> String {
                space + name + "=\"" + escapeHTML(newValue) + "\""
            }
            if name == "srcset" {
                continue                // Alternative picture sizes; the plain src is enough
            } else if name == "id" || name == "name" {
                result += attribute("c\(chapter)-\(value)")
            } else if value.isEmpty || value.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil {
                result += space + name + "=" + quoted        // http:, mailto:, data: and so on stay as they are
            } else if value.hasPrefix("#") {
                result += attribute("#c\(chapter)-\(value.dropFirst())")
            } else if let url = file(value, in: directory, within: folder) {
                let fragment = value.firstIndex(of: "#").map { String(value[value.index(after: $0)...]) }
                if let other = chapterNumbers[url.path] {
                    result += attribute(fragment.map { "#c\(other)-\($0)" } ?? "#c\(other)")
                } else if embedsPictures, name != "href", let picture = embeddedPicture(url) {
                    result += attribute(picture)
                } else {
                    let relative = String(url.path.dropFirst(folder.standardizedFileURL.path.count + 1))
                    let encoded = relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?
                        .replacingOccurrences(of: "&", with: "%26") ?? relative
                    result += attribute("epub/" + encoded)
                }
            } else {
                result += attribute("")                      // Points outside the book
            }
        }
        return result + string.substring(from: last)
    }

    // MARK: - Documents → EPUB

    private struct Source: Sendable {
        let html: String
        let base: URL       // Where the HTML's relative image paths start
    }

    static func write(_ request: Converter.Request, from: Format, input: URL, output: URL) async throws {
        let source = try await source(request, from: from, input: input)
        let package = request.workDir.appending(path: "epub-out")
        let title = request.title
        let language = Locale.current.identifier(.bcp47)
        let quality = request.quality
        try await background {
            try Packager(source: source, title: title, language: language, quality: quality, folder: package).build()
        }
        // The mimetype file must come first and stay uncompressed so readers can recognize the book without unzipping it.
        try await Tools.run("/usr/bin/zip", ["-q", "-X0", output.path, "mimetype"], currentDirectory: package)
        try await Tools.run("/usr/bin/zip", ["-q", "-n", ".png:.jpg:.jpeg:.gif", "-Xr9D", output.path, "META-INF", "OEBPS"], currentDirectory: package)
    }

    private static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
            throw ConversionError.failed("Couldn't read this text file.")
        }
        return text
    }

    private static func paragraphs(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "<p>\(escapeHTML($0).replacingOccurrences(of: "\n", with: "<br/>"))</p>" }.joined(separator: "\n")
    }

    private static func source(_ request: Converter.Request, from: Format, input: URL) async throws -> Source {
        switch from {
        case .md:
            let markdown = try readText(input)
            let html = await Task.detached(priority: .utility) {
                Markdown.$mathOutput.withValue(.mathML) { Markdown.html(from: markdown) }
            }.value
            return Source(html: html, base: request.originalDir)
        case .html:
            return Source(html: try readText(input), base: request.originalDir)
        case .txt:
            return Source(html: paragraphs(try readText(input)), base: request.originalDir)
        case .pdf:
            return Source(html: paragraphs(try await DocumentConversion.extractPDFText(input)), base: request.originalDir)
        case .docx:
            return try await wordSource(input, workDir: request.workDir)
        default:
            // Old Word, RTF and OpenDocument are read by macOS's text system, which keeps lists, tables and links
            // but not heading styles; the Markdown writer already works out headings from the font sizes.
            let text = try NSAttributedString(url: input, options: [:], documentAttributes: nil)
            let markdown = Markdown.markdown(from: text)
            let html = await Task.detached(priority: .utility) { Markdown.html(from: markdown) }.value
            return Source(html: html, base: request.originalDir)
        }
    }

    private static func wordSource(_ docx: URL, workDir: URL) async throws -> Source {
        let folder = workDir.appending(path: "docx")
        try await Tools.run("/usr/bin/unzip", ["-q", "-o", docx.path, "word/*", "-d", folder.path])
        let html = try await background { () throws -> String in
            var reader = WordToHTML(folder: folder)
            return try reader.html()
        }
        return Source(html: html, base: folder)
    }

    /// Builds the unzipped book on disk: cleans the HTML into XHTML, cuts it into chapters, gathers the images
    /// and writes the package, contents and styling.
    private final class Packager {
        let source: Source
        let title: String
        let language: String
        let quality: Quality
        let folder: URL

        private var images: [String: String] = [:]      // Source path → file name in images/
        private var imageTypes: [String: String] = [:]  // File name → media type
        private var anchorLinks: [(element: XMLElement, id: String)] = []
        private var mathBlocks: [String] = []           // MathML set aside while the HTML reader (which would flatten it) runs

        init(source: Source, title: String, language: String, quality: Quality, folder: URL) {
            self.source = source
            self.title = title
            self.language = language
            self.quality = quality
            self.folder = folder
        }

        private struct Entry { var title: String; var file: String; var anchor: String? }

        private struct Chapter {
            var nodes: [XMLNode] = []
            var title: String?
            var subheadings: [Entry] = []
        }

        func build() throws {
            let fileManager = FileManager.default
            let content = folder.appending(path: "OEBPS")
            try fileManager.createDirectory(at: content.appending(path: "images"), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: folder.appending(path: "META-INF"), withIntermediateDirectories: true)

            let body = try parse(source.html)
            clean(body)

            var chapters = split(Self.hoistingHeadings(body.children ?? []))
            // Ids may move to another chapter, so internal links are pointed at wherever their target ended up.
            var homes: [String: Int] = [:]
            for (number, chapter) in chapters.enumerated() {
                for node in chapter.nodes { collectIDs(node, chapter: number, into: &homes) }
            }
            for link in anchorLinks {
                if let number = homes[link.id] {
                    link.element.addAttribute(XMLNode.attribute(withName: "href", stringValue: "\(Self.fileName(number))#\(link.id)") as! XMLNode)
                } else {
                    link.element.removeAttribute(forName: "href")
                }
            }

            var manifest = "", spine = ""
            for number in chapters.indices {
                var xhtml = ""
                chapters[number].nodes.forEach { Self.serialize($0, into: &xhtml) }
                if !mathBlocks.isEmpty {
                    xhtml = xhtml.replacing(/<span id="zzmath(\d+)"><\/span>/) { mathBlocks[Int($0.1) ?? 0] }
                }
                let hasMath = xhtml.contains("<math")
                let name = Self.fileName(number)
                try """
                <?xml version="1.0" encoding="utf-8"?>
                <!DOCTYPE html>
                <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(language)" xml:lang="\(language)">
                <head><meta charset="utf-8"/><title>\(escapeHTML(chapters[number].title ?? title))</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
                <body>
                \(xhtml)
                </body>
                </html>
                """.write(to: content.appending(path: name), atomically: false, encoding: .utf8)
                manifest += "<item id=\"c\(number)\" href=\"\(name)\" media-type=\"application/xhtml+xml\"\(hasMath ? " properties=\"mathml\"" : "")/>\n"
                spine += "<itemref idref=\"c\(number)\"/>\n"
                chapters[number].title = chapters[number].title ?? title
            }
            for (name, type) in imageTypes.sorted(by: { $0.key < $1.key }) {
                manifest += "<item id=\"\(name.replacingOccurrences(of: ".", with: "-"))\" href=\"images/\(name)\" media-type=\"\(type)\"/>\n"
            }

            try writePackage(content: content, chapters: chapters, manifest: manifest, spine: spine)
        }

        private static func fileName(_ chapter: Int) -> String { String(format: "chapter-%03d.xhtml", chapter + 1) }

        /// Writes a node as XHTML. The HTML reader's own serializer doesn't produce XML (it leaves <br> open),
        /// so this one does: void elements close themselves, everything else gets an end tag.
        private static func serialize(_ node: XMLNode, into out: inout String) {
            if node.kind == .text {
                out += escapeHTML(node.stringValue ?? "").replacingOccurrences(of: "&quot;", with: "\"")
            } else if let element = node as? XMLElement, let name = element.name?.lowercased() {
                guard allowed.contains(name) else {     // Tags a book can't use (<font>, <center>…) are left out, their contents kept
                    for child in element.children ?? [] { serialize(child, into: &out) }
                    return
                }
                out += "<" + name
                for attribute in element.attributes ?? [] {
                    if let key = attribute.name { out += " \(key)=\"\(escapeHTML(attribute.stringValue ?? ""))\"" }
                }
                if EPUB.voidElements.contains(name) { out += "/>"; return }
                out += ">"
                for child in element.children ?? [] { serialize(child, into: &out) }
                out += "</\(name)>"
            }
        }

        /// XML refuses most control characters, which turn up in text files and pasted documents.
        private static func removeInvalidCharacters(_ text: String) -> String {
            guard text.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" && $0 != "\n" && $0 != "\r" || $0.value == 0xFFFE || $0.value == 0xFFFF }) else { return text }
            var scalars = String.UnicodeScalarView()
            for scalar in text.unicodeScalars where !(scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r") && scalar.value != 0xFFFE && scalar.value != 0xFFFF {
                scalars.append(scalar)
            }
            return String(scalars)
        }

        // MARK: Parsing and cleaning

        private func parse(_ html: String) throws -> XMLElement {
            // The charset line goes first because the HTML reader would otherwise guess the encoding.
            // Equations are lifted out first: the HTML reader doesn't know MathML and would keep only the text.
            let withoutMath = Self.removeInvalidCharacters(html).replacing(/<math\b.*?<\/math>/.dotMatchesNewlines()) { match -> String in
                var block = String(match.0)
                guard (try? XMLDocument(xmlString: block, options: [])) != nil else { return block }
                if !block.contains("xmlns=") { block = "<math xmlns=\"http://www.w3.org/1998/Math/MathML\"" + block.dropFirst(5) }
                mathBlocks.append(block)
                return "<span id=\"zzmath\(mathBlocks.count - 1)\"></span>"
            }
            let page = "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">"
                + withoutMath.replacing(/<meta\b[^>]*charset[^>]*>/.ignoresCase(), with: "")
            guard let document = try? XMLDocument(data: Data(page.utf8), options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
                  let html = document.rootElement() else {
                throw ConversionError.failed("Couldn't read this document.")
            }
            return html.elements(forName: "body").first ?? html
        }

        /// What a reader may show: these stay, other tags are replaced by their contents.
        private static let allowed: Set<String> = [
            "a", "abbr", "address", "article", "aside", "b", "bdi", "bdo", "blockquote", "br", "caption", "cite", "code", "col",
            "colgroup", "dd", "del", "details", "dfn", "div", "dl", "dt", "em", "figcaption", "figure", "footer", "h1", "h2", "h3",
            "h4", "h5", "h6", "header", "hr", "i", "img", "ins", "kbd", "li", "main", "mark", "ol", "p", "pre", "q", "rp", "rt",
            "ruby", "s", "samp", "section", "small", "span", "strong", "sub", "summary", "sup", "table", "tbody", "td", "tfoot",
            "th", "thead", "time", "tr", "u", "ul", "var", "wbr",
        ]
        private static let dropped: Set<String> = [
            "script", "style", "link", "meta", "noscript", "iframe", "object", "embed", "canvas", "video", "audio", "template",
            "svg", "head", "title", "base", "input", "button", "select", "textarea", "map", "applet",
        ]
        private static let keptAttributes: Set<String> = [
            "id", "href", "src", "alt", "title", "colspan", "rowspan", "lang", "xml:lang", "dir", "start", "headers", "scope", "datetime", "cite",
        ]

        private func clean(_ element: XMLElement) {
            for child in element.children ?? [] {
                guard child.kind == .element, let node = child as? XMLElement else {
                    if child.kind != .text { child.detach() }       // Comments and the like
                    continue
                }
                let name = node.name?.lowercased() ?? ""
                if Self.dropped.contains(name) { node.detach(); continue }
                if name == "img" { image(node); continue }
                clean(node)
                if Self.allowed.contains(name) { cleanAttributes(node, name: name) }
            }
        }

        private func cleanAttributes(_ element: XMLElement, name: String) {
            for attribute in element.attributes ?? [] {
                let key = attribute.name?.lowercased() ?? ""
                if key == "name", name == "a", element.attribute(forName: "id") == nil, let value = attribute.stringValue, !value.isEmpty {
                    element.addAttribute(XMLNode.attribute(withName: "id", stringValue: value) as! XMLNode)
                }
                if !Self.keptAttributes.contains(key) { attribute.detach() }
            }
            guard name == "a", let href = element.attribute(forName: "href")?.stringValue else { return }
            if href.hasPrefix("#") {
                anchorLinks.append((element, String(href.dropFirst())))
                element.removeAttribute(forName: "href")        // Set again once the target's chapter is known
            } else if href.range(of: #"^(https?|mailto|tel):"#, options: [.regularExpression, .caseInsensitive]) == nil {
                element.removeAttribute(forName: "href")        // A page or script that doesn't exist in a book
            }
        }

        private func collectIDs(_ node: XMLNode, chapter: Int, into homes: inout [String: Int]) {
            guard let element = node as? XMLElement else { return }
            if let id = element.attribute(forName: "id")?.stringValue, homes[id] == nil { homes[id] = chapter }
            for child in element.children ?? [] { collectIDs(child, chapter: chapter, into: &homes) }
        }

        // MARK: Chapters

        /// Chapters start at the top-level headings: h1, or h2 when the page has a single h1 (its title).
        private func split(_ children: [XMLNode]) -> [Chapter] {
            func level(_ node: XMLNode) -> Int? {
                guard let name = (node as? XMLElement)?.name?.lowercased(), name.count == 2, name.first == "h",
                      let number = Int(name.dropFirst()), (1...6).contains(number) else { return nil }
                return number
            }
            var counts = [Int](repeating: 0, count: 7)
            children.forEach { if let level = level($0) { counts[level] += 1 } }
            let splitLevel = counts[1] >= 2 ? 1 : (2...6).first { counts[$0] > 0 }

            var chapters: [Chapter] = []
            var current = Chapter()
            var anchorNumber = 0
            func finish() {
                let isBlank = current.nodes.allSatisfy { $0.kind == .text && ($0.stringValue ?? "").allSatisfy(\.isWhitespace) }
                if !isBlank { chapters.append(current) }
                current = Chapter()
            }
            for node in children {
                if let splitLevel, level(node) == splitLevel {
                    finish()
                    current.title = Self.text(of: node)
                } else if let splitLevel, splitLevel < 6, level(node) == splitLevel + 1, let element = node as? XMLElement {
                    // The next level down gets an entry of its own inside the chapter's entry.
                    var id = element.attribute(forName: "id")?.stringValue
                    if id == nil {
                        anchorNumber += 1
                        id = "section-\(anchorNumber)"
                        element.addAttribute(XMLNode.attribute(withName: "id", stringValue: id!) as! XMLNode)
                    }
                    current.subheadings.append(Entry(title: Self.text(of: node), file: "", anchor: id))
                }
                current.nodes.append(node)
            }
            finish()
            if chapters.isEmpty { chapters = [Chapter(nodes: children)] }

            // Text before the first heading (a title and an introduction, say) is named after its own heading.
            for number in chapters.indices where chapters[number].title == nil {
                chapters[number].title = chapters[number].nodes.lazy.filter { level($0) != nil }.map(Self.text).first(where: { !$0.isEmpty })
            }
            chapters = chapters.map { var chapter = $0; if chapter.title?.isEmpty == true { chapter.title = nil }; return chapter }
            return chapters
        }

        /// Pages often wrap their chapters in containers (a div around everything, a section per chapter). Those that
        /// hold headings are replaced by their contents, so the headings become top-level. Nothing is moved in the
        /// tree, which would be slow for a long page; the nodes are just listed in reading order.
        private static func hoistingHeadings(_ nodes: [XMLNode], depth: Int = 0) -> [XMLNode] {
            let wrappers: Set<String> = ["div", "section", "article", "main"]
            func containsHeading(_ element: XMLElement) -> Bool {
                (element.children ?? []).contains { child in
                    guard let child = child as? XMLElement, let name = child.name?.lowercased() else { return false }
                    return (name.count == 2 && name.first == "h" && name.last?.isNumber == true) || containsHeading(child)
                }
            }
            return nodes.flatMap { node -> [XMLNode] in
                guard depth < 8, let element = node as? XMLElement, wrappers.contains(element.name?.lowercased() ?? ""),
                      containsHeading(element) else { return [node] }
                return hoistingHeadings(element.children ?? [], depth: depth + 1)
            }
        }

        private static func text(of node: XMLNode) -> String {
            (node.stringValue ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        // MARK: Images

        private func image(_ element: XMLElement) {
            let alt = element.attribute(forName: "alt")?.stringValue ?? ""
            let name = element.attribute(forName: "src")?.stringValue.flatMap(importImage)
            guard let name else {
                // Remote and missing pictures can't go in the book; their description stays.
                if alt.isEmpty {
                    element.detach()
                } else {
                    for attribute in element.attributes ?? [] { attribute.detach() }
                    element.name = "span"
                    element.stringValue = alt
                }
                return
            }
            for attribute in element.attributes ?? [] { attribute.detach() }
            element.addAttribute(XMLNode.attribute(withName: "src", stringValue: "images/\(name)") as! XMLNode)
            element.addAttribute(XMLNode.attribute(withName: "alt", stringValue: alt) as! XMLNode)
        }

        /// Copies a picture into the book and returns its file name there. Formats readers can't show are converted.
        private func importImage(_ reference: String) -> String? {
            let fileManager = FileManager.default
            var url: URL
            let lowercased = reference.lowercased()
            if lowercased.hasPrefix("data:") {
                guard let comma = reference.firstIndex(of: ",") else { return nil }
                let header = reference[..<comma].lowercased()
                let payload = String(reference[reference.index(after: comma)...])
                let data = header.contains(";base64") ? Data(base64Encoded: payload, options: .ignoreUnknownCharacters) : payload.removingPercentEncoding.map { Data($0.utf8) }
                guard let data, !data.isEmpty else { return nil }
                let ext = header.contains("svg") ? "svg" : "img"
                url = folder.appending(path: "embedded-\(images.count).\(ext)")
                guard (try? data.write(to: url)) != nil else { return nil }
            } else if lowercased.hasPrefix("file:") {
                guard let path = URL(string: reference)?.path else { return nil }
                url = URL(fileURLWithPath: path)
            } else if lowercased.range(of: #"^[a-z][a-z0-9+.-]*:"#, options: .regularExpression) != nil || lowercased.hasPrefix("//") {
                return nil          // http(s): and other remote pictures
            } else {
                let path = reference.split(whereSeparator: { $0 == "#" || $0 == "?" }).first.map(String.init) ?? ""
                guard !path.isEmpty else { return nil }
                let decoded = path.removingPercentEncoding ?? path
                url = decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded) : source.base.appending(path: decoded).standardizedFileURL
            }
            var isFolder: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { return nil }
            if let existing = images[url.path] { return existing }

            let number = images.count + 1
            let images = folder.appending(path: "OEBPS/images")
            func install(_ ext: String, _ type: String, convertTo format: Format? = nil) -> String? {
                let name = "image-\(number).\(ext)"
                let destination = images.appending(path: name)
                do {
                    if let format {
                        try ImageConversion.convert(url, to: format, output: destination, quality: quality)
                    } else {
                        try fileManager.copyItem(at: url, to: destination)
                    }
                } catch { return nil }
                imageTypes[name] = type
                return name
            }
            var name: String?
            if url.pathExtension.lowercased() == "svg" {
                name = install("svg", "image/svg+xml")
            } else {
                switch Sniffer.detect(url) {
                case .format(.png): name = install("png", "image/png")
                case .format(.jpeg): name = install("jpg", "image/jpeg")
                case .format(.gif): name = install("gif", "image/gif")
                case .format(.heic), .format(.tiff), .format(.bmp), .format(.avif): name = install("jpg", "image/jpeg", convertTo: .jpeg)
                case .format(.webp), .format(.ico): name = install("png", "image/png", convertTo: .png)
                default: name = nil
                }
            }
            if lowercased.hasPrefix("data:") { try? fileManager.removeItem(at: url) }
            if let name { self.images[url.path] = name }
            return name
        }

        // MARK: Package files

        private func writePackage(content: URL, chapters: [Chapter], manifest: String, spine: String) throws {
            let identifier = "urn:uuid:" + UUID().uuidString
            let modified = ISO8601DateFormatter().string(from: Date())
            let bookTitle = escapeHTML(title)

            try "application/epub+zip".write(to: folder.appending(path: "mimetype"), atomically: false, encoding: .ascii)
            try """
            <?xml version="1.0" encoding="utf-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.write(to: folder.appending(path: "META-INF/container.xml"), atomically: false, encoding: .utf8)

            try """
            <?xml version="1.0" encoding="utf-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id" xml:lang="\(language)">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="book-id">\(identifier)</dc:identifier>
            <dc:title>\(bookTitle)</dc:title>
            <dc:language>\(language)</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
            </metadata>
            <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="style" href="style.css" media-type="text/css"/>
            \(manifest)</manifest>
            <spine toc="ncx">
            \(spine)</spine>
            </package>
            """.write(to: content.appending(path: "content.opf"), atomically: false, encoding: .utf8)

            // The contents, for EPUB 3 readers (nav) and for older ones (NCX).
            var list = "", points = ""
            var order = 0
            for (number, chapter) in chapters.enumerated() {
                let file = Self.fileName(number)
                let name = escapeHTML(chapter.title ?? title)
                order += 1
                var nested = "", nestedPoints = ""
                for sub in chapter.subheadings {
                    nested += "<li><a href=\"\(file)#\(escapeHTML(sub.anchor ?? ""))\">\(escapeHTML(sub.title))</a></li>"
                    order += 1
                    nestedPoints += "<navPoint id=\"p\(order)\" playOrder=\"\(order)\"><navLabel><text>\(escapeHTML(sub.title))</text></navLabel><content src=\"\(file)#\(escapeHTML(sub.anchor ?? ""))\"/></navPoint>\n"
                }
                list += "<li><a href=\"\(file)\">\(name)</a>" + (nested.isEmpty ? "" : "<ol>\(nested)</ol>") + "</li>\n"
                points += "<navPoint id=\"c\(number)\" playOrder=\"\(order - chapter.subheadings.count)\"><navLabel><text>\(name)</text></navLabel><content src=\"\(file)\"/>\n\(nestedPoints)</navPoint>\n"
            }
            try """
            <?xml version="1.0" encoding="utf-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(language)" xml:lang="\(language)">
            <head><meta charset="utf-8"/><title>\(bookTitle)</title></head>
            <body>
            <nav epub:type="toc" id="toc"><h1>Contents</h1>
            <ol>
            \(list)</ol>
            </nav>
            </body>
            </html>
            """.write(to: content.appending(path: "nav.xhtml"), atomically: false, encoding: .utf8)

            try """
            <?xml version="1.0" encoding="utf-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1" xml:lang="\(language)">
            <head><meta name="dtb:uid" content="\(identifier)"/><meta name="dtb:depth" content="2"/><meta name="dtb:totalPageCount" content="0"/><meta name="dtb:maxPageNumber" content="0"/></head>
            <docTitle><text>\(bookTitle)</text></docTitle>
            <navMap>
            \(points)</navMap>
            </ncx>
            """.write(to: content.appending(path: "toc.ncx"), atomically: false, encoding: .utf8)

            // Plain styling only: readers apply the reader's own font and size.
            try """
            body { line-height: 1.4; }
            img { max-width: 100%; height: auto; }
            pre { white-space: pre-wrap; font-family: monospace; font-size: 0.9em; }
            blockquote { margin: 1em 2em; }
            table { border-collapse: collapse; }
            td, th { border: 1px solid #999; padding: 0.2em 0.5em; }
            p.math { text-align: center; }
            h1, h2, h3, h4 { page-break-after: avoid; }
            """.write(to: content.appending(path: "style.css"), atomically: false, encoding: .utf8)
        }
    }
}
