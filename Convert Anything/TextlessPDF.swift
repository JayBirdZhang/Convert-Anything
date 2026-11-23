import CoreGraphics
import Foundation
import ImageIO
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

    /// One of the page's drawing steps: where it lands and whether it draws a picture (an image).
    struct Step {
        var area: CGRect
        var isImage: Bool
        /// The image's resource name when it's drawn plainly: upright, whole (`area` is where it's placed),
        /// opaque and with no blending, so the image file itself looks the same as the drawing.
        var plainImage: String? = nil
        /// The simple shape it paints (a line, a box, a circle), when it can be rebuilt exactly as one.
        var shape: Shape? = nil
    }

    /// A lone straight line, rectangle, ellipse or rounded rectangle, painted plainly (opaque flat colors,
    /// unclipped, no blending), with what's needed to draw it again: in page space.
    struct Shape {
        enum Kind { case line(CGPoint, CGPoint), rect, ellipse, roundRect(radius: CGFloat) }
        var kind: Kind
        var bounds: CGRect              // The path's box (a line's two ends), without the stroke
        var fill: UInt32?               // 0xRRGGBB, nil when it isn't filled
        var stroke: UInt32?             // 0xRRGGBB, nil when it isn't stroked
        var lineWidth: CGFloat = 0
        var cap = 0, join = 0           // PDF codes: butt, round, square; miter, round, bevel
    }

    /// A one-page PDF with the same boxes and rotation as `page` and none of its text. With `keeping`,
    /// only the page's own drawing steps (numbered as in `paintedAreas`) it returns true for are drawn.
    static func data(for page: CGPDFPage, keeping: ((Int) -> Bool)? = nil) throws -> Data {
        try Writer(page: page).build(keepings: [keeping])[0]
    }

    /// Where each of the page's own drawing steps (a filled or stroked shape, an image, a shading or a nested
    /// drawing) lands, in page space, in drawing order. `.null` where nothing shows (clipped away); an
    /// unclipped shading is `.infinite`. Text isn't a drawing step here: it's left out of every copy.
    static func paintedAreas(on page: CGPDFPage) throws -> [Step] {
        try Writer(page: page).paintedAreas()
    }

    enum NativeImage {
        case jpeg(Data)         // As stored in the PDF (or made smaller)
        case image(CGImage)     // Decoded samples, to be written as PNG
    }

    /// An image the page draws (see `Step.plainImage`), as it's stored in the PDF; see `Writer.image`.
    static func image(named name: String, on page: CGPDFPage, maxPixels: Int, minPixels: Int) -> NativeImage? {
        Writer(page: page).image(named: name, maxPixels: maxPixels, minPixels: minPixels)
    }

    /// The page without its text, opened in PDFKit, with the markup people add on top (highlights, ink,
    /// shapes, stamps, comment boxes) carried over. Links, form fields and pop-up notes draw nothing
    /// worth keeping and are left out.
    static func document(for page: PDFPage, keeping: ((Int) -> Bool)? = nil, annotations: Bool = true) throws -> PDFDocument {
        try documents(for: page, [(keeping, annotations)])[0]
    }

    /// Several copies of the page that differ only in which drawing steps they keep (and whether the
    /// markup comes along), from one reading of the page: its images are decoded once for all of them.
    static func documents(for page: PDFPage, _ copies: [(keeping: ((Int) -> Bool)?, annotations: Bool)]) throws -> [PDFDocument] {
        guard let source = page.pageRef else { throw Unsupported(reason: "no page reference") }
        let datas = try Writer(page: source).build(keepings: copies.map(\.keeping))
        let skipped: Set<String> = ["Link", "Widget", "Popup"]
        return try zip(datas, copies).map { data, options in
            guard let document = PDFDocument(data: data), let copy = document.page(at: 0) else {
                throw Unsupported(reason: "copy couldn't be opened")
            }
            for annotation in page.annotations where options.annotations && !skipped.contains(annotation.type ?? "") && annotation.shouldDisplay {
                if let duplicate = annotation.copy() as? PDFAnnotation { copy.addAnnotation(duplicate) }
            }
            return document
        }
    }

    /// Whether the page has markup that `document(for:)` carries over.
    static func hasMarkup(_ page: PDFPage) -> Bool {
        page.annotations.contains { !["Link", "Widget", "Popup"].contains($0.type ?? "") && $0.shouldDisplay }
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

    /// One copy of the page per entry in `keepings`; everything but the page's own drawing steps is
    /// written once and shared.
    func build(keepings: [((Int) -> Bool)?]) throws -> [Data] {
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

        let content = try pageContent(pageDictionary)
        let contents = reserve()
        entries += " /Contents \(contents) 0 R"
        objects[pageNumber - 1] = Data("<<\(entries)>>".utf8)
        objects[pages - 1] = Data("<< /Type /Pages /Kids [\(pageNumber) 0 R] /Count 1 >>".utf8)

        // Layers hidden by default stay hidden.
        var catalogEntries = "/Type /Catalog /Pages \(pages) 0 R"
        if let root = page.document?.catalog, let layers = dictionary(root, "OCProperties") {
            catalogEntries += " /OCProperties " + (try reference(dictionary: layers))
        }
        objects[catalog - 1] = Data("<<\(catalogEntries)>>".utf8)
        return try keepings.map { keep in
            objects[contents - 1] = streamObject("", data: try ContentFilter.strip(content, keeping: keep))
            return assemble()
        }
    }

    func paintedAreas() throws -> [TextlessPDF.Step] {
        guard let pageDictionary = page.dictionary else { throw TextlessPDF.Unsupported(reason: "no page dictionary") }
        let resources = inherited(pageDictionary, "Resources")
        let xobjects = resources.flatMap { dictionary($0, "XObject") }
        let states = resources.flatMap { dictionary($0, "ExtGState") }
        let spaces = resources.flatMap { dictionary($0, "ColorSpace") }
        let lookup = ContentFilter.Resources(xobject: { name in
            var stream: CGPDFStreamRef?
            guard let xobjects, CGPDFDictionaryGetStream(xobjects, name, &stream), let stream,
                  let entries = CGPDFStreamGetDictionary(stream) else { return nil }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(entries, "Subtype", &subtype), let subtype else { return nil }
            if strcmp(subtype, "Image") == 0 { return .image }
            guard strcmp(subtype, "Form") == 0 else { return nil }
            func numbers(_ key: String) -> [CGFloat]? {
                var array: CGPDFArrayRef?
                guard CGPDFDictionaryGetArray(entries, key, &array), let array else { return nil }
                return (0..<CGPDFArrayGetCount(array)).compactMap { index in
                    var value: CGPDFReal = 0
                    return CGPDFArrayGetNumber(array, index, &value) ? value : nil
                }
            }
            let m = numbers("Matrix").flatMap { $0.count == 6 ? $0 : nil } ?? [1, 0, 0, 1, 0, 0]
            let box = numbers("BBox").flatMap { $0.count == 4 ? $0 : nil }
                .map { CGRect(x: $0[0], y: $0[1], width: $0[2] - $0[0], height: $0[3] - $0[1]).standardized } ?? .infinite
            return .form(CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]), box)
        }, isPlainState: { name in
            // Graphics states that make what's drawn see-through or blend it with what's behind.
            var state: CGPDFDictionaryRef?
            guard let states, CGPDFDictionaryGetDictionary(states, name, &state), let state else { return false }
            var mask: UnsafePointer<CChar>?, value: CGPDFReal = 1, object: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(state, "SMask", &object), !(CGPDFDictionaryGetName(state, "SMask", &mask) && strcmp(mask!, "None") == 0) { return false }
            if CGPDFDictionaryGetNumber(state, "ca", &value), value < 1 { return false }
            if CGPDFDictionaryGetNumber(state, "CA", &value), value < 1 { return false }
            var blend: UnsafePointer<CChar>?
            if CGPDFDictionaryGetObject(state, "BM", &object) {
                guard CGPDFDictionaryGetName(state, "BM", &blend), let blend, strcmp(blend, "Normal") == 0 || strcmp(blend, "Compatible") == 0 else { return false }
            }
            return true
        }, setsLineStyle: { name in
            var state: CGPDFDictionaryRef?, object: CGPDFObjectRef?
            guard let states, CGPDFDictionaryGetDictionary(states, name, &state), let state else { return true }
            return ["LW", "LC", "LJ", "D", "ML"].contains { (key: String) in CGPDFDictionaryGetObject(state, key, &object) }
        }, colorComponents: { name in
            // Named color spaces that are plain gray or RGB (with a profile, which is taken as standard).
            var array: CGPDFArrayRef?, kind: UnsafePointer<CChar>?
            guard let spaces, CGPDFDictionaryGetArray(spaces, name, &array), let array, CGPDFArrayGetCount(array) == 2,
                  CGPDFArrayGetName(array, 0, &kind), let kind else { return 0 }
            if strcmp(kind, "CalRGB") == 0 { return 3 }
            if strcmp(kind, "CalGray") == 0 { return 1 }
            var stream: CGPDFStreamRef?, count: CGPDFInteger = 0
            guard strcmp(kind, "ICCBased") == 0, CGPDFArrayGetStream(array, 1, &stream), let stream,
                  let entries = CGPDFStreamGetDictionary(stream), CGPDFDictionaryGetInteger(entries, "N", &count) else { return 0 }
            return count == 1 || count == 3 ? Int(count) : 0
        })
        return try ContentFilter.areas(of: try pageContent(pageDictionary), resources: lookup)
    }

    /// The image the page draws under `name`, as a file to embed in place of a picture of it: the JPEG as
    /// it's stored, or the decoded samples, when that's sure to look the same as the page's drawing of it
    /// (plain RGB or gray, 8 bits, no masks or remapping). At most `maxPixels` on its longer side; nil when
    /// it can't be taken as is, or (for samples that would be written out again) when it isn't sharper than
    /// `minPixels` on its longer side, in which case the page's own picture is just as good.
    func image(named name: String, maxPixels: Int, minPixels: Int) -> TextlessPDF.NativeImage? {
        guard let pageDictionary = page.dictionary,
              let xobjects = inherited(pageDictionary, "Resources").flatMap({ dictionary($0, "XObject") }) else { return nil }
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(xobjects, name, &stream), let stream, let entries = CGPDFStreamGetDictionary(stream) else { return nil }
        var width: CGPDFInteger = 0, height: CGPDFInteger = 0, bits: CGPDFInteger = 0, flag: CGPDFBoolean = 0
        var object: CGPDFObjectRef?
        guard CGPDFDictionaryGetInteger(entries, "Width", &width), CGPDFDictionaryGetInteger(entries, "Height", &height),
              width > 0, height > 0, CGPDFDictionaryGetInteger(entries, "BitsPerComponent", &bits), bits == 8,
              !(CGPDFDictionaryGetBoolean(entries, "ImageMask", &flag) && flag != 0),
              !CGPDFDictionaryGetObject(entries, "SMask", &object), !CGPDFDictionaryGetObject(entries, "Mask", &object),
              !CGPDFDictionaryGetObject(entries, "Decode", &object), !CGPDFDictionaryGetObject(entries, "SMaskInData", &object) else { return nil }
        // DeviceRGB or DeviceGray, or (for samples) an RGB or gray ICC profile, which goes along with them.
        var components = 0, profile: CGColorSpace?
        var space: UnsafePointer<CChar>?, array: CGPDFArrayRef?
        if CGPDFDictionaryGetName(entries, "ColorSpace", &space), let space {
            components = strcmp(space, "DeviceRGB") == 0 ? 3 : strcmp(space, "DeviceGray") == 0 ? 1 : 0
        } else if CGPDFDictionaryGetArray(entries, "ColorSpace", &array), let array, CGPDFArrayGetCount(array) == 2,
                  CGPDFArrayGetName(array, 0, &space), let space, strcmp(space, "ICCBased") == 0 {
            var iccStream: CGPDFStreamRef?, count: CGPDFInteger = 0, format = CGPDFDataFormat.raw
            if CGPDFArrayGetStream(array, 1, &iccStream), let iccStream, let iccEntries = CGPDFStreamGetDictionary(iccStream),
               CGPDFDictionaryGetInteger(iccEntries, "N", &count), count == 1 || count == 3,
               let data = CGPDFStreamCopyData(iccStream, &format), format == .raw,
               let colorSpace = CGColorSpace(iccData: data), colorSpace.numberOfComponents == count {
                components = Int(count)
                profile = colorSpace
            }
        }
        guard components > 0 else { return nil }
        let longest = max(Int(width), Int(height))
        // Samples that wouldn't be sharper than the page picture aren't worth decoding.
        var filter: UnsafePointer<CChar>?, filters: CGPDFArrayRef?
        let isJPEG = CGPDFDictionaryGetName(entries, "Filter", &filter) ? strcmp(filter!, "DCTDecode") == 0
            : CGPDFDictionaryGetArray(entries, "Filter", &filters) && filters.map {
                CGPDFArrayGetCount($0) > 0 && CGPDFArrayGetName($0, CGPDFArrayGetCount($0) - 1, &filter) && strcmp(filter!, "DCTDecode") == 0
            } == true
        guard isJPEG || longest > minPixels else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { return nil }
        let fits = longest <= maxPixels
        switch format {
        case .jpegEncoded:
            // The stored JPEG, unless its own header disagrees with the PDF's description, it has an ICC
            // profile of its own in the PDF (which the file wouldn't carry), or a color-transform override.
            // The PDF ignores the file's own orientation and color profile, which slide apps would follow,
            // so it must have none (or the standard sRGB profile).
            guard profile == nil, Writer.colorTransform(entries).isEmpty,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  properties[kCGImagePropertyPixelWidth] as? Int == Int(width), properties[kCGImagePropertyPixelHeight] as? Int == Int(height),
                  properties[kCGImagePropertyColorModel] as? String == (components == 3 ? "RGB" : "Gray"),
                  (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
                  (properties[kCGImagePropertyProfileName] as? String).map({ components == 3 && $0.contains("sRGB") }) ?? true else { return nil }
            if fits { return .jpeg(data) }
            let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                           kCGImageSourceCreateThumbnailWithTransform: false] as CFDictionary
            guard let smaller = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, smaller, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            return CGImageDestinationFinalize(destination) ? .jpeg(output as Data) : nil
        case .raw:
            guard longest > minPixels, data.count >= Int(width) * Int(height) * components,
                  let provider = CGDataProvider(data: data as CFData),
                  let colorSpace = profile ?? CGColorSpace(name: components == 3 ? CGColorSpace.sRGB : CGColorSpace.genericGrayGamma2_2),
                  let image = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 8 * components,
                                      bytesPerRow: Int(width) * components, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
            if fits { return .image(image) }
            let scale = CGFloat(maxPixels) / CGFloat(longest)
            let size = (width: max(1, Int(CGFloat(width) * scale)), height: max(1, Int(CGFloat(height) * scale)))
            guard let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: colorSpace, bitmapInfo: components == 3 ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.none.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            return context.makeImage().map { .image($0) }
        default:
            return nil
        }
    }

    private func pageContent(_ pageDictionary: CGPDFDictionaryRef) throws -> Data {
        var content = Data()
        for stream in contentStreams(pageDictionary) {
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(stream, &format) as Data?, format == .raw else {
                throw TextlessPDF.Unsupported(reason: "unreadable page contents")
            }
            content.append(data)
            content.append(0x0A)
        }
        return content
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
    static func colorTransform(_ dictionary: CGPDFDictionaryRef) -> String {
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
///
/// It also follows the drawing position (cm, q/Q, clipping) closely enough to say where each drawing step
/// lands: a painted path, an image, a shading or a nested drawing. `keeping` can leave steps out: a
/// dropped path still clips (it ends with `n`), a dropped image or shading isn't drawn.
nonisolated private struct ContentFilter {
    enum XObject { case image, form(CGAffineTransform, CGRect) }

    /// Looks up the page's named resources while working out where steps land.
    struct Resources {
        var xobject: (String) -> XObject?
        var isPlainState: (String) -> Bool      // An ExtGState with no transparency or blending
        var setsLineStyle: (String) -> Bool     // An ExtGState that sets the line width, dashes, caps or joins
        var colorComponents: (String) -> Int    // 1 or 3 for a named gray or RGB color space, else 0
    }

    private let bytes: [UInt8]
    private var output = Data()
    private let keep: ((Int) -> Bool)?
    private let resources: Resources?
    private var areas: [TextlessPDF.Step] = []

    private init(_ content: Data, keep: ((Int) -> Bool)?, resources: Resources?) {
        bytes = [UInt8](content)
        self.keep = keep
        self.resources = resources
        output.reserveCapacity(content.count)
    }

    static func strip(_ content: Data, keeping keep: ((Int) -> Bool)? = nil) throws -> Data {
        var filter = ContentFilter(content, keep: keep, resources: nil)
        return try filter.run()
    }

    static func areas(of content: Data, resources: Resources) throws -> [TextlessPDF.Step] {
        var filter = ContentFilter(content, keep: nil, resources: resources)
        _ = try filter.run()
        return filter.areas
    }

    /// Records a drawing step's area and says whether it's drawn.
    private mutating func paints(_ area: CGRect, image: Bool = false, plainImage: String? = nil, shape: TextlessPDF.Shape? = nil) -> Bool {
        areas.append(TextlessPDF.Step(area: area, isImage: image, plainImage: plainImage, shape: shape))
        return keep?(areas.count - 1) ?? true
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

        // Where things land: the current transform, clip and line width (saved by q), the path being built.
        // `clip` is the clip's bounding box; `rectClip` says it's exact (every clip so far was one
        // upright rectangle). `plain`: no transparency or blending is in effect.
        var ctm = CGAffineTransform.identity
        var clip = CGRect.infinite
        var lineWidth: CGFloat = 1
        var rectClip = true, plain = true
        var style = Style()
        var saved: [(CGAffineTransform, CGRect, CGFloat, Bool, Bool, Style)] = []
        var path = CGRect.null
        var pathParts = 0, pathIsRect = false   // Operators in the path; whether it's one `re`
        // The path's pieces, in page space, while it's short enough to be a simple shape (areas pass only).
        let recordsShapes = resources != nil
        var pieces: [UInt8] = [], points: [CGPoint] = []
        var current = CGPoint.zero, simple = true
        func record(_ piece: UInt8, _ values: [CGFloat]?) {
            guard recordsShapes, simple else { return }
            guard let values, pieces.count < 12 else { simple = false; return }
            if piece == UInt8(ascii: "v") { points.append(current) }
            var last = current
            for pair in stride(from: 0, to: values.count - 1, by: 2) {
                last = CGPoint(x: values[pair], y: values[pair + 1]).applying(ctm)
                points.append(last)
            }
            if piece == UInt8(ascii: "y") { points.append(last) }
            pieces.append(piece == UInt8(ascii: "v") || piece == UInt8(ascii: "y") ? UInt8(ascii: "c") : piece)
            current = last
        }
        /// The bytes of a color's operands (read only if a shape is painted with it), nil when it can't be.
        func color(_ operands: [Range<Int>], components: Int) -> Range<Int>? {
            guard components > 0, operands.count == components, let first = operands.first, let last = operands.last else { return nil }
            return first.lowerBound..<last.upperBound
        }
        // Colors and line style, for simple shapes. Checked by first byte so other operators don't pay for it.
        func setsStyle(_ name: String) -> Bool {
            let stroking = name.utf8.first! < 0x61
            switch name {
            case "g", "G", "rg", "RG", "k", "K":
                let components = name == "k" || name == "K" ? 0 : name.utf8.count == 1 ? 1 : 3
                let value = color(operands, components: components)
                if stroking { style.stroke = value; style.strokeComponents = components } else { style.fill = value; style.fillComponents = components }
            case "cs", "CS":
                var components = 0
                if let operand = operands.last, bytes[operand.lowerBound] == 0x2F {
                    let space = ContentFilter.decodedName(bytes[operand])
                    components = space == "DeviceGray" ? 1 : space == "DeviceRGB" ? 3 : resources?.colorComponents(space) ?? 0
                }
                let initial: Range<Int>? = components == 0 ? nil : 0..<0
                if stroking { style.stroke = initial; style.strokeComponents = components } else { style.fill = initial; style.fillComponents = components }
            case "sc", "scn", "SC", "SCN":
                if stroking { style.stroke = color(operands, components: style.strokeComponents) }
                else { style.fill = color(operands, components: style.fillComponents) }
            case "d":
                // Solid: an empty dash array (or only zeros).
                style.solid = operands.count == 2 && bytes[operands[0]].allSatisfy {
                    $0 == 0x5B || $0 == 0x5D || $0 == 0x30 || $0 == 0x2E || ContentFilter.isSpace($0)
                }
            case "J":
                style.cap = numbers(operands, 1).map { Int($0[0]) } ?? -1
            case "j":
                style.join = numbers(operands, 1).map { Int($0[0]) } ?? -1
            case "h":
                record(UInt8(ascii: "h"), [])
            default:
                return false
            }
            return true
        }
        var clipsPath = false            // W or W* seen: the next painting operator also clips
        var inlineStart = 0              // Output position of the BI that starts an inline image
        func numbers(_ operands: [Range<Int>], _ count: Int) -> [CGFloat]? {
            guard operands.count >= count else { return nil }
            let values = operands.suffix(count).compactMap { Double(String(decoding: bytes[$0], as: UTF8.self)) }
            return values.count == count ? values.map { CGFloat($0) } : nil
        }
        func add(_ values: [CGFloat]?) {
            guard let values else { return }
            for pair in stride(from: 0, to: values.count - 1, by: 2) {
                let point = CGPoint(x: values[pair], y: values[pair + 1]).applying(ctm)
                path = path.union(CGRect(origin: point, size: .zero))
            }
        }

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
                let name = String(decoding: token, as: UTF8.self)
                if recordsShapes, token.count <= 3, ContentFilter.maySetStyle(token.first!), setsStyle(name) {
                    emit(run)
                    runStart = index
                    operands.removeAll(keepingCapacity: true)
                    continue
                }
                switch name {
                case "m", "l":
                    let values = numbers(operands, 2)
                    add(values); record(token.first!, values); pathParts += 1; emit(run)
                case "c":
                    let values = numbers(operands, 6)
                    add(values); record(token.first!, values); pathParts += 1; emit(run)
                case "v", "y":
                    let values = numbers(operands, 4)
                    add(values); record(token.first!, values); pathParts += 1; emit(run)
                case "re":
                    let r = numbers(operands, 4)
                    if let r { add([r[0], r[1], r[0] + r[2], r[1], r[0], r[1] + r[3], r[0] + r[2], r[1] + r[3]]) }
                    if ctm.b == 0 && ctm.c == 0 { record(UInt8(ascii: "r"), r.map { [$0[0], $0[1], $0[0] + $0[2], $0[1] + $0[3]] }) } else { simple = false }
                    pathParts += 1
                    pathIsRect = pathParts == 1
                    emit(run)
                case "W", "W*":
                    clipsPath = true
                    emit(run)
                case "f", "F", "f*", "S", "s", "B", "B*", "b", "b*", "n":
                    if name == "n" {
                        emit(run)
                    } else {
                        var area = path
                        if name != "f" && name != "F" && name != "f*" && !area.isNull {
                            let pad = max(lineWidth * sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c)), 1) / 2
                            area = area.insetBy(dx: -pad, dy: -pad)
                        }
                        var shape: TextlessPDF.Shape?
                        if recordsShapes, simple, plain, !area.isNull, clip.isInfinite || (rectClip && clip.contains(area)) {
                            shape = self.shape(pieces, points, painter: name, style: style, lineWidth: lineWidth, ctm: ctm)
                        }
                        if paints(area.intersection(clip), shape: shape) { emit(run) } else { output.append(contentsOf: Array("n\n".utf8)) }
                    }
                    if clipsPath {
                        clip = clip.intersection(path)
                        if !(pathIsRect && pathParts == 1 && ctm.b == 0 && ctm.c == 0) { rectClip = false }
                    }
                    clipsPath = false
                    path = .null
                    pathParts = 0; pathIsRect = false
                    if recordsShapes { pieces.removeAll(keepingCapacity: true); points.removeAll(keepingCapacity: true); simple = true }
                case "cm":
                    if let m = numbers(operands, 6) {
                        ctm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).concatenating(ctm)
                    }
                    emit(run)
                case "w":
                    if let width = numbers(operands, 1) { lineWidth = width[0] }
                    emit(run)
                case "sh":
                    if paints(clip) { emit(run) }
                case "Do":
                    var area = clip, image = false, plainImage: String?
                    if let resources, let operand = operands.last, bytes[operand.lowerBound] == 0x2F {
                        let name = ContentFilter.decodedName(bytes[operand])
                        switch resources.xobject(name) {
                        case .image:
                            let placed = CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm)
                            area = placed.intersection(clip)
                            image = true
                            // Upright (not turned or flipped), and the clip, if any, is a rectangle around it.
                            if plain, ctm.b == 0, ctm.c == 0, ctm.a > 0, ctm.d > 0,
                               clip.isInfinite || (rectClip && clip.insetBy(dx: -0.01, dy: -0.01).contains(placed)) {
                                plainImage = name
                            }
                        case .form(let matrix, let box) where !box.isInfinite: area = box.applying(matrix.concatenating(ctm)).intersection(clip)
                        default: break
                        }
                    }
                    if paints(area, image: image, plainImage: plainImage) { emit(run) }
                case "gs":
                    if let resources, let operand = operands.last, bytes[operand.lowerBound] == 0x2F {
                        let state = ContentFilter.decodedName(bytes[operand])
                        if plain && !resources.isPlainState(state) { plain = false }
                        if style.known && resources.setsLineStyle(state) { style.known = false }
                    }
                    emit(run)
                case "BI":
                    inlineStart = output.count
                    emit(run)
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
                    if clipsText {
                        output.append(contentsOf: Array("0 0 0 0 re W n\n".utf8))
                        clip = .null
                        rectClip = false
                    }
                    clipsText = false
                case "q":
                    savedModes.append(renderMode)
                    saved.append((ctm, clip, lineWidth, rectClip, plain, style))
                    emit(run)
                case "Q":
                    renderMode = savedModes.popLast() ?? renderMode
                    if let state = saved.popLast() { (ctm, clip, lineWidth, rectClip, plain, style) = state }
                    emit(run)
                case "ID":
                    // Inline image data runs to an EI that stands on its own.
                    let drawn = paints(CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm).intersection(clip), image: true)
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
                    if drawn {
                        output.append(contentsOf: bytes[index..<end])
                        output.append(0x0A)
                    } else {
                        output.removeSubrange(min(inlineStart, output.count)..<output.count)
                    }
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

    /// The color and line settings a simple shape is painted with. Colors are gray or RGB components, nil
    /// when they're something else (CMYK, a pattern, a separation); `dash` is nil when it can't be redrawn.
    struct Style {
        var fill: Range<Int>? = 0..<0, stroke: Range<Int>? = 0..<0     // Operand bytes; empty is black
        var fillComponents = 1, strokeComponents = 1
        var solid = true
        var cap = 0, join = 0
        var known = true            // No graphics state set line settings this doesn't follow
    }

    /// The first bytes of the operators `setsStyle` handles.
    private static func maySetStyle(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x67, 0x47, 0x72, 0x52, 0x6B, 0x4B, 0x73, 0x53, 0x63, 0x43, 0x64, 0x4A, 0x6A, 0x68: true   // g G r R k K s S c C d J j h
        default: false
        }
    }

    /// The simple shape a path makes when painted with `painter` (f, S, B…), or nil when it's anything else.
    /// `pieces` are the path's operators (m, l, c, r for re, h), `points` their points in page space.
    private func shape(_ pieces: [UInt8], _ points: [CGPoint], painter: String, style: Style, lineWidth: CGFloat,
                       ctm: CGAffineTransform) -> TextlessPDF.Shape? {
        let fills = painter.hasPrefix("f") || painter.hasPrefix("F") || painter.hasPrefix("B") || painter.hasPrefix("b")
        let strokes = painter != "f" && painter != "F" && painter != "f*"
        // Cheap checks first: most paths (letters, icons, curves) aren't one of these shapes.
        let (m, l, c, r) = (UInt8(ascii: "m"), UInt8(ascii: "l"), UInt8(ascii: "c"), UInt8(ascii: "r"))
        var lines = 0, curves = 0, rects = 0, moves = 0
        for piece in pieces {
            switch piece {
            case l: lines += 1
            case c: curves += 1
            case r: rects += 1
            case m: moves += 1
            default: break
            }
        }
        guard (rects == 1 && moves + lines + curves == 0) || (rects == 0 && moves == 1 && pieces.first == m
                && ((curves == 0 && (lines == 1 || (3...4).contains(lines))) || (curves == 4 && lines <= 5))),
              !fills || style.fill != nil, !strokes || (style.stroke != nil && style.solid && style.known) else { return nil }
        /// The color's operands as 0xRRGGBB (empty is black).
        func hex(_ span: Range<Int>?, _ count: Int) -> UInt32? {
            guard let span else { return nil }
            var result: UInt32 = 0, found = 0, index = span.lowerBound
            while index < span.upperBound {
                while index < span.upperBound, ContentFilter.isSpace(bytes[index]) { index += 1 }
                guard index < span.upperBound else { break }
                var end = index
                while end < span.upperBound, !ContentFilter.isSpace(bytes[end]) { end += 1 }
                guard let value = ContentFilter.number(bytes[index..<end]), (0...1).contains(value) else { return nil }
                result = result << 8 | UInt32((value * 255).rounded())
                found += 1
                index = end
            }
            guard found == count || span.isEmpty else { return nil }
            return count == 1 ? result * 0x010101 : result
        }
        if pieces.count == 1 && rects == 1 {
            // The common case, a box drawn with re: its two corners.
            let box = CGRect(x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y),
                             width: abs(points[1].x - points[0].x), height: abs(points[1].y - points[0].y))
            guard box.width > 0, box.height > 0 else { return nil }
            return finish(TextlessPDF.Shape(kind: .rect, bounds: box))
        }
        func finish(_ shape: TextlessPDF.Shape) -> TextlessPDF.Shape? {
            var shape = shape
            if fills {
                guard let fill = hex(style.fill, style.fillComponents) else { return nil }
                shape.fill = fill
            }
            if strokes {
                // A stroke is redrawn only with an even scale (so its width is the same both ways).
                let scale = abs(ctm.a)
                // Solid lines only: Apple's importer (Keynote, Quick Look) doesn't draw PowerPoint's dashes as
                // PowerPoint does, so a dashed line stays a picture.
                // Plain ends on a line and sharp corners on a box: Apple's importer draws every line end flat
                // and every corner sharp.
                var plainEnds = style.cap == 0, sharpCorners = style.join == 0
                switch shape.kind {
                case .line: sharpCorners = true
                case .rect: plainEnds = true
                case .ellipse, .roundRect: plainEnds = true; sharpCorners = true
                }
                guard let stroke = hex(style.stroke, style.strokeComponents), plainEnds, sharpCorners,
                      ctm.b == 0, ctm.c == 0, scale > 0, abs(abs(ctm.d) - scale) < scale * 0.001, lineWidth > 0 else { return nil }
                shape.stroke = stroke
                shape.lineWidth = lineWidth * scale
                shape.cap = style.cap
                shape.join = style.join
            }
            return shape
        }

        // Tidy the path: drop a closing h, a last line back to the start, and lines that go nowhere. Each
        // piece is kept as its kind and the index of its last point (a curve's handles come just before).
        var kinds: [UInt8] = [], ends: [Int] = []
        kinds.reserveCapacity(pieces.count); ends.reserveCapacity(pieces.count)
        var index = 0
        for piece in pieces {
            let count = piece == c ? 3 : piece == r ? 2 : piece == UInt8(ascii: "h") ? 0 : 1
            guard index + count <= points.count else { return nil }
            index += count
            if count == 0 { continue }
            if piece == l, let previous = ends.last, points[index - 1] == points[previous] { continue }
            if piece == m && !kinds.isEmpty { return nil }   // A second subpath
            kinds.append(piece); ends.append(index - 1)
        }
        let closed = pieces.last == UInt8(ascii: "h") || painter == "s" || painter == "b" || painter == "b*"
        if kinds.count > 2, kinds.last == l, let start = points.first, let end = ends.last.map({ points[$0] }),
           abs(start.x - end.x) < 0.01, abs(start.y - end.y) < 0.01 {
            kinds.removeLast(); ends.removeLast()
        }
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x); minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let tolerance = max(box.width, box.height) * 0.01 + 0.05
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= tolerance }
        func onSide(_ point: CGPoint) -> Bool { near(point.x, box.minX) || near(point.x, box.maxX) }
        func onEnd(_ point: CGPoint) -> Bool { near(point.y, box.minY) || near(point.y, box.maxY) }
        var shape = TextlessPDF.Shape(kind: .rect, bounds: box)

        if kinds.count == 2 && kinds[1] == l && !closed {
            guard strokes, !fills, points[ends[1]] != first else { return nil }
            shape.kind = .line(first, points[ends[1]])
            return finish(shape)
        }
        if kinds.count == 4 && !kinds.contains(c) {
            // Four corners, each step straight across or up and down: a box (closed when painted).
            guard closed || !strokes, box.width > 0, box.height > 0 else { return nil }
            for (position, end) in ends.enumerated() {
                let a = points[end], b = points[ends[(position + 1) % 4]]
                guard near(a.x, b.x) || near(a.y, b.y), onSide(a), onEnd(a) else { return nil }
            }
            return finish(shape)
        }
        // Curves: an ellipse (four quarter curves) or a rounded rectangle (four corner curves and straight sides).
        guard kinds.filter({ $0 == c }).count == 4, box.width > 1, box.height > 1 else { return nil }
        // Stroked, it must close: with h, or by ending where it starts (smoothly, on a curve, so no corner is
        // left open).
        if strokes && !closed {
            guard kinds.last == c, let end = ends.last.map({ points[$0] }), near(end.x, first.x), near(end.y, first.y) else { return nil }
        }
        let isEllipse = kinds.count == 5
        var start = first, corners = 0, radius: CGFloat = 0
        for position in 1..<kinds.count {
            let end = points[ends[position]]
            defer { start = end }
            if kinds[position] == l {
                // A straight side runs along the box.
                guard (near(start.x, end.x) && onSide(start)) || (near(start.y, end.y) && onEnd(start)) else { return nil }
                continue
            }
            // A quarter curve: from the middle of one side of its box to the next, its handles pointing at the
            // corner they turn around, about 0.55 of the way.
            let rx = abs(end.x - start.x), ry = abs(end.y - start.y)
            guard rx > tolerance, ry > tolerance else { return nil }
            let corner = onSide(start) ? CGPoint(x: start.x, y: end.y) : CGPoint(x: end.x, y: start.y)
            guard onSide(corner), onEnd(corner) else { return nil }
            let handle1 = points[ends[position] - 2], handle2 = points[ends[position] - 1]
            let along1 = near(start.x, corner.x) ? (near(handle1.x, start.x), abs(handle1.y - start.y) / ry) : (near(handle1.y, start.y), abs(handle1.x - start.x) / rx)
            let along2 = near(end.x, corner.x) ? (near(handle2.x, end.x), abs(handle2.y - end.y) / ry) : (near(handle2.y, end.y), abs(handle2.x - end.x) / rx)
            guard along1.0, along2.0, (0.5...0.6).contains(along1.1), (0.5...0.6).contains(along2.1) else { return nil }
            corners |= 1 << ((corner.x > box.midX ? 1 : 0) + (corner.y > box.midY ? 2 : 0))
            if isEllipse {
                guard near(rx, box.width / 2), near(ry, box.height / 2) else { return nil }
            } else {
                if radius == 0 { radius = rx }
                guard near(rx, radius), near(ry, radius) else { return nil }
            }
        }
        guard corners == 0b1111 else { return nil }
        if isEllipse {
            shape.kind = .ellipse
            return finish(shape)
        }
        guard radius <= min(box.width, box.height) / 2 + tolerance else { return nil }
        shape.kind = .roundRect(radius: radius)
        return finish(shape)
    }

    /// A content-stream number, read straight from its bytes (no exponents in PDF).
    static func number(_ token: ArraySlice<UInt8>) -> Double? {
        var value = 0.0, scale = 0.0, negative = false, digits = 0
        for (offset, byte) in zip(0..., token) {
            switch byte {
            case 0x30...0x39:
                digits += 1
                if scale == 0 { value = value * 10 + Double(byte - 0x30) } else { value += Double(byte - 0x30) * scale; scale /= 10 }
            case 0x2E where scale == 0: scale = 0.1
            case 0x2D where offset == 0: negative = true
            case 0x2B where offset == 0: break
            default: return nil
            }
        }
        return digits > 0 ? (negative ? -value : value) : nil
    }

    /// A content-stream name without its slash, with #xx escapes decoded.
    private static func decodedName(_ token: ArraySlice<UInt8>) -> String {
        var result: [UInt8] = []
        var index = token.startIndex + 1
        while index < token.endIndex {
            if token[index] == 0x23, index + 2 < token.endIndex,
               let value = UInt8(String(decoding: token[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                result.append(value)
                index += 3
            } else {
                result.append(token[index])
                index += 1
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    private mutating func emit(_ range: Range<Int>) {
        output.append(contentsOf: bytes[range])
        output.append(0x0A)
    }
}
