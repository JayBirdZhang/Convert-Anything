import AppKit
import PDFKit
import ObjectiveC

/// Repairs ligatures that a PDF's text layer gets wrong. Some PDFs (Pages with Calibri, for one) leave their
/// ligature glyphs out of the font's character map, so every reader shows a stand-in character instead:
/// "Publica@on", "scienAfic", "wriEen". Only words with such a character (a symbol, or a capital inside a
/// lowercase word) are looked at; a ligature is put in only when the spell checker accepts the result.
/// Once a font's stand-in has been confirmed a few times it's applied straight away.
nonisolated enum Ligatures {
    private static let candidates = ["ti", "tt", "ft", "fi", "fl", "ff", "ffi", "ffl", "tf", "tti"]
    /// Characters a stand-in can be besides letters. Common punctuation (. , ' - / …) is never touched.
    private static let symbols: Set<Unicode.Scalar> = Set("@#$%&*+<=>^_`|~\\{}[]".unicodeScalars)
    private static let symbolBytes: [Bool] = (0..<128).map { symbols.contains(Unicode.Scalar(UInt8($0))) }
    private static let confirmations = 3

    /// The text with broken ligatures repaired. `font` names the font (stand-ins differ between fonts);
    /// `document` holds what has been learned about it.
    static func repair(_ text: String, font: String, document: PDFDocument?) -> String {
        // Cheap check first, on the raw bytes: a capital after a lowercase letter, or a symbol next to a letter.
        // (Stand-ins are plain ASCII; other characters count as neither.)
        var previous: UInt8 = 0     // 1 lowercase, 2 capital, 3 symbol
        var suspicious = false
        for byte in text.utf8 {
            let kind: UInt8 = byte >= 0x61 && byte <= 0x7A ? 1 : byte >= 0x41 && byte <= 0x5A ? 2 : symbolBytes[Int(byte & 0x7F)] && byte < 0x80 ? 3 : 0
            if (previous == 1 && kind >= 2) || (previous == 2 && kind == 3) || (previous == 3 && kind == 1) { suspicious = true; break }
            previous = kind
        }
        guard suspicious else { return text }

        let memory = document.map(Memory.of)
        var result = ""
        var changed = false
        // Whole tokens (between spaces), so e-mail addresses, links and code can be recognized and skipped.
        for (index, token) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { result += " " }
            let repaired = repairToken(token, font: font, memory: memory)
            if repaired != token { changed = true }
            result += repaired
        }
        return changed ? result : text
    }

    private static func repairToken(_ token: Substring, font: String, memory: Memory?) -> String {
        let leading: Set<Character> = ["(", "[", "\"", "'", "“", "‘"]
        let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "\"", "'", "”", "’", "…"]
        var core = token
        while let first = core.first, leading.contains(first) { core.removeFirst() }
        while let last = core.last, trailing.contains(last) { core.removeLast() }
        // Links, e-mail addresses, file names, code, numbers: left alone.
        guard !core.isEmpty, !core.contains(where: { ".:\\=_".contains($0) || $0.isNumber }) else { return String(token) }

        // Hyphenated words and "and/or": each part on its own.
        var parts: [String] = []
        var separators: [Character] = []
        var part = ""
        var changed = false
        func finish() {
            let fixed = repairWord(Substring(part), font: font, memory: memory) ?? part
            if fixed != part { changed = true }
            parts.append(fixed)
            part = ""
        }
        for character in core {
            if "-/–—".contains(character) { finish(); separators.append(character) } else { part.append(character) }
        }
        finish()
        guard changed else { return String(token) }
        let prefix = token[token.startIndex..<core.startIndex], suffix = token[core.endIndex...]
        var joined = parts[0]
        for (separator, part) in zip(separators, parts.dropFirst()) { joined.append(separator); joined += part }
        return prefix + joined + suffix
    }

    /// The repaired word, or nil to leave it as it is.
    private static func repairWord(_ word: Substring, font: String, memory: Memory?) -> String? {
        let characters = Array(word)
        guard characters.count >= 3, characters.count < 40 else { return nil }
        // Where the stand-ins are: after a letter, a symbol; after a lowercase letter, a capital.
        var spots: [Int] = []
        var symbolOnly = true
        var letterSpots = 0
        // A symbol can also start a word ("@meline"); such words are always spell checked.
        let startsWithSymbol = characters[0].unicodeScalars.count == 1 && symbols.contains(characters[0].unicodeScalars.first!)
            && characters[1].isLowercase
        if startsWithSymbol { spots.append(0) }
        for i in 1..<characters.count {
            let c = characters[i], previous = characters[i - 1]
            if c.unicodeScalars.count == 1, symbols.contains(c.unicodeScalars.first!), previous.isLetter {
                spots.append(i)
            } else if c.isUppercase && (previous.isLowercase
                        || (spots.last == i - 1 && i + 1 < characters.count && characters[i + 1].isLowercase)) {  // "compeAAon"
                spots.append(i)
                symbolOnly = false
                letterSpots += 1
            } else if !c.isLetter {
                return nil
            }
        }
        guard !spots.isEmpty, spots.count <= 2, characters[0].isLetter || startsWithSymbol,
              characters.count - spots.count >= 3 else { return nil }   // Not "a&b", "x+y"
        let key = font + "\u{1}" + String(word)
        if let known = memory?.word(key) { return known }
        // A font that has had many such words and no ligatures isn't broken: stop checking it
        // (a programming manual's camel-case names would otherwise cost a spell check each).
        if memory?.givenUp(font: font) == true { return nil }

        // In a word in capitals the ligature is in capitals too.
        let others = characters.indices.filter { !spots.contains($0) }.map { characters[$0] }
        let upper = others.allSatisfy(\.isUppercase)
        // A capital stand-in only inside an otherwise lowercase word: "DiRAC" and "MuSCAT" are acronyms.
        if letterSpots > 0 && others.dropFirst().contains(where: \.isUppercase) { return nil }
        func build(_ choice: [String]) -> String {
            var text = ""
            var next = 0
            for (i, c) in characters.enumerated() {
                if next < spots.count && spots[next] == i { text += upper ? choice[next].uppercased() : choice[next]; next += 1 }
                else { text.append(c) }
            }
            return text
        }
        let standIns = spots.map { String(characters[$0]) }
        let learned = standIns.map { memory?.learned(font: font, standIn: $0) }
        let allLearned = learned.allSatisfy { $0 != nil }
        // A symbol ending a word is usually a footnote mark ("the*"), not a ligature, unless already learned.
        if let last = spots.last, last == characters.count - 1, !characters[last].isLetter, learned.last! == nil { return nil }
        // Two different capitals inside one word is usually camel case ("LaTeX"): only repaired with learned
        // ligatures. The same one twice ("desAnaAon") is tried as the same ligature twice.
        let sameStandIn = standIns.count == 2 && standIns[0] == standIns[1]
        if letterSpots > 1 && !allLearned && !sameStandIn { return nil }

        // A symbol that's been confirmed is put in without checking again.
        var answer: String?
        if symbolOnly, !upper, !startsWithSymbol, allLearned {
            answer = build(learned.map { $0! })
        } else {
            answer = SpellCheck.withLock { checker in
                // The learned ligature first.
                if allLearned {
                    let word = build(learned.map { $0! })
                    if checker.accepts(word) { return word }
                }
                if letterSpots > 1 && !sameStandIn { return nil }
                var accepted: [[String]] = []
                var choice = [String](repeating: "", count: spots.count)
                func search(_ position: Int) {
                    if position == spots.count {
                        if checker.accepts(build(choice)) { accepted.append(choice) }
                        return
                    }
                    for candidate in candidates where accepted.count < 2 {
                        if sameStandIn && position == 1 && candidate != choice[0] { continue }
                        choice[position] = candidate
                        search(position + 1)
                    }
                }
                search(0)
                // (The word as it stands isn't asked about: the spell checker passes "draYs" and "@meline". Names
                // like "iPhone", "McDonald" and "AT&T" are safe anyway, since no ligature makes them a word.)
                guard let first = accepted.first else { return nil }
                // Only a word with one possible reading confirms a stand-in ("rattle" or "raffle" doesn't).
                if accepted.count == 1 {
                    for (standIn, ligature) in zip(standIns, first) { memory?.confirm(font: font, standIn: standIn, ligature: ligature) }
                }
                return build(first)
            }
        }
        memory?.remember(key, answer, font: font)
        return answer
    }

    /// What has been learned about one document: each word's decision, so a word reads the same every time
    /// (tables compare two readings of the same text), and which ligature each font's stand-ins are.
    private final class Memory {
        private let lock = NSLock()
        private var words: [String: String?] = [:]
        private var counts: [String: [String: Int]] = [:]
        private var learnedLigatures: [String: String] = [:]
        nonisolated(unsafe) private static var key: UInt8 = 0
        nonisolated(unsafe) private static var byFile: [URL: Memory] = [:]
        private static let creation = NSLock()

        /// Shared by the page workers' copies of the same file, so what one learns helps the others.
        static func of(_ document: PDFDocument) -> Memory {
            creation.withLock {
                if let memory = objc_getAssociatedObject(document, &key) as? Memory { return memory }
                let memory: Memory
                if let url = document.documentURL {
                    if byFile.count > 8 { byFile.removeAll() }
                    memory = byFile[url] ?? Memory()
                    byFile[url] = memory
                } else {
                    memory = Memory()
                }
                objc_setAssociatedObject(document, &key, memory, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                return memory
            }
        }

        func word(_ key: String) -> String?? { lock.withLock { words[key] } }
        private var misses: [String: Int] = [:]
        private var fixed: Set<String> = []

        func remember(_ key: String, _ value: String?, font: String) {
            lock.withLock {
                words[key] = .some(value)
                if value == nil { misses[font, default: 0] += 1 } else { fixed.insert(font) }
            }
        }
        func givenUp(font: String) -> Bool { lock.withLock { !fixed.contains(font) && misses[font, default: 0] >= 30 } }
        func learned(font: String, standIn: String) -> String? { lock.withLock { learnedLigatures[font + "\u{1}" + standIn] } }

        func confirm(font: String, standIn: String, ligature: String) {
            lock.withLock {
                let key = font + "\u{1}" + standIn
                var tally = counts[key] ?? [:]
                tally[ligature, default: 0] += 1
                counts[key] = tally
                if let best = tally.max(by: { $0.value < $1.value }), best.value >= confirmations,
                   !tally.contains(where: { $0.key != best.key && $0.value * 2 > best.value }) {
                    learnedLigatures[key] = best.key
                }
            }
        }
    }
}

/// The system spell checker, one caller at a time: pages are read on several threads and NSSpellChecker
/// isn't documented as thread-safe.
nonisolated enum SpellCheck {
    struct Checker {
        fileprivate let checker: NSSpellChecker
        /// Words in capitals are checked in lowercase: the spell checker passes anything in capitals.
        func accepts(_ word: String) -> Bool {
            let word = word.contains(where: \.isLowercase) ? word : word.lowercased()
            return checker.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
                .location == NSNotFound
        }
    }

    private static let lock = NSLock()

    static func withLock<T>(_ body: (Checker) -> T) -> T {
        lock.withLock { body(Checker(checker: NSSpellChecker.shared)) }
    }
}
