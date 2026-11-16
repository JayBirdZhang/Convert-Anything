import CoreGraphics
import Foundation
import PDFKit

/// Makes a copy of a PDF page with everything except its text: photos, shapes, backgrounds and lines stay,
/// glyphs go. Editable slides use it as each slide's background picture, with the text laid back on top
/// as text boxes.
///
/// The page's drawing instructions are read with Core Graphics and written into a new one-page PDF in
/// memory, leaving out the instructions that draw text. Everything else the page uses (images, nested
/// drawings, patterns, colors, soft masks, layers) is copied across, decoded. Fonts aren't needed.
/// Text used as a clipping shape (a photo showing through letters) goes too, with what it revealed:
/// the letters come back as a text box, so the background shouldn't show them again.
nonisolated enum TextlessPDF {
    struct Unsupported: Error { let reason: String }

    /// A one-page PDF with the same boxes and rotation as `page` and none of its text.
    static func data(for page: CGPDFPage) throws -> Data {
        try Writer(page: page).build()
    }

    /// The page without its text, opened in PDFKit, with the markup people add on top (highlights, ink,
    /// shapes, stamps, comment boxes) carried over. Links, form fields and pop-up notes draw nothing
    /// worth keeping and are left out.
    static func document(for page: PDFPage) throws -> PDFDocument {
        guard let source = page.pageRef else { throw Unsupported(reason: "no page reference") }
        guard let document = PDFDocument(data: try data(for: source)), let copy = document.page(at: 0) else {
            throw Unsupported(reason: "copy couldn't be opened")
        }
        let skipped: Set<String> = ["Link", "Widget", "Popup"]
        for annotation in page.annotations where !skipped.contains(annotation.type ?? "") && annotation.shouldDisplay {
            if let duplicate = annotation.copy() as? PDFAnnotation { copy.addAnnotation(duplicate) }
        }
        return document
    }
}

// MARK: - Writer

nonisolated private final class Writer {
    private let page: CGPDFPage
    private var objects: [Data] = []                       // Object n is objects[n - 1]
    private var numbers: [UnsafeRawPointer: Int] = [:]     // Core Graphics returns one pointer per PDF object
    private var arrayDepth = 0

    /// Stream entries that described the original encoding; the copy is written decoded.
    private static let encodingKeys: Set<String> = ["Length", "Filter", "DecodeParms", "DL", "F", "FFilter", "FDecodeParms"]
    /// Back-references and data nothing draws with.
    private static let skippedKeys: Set<String> = ["Parent", "P", "Metadata", "PieceInfo", "StructParents", "StructParent"]

    init(page: CGPDFPage) {
        self.page = page
    }

    func build() throws -> Data {
        guard let pageDictionary = page.dictionary else { throw TextlessPDF.Unsupported(reason: "no page dictionary") }
        let catalog = reserve(), pages = reserve(), pageNumber = reserve()

        var entries = "/Type /Page /Parent \(pages) 0 R"
        entries += " /MediaBox \(box(.mediaBox)) /CropBox \(box(.cropBox))"
        if page.rotationAngle != 0 { entries += " /Rotate \(page.rotationAngle)" }
        if let resources = inherited(pageDictionary, "Resources") {
            entries += " /Resources " + (try reference(dictionary: resources, isResources: true))
        }
        if let group = dictionary(pageDictionary, "Group") {
            entries += " /Group " + (try reference(dictionary: group))
        }
        var userUnit: CGPDFReal = 1
        if CGPDFDictionaryGetNumber(pageDictionary, "UserUnit", &userUnit), userUnit != 1 {
            entries += " /UserUnit \(Writer.number(userUnit))"
        }

        var content = Data()
        for stream in contentStreams(pageDictionary) {
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(stream, &format) as Data?, format == .raw else {
                throw TextlessPDF.Unsupported(reason: "unreadable page contents")
            }
            content.append(data)
            content.append(0x0A)
        }
        let contents = reserve()
        objects[contents - 1] = streamObject("", data: try ContentFilter.strip(content))
        entries += " /Contents \(contents) 0 R"
        objects[pageNumber - 1] = Data("<<\(entries)>>".utf8)
        objects[pages - 1] = Data("<< /Type /Pages /Kids [\(pageNumber) 0 R] /Count 1 >>".utf8)

        // Layers hidden by default stay hidden.
        var catalogEntries = "/Type /Catalog /Pages \(pages) 0 R"
        if let root = page.document?.catalog, let layers = dictionary(root, "OCProperties") {
            catalogEntries += " /OCProperties " + (try reference(dictionary: layers))
        }
        objects[catalog - 1] = Data("<<\(catalogEntries)>>".utf8)
        return assemble()
    }

    // MARK: Objects

    private func reserve() -> Int {
        objects.append(Data())
        return objects.count
    }

    /// Every dictionary and stream becomes its own numbered object, numbered before its contents are
    /// written, so shared objects are written once and loops end.
    private func reference(dictionary: CGPDFDictionaryRef, isResources: Bool = false) throws -> String {
        let key = unsafeBitCast(dictionary, to: UnsafeRawPointer.self)
        if let number = numbers[key] { return "\(number) 0 R" }
        let number = reserve()
        numbers[key] = number
        let skipping = isResources ? Writer.skippedKeys.union(["Font"]) : Writer.skippedKeys
        objects[number - 1] = Data("<<\(try body(of: dictionary, skipping: skipping))>>".utf8)
        return "\(number) 0 R"
    }

    private func reference(stream: CGPDFStreamRef) throws -> String {
        let key = unsafeBitCast(stream, to: UnsafeRawPointer.self)
        if let number = numbers[key] { return "\(number) 0 R" }
        let number = reserve()
        numbers[key] = number
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { throw TextlessPDF.Unsupported(reason: "stream without dictionary") }
        var format = CGPDFDataFormat.raw
        guard var data = CGPDFStreamCopyData(stream, &format) as Data? else {
            throw TextlessPDF.Unsupported(reason: "undecodable stream")
        }
        var encoding = ""
        switch format {
        case .raw:
            if Writer.draws(dictionary) { data = try ContentFilter.strip(data) }
        case .jpegEncoded:
            encoding = " /Filter /DCTDecode" + Writer.colorTransform(dictionary)
        case .JPEG2000:
            encoding = " /Filter /JPXDecode"
        @unknown default:
            throw TextlessPDF.Unsupported(reason: "unknown stream format")
        }
        let entries = try body(of: dictionary, skipping: Writer.skippedKeys.union(Writer.encodingKeys))
        objects[number - 1] = streamObject(entries + encoding, data: data)
        return "\(number) 0 R"
    }

    private func streamObject(_ entries: String, data: Data) -> Data {
        var object = Data("<<\(entries) /Length \(data.count)>>\nstream\n".utf8)
        object.append(data)
        object.append(contentsOf: Array("\nendstream".utf8))
        return object
    }

    private func body(of dictionary: CGPDFDictionaryRef, skipping: Set<String>) throws -> String {
        var entries: [(String, CGPDFObjectRef)] = []
        CGPDFDictionaryApplyBlock(dictionary, { key, value, _ in
            entries.append((String(cString: key), value))
            return true
        }, nil)
        var body = ""
        for (key, value) in entries.sorted(by: { $0.0 < $1.0 }) where !skipping.contains(key) {
            var nested: CGPDFDictionaryRef?
            let text = key == "Resources" && CGPDFObjectGetValue(value, .dictionary, &nested)
                ? try reference(dictionary: nested!, isResources: true)
                : try serialize(value)
            body += " " + Writer.name(key) + " " + text
        }
        return body
    }

    private func serialize(_ object: CGPDFObjectRef) throws -> String {
        switch CGPDFObjectGetType(object) {
        case .null:
            return "null"
        case .boolean:
            var value: CGPDFBoolean = 0
            CGPDFObjectGetValue(object, .boolean, &value)
            return value != 0 ? "true" : "false"
        case .integer:
            var value: CGPDFInteger = 0
            CGPDFObjectGetValue(object, .integer, &value)
            return String(value)
        case .real:
            var value: CGPDFReal = 0
            CGPDFObjectGetValue(object, .real, &value)
            return Writer.number(value)
        case .name:
            var value: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, .name, &value), let value else { return "null" }
            return Writer.name(String(cString: value))
        case .string:
            var value: CGPDFStringRef?
            guard CGPDFObjectGetValue(object, .string, &value), let value else { return "<>" }
            return Writer.hex(value)
        case .array:
            var value: CGPDFArrayRef?
            guard CGPDFObjectGetValue(object, .array, &value), let value else { return "[]" }
            arrayDepth += 1
            defer { arrayDepth -= 1 }
            guard arrayDepth < 64 else { throw TextlessPDF.Unsupported(reason: "arrays nested too deeply") }
            var items: [String] = []
            for index in 0..<CGPDFArrayGetCount(value) {
                var item: CGPDFObjectRef?
                items.append(CGPDFArrayGetObject(value, index, &item) && item != nil ? try serialize(item!) : "null")
            }
            return "[" + items.joined(separator: " ") + "]"
        case .dictionary:
            var value: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &value), let value else { return "null" }
            return try reference(dictionary: value)
        case .stream:
            var value: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &value), let value else { return "null" }
            return try reference(stream: value)
        @unknown default:
            return "null"
        }
    }

    private func assemble() -> Data {
        var pdf = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37, 0x0A, 0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])   // %PDF-1.7, binary marker
        var offsets: [Int] = []
        offsets.reserveCapacity(objects.count)
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(contentsOf: Array("\(index + 1) 0 obj\n".utf8))
            pdf.append(object)
            pdf.append(contentsOf: Array("\nendobj\n".utf8))
        }
        let xref = pdf.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(contentsOf: Array(table.utf8))
        return pdf
    }

    // MARK: Page helpers

    private func box(_ kind: CGPDFBox) -> String {
        let rect = page.getBoxRect(kind)
        return "[\(Writer.number(rect.minX)) \(Writer.number(rect.minY)) \(Writer.number(rect.maxX)) \(Writer.number(rect.maxY))]"
    }

    /// Pages can inherit their resources from the page tree above them.
    private func inherited(_ start: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var current: CGPDFDictionaryRef? = start
        for _ in 0..<32 {
            guard let node = current else { return nil }
            if let value = dictionary(node, key) { return value }
            current = dictionary(node, "Parent")
        }
        return nil
    }

    private func contentStreams(_ pageDictionary: CGPDFDictionaryRef) -> [CGPDFStreamRef] {
        var stream: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(pageDictionary, "Contents", &stream), let stream { return [stream] }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(pageDictionary, "Contents", &array), let array else { return [] }
        return (0..<CGPDFArrayGetCount(array)).compactMap { index in
            var item: CGPDFStreamRef?
            return CGPDFArrayGetStream(array, index, &item) ? item : nil
        }
    }

    private func dictionary(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(dictionary, key, &value) ? value : nil
    }

    // MARK: Formatting

    /// Streams holding drawing instructions: nested drawings (including soft masks) and tiling patterns.
    private static func draws(_ dictionary: CGPDFDictionaryRef) -> Bool {
        var subtype: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype, strcmp(subtype, "Form") == 0 { return true }
        var patternType: CGPDFInteger = 0
        return CGPDFDictionaryGetInteger(dictionary, "PatternType", &patternType) && patternType == 1
    }

    /// Adobe's JPEG color-transform flag; without it some CMYK and RGB JPEGs change color.
    private static func colorTransform(_ dictionary: CGPDFDictionaryRef) -> String {
        func flag(_ parameters: CGPDFDictionaryRef) -> String? {
            var value: CGPDFInteger = 0
            return CGPDFDictionaryGetInteger(parameters, "ColorTransform", &value) ? " /DecodeParms << /ColorTransform \(value) >>" : nil
        }
        var parameters: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dictionary, "DecodeParms", &parameters), let parameters { return flag(parameters) ?? "" }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "DecodeParms", &array), let array else { return "" }
        for index in 0..<CGPDFArrayGetCount(array) {
            var item: CGPDFDictionaryRef?
            if CGPDFArrayGetDictionary(array, index, &item), let item, let result = flag(item) { return result }
        }
        return ""
    }

    static func number(_ value: CGFloat) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        var text = String(format: "%.6f", Double(value))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    static func name(_ name: String) -> String {
        var result = "/"
        for byte in name.utf8 {
            let regular = byte > 0x20 && byte < 0x7F && !"()<>[]{}/%#".utf8.contains(byte)
            result += regular ? String(UnicodeScalar(byte)) : String(format: "#%02X", byte)
        }
        return result
    }

    static func hex(_ string: CGPDFStringRef) -> String {
        guard let bytes = CGPDFStringGetBytePtr(string) else { return "<>" }
        let length = CGPDFStringGetLength(string)
        var result = "<"
        result.reserveCapacity(length * 2 + 2)
        for index in 0..<length { result += String(format: "%02X", bytes[index]) }
        return result + ">"
    }
}

// MARK: - Content filter

/// Copies a content stream, dropping the operators that paint text (Tj, TJ, ' and ") along with their
/// operands. Everything else, including the color and line settings made between BT and ET, stays.
/// Text in a clipping render mode (4–7) would have narrowed the clip at ET; it becomes an empty clip,
/// so what the letters revealed isn't drawn either.
nonisolated private struct ContentFilter {
    private let bytes: [UInt8]
    private var output = Data()

    private init(_ content: Data) {
        bytes = [UInt8](content)
        output.reserveCapacity(content.count)
    }

    static func strip(_ content: Data) throws -> Data {
        var filter = ContentFilter(content)
        return try filter.run()
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 || byte == 0x0C || byte == 0x00
    }

    private static func isDelimiter(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: true   // ( ) < > [ ] { } / %
        default: false
        }
    }

    private static func isNumeric(_ token: ArraySlice<UInt8>) -> Bool {
        token.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E || $0 == 0x2B || $0 == 0x2D }
    }

    private mutating func run() throws -> Data {
        let count = bytes.count
        var index = 0
        var runStart = 0                 // First byte of the operands waiting for their operator
        var operands: [Range<Int>] = []  // Top-level operands since the last operator
        var depth = 0                    // Inside [ ] or << >>
        var compoundStart = 0
        var renderMode = 0
        var savedModes: [Int] = []
        var clipsText = false            // A clipping-mode glyph was dropped in this text object

        while index < count {
            let byte = bytes[index]
            if ContentFilter.isSpace(byte) { index += 1; continue }
            let start = index
            switch byte {
            case 0x25:   // % comment
                while index < count, bytes[index] != 0x0A, bytes[index] != 0x0D { index += 1 }
                continue
            case 0x28:   // ( literal string )
                var level = 0
                repeat {
                    switch bytes[index] {
                    case 0x5C: index += 1
                    case 0x28: level += 1
                    case 0x29: level -= 1
                    default: break
                    }
                    index += 1
                } while index < count && level > 0
            case 0x3C:
                if index + 1 < count, bytes[index + 1] == 0x3C {   // <<
                    if depth == 0 { compoundStart = start }
                    depth += 1
                    index += 2
                    continue
                }
                while index < count, bytes[index] != 0x3E { index += 1 }   // <hex string>
                index += 1
            case 0x3E:
                if index + 1 < count, bytes[index + 1] == 0x3E {   // >>
                    index += 2
                    depth = max(0, depth - 1)
                    if depth == 0 { operands.append(compoundStart..<index) }
                } else {
                    index += 1
                }
                continue
            case 0x5B:   // [
                if depth == 0 { compoundStart = start }
                depth += 1
                index += 1
                continue
            case 0x5D:   // ]
                index += 1
                depth = max(0, depth - 1)
                if depth == 0 { operands.append(compoundStart..<index) }
                continue
            case 0x7B, 0x7D, 0x29:   // { } and a stray )
                index += 1
                continue
            case 0x2F:   // /Name
                index += 1
                while index < count, !ContentFilter.isSpace(bytes[index]), !ContentFilter.isDelimiter(bytes[index]) { index += 1 }
            default:
                while index < count, !ContentFilter.isSpace(bytes[index]), !ContentFilter.isDelimiter(bytes[index]) { index += 1 }
                let token = bytes[start..<index]
                if depth > 0 { continue }
                if ContentFilter.isNumeric(token) || token.elementsEqual("true".utf8) || token.elementsEqual("false".utf8) || token.elementsEqual("null".utf8) {
                    operands.append(start..<index)
                    continue
                }

                // An operator: decide what happens to it and its operands.
                let run = runStart..<index
                switch String(decoding: token, as: UTF8.self) {
                case "Tj", "TJ":
                    if renderMode >= 4 { clipsText = true }
                case "'":
                    if renderMode >= 4 { clipsText = true }
                    output.append(contentsOf: Array("T*\n".utf8))
                case "\"":
                    if renderMode >= 4 { clipsText = true }
                    if operands.count >= 3 {
                        // Keep the word and character spacing it sets.
                        output.append(contentsOf: bytes[operands[0]])
                        output.append(contentsOf: Array(" Tw ".utf8))
                        output.append(contentsOf: bytes[operands[1]])
                        output.append(contentsOf: Array(" Tc T*\n".utf8))
                    }
                case "Tr":
                    renderMode = operands.last.flatMap { Double(String(decoding: bytes[$0], as: UTF8.self)) }.map { Int($0) } ?? 0
                    emit(run)
                case "BT":
                    clipsText = false
                    emit(run)
                case "ET":
                    emit(run)
                    if clipsText { output.append(contentsOf: Array("0 0 0 0 re W n\n".utf8)) }
                    clipsText = false
                case "q":
                    savedModes.append(renderMode)
                    emit(run)
                case "Q":
                    renderMode = savedModes.popLast() ?? renderMode
                    emit(run)
                case "ID":
                    // Inline image data runs to an EI that stands on its own.
                    emit(run)
                    var end = index + 1
                    while true {
                        guard end + 1 < count else { throw TextlessPDF.Unsupported(reason: "unterminated inline image") }
                        if bytes[end] == 0x45, bytes[end + 1] == 0x49, ContentFilter.isSpace(bytes[end - 1]),
                           end + 2 == count || ContentFilter.isSpace(bytes[end + 2]) || ContentFilter.isDelimiter(bytes[end + 2]) {
                            break
                        }
                        end += 1
                    }
                    end += 2
                    output.append(contentsOf: bytes[index..<end])
                    output.append(0x0A)
                    index = end
                default:
                    emit(run)
                }
                runStart = index
                operands.removeAll(keepingCapacity: true)
                continue
            }
            if depth == 0 { operands.append(start..<index) }
        }
        if runStart < count { output.append(contentsOf: bytes[runStart..<count]) }
        return output
    }

    private mutating func emit(_ range: Range<Int>) {
        output.append(contentsOf: bytes[range])
        output.append(0x0A)
    }
}
