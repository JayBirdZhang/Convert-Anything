import Foundation

/// Turns math found in documents back into LaTeX: Word's Office Math (OMML) and the MathML of HTML pages.
/// The output is LaTeX that `TeXMath` understands, so a .docx or .html converted to Markdown keeps its
/// equations as `$…$`. Parsing is one linear pass over the snippet with a tiny tolerant tag reader
/// (HTML entities, unquoted attributes and missing namespaces are fine); if nothing useful comes out,
/// the text content is returned instead, so a non-empty input never yields an empty result.
nonisolated enum MathTeX {
    /// One Word equation: the XML of a single `<m:oMath>…</m:oMath>` element. Returns LaTeX without `$`.
    static func tex(fromOMML xml: String) -> String {
        let (root, plain) = Reader.parse(xml, stripPrefix: false)
        var found: [Node] = []
        collect(root, "m:oMath", &found)
        var out = ""
        if found.isEmpty {
            out = OMML.seq(root.kids)
        } else {
            for math in found { Tex.cat(&out, out.isEmpty ? "" : " "); Tex.cat(&out, OMML.seq(math.kids)) }
        }
        out = Tex.tidy(out)
        return out.isEmpty ? Tex.fallback(plain) : out
    }

    /// One `<math>…</math>` element from an HTML page. A TeX annotation, if present, wins.
    static func tex(fromMathML xml: String) -> String {
        let (root, plain) = Reader.parse(xml, stripPrefix: true)
        if let annotation = findAnnotation(root) {
            let t = annotation.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        var found: [Node] = []
        collect(root, "math", &found)
        let out = Tex.tidy(MML.seq(found.isEmpty ? root.kids : found.flatMap { $0.kids }))
        return out.isEmpty ? Tex.fallback(plain) : out
    }

    private static func collect(_ node: Node, _ name: String, _ into: inout [Node]) {
        for kid in node.kids {
            if kid.name == name { into.append(kid) } else { collect(kid, name, &into) }
        }
    }

    private static func findAnnotation(_ node: Node) -> String? {
        for kid in node.kids {
            if kid.name == "annotation", let enc = kid.attrs["encoding"]?.lowercased(), enc.contains("tex") { return kid.text }
            if let t = findAnnotation(kid) { return t }
        }
        return nil
    }

    // MARK: Tiny tolerant XML/HTML reader

    private final class Node {
        let name: String
        var attrs: [String: String] = [:]
        var kids: [Node] = []
        var text = ""
        init(_ name: String) { self.name = name }
        func attr(_ key: String) -> String? { attrs["m:" + key] ?? attrs[key] }
        func child(_ name: String) -> Node? { kids.first { $0.name == name } }
    }

    private enum Reader {
        static let entities: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}", "minus": "\u{2212}", "times": "×",
            "InvisibleTimes": "\u{2062}", "it": "\u{2062}", "ApplyFunction": "\u{2061}", "af": "\u{2061}",
            "InvisibleComma": "\u{2063}", "ic": "\u{2063}", "PlusMinus": "±", "pm": "±", "mp": "∓", "MinusPlus": "∓",
            "infin": "∞", "le": "≤", "ge": "≥", "ne": "≠", "leq": "≤", "geq": "≥", "hellip": "…", "middot": "·",
            "sdot": "⋅", "CenterDot": "·", "bull": "•", "deg": "°", "prime": "′", "Prime": "″", "partial": "∂",
            "PartialD": "∂", "nabla": "∇", "Del": "∇", "sum": "∑", "Sum": "∑", "prod": "∏", "Product": "∏", "int": "∫",
            "Integral": "∫", "radic": "√", "Sqrt": "√", "rarr": "→", "larr": "←", "rArr": "⇒", "lArr": "⇐", "hArr": "⇔",
            "harr": "↔", "uarr": "↑", "darr": "↓", "RightArrow": "→", "LeftArrow": "←", "isin": "∈", "in": "∈",
            "notin": "∉", "ni": "∋", "cap": "∩", "cup": "∪", "sub": "⊂", "sup": "⊃", "sube": "⊆", "supe": "⊇",
            "forall": "∀", "ForAll": "∀", "exist": "∃", "Exists": "∃", "empty": "∅", "and": "∧", "or": "∨", "not": "¬",
            "ap": "≈", "approx": "≈", "asymp": "≍", "equiv": "≡", "sim": "∼", "cong": "≅", "prop": "∝", "lang": "⟨",
            "rang": "⟩", "langle": "⟨", "rangle": "⟩", "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊", "rfloor": "⌋",
            "thinsp": "\u{2009}", "ensp": "\u{2002}", "emsp": "\u{2003}", "hairsp": "\u{200A}", "ThinSpace": "\u{2009}",
            "ThickSpace": "\u{2009}", "MediumSpace": "\u{205F}", "NegativeThinSpace": "", "NoBreak": "", "ZeroWidthSpace": "",
            "plusmn": "±", "divide": "÷", "div": "÷", "lowast": "∗", "ast": "∗", "compfn": "∘", "ring": "˚",
            "oplus": "⊕", "otimes": "⊗", "angle": "∠", "ang": "∠", "there4": "∴", "because": "∵", "perp": "⊥",
            "lt;": "<", "vert": "|", "Vert": "‖", "verbar": "|", "lbrace": "{", "rbrace": "}", "lbrack": "[", "rbrack": "]",
            "lpar": "(", "rpar": ")", "comma": ",", "period": ".", "colon": ":", "semi": ";", "equals": "=", "plus": "+",
            "excl": "!", "quest": "?", "sol": "/", "bsol": "\\", "lowbar": "_", "num": "#", "dollar": "$", "percnt": "%",
            "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "epsi": "ϵ", "zeta": "ζ", "eta": "η",
            "theta": "θ", "thetasym": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
            "omicron": "ο", "pi": "π", "piv": "ϖ", "rho": "ρ", "sigma": "σ", "sigmaf": "ς", "tau": "τ", "upsilon": "υ",
            "phi": "ϕ", "straightphi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
            "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
            "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω", "hbar": "ℏ", "planck": "ℏ", "ell": "ℓ", "real": "ℜ", "image": "ℑ",
            "aleph": "ℵ", "Copf": "ℂ", "Nopf": "ℕ", "Qopf": "ℚ", "Ropf": "ℝ", "Zopf": "ℤ", "Popf": "ℙ",
            "mid": "∣", "parallel": "∥", "par": "∥", "setminus": "∖", "Backslash": "∖", "wedge": "∧", "vee": "∨",
            "ll": "≪", "gg": "≫", "Lt": "≪", "Gt": "≫", "ltrif": "◂", "star": "⋆", "dagger": "†", "Dagger": "‡",
            "copy": "©", "reg": "®", "trade": "™", "sect": "§", "para": "¶", "laquo": "«", "raquo": "»",
            "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "ndash": "–", "mdash": "—", "dash": "‐",
            "mapsto": "↦", "map": "↦", "to": "→", "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔", "iff": "⇔",
            "UnderBrace": "⏟", "OverBrace": "⏞", "OverBar": "‾", "UnderBar": "_", "macr": "¯", "Hat": "^", "tilde": "˜",
            "circ": "ˆ", "caron": "ˇ", "breve": "˘", "dot": "˙", "die": "¨", "uml": "¨", "acute": "´", "grave": "`",
        ]

        static func parse(_ xml: String, stripPrefix: Bool) -> (Node, String) {
            let b = Array(xml.utf8)
            let n = b.count
            let root = Node("#root")
            var stack: [Node] = [root]
            var plain = ""
            var i = 0

            func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 10 || c == 13 || c == 9 }
            func has(_ s: StaticString, at p: Int) -> Bool {
                let len = s.utf8CodeUnitCount
                guard p + len <= n else { return false }
                let ptr = s.utf8Start
                for k in 0..<len where b[p + k] != ptr[k] { return false }
                return true
            }
            func find(_ s: StaticString, from p: Int) -> Int? {
                var q = p
                while q < n { if has(s, at: q) { return q }; q += 1 }
                return nil
            }
            func name(_ raw: String) -> String {
                if stripPrefix, let colon = raw.lastIndex(of: ":") { return String(raw[raw.index(after: colon)...]) }
                return raw
            }

            while i < n {
                if b[i] != 60 {   // text
                    var j = i
                    while j < n, b[j] != 60 { j += 1 }
                    let text = decode(b, i, j)
                    stack[stack.count - 1].text += text
                    plain += text
                    i = j
                    continue
                }
                if has("<!--", at: i) { i = (find("-->", from: i + 4) ?? n - 3) + 3; continue }
                if has("<![CDATA[", at: i) {
                    let end = find("]]>", from: i + 9) ?? n
                    let text = String(decoding: b[(i + 9)..<min(end, n)], as: UTF8.self)
                    stack[stack.count - 1].text += text
                    plain += text
                    i = end + 3
                    continue
                }
                if i + 1 < n, b[i + 1] == 63 || b[i + 1] == 33 {   // <? … > and <! … >
                    while i < n, b[i] != 62 { i += 1 }
                    i += 1
                    continue
                }
                if i + 1 < n, b[i + 1] == 47 {   // end tag
                    var j = i + 2
                    while j < n, b[j] != 62, !isSpace(b[j]) { j += 1 }
                    let tag = name(String(decoding: b[(i + 2)..<j], as: UTF8.self))
                    while j < n, b[j] != 62 { j += 1 }
                    i = j + 1
                    if let at = stack.lastIndex(where: { $0.name == tag }), at > 0 { stack.removeSubrange(at...) }
                    continue
                }
                // start tag
                var j = i + 1
                while j < n, b[j] != 62, b[j] != 47, !isSpace(b[j]) { j += 1 }
                if j == i + 1 { plain += "<"; i += 1; continue }
                let node = Node(name(String(decoding: b[(i + 1)..<j], as: UTF8.self)))
                var selfClosing = false
                while j < n {
                    while j < n, isSpace(b[j]) { j += 1 }
                    if j >= n { break }
                    if b[j] == 62 { j += 1; break }
                    if b[j] == 47 { selfClosing = true; j += 1; continue }
                    let ks = j
                    while j < n, b[j] != 61, b[j] != 62, b[j] != 47, !isSpace(b[j]) { j += 1 }
                    let key = String(decoding: b[ks..<j], as: UTF8.self)
                    while j < n, isSpace(b[j]) { j += 1 }
                    var value = ""
                    if j < n, b[j] == 61 {
                        j += 1
                        while j < n, isSpace(b[j]) { j += 1 }
                        if j < n, b[j] == 34 || b[j] == 39 {
                            let quote = b[j]
                            let vs = j + 1
                            j = vs
                            while j < n, b[j] != quote { j += 1 }
                            value = decode(b, vs, j)
                            j += 1
                        } else {
                            let vs = j
                            while j < n, b[j] != 62, !isSpace(b[j]) { j += 1 }
                            value = decode(b, vs, j)
                        }
                    }
                    if !key.isEmpty { node.attrs[key] = value }
                }
                i = j
                stack[stack.count - 1].kids.append(node)
                if !selfClosing { stack.append(node) }
            }
            return (root, plain)
        }

        /// Text with entities resolved; entities nobody knows are dropped.
        static func decode(_ b: [UInt8], _ from: Int, _ to: Int) -> String {
            guard from < to else { return "" }
            var hasAmp = false
            for k in from..<to where b[k] == 38 { hasAmp = true; break }
            if !hasAmp { return String(decoding: b[from..<to], as: UTF8.self) }
            var out = ""
            var run = from
            var i = from
            while i < to {
                if b[i] == 38 {
                    var j = i + 1
                    while j < to, j - i < 32, b[j] != 59, b[j] != 38, b[j] != 32 { j += 1 }
                    if j < to, b[j] == 59 {
                        out += String(decoding: b[run..<i], as: UTF8.self)
                        let name = String(decoding: b[(i + 1)..<j], as: UTF8.self)
                        if name.hasPrefix("#") {
                            let digits = name.dropFirst()
                            let value: UInt32? = digits.first == "x" || digits.first == "X"
                                ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                            if let value, let scalar = Unicode.Scalar(value) { out.unicodeScalars.append(scalar) }
                        } else if let text = entities[name] {
                            out += text
                        }
                        i = j + 1
                        run = i
                        continue
                    }
                }
                i += 1
            }
            out += String(decoding: b[run..<to], as: UTF8.self)
            return out
        }
    }

    // MARK: Shared pieces

    private enum Tex {
        /// Symbol → TeX command, inverted from TeXMath's own tables.
        static let symbols: [String: String] = {
            var rev: [String: String] = [
                "≤": "\\le", "≥": "\\ge", "≠": "\\ne", "→": "\\to", "←": "\\leftarrow", "∧": "\\wedge", "∨": "\\vee",
                "∅": "\\emptyset", "¬": "\\neg", "⋅": "\\cdot", "…": "\\ldots", "∣": "\\mid", "ϵ": "\\epsilon",
                "ε": "\\varepsilon", "ϕ": "\\phi", "φ": "\\varphi", "∈": "\\in", "∋": "\\ni", "⟹": "\\implies",
                "⟺": "\\iff", "|": "|", "‖": "\\|", ":": ":", "′": "'", "″": "''", "‴": "'''", "−": "-", "∕": "/",
                "·": "\\cdot", "°": "^\\circ", "⊥": "\\perp", "⊤": "\\top", "ℝ": "\\mathbb{R}", "ℕ": "\\mathbb{N}",
                "ℤ": "\\mathbb{Z}", "ℚ": "\\mathbb{Q}", "ℂ": "\\mathbb{C}", "ℙ": "\\mathbb{P}", "ℍ": "\\mathbb{H}",
                "⇒": "\\Rightarrow", "⇐": "\\Leftarrow", "⇔": "\\Leftrightarrow", "∑": "\\sum", "∏": "\\prod", "∫": "\\int",
                "√": "\\sqrt{}", "÷": "\\div", "≈": "\\approx",
            ]
            func add(_ table: [String: String]) {
                for name in table.keys.sorted(by: { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }) {
                    let symbol = table[name]!
                    if rev[symbol] == nil { rev[symbol] = "\\" + name }
                }
            }
            add(TeXMath.operators)
            add(TeXMath.bigOperators)
            add(TeXMath.greek)
            rev["√"] = nil
            return rev
        }()

        static let bigSymbols: Set<String> = Set(TeXMath.bigOperators.values)
        static let wordFunctions: Set<String> = TeXMath.functions.union(TeXMath.limitFunctions)

        static let variants: [String: String] = [
            "bold": "\\mathbf", "normal": "\\mathrm", "double-struck": "\\mathbb", "script": "\\mathcal",
            "bold-script": "\\mathcal", "fraktur": "\\mathfrak", "bold-fraktur": "\\mathfrak", "sans-serif": "\\mathsf",
            "monospace": "\\mathtt", "bold-italic": "\\boldsymbol",
        ]

        /// Accent (spacing or combining) → (TeX command for one symbol, command for a wide base).
        static let accentNames: [String: (String, String)] = [
            "^": ("hat", "widehat"), "\u{302}": ("hat", "widehat"), "ˆ": ("hat", "widehat"),
            "¯": ("bar", "overline"), "‾": ("bar", "overline"), "\u{305}": ("bar", "overline"), "\u{304}": ("bar", "overline"),
            "→": ("vec", "overrightarrow"), "\u{20D7}": ("vec", "overrightarrow"),
            "˙": ("dot", "dot"), "\u{307}": ("dot", "dot"), "¨": ("ddot", "ddot"), "\u{308}": ("ddot", "ddot"),
            "~": ("tilde", "widetilde"), "˜": ("tilde", "widetilde"), "\u{303}": ("tilde", "widetilde"),
            "ˇ": ("check", "check"), "\u{30C}": ("check", "check"), "˘": ("breve", "breve"), "\u{306}": ("breve", "breve"),
            "´": ("acute", "acute"), "\u{301}": ("acute", "acute"), "`": ("grave", "grave"), "\u{300}": ("grave", "grave"),
        ]
        static let overlineMarks: Set<String> = ["¯", "‾", "\u{305}", "―", "⎯", "─"]
        static let underlineMarks: Set<String> = ["_", "‗", "▁", "\u{332}", "¯", "‾", "―"]

        static func isLetter(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
        static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

        /// Appends with the one space TeX needs: after a command word before a letter, between two numbers.
        static func cat(_ a: inout String, _ b: String) {
            guard let f = b.utf8.first, let l = a.utf8.last else { a += b; return }
            if isLetter(f), isLetter(l), endsWithCommand(a) { a += " " }
            else if isDigit(f), isDigit(l) { a += " " }
            a += b
        }

        static func endsWithCommand(_ s: String) -> Bool {
            var count = 0
            for c in s.utf8.reversed() {
                if isLetter(c) { count += 1; continue }
                return c == 92 && count > 0
            }
            return false
        }

        /// A single token that may follow ^ or _ without braces.
        static func isAtomic(_ s: String) -> Bool {
            let u = s.utf8
            guard let first = u.first else { return false }
            if first == 92 {
                if u.count == 2 { return true }
                return u.count > 2 && u.dropFirst().allSatisfy(isLetter)
            }
            if u.count > 4 { return false }
            guard s.count == 1 else { return false }
            return !"{}^_&\\'".utf8.contains(first)
        }

        /// Limits of a big operator: always braced, followed by a space so the body reads apart.
        static func limitMarks(_ sub: String, _ sup: String) -> String {
            (sub.isEmpty ? "" : "_{" + sub + "}") + (sup.isEmpty ? "" : "^{" + sup + "}") + (sub.isEmpty && sup.isEmpty ? "" : " ")
        }

        static func braced(_ s: String) -> String { isAtomic(s) ? s : "{" + s + "}" }
        static func script(_ s: String) -> String { s.isEmpty ? "{}" : braced(s) }

        static func char(_ c: Unicode.Scalar) -> String {
            if c.value < 128 {
                switch c {
                case "#", "$", "%", "&", "_", "{", "}": return "\\" + String(c)
                case "~": return "\\sim"
                case "^": return "\\^{}"
                case "\\": return "\\backslash"
                default: return String(c)
                }
            }
            let s = String(c)
            return symbols[s] ?? s
        }

        /// Every character mapped; invisible operators and spaces dropped.
        static func map(_ text: String) -> String {
            var out = ""
            for c in text.unicodeScalars {
                switch c.value {
                case 0x2061...0x2064, 0xA0, 0x200B, 0x2009, 0x2002, 0x2003, 0x20, 0x0A, 0x09, 0x0D: continue
                default:
                    let piece = char(c)
                    if let l = out.utf8.last, isDigit(l), let f = piece.utf8.first, isDigit(f) { out += piece } else { cat(&out, piece) }
                }
            }
            return out
        }

        static func escapeText(_ s: String) -> String {
            var out = ""
            for c in s.unicodeScalars {
                switch c {
                case "{", "}", "#", "$", "%", "&", "_": out += "\\" + String(c)
                case "\\": out += "\\backslash "
                case "~": out += "\\sim"
                case "^": out += "\\^{}"
                case "\u{A0}": out += " "
                default: out.unicodeScalars.append(c)
                }
            }
            return out
        }

        static func delimiter(_ s: String) -> String {
            switch s {
            case "": return "."
            case "{": return "\\{"
            case "}": return "\\}"
            case "‖": return "\\|"
            default:
                if s.utf8.count == 1 { return s }
                return symbols[s] ?? s
            }
        }

        /// matrix-like environment name for a bracket pair around a table.
        static func matrixEnvironment(_ open: String, _ close: String) -> String? {
            switch (open, close) {
            case ("(", ")"): return "pmatrix"
            case ("[", "]"): return "bmatrix"
            case ("{", "}"): return "Bmatrix"
            case ("|", "|"): return "vmatrix"
            case ("‖", "‖"): return "Vmatrix"
            case ("{", ""): return "cases"
            default: return nil
            }
        }

        static func environment(_ name: String, _ rows: [[String]]) -> String {
            let body = rows.map { $0.joined(separator: " & ") }.joined(separator: " \\\\ ")
            return "\\begin{\(name)} \(body) \\end{\(name)}"
        }

        /// Collapses whitespace runs and trims, keeping the space of a `\ `.
        static func tidy(_ s: String) -> String {
            var out = String.UnicodeScalarView()
            var pendingSpace = false
            for c in s.unicodeScalars {
                if c == " " || c == "\n" || c == "\t" || c == "\r" || c == "\u{A0}" {
                    pendingSpace = !out.isEmpty
                    continue
                }
                if pendingSpace { out.append(" "); pendingSpace = false }
                out.append(c)
            }
            if pendingSpace, out.last == "\\" { out.append(" ") }
            return String(out)
        }

        static func fallback(_ plain: String) -> String {
            let t = tidy(plain)
            return t.isEmpty ? "?" : escapeLoose(t)
        }

        private static func escapeLoose(_ s: String) -> String {
            var out = ""
            for c in s.unicodeScalars { c.value < 128 && "#$%&_{}^~\\".unicodeScalars.contains(c) ? out += "\\text{" + escapeText(String(c)) + "}" : out.unicodeScalars.append(c) }
            return out
        }
    }

    // MARK: MathML

    private enum MML {
        static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

        static func isSimple(_ t: String) -> Bool { !t.isEmpty && t.utf8.allSatisfy { Tex.isLetter($0) || Tex.isDigit($0) } }

        static func seq(_ nodes: [Node]) -> String {
            var out = ""
            var i = 0
            while i < nodes.count {
                let n = nodes[i]
                if n.name == "mi" || n.name == "mn", let v = n.attrs["mathvariant"], let wrap = Tex.variants[v] {
                    var text = trim(n.text)
                    if isSimple(text), !(v == "normal" && Tex.wordFunctions.contains(text)) {
                        var j = i + 1
                        while j < nodes.count, nodes[j].name == "mi" || nodes[j].name == "mn", nodes[j].attrs["mathvariant"] == v {
                            let t = trim(nodes[j].text)
                            if !isSimple(t) || (v == "normal" && Tex.wordFunctions.contains(t)) { break }
                            text += t
                            j += 1
                        }
                        Tex.cat(&out, wrap + "{" + text + "}")
                        i = j
                        continue
                    }
                }
                if n.name == "mi", i + 1 < nodes.count, nodes[i + 1].name == "mo", trim(nodes[i + 1].text) == "\u{2061}" {
                    let t = trim(n.text)
                    if t.count > 1, t.utf8.allSatisfy(Tex.isLetter), !Tex.wordFunctions.contains(t), n.attrs["mathvariant"] == nil || n.attrs["mathvariant"] == "normal" {
                        Tex.cat(&out, "\\operatorname{" + t + "}")
                        i += 1
                        continue
                    }
                }
                Tex.cat(&out, conv(n))
                i += 1
            }
            return out
        }

        static func unwrap(_ n: Node) -> Node {
            var x = n
            while x.name == "mrow" || x.name == "mstyle", x.kids.count == 1 { x = x.kids[0] }
            return x
        }

        static func moText(_ n: Node) -> String? {
            let x = unwrap(n)
            return x.name == "mo" ? trim(x.text) : nil
        }

        static func styled(_ body: String, _ variant: String?, symbolic: Bool) -> String {
            guard let v = variant, let wrap = Tex.variants[v] else { return body }
            if v == "normal", symbolic { return body }
            return wrap + "{" + body + "}"
        }

        static func conv(_ n: Node) -> String {
            switch n.name {
            case "mi": return mi(n)
            case "mn": return styled(Tex.map(trim(n.text)), n.attrs["mathvariant"], symbolic: false)
            case "mo": return mo(n)
            case "mtext", "ms": return text(n)
            case "mspace": return space(n)
            case "mrow": return mrow(n)
            case "math", "mstyle", "mpadded", "menclose", "merror", "mtd", "mlongdiv", "msgroup", "mscarries":
                return seq(n.kids)
            case "maction": return n.kids.first.map(conv) ?? ""
            case "semantics": return seq(n.kids.first { !$0.name.hasPrefix("annotation") }.map { [$0] } ?? [])
            case "annotation", "annotation-xml", "mprescripts", "none", "mglyph": return ""
            case "msup", "msub", "msubsup": return scripts(n)
            case "mfrac":
                guard n.kids.count >= 2 else { return seq(n.kids) }
                let a = seq(n.kids[0].name == "mrow" ? n.kids[0].kids : [n.kids[0]]), b = seq(n.kids[1].name == "mrow" ? n.kids[1].kids : [n.kids[1]])
                if n.attrs["linethickness"] == "0" || n.attrs["linethickness"] == "0px" { return "{" + a + " \\atop " + b + "}" }
                return "\\frac{" + a + "}{" + b + "}"
            case "msqrt": return "\\sqrt{" + seq(n.kids) + "}"
            case "mroot":
                guard n.kids.count >= 2 else { return "\\sqrt{" + seq(n.kids) + "}" }
                return "\\sqrt[" + conv(n.kids[1]) + "]{" + conv(n.kids[0]) + "}"
            case "munder", "mover", "munderover": return limits(n)
            case "mfenced": return fenced(n)
            case "mtable": return table(n, open: nil, close: nil)
            case "mphantom": return "\\phantom{" + seq(n.kids) + "}"
            case "mmultiscripts": return multiscripts(n)
            default: return n.kids.isEmpty ? Tex.map(trim(n.text)) : seq(n.kids)
            }
        }

        static func mi(_ n: Node) -> String {
            let t = trim(n.text)
            if t.isEmpty { return "" }
            let v = n.attrs["mathvariant"]
            if t.count > 1 {
                if t.utf8.allSatisfy(Tex.isLetter) {
                    if Tex.wordFunctions.contains(t), v == nil || v == "normal" { return "\\" + t }
                    if v == nil { return "\\mathrm{" + t + "}" }
                }
                return styled(Tex.map(t), v, symbolic: false)
            }
            if t == "′" { return "\\prime" }
            if t == "⊥" { return "\\bot" }
            if t == "⊤" { return "\\top" }
            let c = t.unicodeScalars.first!
            let isSymbol = c.value >= 128 && Tex.symbols[t] != nil
            return styled(Tex.char(c), v, symbolic: isSymbol)
        }

        static func mo(_ n: Node) -> String {
            let t = trim(n.text)
            if t.isEmpty { return "" }
            if Tex.wordFunctions.contains(t) { return "\\" + t }
            return Tex.map(t)
        }

        static func text(_ n: Node) -> String {
            let raw = n.text
            let t = trim(raw)
            if t.isEmpty { return raw.isEmpty ? "" : "\\;" }
            if t.hasPrefix("\\"), t.dropFirst().utf8.allSatisfy(Tex.isLetter), t.count > 1 { return t }
            return "\\text{" + Tex.escapeText(raw.replacingOccurrences(of: "\n", with: " ")) + "}"
        }

        static func space(_ n: Node) -> String {
            guard let w = n.attrs["width"] else { return "" }
            switch w {
            case "0.17em", "thinmathspace": return "\\,"
            case "0.22em", "mediummathspace": return "\\:"
            case "0.28em", "thickmathspace": return "\\;"
            case "0.25em": return "\\ "
            case "1em", "veryverythickmathspace": return "\\quad"
            case "2em": return "\\qquad"
            case "-0.17em", "negativethinmathspace": return "\\!"
            default:
                let digits = w.prefix { $0.isNumber || $0 == "." || $0 == "-" }
                guard let v = Double(digits), v > 0 else { return "" }
                return v < 0.2 ? "\\," : v < 0.6 ? "\\;" : v < 1.5 ? "\\quad" : "\\qquad"
            }
        }

        // MARK: groups and fences

        static func mrow(_ n: Node) -> String {
            let k = n.kids
            if k.count == 3, moText(k[0]) == "(", moText(k[2]) == ")", k[1].name == "mfrac", k[1].attrs["linethickness"] == "0",
               k[1].kids.count >= 2 {
                return "\\binom{" + conv(k[1].kids[0]) + "}{" + conv(k[1].kids[1]) + "}"
            }
            if isFenced(n) {
                let open = trim(k[0].text), close = trim(k[k.count - 1].text)
                let mid = Array(k.dropFirst().dropLast())
                if mid.count == 1, mid[0].name == "mtable", let env = Tex.matrixEnvironment(open, close) {
                    return table(mid[0], open: open, close: close, environment: env)
                }
                var out = "\\left" + Tex.delimiter(open)
                Tex.cat(&out, seq(mid))
                Tex.cat(&out, "\\right" + Tex.delimiter(close))
                return out
            }
            return seq(k)
        }

        static func isFenced(_ n: Node) -> Bool {
            let k = n.kids
            guard n.name == "mrow", k.count >= 2, k[0].name == "mo", k[k.count - 1].name == "mo",
                  k[0].attrs["fence"] == "true", k[k.count - 1].attrs["fence"] == "true",
                  k[0].attrs["stretchy"] != "false" else { return false }
            return true
        }

        /// `(a+b)` written as one mrow: safe to put a script on without extra braces.
        static func isParenGroup(_ n: Node) -> Bool {
            let k = n.kids
            guard n.name == "mrow", k.count >= 2, let open = moText(k[0]), let close = moText(k[k.count - 1]),
                  (open == "(" && close == ")") || (open == "[" && close == "]") else { return false }
            var depth = 0
            for (i, kid) in k.enumerated() {
                guard let t = moText(kid), kid.name == "mo" else { continue }
                if t == open { depth += 1 } else if t == close { depth -= 1; if depth == 0, i < k.count - 1 { return false } }
            }
            return depth == 0
        }

        static func fenced(_ n: Node) -> String {
            let open = n.attrs["open"] ?? "(", close = n.attrs["close"] ?? ")"
            let seps = Array((n.attrs["separators"] ?? ",").filter { $0 != " " })
            var body = ""
            for (i, kid) in n.kids.enumerated() {
                if i > 0, !seps.isEmpty { Tex.cat(&body, Tex.map(String(seps[min(i - 1, seps.count - 1)]))) }
                Tex.cat(&body, conv(kid))
            }
            var out = "\\left" + Tex.delimiter(open)
            Tex.cat(&out, body)
            Tex.cat(&out, "\\right" + Tex.delimiter(close))
            return out
        }

        static func table(_ t: Node, open: String?, close: String?, environment: String? = nil) -> String {
            var rows: [[String]] = []
            for r in t.kids where r.name == "mtr" || r.name == "mlabeledtr" {
                var kids = r.kids
                if r.name == "mlabeledtr", !kids.isEmpty { kids.removeFirst() }
                rows.append(kids.map { Tex.tidy(seq($0.name == "mtd" ? $0.kids : [$0])) })
            }
            if let environment { return Tex.environment(environment, rows) }
            let align = t.attrs["columnalign"] ?? ""
            let body = align.hasPrefix("right left") ? Tex.environment("aligned", rows) : Tex.environment("matrix", rows)
            guard let open, let close else { return body }
            var out = "\\left" + Tex.delimiter(open)
            Tex.cat(&out, body)
            Tex.cat(&out, "\\right" + Tex.delimiter(close))
            return out
        }

        // MARK: scripts

        static func base(_ n: Node) -> String {
            let s = conv(n)
            if s.isEmpty { return "{}" }
            if Tex.isAtomic(s) { return s }
            let x = unwrap(n)
            switch x.name {
            case "mi", "mn": if s.hasPrefix("\\math"), s.hasSuffix("}"), s.utf8.filter({ $0 == 123 }).count == 1 { return s }
            case "msqrt", "mroot", "munder", "mover", "munderover", "mtable": return s
            case "mfrac": if x.attrs["linethickness"] != "0" { return s }
            case "mrow": if isFenced(x) || isParenGroup(x) { return s }
                if x.kids.count == 3, s.hasPrefix("\\binom") { return s }
            default: break
            }
            return "{" + s + "}"
        }

        static func primeCount(_ nodes: [Node]) -> Int? {
            var count = 0
            for n in nodes {
                let x = unwrap(n)
                if x.name == "mrow" {
                    guard !x.kids.isEmpty, let c = primeCount(x.kids) else { return nil }
                    count += c
                    continue
                }
                guard x.name == "mo" else { return nil }
                switch trim(x.text) {
                case "′", "'": count += 1
                case "″": count += 2
                case "‴": count += 3
                default: return nil
                }
            }
            return count == 0 ? nil : count
        }

        static func scripts(_ n: Node) -> String {
            let k = n.kids
            guard k.count >= 2 else { return seq(k) }
            if isBig(k[0]), primeCount(Array(k[1...])) == nil {
                let sub = n.name == "msup" ? "" : conv(k[1])
                let sup = n.name == "msup" ? conv(k[1]) : (n.name == "msubsup" && k.count > 2 ? conv(k[2]) : "")
                return conv(k[0]) + Tex.limitMarks(sub, sup)
            }
            let b = base(k[0])
            switch n.name {
            case "msup":
                if let p = primeCount(Array(k[1...])) { return b + String(repeating: "'", count: p) }
                return b + "^" + Tex.script(conv(k[1]))
            case "msub":
                return b + "_" + Tex.script(conv(k[1]))
            default:
                guard k.count >= 3 else { return b + "_" + Tex.script(conv(k[1])) }
                if let p = primeCount(Array(k[2...])) { return b + "_" + Tex.script(conv(k[1])) + String(repeating: "'", count: p) }
                return b + "_" + Tex.script(conv(k[1])) + "^" + Tex.script(conv(k[2]))
            }
        }

        static func multiscripts(_ n: Node) -> String {
            let k = n.kids
            guard let first = k.first else { return "" }
            func part(_ x: Node?) -> String { x == nil || x!.name == "none" ? "" : conv(x!) }
            var post: [(String, String)] = [], pre: [(String, String)] = []
            var inPre = false
            var i = 1
            while i < k.count {
                if k[i].name == "mprescripts" { inPre = true; i += 1; continue }
                let pair = (part(k[i]), part(i + 1 < k.count ? k[i + 1] : nil))
                if inPre { pre.append(pair) } else { post.append(pair) }
                i += 2
            }
            func marks(_ p: (String, String)) -> String {
                (p.0.isEmpty ? "" : "_" + Tex.script(p.0)) + (p.1.isEmpty ? "" : "^" + Tex.script(p.1))
            }
            var out = ""
            for p in pre { Tex.cat(&out, "{}" + marks(p)) }
            Tex.cat(&out, base(first))
            for (idx, p) in post.enumerated() { Tex.cat(&out, (idx > 0 ? "{}" : "") + marks(p)) }
            return out
        }

        static func isBig(_ n: Node) -> Bool {
            guard let t = moText(n) else { return false }
            return Tex.bigSymbols.contains(t) || TeXMath.limitFunctions.contains(t)
        }

        static func isBrace(_ n: Node) -> Bool {
            let x = unwrap(n)
            guard x.name == "munder" || x.name == "mover", let last = x.kids.last, let t = moText(last) else { return false }
            return t == "⏟" || t == "⏞"
        }

        static func limits(_ n: Node) -> String {
            let k = n.kids
            guard k.count >= 2 else { return seq(k) }
            let under: Node? = n.name == "mover" ? nil : k[1]
            let over: Node? = n.name == "munder" ? nil : (n.name == "mover" ? k[1] : (k.count > 2 ? k[2] : nil))
            let b = k[0]
            if isBig(b) || isBrace(b) {
                if isBrace(b) {
                    var out = conv(b)
                    if let u = under { out += "_" + Tex.script(conv(u)) }
                    if let o = over { out += "^" + Tex.script(conv(o)) }
                    return out
                }
                return conv(b) + Tex.limitMarks(under.map(conv) ?? "", over.map(conv) ?? "")
            }
            if let o = over, under == nil, let mark = moText(o) {
                if mark == "⏞" { return "\\overbrace{" + conv(b) + "}" }
                if Tex.overlineMarks.contains(mark) { return "\\overline{" + conv(b) + "}" }
                if let names = Tex.accentNames[mark] {
                    let s = conv(b)
                    return "\\" + (Tex.isAtomic(s) ? names.0 : names.1) + "{" + s + "}"
                }
            }
            if let u = under, over == nil, let mark = moText(u) {
                if mark == "⏟" { return "\\underbrace{" + conv(b) + "}" }
                if Tex.underlineMarks.contains(mark) { return "\\underline{" + conv(b) + "}" }
            }
            var inner = conv(b)
            if let u = under { inner = "\\underset{" + conv(u) + "}{" + inner + "}" }
            if let o = over { inner = "\\overset{" + conv(o) + "}{" + inner + "}" }
            return inner
        }
    }

    // MARK: OMML

    private enum OMML {
        struct RunKey: Equatable { var sty: String?; var scr: String?; var nor: Bool }
        enum Item {
            case run(RunKey, String, Bool)
            case tex(String)
            case atop(String, String)
        }

        static func isOn(_ n: Node?) -> Bool {
            guard let n else { return false }
            let v = n.attr("val") ?? "1"
            return v == "1" || v == "on" || v == "true"
        }

        static func structural(_ nodes: [Node]) -> [Node] {
            nodes.filter { !$0.name.hasSuffix("Pr") && !$0.name.hasPrefix("w:") }
        }

        static func part(_ n: Node, _ name: String, fm: Bool = false) -> String {
            guard let c = n.child(name) else { return "" }
            return seq(c.kids, funcMode: fm)
        }

        static func seq(_ nodes: [Node], funcMode: Bool = false, amp: Bool = false) -> String {
            var items: [Item] = []
            for n in nodes {
                if n.name == "m:r" {
                    var key = RunKey(sty: nil, scr: nil, nor: false)
                    var aln = false
                    if let pr = n.child("m:rPr") {
                        key.sty = pr.child("m:sty")?.attr("val")
                        key.scr = pr.child("m:scr")?.attr("val")
                        key.nor = isOn(pr.child("m:nor"))
                        aln = pr.child("m:aln") != nil
                    }
                    var text = ""
                    for t in n.kids where t.name == "m:t" || t.name == "w:t" { text += t.text }
                    if text.isEmpty && !aln { continue }
                    if case .run(let k, let prev, let a)? = items.last, k == key, !aln {
                        items[items.count - 1] = .run(k, prev + text, a)
                    } else {
                        items.append(.run(key, text, aln))
                    }
                    continue
                }
                if n.name.hasSuffix("Pr") || n.name.hasPrefix("w:") { continue }
                if n.name == "m:f", n.child("m:fPr")?.child("m:type")?.attr("val") == "noBar" {
                    items.append(.atop(part(n, "m:num"), part(n, "m:den")))
                    continue
                }
                let s = conv(n, funcMode: funcMode)
                if !s.isEmpty { items.append(.tex(s)) }
            }
            // a "(", a bar-less fraction and a ")" are a binomial
            for i in items.indices {
                guard case .atop(let num, let den) = items[i] else { continue }
                var done = false
                if i > 0, i + 1 < items.count, case .run(let k1, let t1, let a1) = items[i - 1], case .run(let k2, let t2, let a2) = items[i + 1],
                   t1.trimmingCharacters(in: .whitespaces).hasSuffix("("), t2.trimmingCharacters(in: .whitespaces).hasPrefix(")") {
                    let a = t1.trimmingCharacters(in: .whitespaces), b = t2.trimmingCharacters(in: .whitespaces)
                    items[i - 1] = .run(k1, String(a.dropLast()), a1)
                    items[i + 1] = .run(k2, String(b.dropFirst()), a2)
                    items[i] = .tex("\\binom{" + num + "}{" + den + "}")
                    done = true
                }
                if !done { items[i] = .tex("{" + num + " \\atop " + den + "}") }
            }
            var out = ""
            for item in items {
                switch item {
                case .run(let key, let text, let aln): Tex.cat(&out, run(key, text, aln, funcMode: funcMode, amp: amp))
                case .tex(let s): Tex.cat(&out, s)
                case .atop: break
                }
            }
            return out
        }

        static func run(_ key: RunKey, _ text: String, _ aln: Bool, funcMode: Bool, amp: Bool) -> String {
            if key.nor { return "\\text{" + Tex.escapeText(text) + "}" }
            var wrap: String?
            switch key.scr {
            case "script": wrap = "\\mathcal"
            case "fraktur": wrap = "\\mathfrak"
            case "double-struck": wrap = "\\mathbb"
            case "sans-serif": wrap = "\\mathsf"
            case "monospace": wrap = "\\mathtt"
            default: break
            }
            if wrap == nil { wrap = key.sty == "b" ? "\\mathbf" : key.sty == "bi" ? "\\boldsymbol" : nil }
            let plain = key.sty == "p" && wrap == nil
            var out = aln && amp ? "&" : ""
            let chars = Array(text.unicodeScalars)
            var i = 0
            while i < chars.count {
                let c = chars[i]
                var piece = ""
                if c.value < 128, Tex.isLetter(UInt8(c.value)) {
                    var j = i
                    var word = ""
                    while j < chars.count, chars[j].value < 128, Tex.isLetter(UInt8(chars[j].value)) { word.unicodeScalars.append(chars[j]); j += 1 }
                    i = j
                    if wrap == nil, funcMode || plain {
                        piece = Tex.wordFunctions.contains(word) ? "\\" + word : funcMode ? "\\operatorname{" + word + "}" : "\\mathrm{" + word + "}"
                    } else if let wrap { piece = wrap + "{" + word + "}" } else { piece = word }
                } else if c.value < 128, Tex.isDigit(UInt8(c.value)) {
                    var j = i
                    var number = ""
                    while j < chars.count, chars[j].value < 128, Tex.isDigit(UInt8(chars[j].value)) || (chars[j] == "." && j + 1 < chars.count && Tex.isDigit(UInt8(truncatingIfNeeded: chars[j + 1].value)) && chars[j + 1].value < 128) {
                        number.unicodeScalars.append(chars[j]); j += 1
                    }
                    i = j
                    piece = wrap == nil ? number : wrap! + "{" + number + "}"
                } else {
                    i += 1
                    switch c.value {
                    case 0x2061...0x2064, 0xA0, 0x200B, 0x2009, 0x2002, 0x2003, 0x20, 0x0A, 0x09, 0x0D: continue
                    default: break
                    }
                    piece = amp && c == "&" ? "&" : Tex.char(c)
                }
                Tex.cat(&out, piece)
            }
            return out
        }

        /// Base of a script: braces unless it is one token or one self-delimiting command.
        static func base(_ e: Node?) -> String {
            guard let e else { return "{}" }
            let s = seq(e.kids)
            if s.isEmpty { return "{}" }
            if Tex.isAtomic(s) { return s }
            let ks = structural(e.kids)
            if ks.count == 1, ks[0].name == "m:r", s.hasPrefix("\\math"), s.hasSuffix("}"), s.utf8.filter({ $0 == 123 }).count == 1 { return s }
            if ks.count == 1 {
                let keeps: [String: [String]] = ["m:d": ["\\left", "\\binom", "\\begin"], "m:rad": ["\\sqrt"], "m:f": ["\\frac", "\\binom"],
                                                 "m:bar": ["\\overline", "\\underline"], "m:acc": ["\\"], "m:groupChr": ["\\underbrace", "\\overbrace"]]
                if let prefixes = keeps[ks[0].name], prefixes.contains(where: { s.hasPrefix($0) }) { return s }
            }
            return "{" + s + "}"
        }

        static func isPrimes(_ s: String) -> Bool { !s.isEmpty && s.utf8.allSatisfy { $0 == 39 } }

        static func conv(_ n: Node, funcMode: Bool = false) -> String {
            switch n.name {
            case "m:oMath", "m:oMathPara", "m:e", "m:sub", "m:sup", "m:num", "m:den", "m:deg", "m:lim", "m:fName", "m:box", "m:borderBox":
                if n.name == "m:box" || n.name == "m:borderBox" { return part(n, "m:e") }
                return seq(n.kids)
            case "m:f":
                let type = n.child("m:fPr")?.child("m:type")?.attr("val")
                let num = part(n, "m:num"), den = part(n, "m:den")
                if type == "lin" || type == "skw" { return Tex.braced(num) + "/" + Tex.braced(den) }
                return "\\frac{" + num + "}{" + den + "}"
            case "m:sSup":
                let b = base(n.child("m:e")), s = part(n, "m:sup")
                return isPrimes(s) ? b + s : b + "^" + Tex.script(s)
            case "m:sSub":
                return base(n.child("m:e")) + "_" + Tex.script(part(n, "m:sub"))
            case "m:sSubSup":
                let b = base(n.child("m:e")), sub = part(n, "m:sub"), sup = part(n, "m:sup")
                return isPrimes(sup) ? b + "_" + Tex.script(sub) + sup : b + "_" + Tex.script(sub) + "^" + Tex.script(sup)
            case "m:sPre":
                var out = "{}"
                let sub = part(n, "m:sub"), sup = part(n, "m:sup")
                if !sub.isEmpty { out += "_" + Tex.script(sub) }
                if !sup.isEmpty { out += "^" + Tex.script(sup) }
                Tex.cat(&out, base(n.child("m:e")))
                return out
            case "m:rad":
                let e = part(n, "m:e"), deg = part(n, "m:deg")
                if isOn(n.child("m:radPr")?.child("m:degHide")) || deg.isEmpty { return "\\sqrt{" + e + "}" }
                return "\\sqrt[" + deg + "]{" + e + "}"
            case "m:nary": return nary(n)
            case "m:d": return delimited(n)
            case "m:func":
                let name = part(n, "m:fName", fm: true)
                let body = part(n, "m:e")
                var out = name
                let ks = n.child("m:e").map { structural($0.kids) } ?? []
                let single = ks.count == 1 && ks[0].name != "m:r"
                Tex.cat(&out, Tex.isAtomic(body) || single || body.isEmpty ? body : "{" + body + "}")
                return out
            case "m:limLow", "m:limUpp": return limit(n, funcMode: funcMode)
            case "m:acc":
                let mark = n.child("m:accPr")?.child("m:chr")?.attr("val") ?? "\u{302}"
                let s = part(n, "m:e")
                let names = Tex.accentNames[mark] ?? ("hat", "widehat")
                return "\\" + (Tex.isAtomic(s) ? names.0 : names.1) + "{" + s + "}"
            case "m:bar":
                let top = n.child("m:barPr")?.child("m:pos")?.attr("val") == "top"
                return (top ? "\\overline{" : "\\underline{") + part(n, "m:e") + "}"
            case "m:groupChr":
                let pr = n.child("m:groupChrPr")
                let mark = pr?.child("m:chr")?.attr("val")
                let top = pr?.child("m:pos")?.attr("val") == "top"
                let e = part(n, "m:e")
                if mark == "⏞" || (mark == nil && top) { return "\\overbrace{" + e + "}" }
                if mark == nil || mark == "⏟" { return "\\underbrace{" + e + "}" }
                return top ? "\\overset{" + Tex.map(mark!) + "}{" + e + "}" : "\\underset{" + Tex.map(mark!) + "}{" + e + "}"
            case "m:m": return matrix(n, environment: "matrix")
            case "m:eqArr": return equationArray(n, environment: "aligned")
            case "m:phant":
                let hidden = n.child("m:phantPr")?.child("m:show").map { !isOn($0) } ?? false
                return hidden ? "\\phantom{" + part(n, "m:e") + "}" : part(n, "m:e")
            default:
                return n.kids.isEmpty ? "" : seq(n.kids)
            }
        }

        static func matrix(_ n: Node, environment: String) -> String {
            var rows: [[String]] = []
            for r in n.kids where r.name == "m:mr" {
                rows.append(r.kids.filter { $0.name == "m:e" }.map { Tex.tidy(seq($0.kids)) })
            }
            return Tex.environment(environment, rows)
        }

        static func equationArray(_ n: Node, environment: String) -> String {
            let rows = n.kids.filter { $0.name == "m:e" }.map { Tex.tidy(seq($0.kids, amp: true)) }
            return Tex.environment(environment, rows.map { [$0] })
        }

        static func nary(_ n: Node) -> String {
            let pr = n.child("m:naryPr")
            let mark = pr?.child("m:chr")?.attr("val") ?? "∫"
            var out = Tex.map(mark)
            let sub = isOn(pr?.child("m:subHide")) ? "" : part(n, "m:sub")
            let sup = isOn(pr?.child("m:supHide")) ? "" : part(n, "m:sup")
            out += Tex.limitMarks(sub, sup)
            let body = part(n, "m:e")
            let ks = n.child("m:e").map { structural($0.kids) } ?? []
            let single = ks.count == 1 && ks[0].name != "m:r"
            Tex.cat(&out, Tex.isAtomic(body) || single || body.isEmpty ? body : "{" + body + "}")
            return out
        }

        static func delimited(_ n: Node) -> String {
            let pr = n.child("m:dPr")
            func chr(_ name: String, _ fallback: String) -> String { pr?.child(name)?.attr("val") ?? fallback }
            let open = chr("m:begChr", "("), close = chr("m:endChr", ")"), sep = chr("m:sepChr", "|")
            let es = n.kids.filter { $0.name == "m:e" }
            if es.count == 1 {
                let inner = structural(es[0].kids)
                if inner.count == 1 {
                    if inner[0].name == "m:m", let env = Tex.matrixEnvironment(open, close) { return matrix(inner[0], environment: env) }
                    if inner[0].name == "m:eqArr", open == "{", close.isEmpty { return equationArray(inner[0], environment: "cases") }
                    if inner[0].name == "m:f", open == "(", close == ")", inner[0].child("m:fPr")?.child("m:type")?.attr("val") == "noBar" {
                        return "\\binom{" + part(inner[0], "m:num") + "}{" + part(inner[0], "m:den") + "}"
                    }
                }
            }
            var body = ""
            for (i, e) in es.enumerated() {
                if i > 0 { Tex.cat(&body, sep.isEmpty ? " " : Tex.map(sep)) }
                Tex.cat(&body, seq(e.kids))
            }
            var out = "\\left" + Tex.delimiter(open)
            Tex.cat(&out, body)
            Tex.cat(&out, "\\right" + Tex.delimiter(close))
            return out
        }

        static func limit(_ n: Node, funcMode: Bool) -> String {
            let below = n.name == "m:limLow"
            let limTeX = part(n, "m:lim")
            let eNode = n.child("m:e")
            // ∑ with limits above and below arrives as limUpp(limLow(…))
            if !below, let eNode, let inner = structural(eNode.kids).first, structural(eNode.kids).count == 1, inner.name == "m:limLow" {
                let b = part(inner, "m:e")
                if isBigOrLimit(b) { return b + Tex.limitMarks(part(inner, "m:lim"), limTeX) }
            }
            let e = seq(eNode?.kids ?? [], funcMode: funcMode)
            let lim = rawText(n.child("m:lim"))
            if isBigOrLimit(e) { return e + (below ? Tex.limitMarks(limTeX, "") : Tex.limitMarks("", limTeX)) }
            if e.hasPrefix("\\underbrace") || e.hasPrefix("\\overbrace") { return e + (below ? "_" : "^") + Tex.script(limTeX) }
            if below {
                if lim == "⏟" { return "\\underbrace{" + e + "}" }
                if lim == "_" || lim == "\u{332}" || lim == "‗" { return "\\underline{" + e + "}" }
                return "\\underset{" + limTeX + "}{" + e + "}"
            }
            if lim == "⏞" { return "\\overbrace{" + e + "}" }
            if lim == "\u{305}" || lim == "¯" || lim == "‾" { return "\\overline{" + e + "}" }
            return "\\overset{" + limTeX + "}{" + e + "}"
        }

        static func rawText(_ n: Node?) -> String {
            guard let n else { return "" }
            return n.kids.filter { $0.name == "m:r" }.flatMap { $0.kids.filter { $0.name == "m:t" } }.map { $0.text }.joined()
        }

        static func isBigOrLimit(_ s: String) -> Bool {
            if s.hasPrefix("\\") {
                let name = s.dropFirst().prefix { $0.isLetter }
                if TeXMath.limitFunctions.contains(String(name)) || TeXMath.bigOperators[String(name)] != nil { return name.count == s.count - 1 }
            }
            return false
        }
    }
}
