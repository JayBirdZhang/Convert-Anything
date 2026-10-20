import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Turns a file of one format into another, choosing the right tool for the pair.
enum Converter {
    enum Route {
        case image          // ImageIO (built in)
        case imageToPDF     // PDFKit
        case pdfToImage     // PDFKit
        case document       // pandoc + textutil (+ LibreOffice for Office → PDF)
        case media          // ffmpeg
        case fromSlides     // LibreOffice renders PowerPoint to PDF
        case toSlides       // One full-slide picture per PDF page or image
    }

    static func route(from: Format, to: Format) -> Route? {
        guard from != to else { return nil }
        if from == .pptx {
            return to == .pdf || to.kind == .image ? .fromSlides : nil
        }
        if to == .pptx {
            if from == .pdf || from.kind == .image { return .toSlides }
            return [.md, .txt, .html, .docx, .doc, .rtf, .odt].contains(from) ? .document : nil
        }
        switch (from.kind, to.kind) {
        case (.image, .image): return .image
        case (.image, .document) where to == .pdf: return .imageToPDF
        case (.document, .image) where from == .pdf: return .pdfToImage
        case (.document, .document): return .document
        case (.audio, .audio), (.video, .audio), (.video, .video): return .media
        case (.video, .image) where [.gif, .png, .jpeg, .bmp, .tiff].contains(to): return .media
        case (.image, .video) where from == .gif: return .media
        default: return nil
        }
    }

    /// Video and LibreOffice conversions are slow and use a lot of CPU, so they run one at a time.
    static func isHeavy(from: Format, to: Format) -> Bool {
        switch route(from: from, to: to) {
        case .media: from.kind == .video || to.kind == .video
        case .fromSlides: true
        case .document: DocumentConversion.usesLibreOffice(from: from, to: to)
        default: false
        }
    }

    struct Request: Sendable {
        let input: URL          // A private copy of the file, named input.<source extension>
        let from: Format
        let to: Format
        let workDir: URL
        let title: String       // File name without extension, used for document titles
        let originalDir: URL    // Lets pandoc find images referenced by relative path
        var allPages = false    // PDF/slides → image: render every page into a folder instead of just the first
        var outputExtension: String?   // The extension as typed (jpg vs jpeg), for naming page images
        var editableSlides = false     // PDF → pptx: editable text boxes instead of page pictures
    }

    /// Returns the URL of the converted file inside `request.workDir`, or of a folder of images
    /// when every page of a multi-page PDF or presentation was rendered.
    static func convert(_ request: Request, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let route = route(from: request.from, to: request.to) else {
            throw ConversionError.unsupported(request.from, request.to)
        }
        let output = request.workDir.appending(path: "output.\(request.to.rawValue)")
        var result = output
        switch route {
        case .image:
            if request.to == .webp {
                try await writeWebP(from: request.input, to: output, workDir: request.workDir)
            } else {
                try await Task.detached(priority: .utility) {
                    try ImageConversion.convert(request.input, to: request.to, output: output)
                }.value
            }
        case .imageToPDF:
            try await Task.detached(priority: .utility) {
                try ImageConversion.imageToPDF(request.input, output: output)
            }.value
        case .pdfToImage:
            result = try await renderPages(of: request.input, request: request, output: output, progress: progress)
        case .fromSlides:
            let pdf = try await LibreOffice.convert(request.input, to: "pdf", workDir: request.workDir)
            if request.to == .pdf {
                try FileManager.default.moveItem(at: pdf, to: output)
            } else {
                result = try await renderPages(of: pdf, request: request, output: output, progress: progress)
            }
        case .toSlides:
            try await SlideBuilder.build(request, output: output, progress: progress)
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
        let format = request.to
        let rendersWebP = format == .webp
        let pageCount = PDFDocument(url: pdf)?.pageCount ?? 0
        let allPages = request.allPages && pageCount > 1
        let folder = request.workDir.appending(path: "pages")
        let digits = max(2, String(pageCount).count)

        let title = request.title
        let typedExtension = request.outputExtension ?? format.rawValue
        let name: @Sendable (Int, String) -> String = { index, ext in
            "\(title) \(String(format: "%0\(digits)d", index + 1)).\(ext)"
        }

        // ImageIO can't write WebP, so those pages are rendered as PNG first.
        let renderFormat: Format = rendersWebP ? .png : format
        let rendered: [URL] = try await Task.detached(priority: .utility) {
            guard allPages else {
                let url = rendersWebP ? request.workDir.appending(path: "page.png") : output
                try ImageConversion.pdfToImage(pdf, format: renderFormat, output: url)
                return [url]
            }
            guard let document = PDFDocument(url: pdf) else { throw ConversionError.failed("Couldn't read this PDF.") }
            let directory = rendersWebP ? request.workDir.appending(path: "png-pages") : folder
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var urls: [URL] = []
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { continue }
                let url = directory.appending(path: name(index, rendersWebP ? "png" : typedExtension))
                try ImageConversion.write(ImageConversion.render(page), to: url, format: renderFormat,
                                          properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
                urls.append(url)
                progress(Double(index + 1) / Double(document.pageCount) * (rendersWebP ? 0.5 : 1))
            }
            return urls
        }.value

        guard rendersWebP else { return allPages ? folder : output }
        guard allPages else {
            try await writeWebP(from: rendered[0], to: output, workDir: request.workDir)
            return output
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, png) in rendered.enumerated() {
            try await writeWebP(from: png, to: folder.appending(path: name(index, "webp")), workDir: request.workDir)
            progress(0.5 + Double(index + 1) / Double(rendered.count) * 0.5)
        }
        return folder
    }

    /// Neither ImageIO nor Homebrew's ffmpeg can write WebP, so use Google's cwebp.
    private static func writeWebP(from input: URL, to output: URL, workDir: URL) async throws {
        let cwebp = try Tools.require("cwebp", brewPackage: "webp")
        var source = input
        if ![.png, .jpeg, .tiff, .webp].contains(Format(fileExtension: input.pathExtension)) {
            source = workDir.appending(path: "intermediate.png")
            let png = source
            try await Task.detached(priority: .utility) {
                try ImageConversion.convert(input, to: .png, output: png)
            }.value
        }
        try await Tools.run(cwebp, ["-quiet", "-q", "85", "-metadata", "icc", source.path, "-o", output.path])
    }
}

// MARK: - Images

nonisolated enum ImageConversion {
    static func convert(_ input: URL, to format: Format, output: URL) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ConversionError.failed("Couldn't read this image.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        var maxSize = max(width, height, 1)
        if format == .ico { maxSize = min(maxSize, 256) }

        // A full-size "thumbnail" with the transform applied bakes in the EXIF rotation (e.g. iPhone photos).
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ConversionError.failed("Couldn't decode this image.")
        }
        if [.jpeg, .bmp].contains(format), image.hasAlpha {
            image = try image.flattenedOnWhite()
        }

        var metadata = properties
        metadata[kCGImagePropertyOrientation] = 1
        if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        metadata[kCGImageDestinationLossyCompressionQuality] = 0.9
        try write(image, to: output, format: format, properties: metadata)
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

    /// Renders one page (the first by default) at 2x (144 dpi).
    static func pdfToImage(_ input: URL, page index: Int = 0, format: Format, output: URL) throws {
        guard let page = PDFDocument(url: input)?.page(at: index) else {
            throw ConversionError.failed("Couldn't read this PDF.")
        }
        try write(render(page), to: output, format: format, properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
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

// MARK: - Documents

enum DocumentConversion {
    /// LibreOffice lays out Word and OpenDocument files much more faithfully than converting through HTML.
    static func usesLibreOffice(from: Format, to: Format) -> Bool {
        to == .pdf && [.docx, .doc, .rtf, .odt].contains(from) && LibreOffice.path != nil
    }

    static func convert(_ request: Converter.Request, output: URL) async throws {
        if usesLibreOffice(from: request.from, to: request.to) {
            let pdf = try await LibreOffice.convert(request.input, to: "pdf", workDir: request.workDir)
            try FileManager.default.moveItem(at: pdf, to: output)
            return
        }

        var current = request.input
        var currentFormat = request.from

        // Step 1: turn formats pandoc can't read well into ones it can.
        switch request.from {
        case .doc, .rtf:
            current = try await textutil(current, to: "docx", in: request.workDir)
            currentFormat = .docx
        case .pdf:
            current = try await extractPDFText(current, in: request.workDir)
            currentFormat = .txt
        default:
            break
        }

        if currentFormat == request.to {
            try FileManager.default.moveItem(at: current, to: output)
            return
        }

        // Step 2: write the target format, going through an intermediate one where pandoc can't write it directly.
        switch request.to {
        case .doc:
            let docx = request.workDir.appending(path: "intermediate.docx")
            try await pandoc(current, from: currentFormat, to: .docx, output: docx, request: request)
            let doc = try await textutil(docx, to: "doc", in: request.workDir)
            try FileManager.default.moveItem(at: doc, to: output)
        case .pdf:
            let html = try await pandocFragment(current, from: currentFormat, request: request)
            try renderPDF(html: html, title: request.title, baseURL: request.originalDir, output: output)
        default:
            try await pandoc(current, from: currentFormat, to: request.to, output: output, request: request)
        }
    }

    private static func pandocReader(_ format: Format) -> String {
        switch format {
        case .md, .txt: "markdown"
        case .tex: "latex"
        default: format.rawValue
        }
    }

    private static func pandoc(_ input: URL, from: Format, to: Format, output: URL, request: Converter.Request) async throws {
        let pandoc = try Tools.require("pandoc")
        var args = ["-f", pandocReader(from), "--resource-path", request.originalDir.path, "-o", output.path]
        switch to {
        case .md: args += ["-t", "gfm", "--wrap=none"]
        case .txt: args += ["-t", "plain", "--wrap=none"]
        case .html: args += ["-t", "html", "--standalone", "--embed-resources", "--metadata", "pagetitle=\(request.title)"]
        case .tex: args += ["-t", "latex", "--standalone"]
        case .rtf: args += ["-t", "rtf", "--standalone"]
        case .epub: args += ["-t", "epub3", "--metadata", "title=\(request.title)"]
        case .docx, .odt, .pptx: args += ["-t", to.rawValue]
        default: throw ConversionError.unsupported(from, to)
        }
        try await Tools.run(pandoc, args + [input.path])
    }

    private static func pandocFragment(_ input: URL, from: Format, request: Converter.Request) async throws -> String {
        let pandoc = try Tools.require("pandoc")
        return try await Tools.run(pandoc, ["-f", pandocReader(from), "-t", "html", "--resource-path", request.originalDir.path, input.path])
    }

    private static func textutil(_ input: URL, to type: String, in workDir: URL) async throws -> URL {
        let output = workDir.appending(path: "textutil-\(UUID().uuidString).\(type)")
        try await Tools.run("/usr/bin/textutil", ["-convert", type, "-output", output.path, input.path])
        return output
    }

    private static func extractPDFText(_ input: URL, in workDir: URL) async throws -> URL {
        let text = await Task.detached(priority: .utility) {
            PDFDocument(url: input)?.string ?? ""
        }.value
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.failed("This PDF has no selectable text (it may be a scan).")
        }
        let output = workDir.appending(path: "extracted.txt")
        try text.write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    /// Lays the HTML out on US Letter pages with AppKit's text system and prints it to a PDF file.
    private static func renderPDF(html fragment: String, title: String, baseURL: URL, output: URL) throws {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>
        <style>
        body { font-family: -apple-system, Helvetica, sans-serif; font-size: 11pt; line-height: 1.4; }
        pre, code { font-family: Menlo, monospace; font-size: 9.5pt; }
        table { border-collapse: collapse; } td, th { border: 1px solid #ccc; padding: 3px 6px; }
        </style></head><body>\(fragment)</body></html>
        """
        let text = try NSAttributedString(
            data: Data(html.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue,
                      .baseURL: baseURL],
            documentAttributes: nil)

        let printInfo = NSPrintInfo()
        printInfo.paperSize = NSSize(width: 612, height: 792)
        printInfo.topMargin = 54
        printInfo.bottomMargin = 54
        printInfo.leftMargin = 54
        printInfo.rightMargin = 54
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isVerticallyCentered = false
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 612 - 108, height: 100))
        textView.textStorage?.setAttributedString(text)
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
            let height = layoutManager.usedRect(for: container).height
            textView.frame.size.height = ceil(height) + 20
        }

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw ConversionError.failed("Couldn't create the PDF.") }
    }
}

// MARK: - Audio & video

enum MediaConversion {
    static func convert(_ request: Converter.Request, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let ffmpeg = try Tools.require("ffmpeg")
        let info = await probe(request.input)
        let attempts = try plan(from: request.from, to: request.to, info: info)

        for (index, args) in attempts.enumerated() {
            let duration = info.duration
            let fullArgs = ["-hide_banner", "-nostdin", "-y", "-i", request.input.path] + args
                + ["-progress", "pipe:1", "-nostats", output.path]
            do {
                try await Tools.run(ffmpeg, fullArgs) { line in
                    guard let duration, duration > 0, line.hasPrefix("out_time_us="),
                          let micros = Double(line.dropFirst("out_time_us=".count)) else { return }
                    progress(min(1, max(0, micros / 1_000_000 / duration)))
                }
                return
            } catch ConversionError.cancelled {
                throw ConversionError.cancelled
            } catch {
                // Fall through to the next, more compatible (but slower) strategy.
                try? FileManager.default.removeItem(at: output)
                if index == attempts.count - 1 { throw error }
            }
        }
    }

    struct Info {
        var videoCodecs: [String] = []
        var audioCodecs: [String] = []
        var duration: Double?
    }

    private static func probe(_ url: URL) async -> Info {
        guard let ffprobe = Tools.path(for: "ffprobe"),
              let json = try? await Tools.run(ffprobe, ["-v", "error", "-show_entries", "stream=codec_type,codec_name:format=duration",
                                                        "-of", "json", url.path]),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return Info()
        }
        var info = Info()
        for stream in object["streams"] as? [[String: Any]] ?? [] {
            guard let codec = stream["codec_name"] as? String else { continue }
            switch stream["codec_type"] as? String {
            case "video" where codec != "mjpeg" && codec != "png": info.videoCodecs.append(codec)   // skip cover art
            case "audio": info.audioCodecs.append(codec)
            default: break
            }
        }
        if let format = object["format"] as? [String: Any], let duration = format["duration"] as? String {
            info.duration = Double(duration)
        }
        return info
    }

    /// Returns ffmpeg argument lists to try in order: fastest first (copying streams without re-encoding when possible).
    private static func plan(from: Format, to: Format, info: Info) throws -> [[String]] {
        let evenSize = ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"]
        let aac = ["-c:a", "aac", "-b:a", "192k"]

        switch to.kind {
        case .audio:
            guard !info.audioCodecs.isEmpty || info.duration == nil else {
                throw ConversionError.failed("This file has no audio track.")
            }
            var attempts: [[String]] = []
            if let codec = info.audioCodecs.first, audioCodecs(for: to).contains(codec) {
                attempts.append(["-vn", "-c:a", "copy"])
            }
            attempts.append(["-vn"] + audioEncoder(for: to))
            return attempts

        case .image where to == .gif:
            return [["-vf", "fps=12,scale='min(640,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0"]]

        case .image:
            return [["-frames:v", "1", "-update", "1"]]

        case .video:
            let video = info.videoCodecs.first ?? ""
            let audioOK = { (allowed: [String]) in info.audioCodecs.allSatisfy(allowed.contains) }
            switch to {
            case .mp4, .m4v, .mov:
                let faststart = to == .mov ? [] : ["-movflags", "+faststart"]
                var attempts: [[String]] = []
                let copyableVideo = to == .mov ? ["h264", "hevc", "prores", "mjpeg"] : ["h264", "hevc"]
                let copyableAudio = to == .mov ? ["aac", "alac", "mp3", "pcm_s16le", "pcm_s24le"] : ["aac", "alac", "mp3"]
                if from != .gif, copyableVideo.contains(video), audioOK(copyableAudio) {
                    attempts.append(["-c", "copy", "-sn", "-dn"] + (video == "hevc" ? ["-tag:v", "hvc1"] : []) + faststart)
                }
                // Apple's hardware encoder: fast and cool-running. Software x264 as the universal fallback.
                attempts.append(["-c:v", "h264_videotoolbox", "-q:v", "60", "-pix_fmt", "yuv420p"] + evenSize + aac + ["-sn", "-dn"] + faststart)
                attempts.append(["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p"] + evenSize + aac + ["-sn", "-dn"] + faststart)
                return attempts
            case .mkv:
                return [["-c", "copy"],
                        ["-c:v", "h264_videotoolbox", "-q:v", "60", "-pix_fmt", "yuv420p"] + evenSize + aac,
                        ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p"] + evenSize + aac]
            case .webm:
                var attempts: [[String]] = []
                if ["vp8", "vp9", "av1"].contains(video), audioOK(["opus", "vorbis"]) { attempts.append(["-c", "copy", "-sn"]) }
                attempts.append(["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4",
                                 "-c:a", "libopus", "-b:a", "128k", "-sn"])
                return attempts
            case .avi:
                return [["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "2"]]
            default:
                throw ConversionError.unsupported(from, to)
            }

        default:
            throw ConversionError.unsupported(from, to)
        }
    }

    /// Source codecs that can be copied into the target container as-is.
    private static func audioCodecs(for format: Format) -> [String] {
        switch format {
        case .mp3: ["mp3"]
        case .m4a, .aac: ["aac"]
        case .flac: ["flac"]
        case .opus, .ogg: ["opus"]
        case .wav: ["pcm_s16le"]
        default: []
        }
    }

    private static func audioEncoder(for format: Format) -> [String] {
        switch format {
        case .mp3: ["-c:a", "libmp3lame", "-q:a", "2"]
        case .m4a, .aac: ["-c:a", "aac", "-b:a", "192k"]
        case .wav: ["-c:a", "pcm_s16le"]
        case .aiff: ["-c:a", "pcm_s16be"]
        case .flac: ["-c:a", "flac"]
        // Homebrew's ffmpeg has no Vorbis encoder; Opus in an Ogg file plays everywhere Vorbis does.
        case .ogg, .opus: ["-c:a", "libopus", "-b:a", "128k"]
        default: []
        }
    }
}
