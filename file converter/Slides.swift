import Foundation
import PDFKit

/// Runs LibreOffice invisibly to convert Office files.
nonisolated enum LibreOffice {
    static var path: String? {
        let apps = ["/Applications", "\(NSHomeDirectory())/Applications"].map { "\($0)/LibreOffice.app/Contents/MacOS/soffice" }
        return Tools.path(for: "soffice") ?? apps.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Uses its own settings profile, so it never collides with a LibreOffice window you have open.
    static func convert(_ input: URL, to type: String, workDir: URL) async throws -> URL {
        guard let soffice = path else {
            throw ConversionError.missingTool("LibreOffice", brewPackage: "--cask libreoffice")
        }
        let profile = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "FileConverter/LibreOfficeProfile")
        let outDir = workDir.appending(path: "libreoffice")
        try await Tools.run(soffice, ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--norestore",
                                      "--nolockcheck", "--convert-to", type, "--outdir", outDir.path, input.path])
        let result = outDir.appending(path: input.deletingPathExtension().lastPathComponent + "." + type)
        // LibreOffice can exit successfully without writing anything when it can't read the file.
        guard FileManager.default.fileExists(atPath: result.path) else {
            throw ConversionError.failed("LibreOffice couldn't open this file.")
        }
        return result
    }
}

/// Builds a PowerPoint file with one full-slide picture per PDF page (or a single slide for an image).
/// Slides look exactly like the source but their text isn't editable.
///
/// The slides are added to SlideTemplate.pptx, a complete empty deck (master, layouts, theme and settings
/// from pandoc's standard template). Apple's importer, used by Keynote and Quick Look, rejects decks
/// that leave those parts out, even though PowerPoint and LibreOffice accept them.
nonisolated enum SlideBuilder {
    private static let longSide = 12_192_000   // 13.33 in, PowerPoint's widescreen width, in EMUs
    private static let blankLayout = "slideLayout7.xml"

    static func build(_ request: Converter.Request, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let template = Bundle.main.url(forResource: "SlideTemplate", withExtension: "pptx") else {
            throw ConversionError.failed("The slide template is missing from the app.")
        }
        let package = request.workDir.appending(path: "pptx")
        try await Tools.run("/usr/bin/unzip", ["-q", template.path, "-d", package.path])
        let media = package.appending(path: "ppt/media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)

        let sizes = try await Task.detached(priority: .utility) { () throws -> [CGSize] in
            if request.from == .pdf {
                guard let document = PDFDocument(url: request.input), document.pageCount > 0 else {
                    throw ConversionError.failed("Couldn't read this PDF.")
                }
                var sizes: [CGSize] = []
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index) else { continue }
                    let image = try ImageConversion.render(page)
                    try ImageConversion.write(image, to: media.appending(path: "image\(sizes.count + 1).png"), format: .png)
                    sizes.append(CGSize(width: image.width, height: image.height))
                    progress(Double(index + 1) / Double(document.pageCount) * 0.9)
                }
                return sizes
            } else {
                let png = media.appending(path: "image1.png")
                try ImageConversion.convert(request.input, to: .png, output: png)
                guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw ConversionError.failed("Couldn't read this image.")
                }
                return [CGSize(width: image.width, height: image.height)]
            }
        }.value

        try addSlides(to: package, sizes: sizes)

        // -D: no folder entries. -nw: "[Content_Types].xml" is a literal name, not a wildcard pattern.
        try await Tools.run("/usr/bin/zip", ["-q", "-X", "-D", "-nw", "-r", output.path, "[Content_Types].xml", "_rels", "ppt", "docProps"],
                            currentDirectory: package)
        progress(1)
    }

    private static func addSlides(to package: URL, sizes: [CGSize]) throws {
        // The slide shape follows the first page (16:9 for an exported deck, portrait for a Letter page),
        // with its longer side at the standard widescreen width.
        let first = sizes[0]
        let ratio = first.height / first.width
        let clamp = { (value: Int) in min(max(value, 914_400), 51_206_400) }
        let slideWidth = ratio <= 1 ? longSide : clamp(Int(Double(longSide) / ratio))
        let slideHeight = ratio <= 1 ? clamp(Int(Double(longSide) * ratio)) : longSide

        let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        let ns = #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#
        let relType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let slides = 1...sizes.count

        func edit(_ path: String, _ change: (String) -> String) throws {
            let url = package.appending(path: path)
            let xml = try String(contentsOf: url, encoding: .utf8)
            try change(xml).write(to: url, atomically: true, encoding: .utf8)
        }

        try edit("[Content_Types].xml") {
            $0.replacingOccurrences(of: "</Types>", with: slides.map {
                #"<Override PartName="/ppt/slides/slide\#($0).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"#
            }.joined() + "</Types>")
        }
        try edit("ppt/_rels/presentation.xml.rels") {
            $0.replacingOccurrences(of: "</Relationships>", with: slides.map {
                #"<Relationship Id="rIdSlide\#($0)" Type="\#(relType)/slide" Target="slides/slide\#($0).xml"/>"#
            }.joined() + "</Relationships>")
        }
        try edit("ppt/presentation.xml") {
            $0.replacingOccurrences(of: "<p:sldIdLst></p:sldIdLst>", with: "<p:sldIdLst>"
                    + slides.map { #"<p:sldId id="\#(255 + $0)" r:id="rIdSlide\#($0)"/>"# }.joined() + "</p:sldIdLst>")
                .replacing(/<p:sldSz[^>]*\/>/, with: #"<p:sldSz cx="\#(slideWidth)" cy="\#(slideHeight)"/>"#)
        }

        let slideDir = package.appending(path: "ppt/slides/_rels")
        try FileManager.default.createDirectory(at: slideDir, withIntermediateDirectories: true)
        for (index, size) in sizes.enumerated() {
            let number = index + 1
            // Fit each picture inside the slide, centered, keeping its proportions.
            let scale = min(Double(slideWidth) / size.width, Double(slideHeight) / size.height)
            let width = Int(size.width * scale), height = Int(size.height * scale)
            let x = (slideWidth - width) / 2, y = (slideHeight - height) / 2
            try (header + #"""
                <p:sld \#(ns)><p:cSld><p:spTree>\
                <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
                <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
                <p:pic><p:nvPicPr><p:cNvPr id="2" name="Page \#(number)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
                <p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>\
                <p:spPr><a:xfrm><a:off x="\#(x)" y="\#(y)"/><a:ext cx="\#(width)" cy="\#(height)"/></a:xfrm>\
                <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>\
                </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
                """#).write(to: package.appending(path: "ppt/slides/slide\(number).xml"), atomically: true, encoding: .utf8)
            try (header + #"""
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="\#(relType)/slideLayout" Target="../slideLayouts/\#(blankLayout)"/>\
                <Relationship Id="rId2" Type="\#(relType)/image" Target="../media/image\#(number).png"/></Relationships>
                """#).write(to: slideDir.appending(path: "slide\(number).xml.rels"), atomically: true, encoding: .utf8)
        }
    }
}
