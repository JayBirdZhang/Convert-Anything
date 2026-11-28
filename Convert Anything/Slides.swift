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
        var file: String                // In ppt/media; empty for a shape
        var shape: TextlessPDF.Shape?   // A line, box or circle drawn as a real shape instead
        var frame: CGRect               // In the same units as the slide's `size`, from the top left
        var text: [TextBlock] = []      // Its labels, grouped with it so they move together
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
                try ImageConversion.convert(request.input, to: .png, output: png, keepsLocation: request.keepsLocation)
                guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw ConversionError.failed("Couldn't read this image.")
                }
                let size = CGSize(width: image.width, height: image.height)
                return [Slide(size: size, pictures: [Picture(file: "image1.png", shape: nil, frame: CGRect(origin: .zero, size: size))])]
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
                func save(_ image: CGImage, _ file: String, _ frame: CGRect, text: [TextBlock] = []) throws {
                    try ImageConversion.write(image, to: media.appending(path: file), format: .png)
                    slide.pictures.append(Picture(file: file, shape: nil, frame: frame, text: text))
                }
                func save(_ picture: SlideLayers.Picture, _ name: String, text: [TextBlock]) throws {
                    if let jpeg = picture.jpeg {
                        try jpeg.write(to: media.appending(path: name + ".jpg"))
                        slide.pictures.append(Picture(file: name + ".jpg", shape: nil, frame: picture.frame, text: text))
                    } else if let image = picture.image {
                        try save(image, name + ".png", picture.frame, text: text)
                    } else if let shape = picture.shape {
                        slide.pictures.append(Picture(file: "", shape: shape, frame: picture.frame, text: text))
                    }
                }
                if request.editableSlides && page.rotation == 0, let layers = splitLayers(of: page, scale: scale) {
                    // Text inside a table goes in its cells instead of text boxes; a chart's or diagram's
                    // labels are grouped with its picture.
                    let lines = PDFText.lines(on: page).filter { line in
                        !layers.tables.contains { $0.frame.contains(CGPoint(x: line.frame.midX, y: line.frame.midY)) }
                    }
                    let (labels, rest) = labels(PDFText.group(lines), of: layers.pictures)
                    if let background = layers.background { try save(background, "image\(index + 1).png", full) }
                    for (number, picture) in layers.pictures.enumerated() {
                        try save(picture, "image\(index + 1)-\(number + 1)", text: labels[number])
                    }
                    slide.tables = layers.tables
                    slide.text = rest
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

    /// The text blocks that belong to each picture, and the rest. A block belongs to a picture when it lies
    /// inside its box (a chart's value labels, a diagram's captions, a title over a photo). A chart or
    /// diagram also takes short blocks right next to its box (axis labels, its title); a photo doesn't, so a
    /// caption or a paragraph beside it stays separate. Blocks are taken whole, so the page's other text
    /// keeps exactly the layout it would have had. A picture with running text inside it (a panel, a
    /// banner, a sidebar box) frames the page's body text rather than being a figure, and takes none.
    private static func labels(_ blocks: [TextBlock], of pictures: [SlideLayers.Picture]) -> (labels: [[TextBlock]], rest: [TextBlock]) {
        var labels = Array(repeating: [TextBlock](), count: pictures.count)
        guard !pictures.isEmpty, !blocks.isEmpty else { return (labels, blocks) }
        func inside(_ line: TextLine, _ frame: CGRect) -> Bool {
            let overlap = frame.intersection(line.frame)
            return !overlap.isNull && overlap.width * overlap.height >= max(line.frame.width * line.frame.height, 0.01) * 0.7
        }
        var owner = blocks.map { block in
            pictures.firstIndex { picture in block.lines.allSatisfy { inside($0, picture.frame) } }
        }
        var panels = Set<Int>()
        for (block, index) in zip(blocks, owner) where index != nil && isRunningText(block) { panels.insert(index!) }
        for position in owner.indices {
            if let index = owner[position], panels.contains(index) { owner[position] = nil }
        }
        // Labels next to a chart, then single short labels next to those (an axis title beyond its tick
        // labels). Not next to a thin line: a heading over a rule isn't its label.
        var reach = pictures.map(\.frame)
        let figures = pictures.indices.filter {
            !pictures[$0].hasImage && !panels.contains($0) && min(pictures[$0].frame.width, pictures[$0].frame.height) > 6
        }
        for round in 0..<2 {
            var added = false
            for position in owner.indices where owner[position] == nil {
                if round > 0 && (blocks[position].lines.count > 1 || blocks[position].lines[0].runs.reduce(0, { $0 + $1.text.count }) > 30) { continue }
                guard let index = figures.first(where: { isLabel(blocks[position], of: reach[$0]) }) else { continue }
                owner[position] = index
                reach[index] = reach[index].union(blocks[position].frame)
                added = true
            }
            if !added { break }
        }
        var rest: [TextBlock] = []
        for (block, index) in zip(blocks, owner) {
            if let index { labels[index].append(block) } else { rest.append(block) }
        }
        return (labels, rest)
    }

    /// Sentences rather than labels: a long line, or several lines of some length (a paragraph).
    private static func isRunningText(_ block: TextBlock) -> Bool {
        let lengths = block.lines.map { $0.runs.reduce(0) { $0 + $1.text.count } }
        return lengths.contains { $0 > 60 } || (lengths.count > 1 && lengths.reduce(0, +) > lengths.count * 35)
    }

    /// Whether a block of text sits right next to `frame` and is made of short labels (axis ticks, a legend,
    /// a title), within about a line's height of the box, beside it or across from it and no longer than it.
    private static func isLabel(_ block: TextBlock, of frame: CGRect) -> Bool {
        let box = block.frame
        let size = block.lines.map(\.fontSize).max() ?? 0
        let reach = max(4, size * 1.2)
        // An icon beside a name (an email or ORCID mark) isn't a figure with labels.
        guard !isRunningText(block), max(frame.width, frame.height) >= size * 2.5 else { return false }
        let dx = max(frame.minX - box.maxX, box.minX - frame.maxX, 0)
        let dy = max(frame.minY - box.maxY, box.minY - frame.maxY, 0)
        guard dx <= reach, dy <= reach else { return false }
        // Beside the box, level with it (an axis's end label may sit centered on the axis); or above or
        // below it, within its width.
        return dx > 0 && dy > 0 ? false
            : dx > 0 ? box.height <= frame.height + 2 * reach && (frame.minY - box.height...frame.maxY + box.height).contains(box.midY)
            : box.width <= frame.width + 2 * reach && (frame.minX - box.width / 2...frame.maxX + box.width / 2).contains(box.midX)
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

        let jpeg = slides.contains { $0.pictures.contains { $0.file.hasSuffix(".jpg") } }
        try edit("[Content_Types].xml") {
            $0.replacingOccurrences(of: "</Types>", with: (jpeg ? #"<Default Extension="jpg" ContentType="image/jpeg"/>"# : "") + numbers.map {
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
            let origin = CGPoint(x: x, y: y)
            var nextID = 2, textCount = 0
            func takeID() -> Int { nextID += 1; return nextID - 1 }
            func text(_ block: TextBlock) -> String {
                textCount += 1
                return textBox(block, id: takeID(), number: textCount, scale: scale, origin: origin)
            }
            var groupCount = 0, shapeCount = 0
            let pictures = slide.pictures.enumerated().map { offset, picture in
                let name = picture.frame.size != slide.size ? "Picture \(offset + 1)" : slide.pictures.count == 1 ? "Page \(number)" : "Background"
                let frame = (x: x + Int(picture.frame.minX * scale), y: y + Int(picture.frame.minY * scale),
                             width: max(1, Int(picture.frame.width * scale)), height: max(1, Int(picture.frame.height * scale)))
                // A picture with labels goes in a group with them, so they move together.
                let groupID = picture.text.isEmpty ? 0 : takeID()
                let xml = picture.shape.map { shape -> String in
                    shapeCount += 1
                    return shapeXML(shape, id: takeID(), number: shapeCount, scale: scale, origin: origin)
                } ?? #"<p:pic><p:nvPicPr><p:cNvPr id="\#(takeID())" name="\#(name)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>"#
                    + #"<p:blipFill><a:blip r:embed="rId\#(offset + 2)"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>"#
                    + #"<p:spPr><a:xfrm><a:off x="\#(frame.x)" y="\#(frame.y)"/><a:ext cx="\#(frame.width)" cy="\#(frame.height)"/></a:xfrm>"#
                    + #"<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>"#
                guard groupID != 0 else { return xml }
                groupCount += 1
                var minX = frame.x, minY = frame.y, maxX = frame.x + frame.width, maxY = frame.y + frame.height
                for block in picture.text {
                    let box = textFrame(block, scale: scale, origin: origin)
                    minX = min(minX, box.x); minY = min(minY, box.y)
                    maxX = max(maxX, box.x + box.width); maxY = max(maxY, box.y + box.height)
                }
                let position = #"<a:off x="\#(minX)" y="\#(minY)"/><a:ext cx="\#(maxX - minX)" cy="\#(maxY - minY)"/>"#
                return #"<p:grpSp><p:nvGrpSpPr><p:cNvPr id="\#(groupID)" name="Group \#(groupCount)"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"#
                    + #"<p:grpSpPr><a:xfrm>\#(position)\#(position.replacingOccurrences(of: "a:off", with: "a:chOff").replacingOccurrences(of: "a:ext", with: "a:chExt"))</a:xfrm></p:grpSpPr>"#
                    + xml + picture.text.map(text).joined() + "</p:grpSp>"
            }.joined()
            let tables = slide.tables.map { table in
                tableFrame(table, id: takeID(), scale: scale, origin: origin)
            }.joined()
            let textBoxes = slide.text.map(text).joined()
            let pictureLinks = slide.pictures.enumerated().filter { $0.element.shape == nil }.map { offset, picture in
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
    private static func textBox(_ block: TextBlock, id: Int, number: Int, scale: Double, origin: CGPoint) -> String {
        let pointsPerUnit = scale / 12_700
        func hundredths(_ points: CGFloat) -> Int { min(max(Int(Double(points) * pointsPerUnit * 100), 100), 400_000) }

        let (x, y, width, height) = textFrame(block, scale: scale, origin: origin)
        let alignment = block.centered ? "ctr" : "l"
        let spacing = block.lineSpacing.map { #"<a:lnSpc><a:spcPts val="\#(min(hundredths($0), 158_400))"/></a:lnSpc>"# } ?? ""

        let paragraphs = block.lines.map { line in
            #"<a:p><a:pPr algn="\#(alignment)">\#(spacing)<a:spcBef><a:spcPts val="0"/></a:spcBef></a:pPr>\#(runs(line.runs, hundredths))</a:p>"#
        }.joined()

        return #"<p:sp><p:nvSpPr><p:cNvPr id="\#(id)" name="Text \#(number)"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>"#
            + #"<p:spPr><a:xfrm><a:off x="\#(x)" y="\#(y)"/><a:ext cx="\#(width)" cy="\#(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>"#
            + #"<p:txBody><a:bodyPr wrap="none" lIns="0" tIns="0" rIns="0" bIns="0" rtlCol="0" anchor="t"><a:noAutofit/></a:bodyPr><a:lstStyle/>\#(paragraphs)</p:txBody></p:sp>"#
    }

    /// A line, rectangle, ellipse or rounded rectangle with the PDF's colors and line settings.
    private static func shapeXML(_ shape: TextlessPDF.Shape, id: Int, number: Int, scale: Double, origin: CGPoint) -> String {
        func emu(_ value: CGFloat) -> Int { Int((Double(value) * scale).rounded()) }
        func hex(_ color: UInt32) -> String { String(format: "%06X", color) }
        let fill = shape.fill.map { #"<a:solidFill><a:srgbClr val="\#(hex($0))"/></a:solidFill>"# } ?? "<a:noFill/>"
        var line = "<a:ln><a:noFill/></a:ln>"
        if let stroke = shape.stroke {
            let width = max(1, emu(shape.lineWidth))
            let cap = ["flat", "rnd", "sq"][shape.cap]
            let join = [#"<a:miter lim="1000000"/>"#, "<a:round/>", "<a:bevel/>"][shape.join]
            line = #"<a:ln w="\#(width)" cap="\#(cap)"><a:solidFill><a:srgbClr val="\#(hex(stroke))"/></a:solidFill><a:prstDash val="solid"/>\#(join)</a:ln>"#
        }
        let x = Int(origin.x) + emu(shape.bounds.minX), y = Int(origin.y) + emu(shape.bounds.minY)
        let size = #"<a:ext cx="\#(emu(shape.bounds.width))" cy="\#(emu(shape.bounds.height))"/>"#
        switch shape.kind {
        case .line(let from, let to):
            // Drawn from the top left to the bottom right of its box unless flipped.
            let flip = (to.x - from.x) * (to.y - from.y) < 0 ? #" flipV="1""# : ""
            return #"<p:cxnSp><p:nvCxnSpPr><p:cNvPr id="\#(id)" name="Line \#(number)"/><p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr>"#
                + #"<p:spPr><a:xfrm\#(flip)><a:off x="\#(x)" y="\#(y)"/>\#(size)</a:xfrm><a:prstGeom prst="line"><a:avLst/></a:prstGeom><a:noFill/>\#(line)</p:spPr></p:cxnSp>"#
        case .rect, .ellipse, .roundRect:
            // A box with an outline is a rounded rectangle with square corners: Apple's importer (Keynote,
            // Quick Look) draws a plain rectangle's outline a hairline whatever its width.
            var geometry = "rect", adjust = ""
            if case .rect = shape.kind, shape.stroke != nil {
                geometry = "roundRect"
                adjust = #"<a:gd name="adj" fmla="val 0"/>"#
            }
            if case .ellipse = shape.kind { geometry = "ellipse" }
            if case .roundRect(let radius) = shape.kind {
                geometry = "roundRect"
                adjust = #"<a:gd name="adj" fmla="val \#(min(50_000, Int(radius / min(shape.bounds.width, shape.bounds.height) * 100_000)))"/>"#
            }
            return #"<p:sp><p:nvSpPr><p:cNvPr id="\#(id)" name="Shape \#(number)"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>"#
                + #"<p:spPr><a:xfrm><a:off x="\#(x)" y="\#(y)"/>\#(size)</a:xfrm><a:prstGeom prst="\#(geometry)"><a:avLst>\#(adjust)</a:avLst></a:prstGeom>\#(fill)\#(line)</p:spPr></p:sp>"#
        }
    }

    /// A text box's position and size in EMUs.
    private static func textFrame(_ block: TextBlock, scale: Double, origin: CGPoint) -> (x: Int, y: Int, width: Int, height: Int) {
        func emu(_ value: CGFloat) -> Int { Int(Double(value) * scale) }
        // A little extra width so substitute fonts that run slightly wider don't get cut off.
        return (Int(origin.x) + emu(block.frame.minX), Int(origin.y) + emu(block.frame.minY),
                emu(block.frame.width * 1.04 + 2), emu(block.frame.height))
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
