import Foundation

/// Turns LaTeX math ("\frac{a}{b}", "x^2 + \alpha") into MathML, which macOS's web engine draws as real
/// math. Covers what notes and papers commonly use: fractions, roots, powers and indexes, Greek letters,
/// operators and relations, big operators with limits, functions, brackets, matrices and cases, accents,
/// fonts and text. Anything it doesn't know is shown as written rather than dropped.
nonisolated enum TeXMath {
    static func mathML(_ tex: String, display: Bool) -> String {
        var parser = Parser(tokens: tokenize(tex))
        let body = parser.parseSequence(until: [])
        let mode = display ? "block" : "inline"
        return #"<math xmlns="http://www.w3.org/1998/Math/MathML" display="\#(mode)"><mrow>\#(body)</mrow></math>"#
    }

    // MARK: Tokens

    enum Token: Equatable {
        case command(String)    // \frac, \alpha, \{ …
        case open, close        // { }
        case sup, sub           // ^ _
        case align, newline     // & \\
        case char(Character)
        case number(String)
    }

    static func tokenize(_ tex: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(tex)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                i += 1
                guard i < chars.count else { break }
                if chars[i] == "\\" { tokens.append(.newline); i += 1; continue }
                if chars[i].isLetter {
                    var name = ""
                    while i < chars.count, chars[i].isLetter { name.append(chars[i]); i += 1 }
                    tokens.append(.command(name))
                } else {
                    tokens.append(.command(String(chars[i]))); i += 1
                }
                continue
            case "{": tokens.append(.open)
            case "}": tokens.append(.close)
            case "^": tokens.append(.sup)
            case "_": tokens.append(.sub)
            case "&": tokens.append(.align)
            case " ", "\t", "\n", "\r": break
            default:
                if c.isNumber {
                    var number = ""
                    while i < chars.count, chars[i].isNumber || (chars[i] == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                        number.append(chars[i]); i += 1
                    }
                    tokens.append(.number(number))
                    continue
                }
                tokens.append(.char(c))
            }
            i += 1
        }
        return tokens
    }

    // MARK: Symbols

    static let greek: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "infty": "∞", "partial": "∂", "nabla": "∇", "ell": "ℓ", "hbar": "ℏ", "emptyset": "∅", "varnothing": "∅",
        "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "forall": "∀", "exists": "∃", "neg": "¬", "lnot": "¬", "top": "⊤", "bot": "⊥",
        "angle": "∠", "triangle": "△", "prime": "′", "dots": "…", "ldots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱",
    ]

    static let operators: [String: String] = [
        "pm": "±", "mp": "∓", "times": "×", "div": "÷", "cdot": "⋅", "ast": "∗", "star": "⋆", "circ": "∘", "bullet": "∙",
        "cap": "∩", "cup": "∪", "setminus": "∖", "wedge": "∧", "land": "∧", "vee": "∨", "lor": "∨", "oplus": "⊕",
        "otimes": "⊗", "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡",
        "sim": "∼", "simeq": "≃", "cong": "≅", "propto": "∝", "ll": "≪", "gg": "≫", "in": "∈", "notin": "∉", "ni": "∋",
        "subset": "⊂", "supset": "⊃", "subseteq": "⊆", "supseteq": "⊇", "mid": "∣", "parallel": "∥", "perp": "⊥",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "gets": "←", "leftrightarrow": "↔", "Rightarrow": "⇒",
        "Leftarrow": "⇐", "Leftrightarrow": "⇔", "implies": "⟹", "iff": "⟺", "mapsto": "↦", "uparrow": "↑",
        "downarrow": "↓", "longrightarrow": "⟶", "therefore": "∴", "because": "∵", "colon": ":",
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉", "vert": "|", "Vert": "‖",
        "{": "{", "}": "}", "|": "‖", "lbrace": "{", "rbrace": "}",
    ]

    static let bigOperators: [String: String] = [
        "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
        "bigcup": "⋃", "bigcap": "⋂", "bigoplus": "⨁", "bigotimes": "⨂",
    ]

    static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "log", "ln", "lg",
        "exp", "det", "dim", "ker", "deg", "gcd", "arg", "hom", "Pr",
    ]
    static let limitFunctions: Set<String> = ["lim", "max", "min", "sup", "inf", "limsup", "liminf", "argmax", "argmin"]

    static let accents: [String: String] = [
        "hat": "^", "widehat": "^", "bar": "¯", "overline": "¯", "vec": "→", "overrightarrow": "→", "dot": "˙",
        "ddot": "¨", "tilde": "~", "widetilde": "~", "check": "ˇ", "breve": "˘", "acute": "´", "grave": "`",
    ]

    static let spaces: [String: String] = [",": "0.17em", ":": "0.22em", ";": "0.28em", " ": "0.25em", "quad": "1em", "qquad": "2em", "!": "-0.17em"]

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: Parser

    struct Parser {
        var tokens: [Token]
        var index = 0

        var peek: Token? { index < tokens.count ? tokens[index] : nil }

        mutating func next() -> Token? {
            defer { index += 1 }
            return peek
        }

        /// Parses until one of `stop` (not consumed) or the end.
        mutating func parseSequence(until stop: [Token], stopCommands: Set<String> = []) -> String {
            var out = ""
            while let token = peek, !stop.contains(token) {
                if case .command(let name) = token, stopCommands.contains(name) { break }
                if token == .close { break }
                out += parseScripted()
            }
            return out
        }

        /// One atom with any ^ and _ attached.
        mutating func parseScripted() -> String {
            var (base, isBig) = parseAtom()
            _ = isBig
            var sub: String?, sup: String?
            while let token = peek, token == .sup || token == .sub || token == .char("'") {
                index += 1
                if token == .char("'") { sup = (sup ?? "") + "<mo>′</mo>"; continue }
                let script = parseAtom().0
                if token == .sup { sup = script } else { sub = script }
            }
            if base.isEmpty && (sub != nil || sup != nil) { base = "<mrow></mrow>" }
            switch (sub, sup) {
            case let (s?, p?): base = isBig ? "<munderover>\(base)\(s)\(p)</munderover>" : "<msubsup>\(base)\(s)\(p)</msubsup>"
            case let (s?, nil): base = isBig ? "<munder>\(base)\(s)</munder>" : "<msub>\(base)\(s)</msub>"
            case let (nil, p?): base = isBig ? "<mover>\(base)\(p)</mover>" : "<msup>\(base)\(p)</msup>"
            default: break
            }
            return base
        }

        /// A group in braces, or a single atom when there are no braces.
        mutating func parseArgument() -> String {
            if peek == .open {
                index += 1
                let content = parseSequence(until: [.close])
                if peek == .close { index += 1 }
                return "<mrow>\(content)</mrow>"
            }
            return parseAtom().0
        }

        /// Raw text of a braced argument (for \text, \begin{…}).
        mutating func parseRawArgument() -> String {
            guard peek == .open else {
                if case .char(let c)? = next() { return String(c) }
                return ""
            }
            index += 1
            var depth = 1, text = ""
            while let token = next() {
                switch token {
                case .open: depth += 1; text += "{"
                case .close:
                    depth -= 1
                    if depth == 0 { return text }
                    text += "}"
                case .char(let c): text.append(c)
                case .number(let n): text += n
                case .command(let name): text += name.count == 1 ? name : "\\" + name + " "
                case .sup: text += "^"
                case .sub: text += "_"
                case .align: text += "&"
                case .newline: text += " "
                }
            }
            return text
        }

        /// Returns the MathML and whether it's a big operator (limits go above and below).
        mutating func parseAtom() -> (String, Bool) {
            guard let token = next() else { return ("", false) }
            switch token {
            case .open:
                let content = parseSequence(until: [.close])
                if peek == .close { index += 1 }
                return ("<mrow>\(content)</mrow>", false)
            case .close, .sup, .sub, .align, .newline:
                return ("", false)
            case .number(let n):
                return ("<mn>\(n)</mn>", false)
            case .char(let c):
                if c.isLetter { return ("<mi>\(TeXMath.escape(String(c)))</mi>", false) }
                if c == "'" { return ("<mo>′</mo>", false) }
                return ("<mo>\(TeXMath.escape(String(c)))</mo>", false)
            case .command(let name):
                return parseCommand(name)
            }
        }

        mutating func parseCommand(_ name: String) -> (String, Bool) {
            if let symbol = TeXMath.greek[name] {
                let isUpright = name.first?.isUppercase == true || ["infty", "partial", "nabla", "emptyset", "varnothing", "forall", "exists", "dots", "ldots", "cdots", "vdots", "ddots", "angle", "triangle", "prime", "neg", "lnot", "top", "bot", "aleph"].contains(name)
                return (isUpright ? "<mi mathvariant=\"normal\">\(symbol)</mi>" : "<mi>\(symbol)</mi>", false)
            }
            if let symbol = TeXMath.operators[name] { return ("<mo>\(TeXMath.escape(symbol))</mo>", false) }
            if let symbol = TeXMath.bigOperators[name] {
                let isIntegral = name.contains("int")
                return (isIntegral ? "<mo>\(symbol)</mo>" : "<mo movablelimits=\"true\">\(symbol)</mo>", !isIntegral)
            }
            if TeXMath.functions.contains(name) { return ("<mi>\(name)</mi><mo>&#x2061;</mo>", false) }
            if TeXMath.limitFunctions.contains(name) { return ("<mo movablelimits=\"true\" form=\"prefix\">\(name)</mo>", true) }
            if let width = TeXMath.spaces[name] { return ("<mspace width=\"\(width)\"/>", false) }
            if let accent = TeXMath.accents[name] {
                let base = parseArgument()
                return ("<mover accent=\"true\">\(base)<mo stretchy=\"true\">\(TeXMath.escape(accent))</mo></mover>", false)
            }

            switch name {
            case "frac", "dfrac", "tfrac", "cfrac":
                return ("<mfrac>\(parseArgument())\(parseArgument())</mfrac>", false)
            case "binom", "dbinom", "tbinom":
                return ("<mrow><mo>(</mo><mfrac linethickness=\"0\">\(parseArgument())\(parseArgument())</mfrac><mo>)</mo></mrow>", false)
            case "sqrt":
                if peek == .char("[") {
                    index += 1
                    let degree = parseSequence(until: [.char("]")])
                    if peek == .char("]") { index += 1 }
                    return ("<mroot>\(parseArgument())<mrow>\(degree)</mrow></mroot>", false)
                }
                return ("<msqrt>\(parseArgument())</msqrt>", false)
            case "text", "textrm", "textnormal", "mbox", "textit", "textbf":
                let variant = name == "textit" ? " mathvariant=\"italic\"" : name == "textbf" ? " mathvariant=\"bold\"" : ""
                return ("<mtext\(variant)>\(TeXMath.escape(parseRawArgument()))</mtext>", false)
            case "operatorname":
                return ("<mi>\(TeXMath.escape(parseRawArgument()))</mi><mo>&#x2061;</mo>", false)
            case "mathrm", "mathbf", "mathit", "mathbb", "mathcal", "mathfrak", "mathsf", "mathtt", "boldsymbol", "bm":
                let variants = ["mathrm": "normal", "mathbf": "bold", "mathit": "italic", "mathbb": "double-struck", "mathcal": "script",
                                "mathfrak": "fraktur", "mathsf": "sans-serif", "mathtt": "monospace", "boldsymbol": "bold-italic", "bm": "bold-italic"]
                let content = parseArgument().replacingOccurrences(of: "<mi>", with: "<mi mathvariant=\"\(variants[name]!)\">")
                    .replacingOccurrences(of: "<mn>", with: "<mn mathvariant=\"\(variants[name]!)\">")
                return (content, false)
            case "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr":
                guard let delimiter = next() else { return ("", false) }
                var symbol = ""
                switch delimiter {
                case .char(let c): symbol = c == "." ? "" : String(c)
                case .command(let n): symbol = TeXMath.operators[n] ?? (n == "|" ? "‖" : n)
                default: break
                }
                if name == "left" {
                    let content = parseSequence(until: [], stopCommands: ["right"])
                    var closing = ""
                    if peek == .command("right") { index += 1; closing = parseDelimiterSymbol() }
                    return ("<mrow><mo fence=\"true\" stretchy=\"true\">\(TeXMath.escape(symbol))</mo>\(content)<mo fence=\"true\" stretchy=\"true\">\(TeXMath.escape(closing))</mo></mrow>", false)
                }
                return (symbol.isEmpty ? "" : "<mo stretchy=\"true\">\(TeXMath.escape(symbol))</mo>", false)
            case "begin":
                return (parseEnvironment(parseRawArgument()), false)
            case "end":
                _ = parseRawArgument()
                return ("", false)
            case "displaystyle", "textstyle", "scriptstyle", "limits", "nolimits", "nonumber", "notag", "label":
                if name == "label" { _ = parseRawArgument() }
                return ("", false)
            case "overbrace", "underbrace":
                let base = parseArgument()
                return name == "overbrace" ? ("<mover>\(base)<mo stretchy=\"true\">⏞</mo></mover>", true) : ("<munder>\(base)<mo stretchy=\"true\">⏟</mo></munder>", true)
            case "underline":
                return ("<munder>\(parseArgument())<mo stretchy=\"true\">_</mo></munder>", false)
            case "not":
                let (next, _) = parseAtom()
                return ("<mrow>\(next)<mo>&#x338;</mo></mrow>", false)
            case "%", "$", "#", "&", "_":
                return ("<mo>\(TeXMath.escape(name))</mo>", false)
            default:
                return ("<mtext>\\\(TeXMath.escape(name))</mtext>", false)
            }
        }

        mutating func parseDelimiterSymbol() -> String {
            switch next() {
            case .char(let c)?: return c == "." ? "" : String(c)
            case .command(let n)?: return TeXMath.operators[n] ?? (n == "|" ? "‖" : n)
            default: return ""
            }
        }

        /// matrix, pmatrix, bmatrix, vmatrix, cases, aligned, align, array…
        mutating func parseEnvironment(_ name: String) -> String {
            let environment = name.replacingOccurrences(of: "*", with: "")
            if environment == "array" { _ = parseRawArgument() }   // column spec
            var rows: [[String]] = [[]]
            var cell = ""
            while let token = peek {
                if case .command("end") = token {
                    index += 1
                    _ = parseRawArgument()
                    break
                }
                switch token {
                case .align: index += 1; rows[rows.count - 1].append(cell); cell = ""
                case .newline: index += 1; rows[rows.count - 1].append(cell); cell = ""; rows.append([])
                case .close: index += 1
                default: cell += parseScripted()
                }
            }
            rows[rows.count - 1].append(cell)
            if rows.count > 1, rows.last == [""] { rows.removeLast() }

            let isAligned = ["aligned", "align", "alignat", "eqnarray", "gather", "split"].contains(environment)
            let table = "<mtable" + (isAligned ? " columnalign=\"right left\" columnspacing=\"0\"" : environment == "cases" ? " columnalign=\"left left\"" : "") + ">"
                + rows.map { "<mtr>" + $0.map { "<mtd><mrow>\($0)</mrow></mtd>" }.joined() + "</mtr>" }.joined() + "</mtable>"
            let fences: [String: (String, String)] = ["pmatrix": ("(", ")"), "bmatrix": ("[", "]"), "Bmatrix": ("{", "}"),
                                                       "vmatrix": ("|", "|"), "Vmatrix": ("‖", "‖"), "cases": ("{", "")]
            if let (open, close) = fences[environment] {
                return "<mrow><mo fence=\"true\" stretchy=\"true\">\(open)</mo>\(table)<mo fence=\"true\" stretchy=\"true\">\(close)</mo></mrow>"
            }
            return table
        }
    }
}
