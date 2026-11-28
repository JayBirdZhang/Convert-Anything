import Foundation

/// OpenDocument presentations (.odp) → PDF without any other app. Keynote and Quick Look can't open them, so each
/// slide becomes a page of absolutely positioned HTML (text with its styles, pictures, shapes, tables, the
/// background and the master's decorations), and the web engine prints one slide per PDF page. Images and
/// PowerPoint are made from that PDF by the routes the other presentations use. Notes, animations, charts and
/// complex shape outlines aren't drawn.
enum OpenDocumentSlides {
    static func renderPDF(_ input: URL, workDir: URL, output: URL) async throws {
        let package = workDir.appending(path: "odp")
        try await Tools.run("/usr/bin/unzip", ["-q", "-o", input.path, "-d", package.path])
        let page = package.appending(path: "convert-anything-slides.html")
        let size = try await background { () throws -> CGSize in
            guard let content = try? XMLDocument(contentsOf: package.appending(path: "content.xml"), options: [.nodeLoadExternalEntitiesNever]) else {
                throw ConversionError.failed("Couldn't read this presentation.")
            }
            let styles = try? XMLDocument(contentsOf: package.appending(path: "styles.xml"), options: [.nodeLoadExternalEntitiesNever])
            let builder = ODPBuilder(content: content, styles: styles)
            let html = builder.html()
            guard builder.slideCount > 0 else { throw ConversionError.failed("This presentation has no slides.") }
            try html.write(to: page, atomically: true, encoding: .utf8)
            return builder.pageSize
        }
        try await WebPDF.render(html: "", baseURL: package, output: output, page: size, margin: 0, file: page)
    }
}

nonisolated private final class ODPBuilder {
    private(set) var slideCount = 0
    private(set) var pageSize = CGSize(width: 793.7, height: 446.5)   // LibreOffice's 28 × 15.75 cm

    private let content: XMLElement?
    private let stylesRoot: XMLElement?
    // Automatic styles are private to their file and their names repeat, so slides and masters look styles up separately.
    private var slideStyles: [String: XMLElement] = [:]
    private var masterStyles: [String: XMLElement] = [:]
    private var commonStyles: [String: XMLElement] = [:]
    private var defaults: [String: XMLElement] = [:]
    private var fonts: [String: String] = [:]                // font-face name → CSS font list
    private var fillImages: [String: String] = [:], gradients: [String: XMLElement] = [:]
    private var masters: [String: XMLElement] = [:]
    private var layouts: [String: CGSize] = [:]
    private var footers: [String: String] = [:], dates: [String: String] = [:]

    // While writing one slide
    private var masterScope = false
    private var slideNumber = 0
    private var footerText = "", dateText = ""

    init(content: XMLDocument, styles: XMLDocument?) {
        self.content = content.rootElement()
        stylesRoot = styles?.rootElement()
        for root in [stylesRoot, self.content].compactMap({ $0 }) {
            for decls in root.elements(forName: "office:font-face-decls") {
                for face in decls.elements(forName: "style:font-face") {
                    guard let name = face["style:name"] else { continue }
                    let family = Self.safe(face["svg:font-family"] ?? name)
                    let generic = ["roman": "Times, serif", "swiss": "Helvetica, sans-serif", "modern": "Menlo, monospace",
                                   "script": "cursive", "decorative": "fantasy"][face["style:font-family-generic"] ?? ""] ?? "Helvetica, sans-serif"
                    fonts[name] = "'\(family)', \(generic)"
                }
            }
        }
        func collect(_ container: XMLElement?, into table: inout [String: XMLElement]) {
            for element in container?.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                if element.name == "style:style" || element.name == "text:list-style", let name = element["style:name"] {
                    table[(element["style:family"] ?? "list") + ":" + name] = element
                }
            }
        }
        collect(self.content?.elements(forName: "office:automatic-styles").first, into: &slideStyles)
        collect(stylesRoot?.elements(forName: "office:automatic-styles").first, into: &masterStyles)
        let common = stylesRoot?.elements(forName: "office:styles").first
        collect(common, into: &commonStyles)
        for element in common?.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            switch element.name {
            case "style:default-style": if let family = element["style:family"] { defaults[family] = element }
            case "draw:fill-image": if let name = element["draw:name"], let href = Self.packagePath(element["xlink:href"]) { fillImages[name] = href }
            case "draw:gradient": if let name = element["draw:name"] { gradients[name] = element }
            default: break
            }
        }
        for layout in stylesRoot?.elements(forName: "office:automatic-styles").first?.elements(forName: "style:page-layout") ?? [] {
            if let name = layout["style:name"], let properties = layout.elements(forName: "style:page-layout-properties").first,
               let width = Self.points(properties["fo:page-width"]), let height = Self.points(properties["fo:page-height"]) {
                layouts[name] = CGSize(width: width, height: height)
            }
        }
        for master in stylesRoot?.elements(forName: "office:master-styles").first?.elements(forName: "style:master-page") ?? [] {
            if let name = master["style:name"] { masters[name] = master }
        }
    }

    // MARK: Styles

    /// The style and its parents, most general first, with the family's default style at the root.
    private func chain(_ family: String, _ name: String?) -> [XMLElement] {
        var result: [XMLElement] = []
        var next = name
        var seen = Set<String>()
        while let current = next, !seen.contains(current) {
            seen.insert(current)
            let key = family + ":" + current
            guard let style = (masterScope ? masterStyles[key] : slideStyles[key]) ?? commonStyles[key] else { break }
            result.insert(style, at: 0)
            next = style["style:parent-style-name"]
        }
        if let base = defaults[family == "presentation" ? "graphic" : family] { result.insert(base, at: 0) }
        return result
    }

    /// One kind of properties (graphic, paragraph, text…) merged down the style's chain.
    private func properties(_ kind: String, _ family: String, _ name: String?) -> [String: String] {
        var merged: [String: String] = [:]
        for style in chain(family, name) {
            // LibreOffice keeps some (table cell fills) in its own namespace.
            for element in style.elements(forName: "style:\(kind)-properties") + style.elements(forName: "loext:\(kind)-properties") {
                for attribute in element.attributes ?? [] { if let key = attribute.name { merged[key] = attribute.stringValue ?? "" } }
            }
        }
        return merged
    }

    private func list(_ name: String) -> XMLElement? {
        (masterScope ? masterStyles["list:" + name] : slideStyles["list:" + name]) ?? commonStyles["list:" + name]
    }

    // MARK: CSS

    static func points(_ value: String?) -> Double? {
        guard let value, let match = value.wholeMatch(of: /\s*(-?[\d.]+)\s*(cm|mm|in|pt|pc|px)?\s*/), let number = Double(match.1) else { return nil }
        switch match.2 {
        case "cm": return number * 72 / 2.54
        case "mm": return number * 72 / 25.4
        case "in": return number * 72
        case "pc": return number * 12
        case "px": return number * 0.75
        default: return number
        }
    }

    private static func pt(_ value: Double) -> String { String(format: "%.2fpt", value) }

    private func textCSS(_ p: [String: String]) -> String {
        var css = ""
        if let size = p["fo:font-size"] { css += "font-size:\(size.hasSuffix("%") ? Self.safe(size) : Self.points(size).map(Self.pt) ?? "inherit");" }
        if let weight = p["fo:font-weight"] { css += "font-weight:\(Self.safe(weight));" }
        if let style = p["fo:font-style"] { css += "font-style:\(style == "oblique" ? "italic" : Self.safe(style));" }
        if let color = p["fo:color"], p["style:use-window-font-color"] != "true" { css += "color:\(Self.safe(color));" }
        if let name = p["style:font-name"], let family = fonts[name] { css += "font-family:\(family);" }
        else if let family = p["fo:font-family"] { css += "font-family:'\(Self.safe(family))', Helvetica, sans-serif;" }
        var decorations: [String] = []
        if let underline = p["style:text-underline-style"], underline != "none" { decorations.append("underline") }
        if let strike = p["style:text-line-through-style"], strike != "none" { decorations.append("line-through") }
        if !decorations.isEmpty { css += "text-decoration:\(decorations.joined(separator: " "));" }
        if let position = p["style:text-position"], position != "0%" && position != "0% 100%" {
            css += position.hasPrefix("sub") || position.hasPrefix("-") ? "vertical-align:sub;font-size:smaller;" : "vertical-align:super;font-size:smaller;"
        }
        if p["fo:font-variant"] == "small-caps" { css += "font-variant:small-caps;" }
        if let transform = p["fo:text-transform"], transform != "none" { css += "text-transform:\(Self.safe(transform));" }
        if let shadow = p["fo:text-shadow"], shadow != "none" { css += "text-shadow:1pt 1pt 1pt rgba(0,0,0,.4);" }
        if let spacing = p["fo:letter-spacing"], let value = Self.points(spacing) { css += "letter-spacing:\(Self.pt(value));" }
        if let background = p["fo:background-color"], background != "transparent" { css += "background-color:\(Self.safe(background));" }
        return css
    }

    private func paragraphCSS(_ p: [String: String]) -> String {
        var css = ""
        if let align = p["fo:text-align"] {
            css += "text-align:\(["start": "left", "end": "right", "left": "left", "right": "right", "center": "center", "justify": "justify"][align] ?? "left");"
        }
        for side in ["left", "right", "top", "bottom"] {
            if let value = Self.points(p["fo:margin-\(side)"]) { css += "margin-\(side):\(Self.pt(value));" }
        }
        if let indent = Self.points(p["fo:text-indent"]) { css += "text-indent:\(Self.pt(indent));" }
        if let height = p["fo:line-height"] {
            if height.hasSuffix("%"), let percent = Double(height.dropLast()) { css += "line-height:\(percent / 100 * 1.17);" }
            else if let value = Self.points(height) { css += "line-height:\(Self.pt(value));" }
        }
        return css
    }

    /// Background for a fill: solid colour, picture or gradient.
    private func fillCSS(_ p: [String: String]) -> String {
        switch p["draw:fill"] {
        case "solid":
            guard let color = p["draw:fill-color"] else { return "" }
            if let opacity = p["draw:opacity"], let percent = Double(opacity.dropLast()), percent < 100 {
                return "background-color:\(Self.rgba(Self.safe(color), percent / 100));"
            }
            return "background-color:\(Self.safe(color));"
        case "bitmap":
            guard let name = p["draw:fill-image-name"], let href = fillImages[name] else { return "" }
            let repeatMode = p["style:repeat"] ?? "repeat"
            let size = repeatMode == "stretch" ? "100% 100%" : "auto"
            return "background-image:url('\(Self.escape(href))');background-size:\(size);background-repeat:\(repeatMode == "repeat" ? "repeat" : "no-repeat");background-position:center;"
        case "gradient":
            guard let name = p["draw:fill-gradient-name"], let gradient = gradients[name] else { return "" }
            let start = Self.safe(gradient["draw:start-color"] ?? "#ffffff"), end = Self.safe(gradient["draw:end-color"] ?? "#000000")
            var angle = 0.0
            if let text = gradient["draw:angle"] {
                angle = text.hasSuffix("deg") ? Double(text.dropLast(3)) ?? 0 : (Double(text) ?? 0) / 10   // Tenths of a degree, or "45deg"
            }
            switch gradient["draw:style"] {
            case "radial", "ellipsoid", "square", "rectangular":
                return "background-image:radial-gradient(\(end), \(start));"
            case "axial":
                return "background-image:linear-gradient(\(180 - angle)deg, \(end), \(start), \(end));"
            default:
                return "background-image:linear-gradient(\(180 - angle)deg, \(start), \(end));"
            }
        default:
            return ""
        }
    }

    private func strokeCSS(_ p: [String: String], property: String = "border") -> String {
        guard let stroke = p["draw:stroke"], stroke != "none" else { return "" }
        let width = max(Self.points(p["svg:stroke-width"]) ?? 0, 0.75)
        return "\(property):\(Self.pt(width)) \(stroke == "dash" ? "dashed" : "solid") \(Self.safe(p["svg:stroke-color"] ?? "#000000"));"
    }

    /// A value from the file, made safe to put in CSS: colours, names, keywords and borders only, so it can't end
    /// the declaration or the attribute, or load anything.
    static func safe(_ value: String?) -> String {
        String((value ?? "").unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || " #%.,-_".unicodeScalars.contains($0) }.map(Character.init))
    }

    /// A picture inside the package. Links to other files or the web aren't followed, so nothing leaves the Mac.
    static func packagePath(_ href: String?) -> String? {
        guard var path = href, !path.hasPrefix("/"), !path.contains(".."), !path.contains(where: { ":'\"()\\<>".contains($0) }) else { return nil }
        if path.hasPrefix("./") { path.removeFirst(2) }
        return path.isEmpty ? nil : path
    }

    private static func rgba(_ hex: String, _ alpha: Double) -> String {
        guard hex.count == 7, let value = Int(hex.dropFirst(), radix: 16) else { return hex }
        return "rgba(\(value >> 16), \((value >> 8) & 255), \(value & 255), \(alpha))"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: The document

    func html() -> String {
        let presentation = content?.elements(forName: "office:body").first?.elements(forName: "office:presentation").first
        for decl in presentation?.elements(forName: "presentation:footer-decl") ?? [] { footers[decl["presentation:name"] ?? ""] = decl.stringValue ?? "" }
        for decl in presentation?.elements(forName: "presentation:date-time-decl") ?? [] {
            let fixed = decl["presentation:source"] != "current"
            dates[decl["presentation:name"] ?? ""] = fixed ? decl.stringValue ?? "" : Date().formatted(date: .numeric, time: .omitted)
        }
        let pages = (presentation?.elements(forName: "draw:page") ?? []).filter { $0["presentation:visibility"] != "hidden" }
        if let first = pages.first, let master = masters[first["draw:master-page-name"] ?? ""],
           let size = layouts[master["style:page-layout-name"] ?? ""] {
            pageSize = size
        }
        var body = ""
        for (index, page) in pages.enumerated() {
            slideNumber = index + 1
            body += slide(page)
        }
        slideCount = pages.count
        // A point short of the paper: a slide even a fraction taller than what the printer lays out spills onto an extra, empty page.
        let width = Self.pt((pageSize.width * 10).rounded(.down) / 10), height = Self.pt((pageSize.height * 10).rounded(.down) / 10 - 1)
        let base = textCSS(defaults["graphic"].map { _ in properties("text", "graphic", nil) } ?? [:])
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        @page { size: \(width) \(height); margin: 0; }
        html, body { margin: 0; padding: 0; background: white; }
        * { -webkit-print-color-adjust: exact; print-color-adjust: exact; box-sizing: border-box; }
        .slide { position: relative; width: \(width); height: \(height); overflow: hidden; contain: strict; font-family: Helvetica, sans-serif; font-size: 18pt; \(base) }
        .slide + .slide { break-before: page; page-break-before: always; }
        .shape { position: absolute; display: flex; flex-direction: column; justify-content: flex-start; }
        .text { width: 100%; }
        p { margin: 0; min-height: 1em; }
        img.picture { position: absolute; inset: 0; width: 100%; height: 100%; }
        table { border-collapse: collapse; table-layout: fixed; width: 100%; }
        td { border: 0.75pt solid #000; vertical-align: top; padding: 2pt 4pt; }
        svg { position: absolute; overflow: visible; }
        </style></head><body>
        \(body)
        <script>
        // Text that LibreOffice shrinks to fit its box.
        document.querySelectorAll('[data-shrink]').forEach(function (box) {
          var text = box.querySelector('.text'); if (!text) return;
          for (var scale = 1; text.scrollHeight * scale > box.clientHeight + 1 && scale > 0.3; scale -= 0.05) {
            text.style.zoom = scale - 0.05; text.style.width = (100 / (scale - 0.05)) + '%';
          }
        });
        </script>
        </body></html>
        """
    }

    private func slide(_ page: XMLElement) -> String {
        let pageProperties = properties("drawing-page", "drawing-page", page["draw:style-name"])
        let master = masters[page["draw:master-page-name"] ?? ""]
        footerText = footers[page["presentation:use-footer-name"] ?? ""] ?? ""
        dateText = dates[page["presentation:use-date-time-name"] ?? ""] ?? ""

        var background = fillCSS(pageProperties)
        var decorations = ""
        if let master {
            masterScope = true
            if background.isEmpty && pageProperties["presentation:background-visible"] != "false" {
                background = fillCSS(properties("drawing-page", "drawing-page", master["draw:style-name"]))
            }
            if pageProperties["presentation:background-objects-visible"] != "false" {
                decorations = shapes(in: master, isMaster: true, flags: pageProperties)
            }
            masterScope = false
        }
        return "<div class=\"slide\" style=\"\(background)\">\(decorations)\(shapes(in: page, isMaster: false, flags: pageProperties))</div>\n"
    }

    private func shapes(in container: XMLElement, isMaster: Bool, flags: [String: String]) -> String {
        var html = ""
        for element in container.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            if element.name == "draw:g" { html += shapes(in: element, isMaster: isMaster, flags: flags); continue }
            let kind = element["presentation:class"]
            if isMaster {
                // The master's placeholders only describe the layout; its footer fields show when the slide asks.
                switch kind {
                case "footer": if flags["presentation:display-footer"] != "true" || footerText.isEmpty { continue }
                case "date-time": if flags["presentation:display-date-time"] != "true" || dateText.isEmpty { continue }
                case "page-number": if flags["presentation:display-page-number"] != "true" { continue }
                case nil: break
                default: continue
                }
            } else if element["presentation:placeholder"] == "true" || ["notes", "handout", "page"].contains(kind ?? "") {
                continue   // An empty placeholder ("Click to add Title") isn't shown in the slide show
            }
            html += shape(element)
        }
        return html
    }

    // MARK: Shapes

    private func shape(_ element: XMLElement) -> String {
        let name = element.name ?? ""
        guard ["draw:frame", "draw:custom-shape", "draw:rect", "draw:ellipse", "draw:circle", "draw:line", "draw:connector",
               "draw:polygon", "draw:polyline", "draw:path", "draw:caption", "draw:measure"].contains(name) else { return "" }
        var graphic = properties("graphic", "presentation", element["presentation:style-name"])
        for (key, value) in properties("graphic", "graphic", element["draw:style-name"]) where element["draw:style-name"] != nil { graphic[key] = value }
        let styleNames = (presentation: element["presentation:style-name"], graphic: element["draw:style-name"])
        func merged(_ kind: String) -> [String: String] {
            var result = styleNames.presentation != nil ? properties(kind, "presentation", styleNames.presentation) : [:]
            if styleNames.graphic != nil { for (key, value) in properties(kind, "graphic", styleNames.graphic) { result[key] = value } }
            return result
        }

        if name == "draw:line" || name == "draw:connector" || name == "draw:measure" {
            guard let x1 = Self.points(element["svg:x1"]), let y1 = Self.points(element["svg:y1"]),
                  let x2 = Self.points(element["svg:x2"]), let y2 = Self.points(element["svg:y2"]), graphic["draw:stroke"] != "none" else { return "" }
            let width = max(Self.points(graphic["svg:stroke-width"]) ?? 0, 0.75)
            let dash = graphic["draw:stroke"] == "dash" ? " stroke-dasharray=\"\(width * 3) \(width * 2)\"" : ""
            return "<svg style=\"left:0;top:0\" width=\"1\" height=\"1\"><line x1=\"\(x1 * 4 / 3)\" y1=\"\(y1 * 4 / 3)\" x2=\"\(x2 * 4 / 3)\" y2=\"\(y2 * 4 / 3)\" stroke=\"\(Self.safe(graphic["svg:stroke-color"] ?? "#000"))\" stroke-width=\"\(width * 4 / 3)\"\(dash)/></svg>"
        }

        // Where it sits: x/y/width/height, or a rotation and translation.
        var x = Self.points(element["svg:x"]) ?? 0, y = Self.points(element["svg:y"]) ?? 0
        let width = Self.points(element["svg:width"]) ?? 0, height = Self.points(element["svg:height"]) ?? 0
        var rotate = ""
        if let transform = element["draw:transform"] {
            if let match = transform.firstMatch(of: /rotate\s*\(\s*(-?[\d.eE+-]+)\s*\)/), let angle = Double(match.1) {
                rotate = "transform:rotate(\(-angle)rad);transform-origin:0 0;"
            }
            if let match = transform.firstMatch(of: /translate\s*\(\s*([^\s)]+)\s+([^\s)]+)\s*\)/) {
                x = Self.points(String(match.1)) ?? x; y = Self.points(String(match.2)) ?? y
            }
        }
        var css = "left:\(Self.pt(x));top:\(Self.pt(y));width:\(Self.pt(width));height:\(Self.pt(height));\(rotate)"
        if let opacity = graphic["draw:opacity"], let percent = Double(opacity.dropLast()), graphic["draw:fill"] != "solid" { css += "opacity:\(percent / 100);" }

        var inner = ""
        var isTextFrame = false
        switch name {
        case "draw:frame":
            let children = element.children?.compactMap { $0 as? XMLElement } ?? []
            if let box = children.first(where: { $0.name == "draw:text-box" }) {
                inner = box.childCount > 0 ? text(box, frame: element) : ""
                isTextFrame = true
            } else if let href = Self.picture(in: element) {
                var imageCSS = ""
                if let opacity = graphic["draw:image-opacity"], let percent = Double(opacity.dropLast()) { imageCSS = " style=\"opacity:\(percent / 100)\"" }
                inner = "<img class=\"picture\" src=\"\(Self.escape(href))\"\(imageCSS)>"
            } else if let table = children.first(where: { $0.name == "table:table" }) {
                inner = self.table(table)
            } else {
                return ""   // Charts and other embedded objects
            }
        default:
            // Shapes: their outline, filled, with any text centred inside.
            var geometry = name
            if name == "draw:custom-shape" { geometry = element.elements(forName: "draw:enhanced-geometry").first?["draw:type"] ?? "rectangle" }
            switch geometry {
            case "draw:ellipse", "draw:circle", "ellipse", "circle": css += "border-radius:50%;"
            case "round-rectangle", "round-quadrat": css += "border-radius:\(Self.pt(min(width, height) / 6));"
            case "diamond": css += "clip-path:polygon(50% 0,100% 50%,50% 100%,0 50%);"
            case "isosceles-triangle": css += "clip-path:polygon(50% 0,100% 100%,0 100%);"
            case "right-triangle": css += "clip-path:polygon(0 0,100% 100%,0 100%);"
            default: break
            }
            if name == "draw:rect", let radius = Self.points(element["draw:corner-radius"]) { css += "border-radius:\(Self.pt(radius));" }
            if name == "draw:polygon" || name == "draw:polyline" || name == "draw:path" {
                inner = outline(element, graphic: graphic, width: width, height: height)
            } else {
                css += fillCSS(graphic) + strokeCSS(graphic)
            }
            if element.elements(forName: "text:p").count + element.elements(forName: "text:list").count > 0 {
                inner += text(element, frame: element, centred: true)
            }
            graphic["draw:textarea-vertical-align"] = graphic["draw:textarea-vertical-align"] ?? "middle"
        }
        if isTextFrame { css += fillCSS(graphic) + strokeCSS(graphic) }
        if graphic["draw:shadow"] == "visible" {
            css += "box-shadow:\(Self.pt(Self.points(graphic["draw:shadow-offset-x"]) ?? 2)) \(Self.pt(Self.points(graphic["draw:shadow-offset-y"]) ?? 2)) 2pt \(Self.safe(graphic["draw:shadow-color"] ?? "#808080"));"
        }
        for side in ["left", "right", "top", "bottom"] {
            if let value = Self.points(graphic["fo:padding-\(side)"]) { css += "padding-\(side):\(Self.pt(value));" }
        }
        switch graphic["draw:textarea-vertical-align"] {
        case "middle": css += "justify-content:center;"
        case "bottom": css += "justify-content:flex-end;"
        default: break
        }
        css += paragraphCSS(merged("paragraph")) + textCSS(merged("text"))
        let shrink = graphic["style:shrink-to-fit"] == "true" || graphic["draw:fit-to-size"] == "shrink-to-fit" ? " data-shrink" : ""
        return "<div class=\"shape\" style=\"\(css)\"\(shrink)>\(inner)</div>"
    }

    /// The first picture the web engine can show. LibreOffice stores WMF, EMF and its own SVM pictures (and chart
    /// previews) with a PNG fallback next to or inside them.
    private static func picture(in element: XMLElement) -> String? {
        for child in element.children?.compactMap({ $0 as? XMLElement }) ?? [] where child.name == "draw:image" {
            if let href = packagePath(child["xlink:href"]), ["png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "tif", "tiff"].contains(href.split(separator: ".").last?.lowercased() ?? "") {
                return href
            }
            if let nested = picture(in: child) { return nested }
        }
        return nil
    }

    /// Polygons and paths, drawn as SVG in the shape's own coordinates.
    private func outline(_ element: XMLElement, graphic: [String: String], width: Double, height: Double) -> String {
        let viewBox = element["svg:viewBox"] ?? "0 0 \(width) \(height)"
        let fill = graphic["draw:fill"] == "solid" && element.name != "draw:polyline" ? Self.safe(graphic["draw:fill-color"] ?? "#729fcf") : "none"
        let stroke = graphic["draw:stroke"] == "none" ? "none" : Self.safe(graphic["svg:stroke-color"] ?? "#3465a4")
        let strokeWidth = max(Self.points(graphic["svg:stroke-width"]) ?? 0, 0.75)
        let shape: String
        if element.name == "draw:path", let d = element["svg:d"] {
            shape = "<path d=\"\(Self.escape(d))\""
        } else if let points = element["draw:points"] {
            shape = "<\(element.name == "draw:polyline" ? "polyline" : "polygon") points=\"\(Self.escape(points))\""
        } else {
            return ""
        }
        return "<svg style=\"left:0;top:0;width:100%;height:100%\" viewBox=\"\(Self.escape(viewBox))\" preserveAspectRatio=\"none\">"
            + "\(shape) fill=\"\(fill)\" stroke=\"\(stroke)\" stroke-width=\"\(strokeWidth)\" vector-effect=\"non-scaling-stroke\"/></svg>"
    }

    private func table(_ element: XMLElement) -> String {
        var html = "<table>"
        var columns = ""
        for column in element.elements(forName: "table:table-column") {
            let width = properties("table-column", "table-column", column["table:style-name"])["style:column-width"]
            let count = Int(column["table:number-columns-repeated"] ?? "1") ?? 1
            for _ in 0..<min(count, 64) { columns += "<col" + (Self.points(width).map { " style=\"width:\(Self.pt($0))\"" } ?? "") + ">" }
        }
        html += columns
        for row in element.elements(forName: "table:table-row") {
            let rowHeight = Self.points(properties("table-row", "table-row", row["table:style-name"])["style:row-height"])
            html += "<tr" + (rowHeight.map { " style=\"height:\(Self.pt($0))\"" } ?? "") + ">"
            for cell in row.elements(forName: "table:table-cell") {
                let style = cell["table:style-name"]
                let graphic = properties("graphic", "table-cell", style)
                var css = fillCSS(graphic) + paragraphCSS(properties("paragraph", "table-cell", style)) + textCSS(properties("text", "table-cell", style))
                let cellProperties = properties("table-cell", "table-cell", style)
                if let border = cellProperties["fo:border"] { css += "border:\(Self.safe(border));" }
                for side in ["left", "right", "top", "bottom"] {
                    if let border = cellProperties["fo:border-\(side)"] { css += "border-\(side):\(Self.safe(border));" }
                }
                var spans = ""
                if let columns = cell["table:number-columns-spanned"].flatMap(Int.init), columns > 1 { spans += " colspan=\"\(columns)\"" }
                if let rows = cell["table:number-rows-spanned"].flatMap(Int.init), rows > 1 { spans += " rowspan=\"\(rows)\"" }
                html += "<td\(spans) style=\"\(css)\">\(text(cell, frame: nil))</td>"
            }
            html += "</tr>"
        }
        return html + "</table>"
    }

    // MARK: Text

    private struct ListContext {
        var style: XMLElement?
        var level: Int
        var counters: [Int: Int] = [:]
    }

    /// The paragraphs and lists inside a text box, shape or table cell.
    private func text(_ container: XMLElement, frame: XMLElement?, centred: Bool = false) -> String {
        // Outline placeholders style each list level with their own presentation style ("…-outline2").
        var outlineBase: String?
        if let frame, frame["presentation:class"] == "outline" || frame["presentation:class"] == "subtitle" {
            let names = chain("presentation", frame["presentation:style-name"]).compactMap { $0["style:name"] }
            outlineBase = names.first { $0.hasSuffix("-outline1") }.map { String($0.dropLast()) }
        }
        var frameList: XMLElement?
        if let frame {
            for style in chain("presentation", frame["presentation:style-name"]) + chain("graphic", frame["draw:style-name"]) {
                if let name = style["style:list-style-name"], let found = list(name) { frameList = found }
                if let inline = style.elements(forName: "style:graphic-properties").first?.elements(forName: "text:list-style").first { frameList = inline }
            }
        }
        let isOutline = frame?["presentation:class"] == "outline"
        let context = ListContext(style: frameList, level: 0)
        return "<div class=\"text\"\(centred ? " style=\"text-align:center\"" : "")>" + blocks(container, context: context, outlineBase: outlineBase, bulletsByDefault: isOutline) + "</div>"
    }

    private func blocks(_ container: XMLElement, context: ListContext, outlineBase: String?, bulletsByDefault: Bool) -> String {
        var html = ""
        for child in container.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            switch child.name {
            case "text:p", "text:h":
                html += paragraph(child, bullet: nil, levelCSS: "")
            case "text:list":
                html += list(child, parent: context, outlineBase: outlineBase, bulletsByDefault: bulletsByDefault)
            default:
                break
            }
        }
        return html
    }

    private func list(_ element: XMLElement, parent: ListContext, outlineBase: String?, bulletsByDefault: Bool) -> String {
        var html = ""
        var inner = parent
        inner.level += 1
        inner.counters = [:]
        if let name = element["text:style-name"], let style = list(name) { inner.style = style }
        for item in element.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            let isHeader = item.name == "text:list-header"
            guard item.name == "text:list-item" || isHeader else { continue }
            let level = inner.level
            let levelStyle = inner.style?.children?.compactMap { $0 as? XMLElement }
                .first { Int($0["text:level"] ?? "") == level }
            var levelCSS = ""
            if let base = outlineBase, level > 1 {
                let name = base + String(level)
                levelCSS = paragraphCSS(properties("paragraph", "presentation", name)) + textCSS(properties("text", "presentation", name))
            }
            // Indentation from the list level, which wins over the paragraph's own (LibreOffice writes 0 there).
            var labelWidth = 0.0, indentCSS = ""
            if let properties = levelStyle?.elements(forName: "style:list-level-properties").first {
                if let alignment = properties.elements(forName: "style:list-level-label-alignment").first {
                    if let margin = Self.points(alignment["fo:margin-left"]) { indentCSS += "margin-left:\(Self.pt(margin));" }
                    if let indent = Self.points(alignment["fo:text-indent"]) { indentCSS += "text-indent:\(Self.pt(indent));"; labelWidth = -indent }
                } else {
                    let before = Self.points(properties["text:space-before"]) ?? 0, label = Self.points(properties["text:min-label-width"]) ?? 0
                    indentCSS = "margin-left:\(Self.pt(before + label));text-indent:\(Self.pt(-label));"
                    labelWidth = label
                }
            } else if bulletsByDefault {
                indentCSS = "margin-left:\(Self.pt(Double(level) * 20));text-indent:-14pt;"
                labelWidth = 14
            }
            var bullet: String?
            if !isHeader {
                inner.counters[level, default: 0] += 1
                bullet = label(levelStyle, number: inner.counters[level] ?? 1, byDefault: bulletsByDefault)
            }
            var first = true
            for part in item.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                if part.name == "text:p" || part.name == "text:h" {
                    let mark = first ? bullet.map { "<span style=\"display:inline-block;min-width:\(Self.pt(labelWidth));text-indent:0\">\($0)</span>" } : nil
                    html += paragraph(part, bullet: mark, levelCSS: levelCSS, indentCSS: indentCSS)
                    first = false
                } else if part.name == "text:list" {
                    html += list(part, parent: inner, outlineBase: outlineBase, bulletsByDefault: bulletsByDefault)
                }
            }
        }
        return html
    }

    /// The bullet or number for a list item, or nil for none.
    private func label(_ level: XMLElement?, number: Int, byDefault: Bool) -> String? {
        guard let level else { return byDefault ? "•" : nil }
        let props = level.elements(forName: "style:text-properties").first
        var css = ""
        if let color = props?["fo:color"], props?["style:use-window-font-color"] != "true" { css += "color:\(Self.safe(color));" }
        // Bullets are drawn in LibreOffice's symbol font, where they're much bigger; shrinking a Mac font's bullet only makes it a dot.
        if let size = props?["fo:font-size"], size.hasSuffix("%"), let percent = Double(size.dropLast()), percent > 100 { css += "font-size:\(min(percent, 150))%;" }
        func styled(_ text: String) -> String { css.isEmpty ? Self.escape(text) : "<span style=\"\(css)\">\(Self.escape(text))</span>" }
        switch level.name {
        case "text:list-level-style-bullet":
            var char = level["text:bullet-char"] ?? "•"
            if char == "●" || char.unicodeScalars.first.map({ (0xE000...0xF8FF).contains($0.value) }) == true { char = "•" }   // Symbol-font characters
            return styled(char)
        case "text:list-level-style-number":
            let format = level["style:num-format"] ?? ""
            guard !format.isEmpty else { return nil }
            let value: String
            switch format {
            case "a": value = Self.letters(number, upper: false)
            case "A": value = Self.letters(number, upper: true)
            case "i": value = Self.roman(number).lowercased()
            case "I": value = Self.roman(number)
            default: value = String(number)
            }
            return styled((level["style:num-prefix"] ?? "") + value + (level["style:num-suffix"] ?? "."))
        case "text:list-level-style-image":
            return "•"
        default:
            return byDefault ? "•" : nil
        }
    }

    private static func letters(_ number: Int, upper: Bool) -> String {
        var n = number, text = ""
        while n > 0 { n -= 1; text = String(UnicodeScalar(UInt8((upper ? 65 : 97) + n % 26))) + text; n /= 26 }
        return text
    }

    private static func roman(_ number: Int) -> String {
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = min(number, 3999), text = ""
        for (value, letters) in table { while n >= value { text += letters; n -= value } }
        return text
    }

    private func paragraph(_ element: XMLElement, bullet: String?, levelCSS: String, indentCSS: String = "") -> String {
        let name = element["text:style-name"]
        let css = levelCSS + paragraphCSS(properties("paragraph", "paragraph", name)) + textCSS(properties("text", "paragraph", name)) + indentCSS
        let body = inline(element)
        return "<p style=\"\(css)\">\(bullet ?? "")\(body.isEmpty ? "&#8203;" : body)</p>"
    }

    private func inline(_ element: XMLElement) -> String {
        var html = ""
        for node in element.children ?? [] {
            guard let child = node as? XMLElement else {
                if node.kind == .text { html += Self.escape(node.stringValue ?? "") }
                continue
            }
            switch child.name {
            case "text:span":
                let css = textCSS(properties("text", "text", child["text:style-name"]))
                html += css.isEmpty ? inline(child) : "<span style=\"\(css)\">\(inline(child))</span>"
            case "text:s": html += String(repeating: "&nbsp;", count: Int(child["text:c"] ?? "1") ?? 1)
            case "text:tab": html += "&emsp;&emsp;"
            case "text:line-break": html += "<br>"
            case "text:page-number", "presentation:page-number": html += String(slideNumber)
            case "presentation:footer": html += Self.escape(footerText)
            case "presentation:date-time": html += Self.escape(dateText)
            case "office:annotation", "text:note": break
            default: html += inline(child)   // Links, fields and other wrappers keep their text
            }
        }
        return html
    }
}

private extension XMLElement {
    nonisolated subscript(_ attribute: String) -> String? { self.attribute(forName: attribute)?.stringValue }
}
