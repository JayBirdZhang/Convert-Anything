import Foundation
import PDFKit

/// Runs LibreOffice invisibly to convert Office files.
nonisolated enum LibreOffice {
    static var path: String? {
        let apps = ["/Applications", "\(NSHomeDirectory())/Applications"].map { "\($0)/LibreOffice.app/Contents/MacOS/soffice" }
        return Tools.path(for: "soffice") ?? apps.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Uses its own settings profile, so it never collides with a LibreOffice window you have open.
    /// `type` is an extension, optionally followed by ":<filter>:<options>" (e.g. for CSV encoding).
    static func convert(_ input: URL, to type: String, workDir: URL, inputFilter: String? = nil) async throws -> URL {
        guard let soffice = path else {
            throw ConversionError.missingTool("LibreOffice", brewPackage: "--cask libreoffice")
        }
        let profile = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "FileConverter/LibreOfficeProfile")
        let outDir = workDir.appending(path: "libreoffice")
        var args = ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--norestore", "--nolockcheck"]
        if let inputFilter { args.append("--infilter=\(inputFilter)") }
        try await Tools.run(soffice, args + ["--convert-to", type, "--outdir", outDir.path, input.path])
        let ext = type.split(separator: ":").first.map(String.init) ?? type
        let result = outDir.appending(path: input.deletingPathExtension().lastPathComponent + "." + ext)
        // LibreOffice can exit successfully without writing anything when it can't read the file.
        guard FileManager.default.fileExists(atPath: result.path) else {
            throw ConversionError.failed("LibreOffice couldn't open this file.")
        }
        return result
    }
}

/// Builds a PowerPoint file from a PDF (one slide per page) or an image (one slide). Two styles:
/// - Pictures: each page as a full-slide picture. Looks exactly like the PDF; text isn't editable.
/// - Editable: Ghostscript strips the text out of the PDF and what's left (photos, shapes, backgrounds)
///   becomes each slide's background picture. The text, read with its position, size, font and color,
///   goes back on top as real text boxes. Rotated pages fall back to a picture.
///
/// The slides are added to SlideTemplate.pptx, a complete empty deck (master, layouts, theme and settings
/// from pandoc's standard template). Apple's importer, used by Keynote and Quick Look, rejects decks
/// that leave those parts out, even though PowerPoint and LibreOffice accept them.
nonisolated enum SlideBuilder {
    private static let longSide = 12_192_000   // 13.33 in, PowerPoint's widescreen width, in EMUs
    private static let blankLayout = "slideLayout7.xml"

    private struct Slide {
        var size: CGSize                // Page points (or image pixels); only the proportions matter
        var text: [TextBlock] = []      // In the same units as `size`
    }

    static func build(_ request: Converter.Request, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let template = Bundle.main.url(forResource: "SlideTemplate", withExtension: "pptx") else {
            throw ConversionError.failed("The slide template is missing from the app.")
        }
        let package = request.workDir.appending(path: "pptx")
        try await Tools.run("/usr/bin/unzip", ["-q", template.path, "-d", package.path])
        let media = package.appending(path: "ppt/media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)

        var textless: URL?
        if request.from == .pdf && request.editableSlides {
            let gs = try Tools.require("gs", brewPackage: "ghostscript")
            let url = request.workDir.appending(path: "textless.pdf")
            try await Tools.run(gs, ["-q", "-dNOPAUSE", "-dBATCH", "-dSAFER", "-sDEVICE=pdfwrite", "-dFILTERTEXT",
                                     "-o", url.path, request.input.path])
            textless = url
        }

        let slides = try await Task.detached(priority: .utility) { [textless] () throws -> [Slide] in
            guard request.from == .pdf else {
                let png = media.appending(path: "image1.png")
                try ImageConversion.convert(request.input, to: .png, output: png)
                guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw ConversionError.failed("Couldn't read this image.")
                }
                return [Slide(size: CGSize(width: image.width, height: image.height))]
            }
            guard let document = PDFDocument(url: request.input), document.pageCount > 0 else {
                throw ConversionError.failed("Couldn't read this PDF.")
            }
            let background = textless.flatMap { PDFDocument(url: $0) }
            var slides: [Slide] = []
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let crop = page.bounds(for: .cropBox)
                var slide = Slide(size: abs(page.rotation) % 180 == 90 ? CGSize(width: crop.height, height: crop.width) : crop.size)
                var picture = page
                if page.rotation == 0, let textlessPage = background?.page(at: index) {
                    picture = textlessPage
                    slide.text = PDFText.blocks(on: page)
                }
                try ImageConversion.write(ImageConversion.render(picture, scale: request.quality.pageScale), to: media.appending(path: "image\(slides.count + 1).png"), format: .png)
                slides.append(slide)
                progress(Double(index + 1) / Double(document.pageCount) * 0.9)
            }
            return slides
        }.value

        try addSlides(to: package, slides: slides)

        // -D: no folder entries. -nw: "[Content_Types].xml" is a literal name, not a wildcard pattern.
        try await Tools.run("/usr/bin/zip", ["-q", "-X", "-D", "-nw", "-r", output.path, "[Content_Types].xml", "_rels", "ppt", "docProps"],
                            currentDirectory: package)
        progress(1)
    }

    private static func addSlides(to package: URL, slides: [Slide]) throws {
        // The slide shape follows the first page (16:9 for an exported deck, portrait for a Letter page),
        // with its longer side at the standard widescreen width.
        let first = slides[0].size
        let ratio = first.height / first.width
        let clamp = { (value: Int) in min(max(value, 914_400), 51_206_400) }
        let slideWidth = ratio <= 1 ? longSide : clamp(Int(Double(longSide) / ratio))
        let slideHeight = ratio <= 1 ? clamp(Int(Double(longSide) * ratio)) : longSide

        let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        let ns = #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#
        let relType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let numbers = 1...slides.count

        func edit(_ path: String, _ change: (String) -> String) throws {
            let url = package.appending(path: path)
            let xml = try String(contentsOf: url, encoding: .utf8)
            try change(xml).write(to: url, atomically: true, encoding: .utf8)
        }

        try edit("[Content_Types].xml") {
            $0.replacingOccurrences(of: "</Types>", with: numbers.map {
                #"<Override PartName="/ppt/slides/slide\#($0).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"#
            }.joined() + "</Types>")
        }
        try edit("ppt/_rels/presentation.xml.rels") {
            $0.replacingOccurrences(of: "</Relationships>", with: numbers.map {
                #"<Relationship Id="rIdSlide\#($0)" Type="\#(relType)/slide" Target="slides/slide\#($0).xml"/>"#
            }.joined() + "</Relationships>")
        }
        try edit("ppt/presentation.xml") {
            $0.replacingOccurrences(of: "<p:sldIdLst></p:sldIdLst>", with: "<p:sldIdLst>"
                    + numbers.map { #"<p:sldId id="\#(255 + $0)" r:id="rIdSlide\#($0)"/>"# }.joined() + "</p:sldIdLst>")
                .replacing(/<p:sldSz[^>]*\/>/, with: #"<p:sldSz cx="\#(slideWidth)" cy="\#(slideHeight)"/>"#)
        }

        let slideDir = package.appending(path: "ppt/slides/_rels")
        try FileManager.default.createDirectory(at: slideDir, withIntermediateDirectories: true)
        for (index, slide) in slides.enumerated() {
            let number = index + 1
            // Fit each page inside the slide, centered, keeping its proportions. Text uses the same mapping.
            let scale = min(Double(slideWidth) / slide.size.width, Double(slideHeight) / slide.size.height)
            let width = Int(slide.size.width * scale), height = Int(slide.size.height * scale)
            let x = (slideWidth - width) / 2, y = (slideHeight - height) / 2
            let textBoxes = slide.text.enumerated().map { offset, block in
                textBox(block, id: offset + 3, scale: scale, origin: CGPoint(x: x, y: y))
            }.joined()
            try (header + #"""
                <p:sld \#(ns)><p:cSld><p:spTree>\
                <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
                <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
                <p:pic><p:nvPicPr><p:cNvPr id="2" name="Page \#(number)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
                <p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>\
                <p:spPr><a:xfrm><a:off x="\#(x)" y="\#(y)"/><a:ext cx="\#(width)" cy="\#(height)"/></a:xfrm>\
                <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>\
                \#(textBoxes)\
                </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
                """#).write(to: package.appending(path: "ppt/slides/slide\(number).xml"), atomically: true, encoding: .utf8)
            try (header + #"""
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="\#(relType)/slideLayout" Target="../slideLayouts/\#(blankLayout)"/>\
                <Relationship Id="rId2" Type="\#(relType)/image" Target="../media/image\#(number).png"/></Relationships>
                """#).write(to: slideDir.appending(path: "slide\(number).xml.rels"), atomically: true, encoding: .utf8)
        }
    }

    /// One text box per block, one paragraph per line so the layout matches the PDF exactly.
    /// `scale` converts page units to EMUs; font sizes scale with it so text keeps its size relative to the page.
    private static func textBox(_ block: TextBlock, id: Int, scale: Double, origin: CGPoint) -> String {
        let pointsPerUnit = scale / 12_700
        func emu(_ value: CGFloat) -> Int { Int(Double(value) * scale) }
        func hundredths(_ points: CGFloat) -> Int { min(max(Int(Double(points) * pointsPerUnit * 100), 100), 400_000) }

        let x = Int(origin.x) + emu(block.frame.minX)
        let y = Int(origin.y) + emu(block.frame.minY)
        // A little extra width so substitute fonts that run slightly wider don't get cut off.
        let width = emu(block.frame.width * 1.04 + 2), height = emu(block.frame.height)
        let alignment = block.centered ? "ctr" : "l"
        let spacing = block.lineSpacing.map { #"<a:lnSpc><a:spcPts val="\#(min(hundredths($0), 158_400))"/></a:lnSpc>"# } ?? ""

        let paragraphs = block.lines.map { line in
            let runs = line.runs.map { run in
                let fill = run.color.map { #"<a:solidFill><a:srgbClr val="\#($0)"/></a:solidFill>"# } ?? ""
                let font = escape(run.font)
                return #"<a:r><a:rPr lang="en-US" sz="\#(hundredths(run.size))" b="\#(run.bold ? 1 : 0)" i="\#(run.italic ? 1 : 0)" dirty="0">\#(fill)<a:latin typeface="\#(font)"/><a:cs typeface="\#(font)"/></a:rPr><a:t>\#(escape(run.text))</a:t></a:r>"#
            }.joined()
            return #"<a:p><a:pPr algn="\#(alignment)">\#(spacing)<a:spcBef><a:spcPts val="0"/></a:spcBef></a:pPr>\#(runs)</a:p>"#
        }.joined()

        return #"<p:sp><p:nvSpPr><p:cNvPr id="\#(id)" name="Text \#(id - 2)"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>"#
            + #"<p:spPr><a:xfrm><a:off x="\#(x)" y="\#(y)"/><a:ext cx="\#(width)" cy="\#(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>"#
            + #"<p:txBody><a:bodyPr wrap="none" lIns="0" tIns="0" rIns="0" bIns="0" rtlCol="0" anchor="t"><a:noAutofit/></a:bodyPr><a:lstStyle/>\#(paragraphs)</p:txBody></p:sp>"#
    }

    private static func escape(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case _ where scalar.value < 0x20: continue   // Control characters aren't allowed in XML
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
