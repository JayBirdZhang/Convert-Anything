import Foundation

/// Converts the MathML that TeXMath makes into Office Math (OMML), the equation format Word uses,
/// so math in a .docx is a real, editable Word equation.
nonisolated enum MathOMML {
    static func omml(fromMathML mathML: String, display: Bool) -> String {
        guard let document = try? XMLDocument(xmlString: mathML, options: []),
              let root = document.rootElement() else { return run(mathML, style: "p") }
        let body = children(root.children ?? [])
        return display ? "<m:oMathPara><m:oMath>\(body)</m:oMath></m:oMathPara>" : "<m:oMath>\(body)</m:oMath>"
    }

    private static let bigOperators: Set<String> = ["∑", "∏", "∐", "∫", "∬", "∭", "∮", "⋃", "⋂", "⨁", "⨂"]
    private static let combiningAccents: [String: String] = [
        "^": "\u{302}", "¯": "\u{305}", "→": "\u{20D7}", "˙": "\u{307}", "¨": "\u{308}", "~": "\u{303}",
        "ˇ": "\u{30C}", "˘": "\u{306}", "´": "\u{301}", "`": "\u{300}",
    ]

    /// A sequence of nodes. A big operator (∑, ∫) takes the node after it as its body.
    private static func children(_ nodes: [XMLNode]) -> String {
        let elements = nodes.compactMap { $0 as? XMLElement }
        var out = ""
        var index = 0
        while index < elements.count {
            let element = elements[index]
            if let limit = limitParts(element) {
                var body = ""
                if index + 1 < elements.count { body = convert(elements[index + 1]); index += 1 }
                out += limit(body)
            } else if let nary = naryParts(element) {
                var body = ""
                if index + 1 < elements.count { body = convert(elements[index + 1]); index += 1 }
                out += nary(body)
            } else {
                out += convert(element)
            }
            index += 1
        }
        return out
    }

    /// lim, max, min… with something underneath: Word writes these as a function whose name has the limit below.
    private static func limitParts(_ element: XMLElement) -> ((String) -> String)? {
        let kids = (element.children ?? []).compactMap { $0 as? XMLElement }
        guard ["munder", "msub"].contains(element.name ?? ""), kids.count == 2, kids[0].name == "mo",
              let name = kids[0].stringValue, ["lim", "max", "min", "sup", "inf", "limsup", "liminf", "argmax", "argmin"].contains(name) else { return nil }
        let below = convert(kids[1])
        return { body in "<m:func><m:fName><m:limLow><m:e>\(run(name, style: "p"))</m:e><m:lim>\(below)</m:lim></m:limLow></m:fName><m:e>\(body)</m:e></m:func>" }
    }

    /// For ∑/∫ with limits (as munderover/msubsup/plain mo), a builder that wraps the body.
    private static func naryParts(_ element: XMLElement) -> ((String) -> String)? {
        let kids = (element.children ?? []).compactMap { $0 as? XMLElement }
        let name = element.name ?? ""
        let base: XMLElement?
        var sub: XMLElement?, sup: XMLElement?
        switch name {
        case "mo": base = element
        case "munderover", "msubsup": base = kids.first; sub = kids.count > 1 ? kids[1] : nil; sup = kids.count > 2 ? kids[2] : nil
        case "munder", "msub": base = kids.first; sub = kids.count > 1 ? kids[1] : nil
        case "mover", "msup": base = kids.first; sup = kids.count > 1 ? kids[1] : nil
        default: return nil
        }
        guard let base, base.name == "mo", let symbol = base.stringValue, bigOperators.contains(symbol) else { return nil }
        let limitLocation = ["∫", "∬", "∭", "∮"].contains(symbol) ? "subSup" : "undOvr"
        let properties = #"<m:naryPr><m:chr m:val="\#(symbol)"/><m:limLoc m:val="\#(limitLocation)"/>"#
            + (sub == nil ? #"<m:subHide m:val="1"/>"# : "") + (sup == nil ? #"<m:supHide m:val="1"/>"# : "") + "</m:naryPr>"
        let subXML = sub.map(convert) ?? "", supXML = sup.map(convert) ?? ""
        return { body in "<m:nary>\(properties)<m:sub>\(subXML)</m:sub><m:sup>\(supXML)</m:sup><m:e>\(body)</m:e></m:nary>" }
    }

    private static func convert(_ element: XMLElement) -> String {
        let kids = (element.children ?? []).compactMap { $0 as? XMLElement }
        func part(_ i: Int) -> String { i < kids.count ? convert(kids[i]) : "" }
        let text = element.stringValue ?? ""

        switch element.name ?? "" {
        case "mrow", "mtd", "mstyle", "math":
            // Brackets made with \left…\right or a matrix: an OMML delimiter around the middle.
            if kids.count >= 2, kids.first?.name == "mo", kids.last?.name == "mo",
               kids.first?.attribute(forName: "fence") != nil, kids.last?.attribute(forName: "fence") != nil {
                let open = kids.first?.stringValue ?? "", close = kids.last?.stringValue ?? ""
                let middle = children(Array(kids.dropFirst().dropLast()))
                return #"<m:d><m:dPr><m:begChr m:val="\#(escape(open))"/><m:endChr m:val="\#(escape(close))"/></m:dPr><m:e>\#(middle)</m:e></m:d>"#
            }
            return children(kids)
        case "mi":
            let variant = element.attribute(forName: "mathvariant")?.stringValue
            return run(text, style: variant == "bold" ? "b" : variant == "normal" || text.count > 1 ? "p" : nil, script: script(variant))
        case "mn":
            return run(text, style: element.attribute(forName: "mathvariant")?.stringValue == "bold" ? "b" : "p")
        case "mo":
            if text == "\u{2061}" { return "" }   // Invisible "function application"
            return run(text, style: "p")
        case "mtext":
            return #"<m:r><m:rPr><m:nor/></m:rPr><w:rPr><w:rFonts w:ascii="Cambria Math" w:hAnsi="Cambria Math"/></w:rPr><m:t xml:space="preserve">\#(escape(text))</m:t></m:r>"#
        case "mspace":
            return run(" ", style: "p")
        case "mfrac":
            let noBar = element.attribute(forName: "linethickness")?.stringValue == "0"
            return "<m:f>" + (noBar ? #"<m:fPr><m:type m:val="noBar"/></m:fPr>"# : "") + "<m:num>\(part(0))</m:num><m:den>\(part(1))</m:den></m:f>"
        case "msqrt":
            return #"<m:rad><m:radPr><m:degHide m:val="1"/></m:radPr><m:deg/><m:e>\#(children(kids))</m:e></m:rad>"#
        case "mroot":
            return "<m:rad><m:deg>\(part(1))</m:deg><m:e>\(part(0))</m:e></m:rad>"
        case "msup":
            return "<m:sSup><m:e>\(part(0))</m:e><m:sup>\(part(1))</m:sup></m:sSup>"
        case "msub":
            return "<m:sSub><m:e>\(part(0))</m:e><m:sub>\(part(1))</m:sub></m:sSub>"
        case "msubsup":
            return "<m:sSubSup><m:e>\(part(0))</m:e><m:sub>\(part(1))</m:sub><m:sup>\(part(2))</m:sup></m:sSubSup>"
        case "mover":
            if element.attribute(forName: "accent")?.stringValue == "true", kids.count > 1 {
                let mark = kids[1].stringValue ?? ""
                return #"<m:acc><m:accPr><m:chr m:val="\#(combiningAccents[mark] ?? mark)"/></m:accPr><m:e>\#(part(0))</m:e></m:acc>"#
            }
            return "<m:limUpp><m:e>\(part(0))</m:e><m:lim>\(part(1))</m:lim></m:limUpp>"
        case "munder":
            return "<m:limLow><m:e>\(part(0))</m:e><m:lim>\(part(1))</m:lim></m:limLow>"
        case "munderover":
            return "<m:limUpp><m:e><m:limLow><m:e>\(part(0))</m:e><m:lim>\(part(1))</m:lim></m:limLow></m:e><m:lim>\(part(2))</m:lim></m:limUpp>"
        case "mtable":
            let rows = kids.filter { $0.name == "mtr" }.map { row in
                "<m:mr>" + (row.children ?? []).compactMap { $0 as? XMLElement }.map { "<m:e>\(convert($0))</m:e>" }.joined() + "</m:mr>"
            }
            return "<m:m>\(rows.joined())</m:m>"
        default:
            return children(kids)
        }
    }

    private static func script(_ variant: String?) -> String? {
        switch variant {
        case "double-struck": "double-struck"
        case "script": "script"
        case "fraktur": "fraktur"
        case "sans-serif": "sans-serif"
        case "monospace": "monospace"
        default: nil
        }
    }

    /// One run of math text. `style`: p = upright, b = bold, nil = Word's default (italic letters).
    private static func run(_ text: String, style: String?, script: String? = nil) -> String {
        var properties = ""
        if let script { properties += #"<m:scr m:val="\#(script)"/>"# }
        if let style { properties += #"<m:sty m:val="\#(style)"/>"# }
        return "<m:r>" + (properties.isEmpty ? "" : "<m:rPr>\(properties)</m:rPr>")
            + #"<w:rPr><w:rFonts w:ascii="Cambria Math" w:hAnsi="Cambria Math"/></w:rPr><m:t xml:space="preserve">\#(escape(text))</m:t></m:r>"#
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
