import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Turns a file of one format into another, choosing the right engine for the pair. Everything runs on
/// macOS's own frameworks, the libraries built into the app (LAME, libwebp), the bundled Ghostscript,
/// or, for Office and iWork files, Keynote, Numbers and Pages.
enum Converter {
    enum Route {
        case image          // ImageIO (+ libwebp for WebP)
        case imageToPDF     // PDFKit
        case pdfToImage     // PDFKit
        case document       // AppKit's text system, Markdown, Pages for Word → PDF
        case media          // AVFoundation, Core Audio, LAME
        case fromSlides     // Keynote exports a presentation as PDF (then pages → images)
        case slidesExport   // Keynote saves older PowerPoint and Keynote files as .pptx
        case toSlides       // One slide per PDF page or image
        case spreadsheet    // Excel ↔ CSV directly; Numbers for the rest
        case textRecognition   // Vision reads the text in an image
    }

    static let documentSources: [Format] = [.md, .txt, .html, .docx, .doc, .rtf, .odt, .pages, .pdf]
    static let documentTargets: [Format] = [.md, .txt, .html, .docx, .doc, .rtf, .odt, .pdf]

    static func route(from: Format, to: Format) -> Route? {
        guard from != to, !to.isIWork else { return nil }   // Pages, Numbers and Keynote can be read but not written
        if from.isSlides {
            if to == .pdf || to.kind == .image { return .fromSlides }
            return to == .pptx ? .slidesExport : nil
        }
        if to.isSlides {
            guard to == .pptx else { return nil }
            return from == .pdf || from.kind == .image ? .toSlides : nil
        }
        if from.kind == .spreadsheet || to.kind == .spreadsheet {
            guard from.kind == .spreadsheet, [.pdf, .csv, .xlsx].contains(to) else { return nil }
            return .spreadsheet
        }
        switch (from.kind, to.kind) {
        case (.image, .image): return .image
        case (.image, .document) where to == .pdf: return .imageToPDF
        case (.image, .document) where [.txt, .md, .docx, .html, .rtf, .odt].contains(to): return .textRecognition
        case (.document, .image) where from == .pdf: return .pdfToImage
        case (.document, .document) where documentSources.contains(from) && documentTargets.contains(to): return .document
        // macOS reads Ogg and Opus audio but can only write Opus inside Apple's own CAF files.
        case (.audio, .audio), (.video, .audio): return [.ogg, .opus].contains(to) ? nil : .media
        case (.video, .video): return .media
        case (.video, .image) where to != .ico && to != .avif: return .media
        case (.image, .video) where from == .gif: return .media
        default: return nil
        }
    }

    /// Video and the iWork apps are slow or can only do one file at a time, so they run one at a time.
    static func isHeavy(from: Format, to: Format) -> Bool {
        switch route(from: from, to: to) {
        case .media: from.kind == .video || to.kind == .video
        case .fromSlides, .slidesExport: true
        case .spreadsheet: !(from == .xlsx && to == .csv) && !(from == .csv && to == .xlsx)
        case .document: from == .pages || (to == .pdf && [.docx, .doc, .rtf].contains(from))
        default: false
        }
    }

    struct Request: Sendable {
        let input: URL          // A private copy of the file, named input.<source extension>
        let from: Format
        let to: Format
        let workDir: URL
        let title: String       // File name without extension, used for document titles
        let originalDir: URL    // Lets HTML and Markdown find images referenced by relative path
        var allPages = false    // PDF/slides → image: render every page into a folder instead of just the first
        var outputExtension: String?   // The extension as typed (jpg vs jpeg), for naming page images
        var editableSlides = false     // PDF → pptx: editable text boxes instead of page pictures
        var quality: Quality = .balanced
    }

    /// Returns the URL of the converted file inside `request.workDir`, or of a folder when the result is
    /// several files (every page of a PDF as images, every sheet of a workbook as CSV).
    static func convert(_ request: Request, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let route = route(from: request.from, to: request.to) else {
            throw ConversionError.unsupported(request.from, request.to)
        }
        let output = request.workDir.appending(path: "output.\(request.to.rawValue)")
        var result = output
        switch route {
        case .image:
            try await Task.detached(priority: .utility) {
                if request.to == .webp {
                    try WebP.write(imageAt: request.input, to: output, quality: request.quality)
                } else {
                    try ImageConversion.convert(request.input, to: request.to, output: output, quality: request.quality)
                }
            }.value
        case .imageToPDF:
            try await Task.detached(priority: .utility) {
                try ImageConversion.imageToPDF(request.input, output: output)
            }.value
        case .pdfToImage:
            result = try await renderPages(of: request.input, request: request, output: output, progress: progress)
        case .fromSlides:
            let pdf = request.to == .pdf ? output : request.workDir.appending(path: "slides.pdf")
            try await IWork.export(request.input, with: .keynote, as: .pdf, to: pdf)
            if request.to != .pdf {
                result = try await renderPages(of: pdf, request: request, output: output, progress: progress)
            }
        case .slidesExport:
            try await IWork.export(request.input, with: .keynote, as: .powerPoint, to: output)
        case .toSlides:
            try await SlideBuilder.build(request, output: output, progress: progress)
        case .spreadsheet:
            switch (request.from, request.to) {
            case (.xlsx, .csv):
                result = try await Spreadsheets.xlsxToCSV(request, output: output)
            case (.csv, .xlsx):
                try await Spreadsheets.csvToXLSX(request, output: output)
            default:
                let format: IWork.ExportFormat = request.to == .pdf ? .pdf : request.to == .csv ? .csv : .excel
                result = try await IWork.export(request.input, with: .numbers, as: format, to: output)
            }
        case .textRecognition:
            try await TextRecognition.convertImage(request, output: output)
        case .document:
            try await DocumentConversion.convert(request, output: output)
        case .media:
            try await MediaConversion.convert(request, output: output, progress: progress)
        }
        guard FileManager.default.fileExists(atPath: result.path) else {
            throw ConversionError.failed("The converter didn't produce a file.")
        }
        return result
    }

    /// Renders the first page to `output`, or, with `allPages`, every page of a multi-page PDF
    /// into a folder of images named "<title> 01", "<title> 02"…
    private static func renderPages(of pdf: URL, request: Request, output: URL,
                                    progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let pageCount = PDFDocument(url: pdf)?.pageCount ?? 0
        let allPages = request.allPages && pageCount > 1
        let folder = request.workDir.appending(path: "pages")
        let digits = max(2, String(pageCount).count)
        let typedExtension = request.outputExtension ?? request.to.rawValue

        try await Task.detached(priority: .utility) {
            guard let document = PDFDocument(url: pdf), document.pageCount > 0 else {
                throw ConversionError.failed("Couldn't read this PDF.")
            }
            func save(_ index: Int, to url: URL) throws {
                guard let page = document.page(at: index) else { return }
                let image = try ImageConversion.render(page, scale: request.quality.pageScale)
                if request.to == .webp {
                    try WebP.write(image, to: url, quality: request.quality)
                } else {
                    try ImageConversion.write(image, to: url, format: request.to,
                                              properties: [kCGImageDestinationLossyCompressionQuality: request.quality.imageQuality])
                }
            }
            guard allPages else { return try save(0, to: output) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                let name = "\(request.title) \(String(format: "%0\(digits)d", index + 1)).\(typedExtension)"
                try save(index, to: folder.appending(path: name))
                progress(Double(index + 1) / Double(document.pageCount))
            }
        }.value
        return allPages ? folder : output
    }
}

// MARK: - Quality

/// How much to favor quality over file size. Applies to photos, page images, audio and video;
/// documents and lossless formats aren't affected.
nonisolated enum Quality: String, CaseIterable, Sendable {
    case best, balanced, small

    var title: String {
        switch self {
        case .best: "Best quality"
        case .balanced: "Balanced"
        case .small: "Smaller files"
        }
    }

    var imageQuality: Double { switch self { case .best: 0.95; case .balanced: 0.88; case .small: 0.7 } }
    var webpQuality: Int { switch self { case .best: 92; case .balanced: 84; case .small: 70 } }
    /// Photos are scaled down so their longest side is at most this many pixels.
    var maxImageSide: Int? { self == .small ? 2560 : nil }
    /// PDF and slide pages: 2.5x = 180 dpi, 2x = 144 dpi, 1.5x = 108 dpi.
    var pageScale: CGFloat { switch self { case .best: 2.5; case .balanced: 2; case .small: 1.5 } }

    var gifSettings: (fps: Int, width: Int) { switch self { case .best: (15, 800); case .balanced: (12, 640); case .small: (10, 480) } }

    var mp3VBR: Int { switch self { case .best: 0; case .balanced: 2; case .small: 5 } }
    var aacBitrate: Int { switch self { case .best: 256_000; case .balanced: 192_000; case .small: 128_000 } }
}

// MARK: - Images

nonisolated enum ImageConversion {
    /// Reads an image with its EXIF rotation applied, scaled down for "Smaller files".
    static func load(_ input: URL, quality: Quality, maxSide: Int? = nil) throws -> CGImage {
        try decode(input, quality: quality, maxSide: maxSide).image
    }

    static func convert(_ input: URL, to format: Format, output: URL, quality: Quality = .balanced) throws {
        var (image, properties) = try decode(input, quality: quality, maxSide: format == .ico ? 256 : nil)
        if [.jpeg, .bmp].contains(format), image.hasAlpha {
            image = try image.flattenedOnWhite()
        }

        var metadata = properties
        metadata[kCGImagePropertyOrientation] = 1
        if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        metadata[kCGImageDestinationLossyCompressionQuality] = quality.imageQuality
        metadata[kCGImagePropertyPixelWidth] = nil
        metadata[kCGImagePropertyPixelHeight] = nil
        try write(image, to: output, format: format, properties: metadata)
    }

    private static func decode(_ input: URL, quality: Quality, maxSide: Int?) throws -> (image: CGImage, properties: [CFString: Any]) {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ConversionError.failed("Couldn't read this image.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        var maxSize = max(width, height, 1)
        if let side = quality.maxImageSide { maxSize = min(maxSize, side) }
        if let maxSide { maxSize = min(maxSize, maxSide) }

        // A full-size "thumbnail" with the transform applied bakes in the EXIF rotation (e.g. iPhone photos).
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ConversionError.failed("Couldn't decode this image.")
        }
        return (image, properties)
    }

    static func write(_ image: CGImage, to output: URL, format: Format, properties: [CFString: Any] = [:]) throws {
        guard let type = format.utType,
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConversionError.failed("Can't write \(format.displayName) images.")
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.failed("Couldn't write the \(format.displayName) file.")
        }
    }

    static func imageToPDF(_ input: URL, output: URL) throws {
        guard let image = NSImage(contentsOf: input), let page = PDFPage(image: image) else {
            throw ConversionError.failed("Couldn't read this image.")
        }
        let document = PDFDocument()
        document.insert(page, at: 0)
        guard document.write(to: output) else { throw ConversionError.failed("Couldn't write the PDF.") }
    }

    /// Renders one page (the first by default) at the quality's resolution.
    static func pdfToImage(_ input: URL, page index: Int = 0, format: Format, output: URL, quality: Quality = .balanced) throws {
        guard let page = PDFDocument(url: input)?.page(at: index) else {
            throw ConversionError.failed("Couldn't read this PDF.")
        }
        try write(render(page, scale: quality.pageScale), to: output, format: format,
                  properties: [kCGImageDestinationLossyCompressionQuality: quality.imageQuality])
    }

    static func render(_ page: PDFPage, scale: CGFloat = 2) throws -> CGImage {
        // The crop box is the visible page; rotated pages (common in scans) swap width and height.
        let bounds = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation) % 180 == 90
        let size = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ConversionError.failed("Couldn't render this PDF.")
        }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { throw ConversionError.failed("Couldn't render this PDF.") }
        return image
    }
}

nonisolated extension Format {
    var utType: UTType? {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .tiff: .tiff
        case .gif: .gif
        case .bmp: .bmp
        case .ico: .ico
        case .avif: UTType("public.avif")
        case .pdf: .pdf
        default: nil
        }
    }
}

nonisolated private extension CGImage {
    var hasAlpha: Bool {
        ![.none, .noneSkipFirst, .noneSkipLast].contains(alphaInfo)
    }

    func flattenedOnWhite() throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ConversionError.failed("Couldn't process this image.")
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(.white)
        context.fill(rect)
        context.draw(self, in: rect)
        guard let image = context.makeImage() else { throw ConversionError.failed("Couldn't process this image.") }
        return image
    }
}

