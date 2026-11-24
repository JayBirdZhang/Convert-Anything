import Foundation
import ImageIO
import PDFKit
import Vision

/// Reads text out of images and scanned PDFs with macOS's built-in text recognition (Vision).
nonisolated enum TextRecognition {
    /// Image → txt writes the recognized text as-is; other document formats go through HTML paragraphs.
    static func convertImage(_ request: Converter.Request, output: URL) async throws {
        let paragraphs = try await background { () throws -> [String] in
            guard let source = CGImageSourceCreateWithURL(request.input as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 8000,
                  ] as CFDictionary) else {
                throw ConversionError.failed("Couldn't read this image.")
            }
            return try paragraphs(in: image)
        }
        guard !paragraphs.isEmpty else { throw ConversionError.failed("No text was found in this image.") }

        if request.to == .txt || request.to == .md {
            try paragraphs.joined(separator: "\n\n").write(to: output, atomically: true, encoding: .utf8)
            return
        }
        let body = paragraphs.map { "<p>\(escapeHTML($0))</p>" }.joined(separator: "\n")
        let html = request.workDir.appending(path: "recognized.html")
        try "<!doctype html><html><head><meta charset=\"utf-8\"></head><body>\(body)</body></html>"
            .write(to: html, atomically: true, encoding: .utf8)
        let htmlRequest = Converter.Request(input: html, from: .html, to: request.to, workDir: request.workDir,
                                            title: request.title, originalDir: request.originalDir, quality: request.quality)
        try await DocumentConversion.convert(htmlRequest, output: output)
    }

    /// All the text in a scanned PDF, page by page.
    static func text(inPDF url: URL) async throws -> String {
        let count = PDFDocument(url: url)?.pageCount ?? 0
        // Vision already uses the Neural Engine/GPU for each page, so a few workers is all that helps.
        let pages = try await PageWorkers.map(url, pageCount: count, maxWorkers: 3) { page, _ in
            try paragraphs(in: ImageConversion.render(page, scale: 2.5)).joined(separator: "\n\n")
        }
        return pages.compactMap { $0 }.joined(separator: "\n\n")
    }

    /// Recognized lines, top to bottom, joined into paragraphs wherever lines sit close together.
    static func paragraphs(in image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            throw ConversionError.failed("macOS couldn't read the text in this image. Try again in a moment.")
        }

        // Vision's boxes are 0–1 with the origin at the bottom left.
        let lines = (request.results ?? []).compactMap { observation -> (box: CGRect, text: String)? in
            observation.topCandidates(1).first.map { (observation.boundingBox, $0.string) }
        }.sorted { a, b in
            let sameRow = abs(a.box.midY - b.box.midY) < min(a.box.height, b.box.height) / 2
            return sameRow ? a.box.minX < b.box.minX : a.box.midY > b.box.midY
        }

        var paragraphs: [String] = []
        var current = ""
        var previous: CGRect?
        for line in lines {
            if let previous, previous.minY - line.box.maxY < line.box.height * 0.75 {
                current += " " + line.text
            } else {
                if !current.isEmpty { paragraphs.append(current) }
                current = line.text
            }
            previous = line.box
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
