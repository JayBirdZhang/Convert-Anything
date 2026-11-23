import AppKit
import PDFKit
import ObjectiveC

/// The PDF's own fonts for a page whose fonts aren't installed on this Mac. PDFKit then reports every run as
/// Helvetica, losing the family and bold/italic, so they're read from the page's content instead: a quick scan
/// that only looks up a character position where the font changes or a new line starts.
nonisolated final class PageFonts {
    struct Font: Equatable {
        var family: String
        var bold: Bool
        var italic: Bool
    }

    /// Page character indices where a font starts, sorted, with the font from there on
    /// (nil: an installed font, so PDFKit's own answer is right).
    private var starts: [Int] = []
    private var fonts: [Font?] = []

    /// The fonts for this page, or nil when PDFKit already knows them all. Computed once per page.
    static func of(_ page: PDFPage) -> PageFonts? {
        if let cached = objc_getAssociatedObject(page, &cacheKey) { return cached as? PageFonts }
        let result = scan(page)
        objc_setAssociatedObject(page, &cacheKey, result ?? NSNull(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return result
    }

    /// Where the font changes within `range` of the page's characters: (offset from range start, font).
    /// Always starts at offset 0.
    func pieces(in range: NSRange) -> [(offset: Int, font: Font?)] {
        // Last start at or before the range.
        var low = 0, high = starts.count
        while low < high { let mid = (low + high) / 2; if starts[mid] <= range.location { low = mid + 1 } else { high = mid } }
        var result: [(Int, Font?)] = [(0, low > 0 ? fonts[low - 1] : nil)]
        var i = low
        while i < starts.count && starts[i] < range.upperBound {
            if fonts[i] != result[result.count - 1].1 { result.append((starts[i] - range.location, fonts[i])) }
            i += 1
        }
        return result
    }

    // MARK: - Font names

    /// "ABCDEF+Calibri-BoldItalic" → Calibri, bold, italic. Nil for installed fonts and symbol fonts.
    static func describe(_ font: CGPDFDictionaryRef) -> Font? {
        var dictionary = font
        var subtype: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(font, "Subtype", &subtype), let subtype, String(cString: subtype) == "Type0" {
            var descendants: CGPDFArrayRef?, first: CGPDFDictionaryRef?
            if CGPDFDictionaryGetArray(font, "DescendantFonts", &descendants), let descendants,
               CGPDFArrayGetDictionary(descendants, 0, &first), let first { dictionary = first }
        }
        var base: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "BaseFont", &base) || CGPDFDictionaryGetName(font, "BaseFont", &base),
              let base else { return nil }
        var name = String(cString: base)
        if let plus = name.firstIndex(of: "+"), name.distance(from: name.startIndex, to: plus) == 6 {
            name = String(name[name.index(after: plus)...])
        }
        for suffix in ["-Identity-H", "-Identity-V"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        guard !name.isEmpty, !installed(name) else { return nil }

        // Family and style: "Calibri-BoldItalic", "Arial,Bold", "TimesNewRomanPS-BoldItalicMT".
        let split = name.firstIndex { $0 == "-" || $0 == "," } ?? name.endIndex
        var family = String(name[..<split])
        let style = name[split...].lowercased()
        for suffix in ["PSMT", "MT", "PS"] where family.hasSuffix(suffix) && family.count > suffix.count + 2 {
            family.removeLast(suffix.count); break
        }
        // "MyriadPro" → "Myriad Pro", as Word and PowerPoint name it.
        var spaced = ""
        var previous: Character = " "
        for character in family {
            if character.isUppercase && previous.isLowercase { spaced.append(" ") }
            spaced.append(character)
            previous = character
        }
        family = spaced
        // Symbol and math fonts: PDFKit's stand-in shows their characters better than a font nobody has.
        let symbols = ["Symbol", "Wingdings", "Webdings", "Zapf Dingbats", "Dingbats", "MT Extra",
                       "CMMI", "CMSY", "CMEX", "MTMI", "MTSY", "MTEX", "MSAM", "MSBM", "Cambria Math"]
        if symbols.contains(where: { family.hasPrefix($0) }) { return nil }

        var bold = ["bold", "black", "heavy", "semibold", "demi"].contains { style.contains($0) }
        var italic = style.contains("italic") || style.contains("oblique") || style.hasSuffix("it")
        var descriptor: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dictionary, "FontDescriptor", &descriptor), let descriptor {
            var flags: CGPDFInteger = 0, weight: CGPDFReal = 0, angle: CGPDFReal = 0
            if CGPDFDictionaryGetInteger(descriptor, "Flags", &flags) {
                if flags & (1 << 6) != 0 { italic = true }
                if flags & (1 << 18) != 0 { bold = true }
            }
            if CGPDFDictionaryGetNumber(descriptor, "FontWeight", &weight), weight >= 600 { bold = true }
            if CGPDFDictionaryGetNumber(descriptor, "ItalicAngle", &angle), angle != 0 { italic = true }
        }
        return Font(family: family, bold: bold, italic: italic)
    }

    private static let installedLock = NSLock()
    nonisolated(unsafe) private static var installedNames: [String: Bool] = [:]
    nonisolated(unsafe) private static var cacheKey: UInt8 = 0

    private static func installed(_ postScriptName: String) -> Bool {
        if let known = installedLock.withLock({ installedNames[postScriptName] }) { return known }
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        let found = (CTFontCopyPostScriptName(font) as String) == postScriptName
        installedLock.withLock { installedNames[postScriptName] = found }
        return found
    }

    // MARK: - Scanning

    private static func scan(_ page: PDFPage) -> PageFonts? {
        guard let cgPage = page.pageRef, let pageDictionary = cgPage.dictionary else { return nil }
        // Cheap check first: only the page's font list (and its forms'), no content.
        guard needsScan(pageDictionary, depth: 0) else { return nil }

        let scanner = Scanner(page: page)
        let stream = CGPDFContentStreamCreateWithPage(cgPage)
        scanner.run(stream)
        CGPDFContentStreamRelease(stream)
        guard scanner.found.contains(where: { $0.font != nil }) else { return nil }

        let result = PageFonts()
        for point in scanner.found.sorted(by: { $0.index < $1.index }) {
            if let last = result.starts.last, last == point.index { result.fonts[result.fonts.count - 1] = point.font; continue }
            if result.fonts.last.map({ $0 == point.font }) == true { continue }
            result.starts.append(point.index)
            result.fonts.append(point.font)
        }
        return result
    }

    private static func needsScan(_ dictionary: CGPDFDictionaryRef, depth: Int) -> Bool {
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return false }
        var found = false
        var fonts: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts {
            CGPDFDictionaryApplyBlock(fonts, { _, object, _ in
                var font: CGPDFDictionaryRef?
                if CGPDFObjectGetValue(object, .dictionary, &font), let font, describe(font) != nil { found = true; return false }
                return true
            }, nil)
        }
        var objects: CGPDFDictionaryRef?
        if !found, depth < 2, CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects {
            CGPDFDictionaryApplyBlock(objects, { _, object, _ in
                var stream: CGPDFStreamRef?
                if CGPDFObjectGetValue(object, .stream, &stream), let stream, let form = CGPDFStreamGetDictionary(stream),
                   needsScan(form, depth: depth + 1) { found = true; return false }
                return true
            }, nil)
        }
        return found
    }

    /// Walks the content stream's text operators, keeping track of where each piece of text starts.
    private final class Scanner {
        struct FontInfo {
            var font: Font?
            var widths: [CGFloat]           // One-byte fonts: code → width in text space (-1 unknown)
            var wideWidths: [Int: CGFloat]  // Two-byte fonts
            var defaultWidth: CGFloat
            var twoByte: Bool
        }
        struct State {
            var ctm = CGAffineTransform.identity
            var font: FontInfo?
            var fontID: UnsafeRawPointer?
            var size: CGFloat = 0, charSpacing: CGFloat = 0, wordSpacing: CGFloat = 0
            var scale: CGFloat = 1, leading: CGFloat = 0, rise: CGFloat = 0
        }

        let page: PDFPage
        var state = State()
        var saved: [State] = []
        var tm = CGAffineTransform.identity, tlm = CGAffineTransform.identity
        var streams: [CGPDFContentStreamRef] = []
        var fontCache: [UnsafeRawPointer: FontInfo] = [:]
        var found: [(index: Int, font: Font?)] = []
        // The last piece of text: its font and where it ended, to skip lookups for text that just continues.
        var lastFont: UnsafeRawPointer?
        var lastEnd: CGPoint?
        let pageString: Int

        init(page: PDFPage) {
            self.page = page
            pageString = page.numberOfCharacters
        }

        func run(_ stream: CGPDFContentStreamRef) {
            streams.append(stream)
            let info = Unmanaged.passUnretained(self).toOpaque()
            let scanner = CGPDFScannerCreate(stream, Scanner.table, info)
            CGPDFScannerScan(scanner)
            CGPDFScannerRelease(scanner)
            streams.removeLast()
        }

        static func from(_ info: UnsafeMutableRawPointer?) -> Scanner { Unmanaged<Scanner>.fromOpaque(info!).takeUnretainedValue() }

        static func number(_ scanner: CGPDFScannerRef) -> CGFloat? {
            var value: CGPDFReal = 0
            return CGPDFScannerPopNumber(scanner, &value) ? value : nil
        }

        static func pair(_ scanner: CGPDFScannerRef) -> (CGFloat, CGFloat)? {
            guard let y = number(scanner), let x = number(scanner) else { return nil }
            return (x, y)
        }

        static func matrix(_ scanner: CGPDFScannerRef) -> CGAffineTransform? {
            guard let ty = number(scanner), let tx = number(scanner), let d = number(scanner), let c = number(scanner),
                  let b = number(scanner), let a = number(scanner) else { return nil }
            return CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
        }

        func moveLine(_ x: CGFloat, _ y: CGFloat) {
            tlm = CGAffineTransform(translationX: x, y: y).concatenating(tlm)
            tm = tlm
        }

        func setFont(_ name: String, size: CGFloat) {
            state.size = size
            guard let stream = streams.last, let object = CGPDFContentStreamGetResource(stream, "Font", name) else {
                state.font = nil; state.fontID = nil; return
            }
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { return }
            let id = unsafeBitCast(dictionary, to: UnsafeRawPointer.self)
            state.fontID = id
            if let cached = fontCache[id] { state.font = cached; return }
            let info = Scanner.fontInfo(dictionary)
            fontCache[id] = info
            state.font = info
        }

        static func fontInfo(_ font: CGPDFDictionaryRef) -> FontInfo {
            var info = FontInfo(font: PageFonts.describe(font), widths: [], wideWidths: [:], defaultWidth: 0.5, twoByte: false)
            var subtype: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(font, "Subtype", &subtype), let subtype, String(cString: subtype) == "Type0" {
                info.twoByte = true
                info.defaultWidth = 1
                var descendants: CGPDFArrayRef?, cid: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetArray(font, "DescendantFonts", &descendants), let descendants,
                      CGPDFArrayGetDictionary(descendants, 0, &cid), let cid else { return info }
                var dw: CGPDFReal = 1000
                if CGPDFDictionaryGetNumber(cid, "DW", &dw) { info.defaultWidth = dw / 1000 }
                // W: [first [w1 w2 …]] or [first last w]
                var w: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(cid, "W", &w), let w {
                    let count = CGPDFArrayGetCount(w)
                    var i = 0
                    while i + 1 < count {
                        var first: CGPDFInteger = 0
                        guard CGPDFArrayGetInteger(w, i, &first) else { break }
                        var list: CGPDFArrayRef?
                        if CGPDFArrayGetArray(w, i + 1, &list), let list {
                            for j in 0..<CGPDFArrayGetCount(list) {
                                var value: CGPDFReal = 0
                                if CGPDFArrayGetNumber(list, j, &value) { info.wideWidths[first + j] = value / 1000 }
                            }
                            i += 2
                        } else {
                            var last: CGPDFInteger = 0, value: CGPDFReal = 0
                            guard i + 2 < count, CGPDFArrayGetInteger(w, i + 1, &last), CGPDFArrayGetNumber(w, i + 2, &value),
                                  last >= first, last - first < 65536 else { break }
                            for code in first...last { info.wideWidths[code] = value / 1000 }
                            i += 3
                        }
                    }
                }
                return info
            }
            var scale: CGFloat = 0.001
            var fontMatrix: CGPDFArrayRef?, a: CGPDFReal = 0
            if CGPDFDictionaryGetArray(font, "FontMatrix", &fontMatrix), let fontMatrix, CGPDFArrayGetNumber(fontMatrix, 0, &a) { scale = a }
            var firstChar: CGPDFInteger = 0, widths: CGPDFArrayRef?
            if CGPDFDictionaryGetInteger(font, "FirstChar", &firstChar), CGPDFDictionaryGetArray(font, "Widths", &widths), let widths {
                info.widths = [CGFloat](repeating: -1, count: 256)
                for j in 0..<CGPDFArrayGetCount(widths) where firstChar + j >= 0 && firstChar + j < 256 {
                    var value: CGPDFReal = 0
                    if CGPDFArrayGetNumber(widths, j, &value) { info.widths[firstChar + j] = value * scale }
                }
            }
            return info
        }

        func show(_ string: CGPDFStringRef) {
            guard let bytes = CGPDFStringGetBytePtr(string) else { return }
            let length = CGPDFStringGetLength(string)
            guard length > 0 else { return }
            let font = state.font
            let twoByte = font?.twoByte ?? false
            func code(_ i: Int) -> Int { twoByte ? (i + 1 < length ? Int(bytes[i]) << 8 | Int(bytes[i + 1]) : Int(bytes[i])) : Int(bytes[i]) }
            func width(_ code: Int) -> CGFloat {
                guard let font else { return 0.5 }
                if twoByte { return font.wideWidths[code] ?? font.defaultWidth }
                return code < font.widths.count && font.widths[code] >= 0 ? font.widths[code] : font.defaultWidth
            }

            let render = CGAffineTransform(a: state.size * state.scale, b: 0, c: 0, d: state.size, tx: 0, ty: state.rise)
                .concatenating(tm).concatenating(state.ctm)
            let origin = CGPoint.zero.applying(render)
            let em = hypot(render.c, render.d)
            let continues = state.fontID == lastFont && lastEnd.map { hypot($0.x - origin.x, $0.y - origin.y) < em * 0.5 } == true
            if !continues {
                // Select across the middle of the first glyph. (Not characterIndex(at:): its numbering
                // drifts from the page's text after replacement text such as ligatures.)
                let glyph = width(code(0)) > 0.05 ? width(code(0)) : 0.25
                let from = CGPoint(x: glyph * 0.2, y: 0.3).applying(render), to = CGPoint(x: glyph * 0.8, y: 0.3).applying(render)
                let index = page.selection(from: from, to: to).map { $0.numberOfTextRanges(on: page) > 0 ? $0.range(at: 0, on: page).location : -1 } ?? -1
                if index >= 0 && index < pageString {
                    found.append((index, font?.font))
                    lastFont = state.fontID
                } else {
                    lastFont = nil
                }
            }

            var i = 0
            while i < length {
                let c = code(i)
                var advance = width(c) * state.size + state.charSpacing
                if !twoByte && c == 32 { advance += state.wordSpacing }
                tm = CGAffineTransform(translationX: advance * state.scale, y: 0).concatenating(tm)
                i += twoByte ? 2 : 1
            }
            if lastFont != nil {
                lastEnd = CGPoint(x: 0, y: state.rise).applying(tm.concatenating(state.ctm))
            }
        }

        func adjust(_ amount: CGFloat) {
            tm = CGAffineTransform(translationX: -amount / 1000 * state.size * state.scale, y: 0).concatenating(tm)
        }

        nonisolated(unsafe) static let table: CGPDFOperatorTableRef = {
            let table = CGPDFOperatorTableCreate()!
            CGPDFOperatorTableSetCallback(table, "q") { _, info in let s = from(info); s.saved.append(s.state) }
            CGPDFOperatorTableSetCallback(table, "Q") { _, info in let s = from(info); if let last = s.saved.popLast() { s.state = last } }
            CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
                let s = from(info)
                if let m = matrix(scanner) { s.state.ctm = m.concatenating(s.state.ctm) }
            }
            CGPDFOperatorTableSetCallback(table, "BT") { _, info in let s = from(info); s.tm = .identity; s.tlm = .identity }
            CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
                let s = from(info)
                if let m = matrix(scanner) { s.tm = m; s.tlm = m }
            }
            CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in
                if let (x, y) = pair(scanner) { from(info).moveLine(x, y) }
            }
            CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
                let s = from(info)
                if let (x, y) = pair(scanner) { s.state.leading = -y; s.moveLine(x, y) }
            }
            CGPDFOperatorTableSetCallback(table, "T*") { _, info in let s = from(info); s.moveLine(0, -s.state.leading) }
            CGPDFOperatorTableSetCallback(table, "TL") { scanner, info in if let v = number(scanner) { from(info).state.leading = v } }
            CGPDFOperatorTableSetCallback(table, "Tc") { scanner, info in if let v = number(scanner) { from(info).state.charSpacing = v } }
            CGPDFOperatorTableSetCallback(table, "Tw") { scanner, info in if let v = number(scanner) { from(info).state.wordSpacing = v } }
            CGPDFOperatorTableSetCallback(table, "Tz") { scanner, info in if let v = number(scanner) { from(info).state.scale = v / 100 } }
            CGPDFOperatorTableSetCallback(table, "Ts") { scanner, info in if let v = number(scanner) { from(info).state.rise = v } }
            CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
                var size: CGPDFReal = 0
                var name: UnsafePointer<CChar>?
                guard CGPDFScannerPopNumber(scanner, &size), CGPDFScannerPopName(scanner, &name), let name else { return }
                from(info).setFont(String(cString: name), size: size)
            }
            CGPDFOperatorTableSetCallback(table, "Tj") { scanner, info in
                var string: CGPDFStringRef?
                if CGPDFScannerPopString(scanner, &string), let string { from(info).show(string) }
            }
            CGPDFOperatorTableSetCallback(table, "'") { scanner, info in
                let s = from(info)
                var string: CGPDFStringRef?
                guard CGPDFScannerPopString(scanner, &string), let string else { return }
                s.moveLine(0, -s.state.leading)
                s.show(string)
            }
            CGPDFOperatorTableSetCallback(table, "\"") { scanner, info in
                let s = from(info)
                var string: CGPDFStringRef?
                guard CGPDFScannerPopString(scanner, &string), let string, let (word, character) = pair(scanner) else { return }
                s.state.wordSpacing = word; s.state.charSpacing = character
                s.moveLine(0, -s.state.leading)
                s.show(string)
            }
            CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
                let s = from(info)
                var array: CGPDFArrayRef?
                guard CGPDFScannerPopArray(scanner, &array), let array else { return }
                for i in 0..<CGPDFArrayGetCount(array) {
                    var string: CGPDFStringRef?, number: CGPDFReal = 0
                    if CGPDFArrayGetString(array, i, &string), let string { s.show(string) }
                    else if CGPDFArrayGetNumber(array, i, &number) { s.adjust(number) }
                }
            }
            CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
                let s = from(info)
                var name: UnsafePointer<CChar>?
                guard s.saved.count < 64, CGPDFScannerPopName(scanner, &name), let name, let parent = s.streams.last,
                      let object = CGPDFContentStreamGetResource(parent, "XObject", name) else { return }
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let form = CGPDFStreamGetDictionary(stream) else { return }
                var subtype: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(form, "Subtype", &subtype), let subtype, String(cString: subtype) == "Form" else { return }
                var resources: CGPDFDictionaryRef?
                // Only forms with text of their own (not drawings such as charts).
                var fonts: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(form, "Resources", &resources), let resources,
                      CGPDFDictionaryGetDictionary(resources, "Font", &fonts) else { return }
                let content = CGPDFContentStreamCreateWithStream(stream, resources, parent)
                s.saved.append(s.state)
                var formMatrix: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(form, "Matrix", &formMatrix), let formMatrix, CGPDFArrayGetCount(formMatrix) == 6 {
                    var v: [CGPDFReal] = [1, 0, 0, 1, 0, 0]
                    for i in 0..<6 { _ = CGPDFArrayGetNumber(formMatrix, i, &v[i]) }
                    s.state.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.state.ctm)
                }
                let (tm, tlm) = (s.tm, s.tlm)
                s.run(content)
                CGPDFContentStreamRelease(content)
                s.tm = tm; s.tlm = tlm
                if let last = s.saved.popLast() { s.state = last }
            }
            return table
        }()
    }
}
