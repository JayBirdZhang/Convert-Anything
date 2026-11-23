import Foundation
import OSLog
import PDFKit

/// Builds a PowerPoint file from a PDF (one slide per page) or an image (one slide). Two styles:
/// - Pictures: each page as a full-slide picture. Looks exactly like the PDF; text isn't editable.
/// - Editable: each page is copied without its text (TextlessPDF) and what's left is split into a
///   background and a separate picture for each photo, chart or shape (SlideLayers), so they can be moved
///   one by one. The text, read with its position, size, font and color, goes back on top as real text
///   boxes. Pages that can't be split keep what's left as one background picture; rotated pages, and any
///   page that can't be copied, fall back to a picture of the page.
///
/// The slides are added to SlideTemplate.pptx, a complete empty deck (master, layouts, theme and settings
/// from pandoc's standard template). Apple's importer, used by Keynote and Quick Look, rejects decks
/// that leave those parts out, even though PowerPoint and LibreOffice accept them.
nonisolated enum SlideBuilder {
    private static let longSide = 12_192_000   // 13.33 in, PowerPoint's widescreen width, in EMUs
    private static let blankLayout = "slideLayout7.xml"

    private struct Picture {
        var file: String                // In ppt/media
        var frame: CGRect               // In the same units as the slide's `size`, from the top left
    }

    private struct Slide {
        var size: CGSize                // Page points (or image pixels); only the proportions matter
        var pictures: [Picture] = []    // Back to front
        var text: [TextBlock] = []      // In the same units as `size`
        var tables: [SlideTable] = []   // Page points, like `text`
    }

    static func build(_ request: Converter.Request, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let template = Bundle.main.url(forResource: "SlideTemplate", withExtension: "pptx") else {
            throw ConversionError.failed("The slide template is missing from the app.")
        }
        let package = request.workDir.appending(path: "pptx")
        try await Tools.run("/usr/bin/unzip", ["-q", template.path, "-d", package.path])
        let media = package.appending(path: "ppt/media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)

        let slides = try await background { () throws -> [Slide] in
            guard request.from == .pdf else {
                let png = media.appending(path: "image1.png")
                try ImageConversion.convert(request.input, to: .png, output: png)
                guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw ConversionError.failed("Couldn't read this image.")
                }
                let size = CGSize(width: image.width, height: image.height)
                return [Slide(size: size, pictures: [Picture(file: "image1.png", frame: CGRect(origin: .zero, size: size))])]
            }
            guard let document = PDFDocument(url: request.input), document.pageCount > 0 else {
                throw ConversionError.failed("Couldn't read this PDF.")
            }
            // Pages are independent: each one renders (and has its text read) on its own worker.
            let scale = request.quality.pageScale
            let slides = try await PageWorkers.map(request.input, pageCount: document.pageCount, maxWorkers: 4,
                                                   progress: { progress($0 * 0.9) }) { page, index in
                let crop = page.bounds(for: .cropBox)
                var slide = Slide(size: abs(page.rotation) % 180 == 90 ? CGSize(width: crop.height, height: crop.width) : crop.size)
                let full = CGRect(origin: .zero, size: slide.size)
                func save(_ image: CGImage, _ file: String, _ frame: CGRect) throws {
                    try ImageConversion.write(image, to: media.appending(path: file), format: .png)
                    slide.pictures.append(Picture(file: file, frame: frame))
                }
                if request.editableSlides && page.rotation == 0, let layers = splitLayers(of: page, scale: scale) {
                    if let background = layers.background { try save(background, "image\(index + 1).png", full) }
                    for (number, picture) in layers.pictures.enumerated() {
                        try save(picture.image, "image\(index + 1)-\(number + 1).png", picture.frame)
                    }
                    // Text inside a table goes in its cells instead of text boxes.
                    slide.tables = layers.tables
                    slide.text = PDFText.group(PDFText.lines(on: page).filter { line in
                        !layers.tables.contains { $0.frame.contains(CGPoint(x: line.frame.midX, y: line.frame.midY)) }
                    })
                    return slide
                }
                var picture = page
                let textless = request.editableSlides && page.rotation == 0 ? textlessCopy(of: page) : nil
                if let textlessPage = textless?.page(at: 0) {
                    picture = textlessPage
                    slide.text = PDFText.blocks(on: page)
                }
                try save(ImageConversion.render(picture, scale: scale), "image\(index + 1).png", full)
                return slide
            }
            return slides.compactMap { $0 }
        }

        try addSlides(to: package, slides: slides)

        // -D: no folder entries. -nw: "[Content_Types].xml" is a literal name, not a wildcard pattern.
        try await Tools.run("/usr/bin/zip", ["-q", "-X", "-D", "-nw", "-r", output.path, "[Content_Types].xml", "_rels", "ppt", "docProps"],
                            currentDirectory: package)
        progress(1)
    }

    /// The page without its text, split into a background and separate pictures, or nil to keep it whole.
    private static func splitLayers(of page: PDFPage, scale: CGFloat) -> SlideLayers.Layers? {
        do {
            return try SlideLayers.split(page, scale: scale)
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "Convert Anything", category: "Slides")
                .notice("Page kept as one picture: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The page without its text, as a one-page document (kept alive while its page is drawn).
    private static func textlessCopy(of page: PDFPage) -> PDFDocument? {
        do {
            return try TextlessPDF.document(for: page)
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "Convert Anything", category: "Slides")
                .notice("Page kept as a picture: \(String(describing: error), privacy: .public)")
            return nil
        }
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
            let pictures = slide.pictures.enumerated().map { offset, picture in
                let name = picture.frame.size != slide.size ? "Picture \(offset + 1)" : slide.pictures.count == 1 ? "Page \(number)" : "Background"
                return #"<p:pic><p:nvPicPr><p:cNvPr id="\#(offset + 2)" name="\#(name)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>"#
                    + #"<p:blipFill><a:blip r:embed="rId\#(offset + 2)"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>"#
                    + #"<p:spPr><a:xfrm><a:off x="\#(x + Int(picture.frame.minX * scale))" y="\#(y + Int(picture.frame.minY * scale))"/>"#
                    + #"<a:ext cx="\#(max(1, Int(picture.frame.width * scale)))" cy="\#(max(1, Int(picture.frame.height * scale)))"/></a:xfrm>"#
                    + #"<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>"#
            }.joined()
            let tables = slide.tables.enumerated().map { offset, table in
                tableFrame(table, id: slide.pictures.count + offset + 2, scale: scale, origin: CGPoint(x: x, y: y))
            }.joined()
            let textBoxes = slide.text.enumerated().map { offset, block in
                textBox(block, id: slide.pictures.count + slide.tables.count + offset + 2, scale: scale, origin: CGPoint(x: x, y: y))
            }.joined()
            let pictureLinks = slide.pictures.enumerated().map { offset, picture in
                #"<Relationship Id="rId\#(offset + 2)" Type="\#(relType)/image" Target="../media/\#(picture.file)"/>"#
            }.joined()
            try (header + #"""
                <p:sld \#(ns)><p:cSld><p:spTree>\#
                <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\#
                <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\#
                \#(pictures)\#(tables)\#(textBoxes)\#
                </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
                """#).write(to: package.appending(path: "ppt/slides/slide\(number).xml"), atomically: true, encoding: .utf8)
            try (header + #"""
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#
                <Relationship Id="rId1" Type="\#(relType)/slideLayout" Target="../slideLayouts/\#(blankLayout)"/>\#
                \#(pictureLinks)</Relationships>
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
            #"<a:p><a:pPr algn="\#(alignment)">\#(spacing)<a:spcBef><a:spcPts val="0"/></a:spcBef></a:pPr>\#(runs(line.runs, hundredths))</a:p>"#
        }.joined()

        return #"<p:sp><p:nvSpPr><p:cNvPr id="\#(id)" name="Text \#(id - 2)"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>"#
            + #"<p:spPr><a:xfrm><a:off x="\#(x)" y="\#(y)"/><a:ext cx="\#(width)" cy="\#(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>"#
            + #"<p:txBody><a:bodyPr wrap="none" lIns="0" tIns="0" rIns="0" bIns="0" rtlCol="0" anchor="t"><a:noAutofit/></a:bodyPr><a:lstStyle/>\#(paragraphs)</p:txBody></p:sp>"#
    }

    private static func runs(_ runs: [TextRun], _ hundredths: (CGFloat) -> Int) -> String {
        runs.map { run in
            let fill = run.color.map { #"<a:solidFill><a:srgbClr val="\#($0)"/></a:solidFill>"# } ?? ""
            let font = escape(run.font)
            return #"<a:r><a:rPr lang="en-US" sz="\#(hundredths(run.size))" b="\#(run.bold ? 1 : 0)" i="\#(run.italic ? 1 : 0)" dirty="0">\#(fill)<a:latin typeface="\#(font)"/><a:cs typeface="\#(font)"/></a:rPr><a:t>\#(escape(run.text))</a:t></a:r>"#
        }.joined()
    }

    /// A table with the page table's grid, border, cell colors and text, one paragraph per line of text.
    private static func tableFrame(_ table: SlideTable, id: Int, scale: Double, origin: CGPoint) -> String {
        let pointsPerUnit = scale / 12_700
        func emu(_ value: CGFloat) -> Int { Int(Double(value) * scale) }
        func hundredths(_ points: CGFloat) -> Int { min(max(Int(Double(points) * pointsPerUnit * 100), 100), 400_000) }
        let border = ["lnL", "lnR", "lnT", "lnB"].map { side in
            #"<a:\#(side) w="\#(max(emu(table.lineWidth), 3175))" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:srgbClr val="\#(table.lineColor)"/></a:solidFill><a:prstDash val="solid"/></a:\#(side)>"#
        }.joined()
        let columns = table.columnWidths.map { #"<a:gridCol w="\#(emu($0))"/>"# }.joined()
        let rows = zip(table.cells, table.rowHeights).map { cells, height in
            let row = cells.map { cell in
                let paragraphs = cell.lines.isEmpty
                    ? #"<a:p><a:endParaRPr lang="en-US" dirty="0"/></a:p>"#
                    : cell.lines.map { #"<a:p><a:pPr algn="\#(cell.alignment)"/>\#(runs($0.runs, hundredths))</a:p>"# }.joined()
                let fill = cell.fill.map { #"<a:solidFill><a:srgbClr val="\#($0)"/></a:solidFill>"# } ?? "<a:noFill/>"
                return #"<a:tc><a:txBody><a:bodyPr/><a:lstStyle/>\#(paragraphs)</a:txBody>"#
                    + #"<a:tcPr marL="\#(emu(cell.insets.left))" marR="\#(emu(cell.insets.right))" marT="\#(emu(cell.insets.top))" marB="\#(emu(cell.insets.bottom))" anchor="\#(cell.anchor)">\#(border)\#(fill)</a:tcPr></a:tc>"#
            }.joined()
            return #"<a:tr h="\#(emu(height))">\#(row)</a:tr>"#
        }.joined()
        return #"<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="\#(id)" name="Table \#(id)"/><p:cNvGraphicFramePr><a:graphicFrameLocks noGrp="1"/></p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr>"#
            + #"<p:xfrm><a:off x="\#(Int(origin.x) + emu(table.frame.minX))" y="\#(Int(origin.y) + emu(table.frame.minY))"/><a:ext cx="\#(emu(table.frame.width))" cy="\#(emu(table.frame.height))"/></p:xfrm>"#
            + #"<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table"><a:tbl><a:tblPr/><a:tblGrid>\#(columns)</a:tblGrid>\#(rows)</a:tbl></a:graphicData></a:graphic></p:graphicFrame>"#
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
