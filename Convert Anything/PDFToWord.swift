import AppKit
import OSLog
import PDFKit

/// PDF → Word as a normal, editable document: paragraphs with their fonts, sizes, bold/italic and colors,
/// larger text as headings, and the PDF's pictures and charts as images in reading order.
///
/// Pictures come from the page's own drawing steps (SlideLayers): each photo, chart or diagram is cut from
/// a drawing of just its shapes and images, so it has exact bounds and no stray text, and photos side by
/// side stay apart. The page's background color isn't copied; a full-page photo is. Ruled grids become
/// Word tables with their cell colors and borders, and so does text laid out in rows and columns. Labels
/// around a chart stay in its picture. Repeated headers, footers and page numbers are left out. Scanned
/// pages are read with text recognition. Pages that can't be split this way have their pictures found in
/// a render with the text masked out.
nonisolated enum PDFToWord {
    /// Text laid out in rows and columns, rebuilt as a Word table.
    private struct Table {
        var rows: [[[TextRun]]]         // Rows → cells → styled text
        var columnWidths: [CGFloat]     // Points
        var ruling: Ruling?             // How a ruled grid looked; nil for text in rows and columns

        struct Ruling {
            var rowHeights: [CGFloat]
            var fills: [[String?]]      // RRGGBB per cell, nil when clear
            var alignments: [[String]]  // l, ctr or r
            var anchors: [[String]]     // t, ctr or b
            var color: String
            var width: CGFloat          // Points
        }
    }

    private enum Item {
        case paragraph(TextBlock)
        case table(Table)
        case image(file: String, size: CGSize)      // Size in points, as on the page
        case pictures([(file: String, size: CGSize)])   // Side by side on the page, left to right
        case text(String)                           // Recognized from a scan
    }

    private struct Page {
        var size: CGSize
        var items: [(frame: CGRect, item: Item)]
    }

    static func convert(_ request: Converter.Request, output: URL) async throws {
        let package = request.workDir.appending(path: "docx")
        let media = package.appending(path: "word/media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)

        let scale = request.quality.pageScale
        let pages = try await background { () throws -> [Page] in
            guard let document = PDFDocument(url: request.input), document.pageCount > 0 else {
                throw ConversionError.failed("Couldn't read this PDF.")
            }
            // Pages are independent, so they're analyzed side by side. Their pictures are saved under
            // per-page names, then numbered in page order so the result doesn't depend on timing.
            var pages = try await PageWorkers.map(request.input, pageCount: document.pageCount, maxWorkers: 4) { page, index in   // PDFKit's text engine stops scaling past ~4
                try analyze(page, media: media, scale: scale, imagePrefix: "page\(index)-")
            }.compactMap { $0 }
            var imageCount = 0
            for p in pages.indices {
                for i in pages[p].items.indices {
                    guard case .image(let file, let size) = pages[p].items[i].item else { continue }
                    imageCount += 1
                    let name = "image\(imageCount).\((file as NSString).pathExtension)"
                    try FileManager.default.moveItem(at: media.appending(path: file), to: media.appending(path: name))
                    pages[p].items[i].item = .image(file: name, size: size)
                }
            }
            return pages
        }

        let items = readingOrder(pages)
        guard !items.isEmpty else { throw ConversionError.failed("No text or pictures could be found in this PDF.") }
        let pageSize = pages.first?.size ?? CGSize(width: 612, height: 792)
        try writePackage(package, items: items, pageSize: pageSize, title: request.title)
        try await Tools.run("/usr/bin/zip", ["-q", "-X", "-D", "-nw", "-r", output.path, "[Content_Types].xml", "_rels", "word", "docProps"],
                            currentDirectory: package)
    }

    // MARK: Reading a page

    private static func analyze(_ page: PDFPage, media: URL, scale: CGFloat, imagePrefix: String) throws -> Page {
        let crop = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation) % 180 == 90
        let size = rotated ? CGSize(width: crop.height, height: crop.width) : crop.size

        var imageCount = 0
        /// Photos filling the page are saved as JPEG (smaller, and much quicker to write); everything else
        /// as PNG, which keeps clear backgrounds and sharp lines.
        func save(_ image: CGImage, _ photo: Bool) throws -> String {
            imageCount += 1
            let name = "\(imagePrefix)\(imageCount).\(photo ? "jpg" : "png")"
            try ImageConversion.write(image, to: media.appending(path: name), format: photo ? .jpeg : .png,
                                      properties: photo ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:])
            return name
        }

        // Turned pages: the text positions don't line up with the picture, so the page goes in whole.
        if page.rotation != 0 {
            let rendered = try ImageConversion.render(page, scale: scale)
            return Page(size: size, items: [(CGRect(origin: .zero, size: size), .image(file: try save(rendered, false), size: size))])
        }

        let lines = PDFText.lines(on: page)
        var rendered: CGImage?
        if lines.isEmpty {
            // A scan: recognize its text instead of copying the picture of it.
            let image = try ImageConversion.render(page, scale: scale)
            rendered = image
            let paragraphs = (try? TextRecognition.paragraphs(in: image)) ?? []
            if !paragraphs.isEmpty {
                return Page(size: size, items: paragraphs.enumerated().map { index, text in
                    (CGRect(x: 0, y: CGFloat(index), width: size.width, height: 1), .text(text))
                })
            }
        }

        do {
            if let items = try layeredItems(page, size: size, lines: lines, scale: scale, save: save) {
                return Page(size: size, items: items)
            }
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "Convert Anything", category: "PDFToWord")
                .notice("Page read the simple way: \(String(describing: error), privacy: .public)")
        }
        // The page couldn't be split into its drawings: find its pictures in a render with the text masked out.
        let image = try rendered ?? ImageConversion.render(page, scale: scale)
        return Page(size: size, items: try maskedItems(page, size: size, lines: lines, rendered: image, scale: scale, save: save))
    }

    /// Pictures of shapes smaller than this (points, either way) are left out: rules, underlines, bullets,
    /// table borders.
    private static let minPicture: CGFloat = 24

    /// The page's pictures, tables and text, with each picture cut from a drawing of just that picture's
    /// shapes and images (SlideLayers), or nil when the page can't be split that way.
    ///
    /// The page is drawn once without its text, on a clear background, and without the page background
    /// (a color or gradient behind everything isn't something to copy into a Word document). Ruled grids
    /// become Word tables. Labels around a chart or diagram stay in its picture: those pictures are cut
    /// from one more drawing of the page with its text, made only where they are.
    private static func layeredItems(_ page: PDFPage, size: CGSize, lines allLines: [TextLine], scale: CGFloat,
                                     save: (CGImage, Bool) throws -> String) throws -> [(CGRect, Item)]? {
        guard let plan = try SlideLayers.plan(page, minSide: minPicture) else { return nil }
        let pageRect = CGRect(origin: .zero, size: size)
        var lines = allLines
        var items: [(CGRect, Item)] = []
        func finish() -> [(CGRect, Item)] {
            let (tables, used) = detectTables(lines)
            items += tables.map { ($0.frame, Item.table($0.table)) }
            items += PDFText.group(lines.enumerated().filter { !used.contains($0.offset) }.map(\.element)).map { ($0.frame, Item.paragraph($0)) }
            return items
        }

        // The old way of finding pictures, a coarse drawing of the page with its text masked, still
        // answers two questions about a page with a background; made at most once.
        var coarse: (regions: [CGRect], share: CGFloat)?
        func coarseInk() -> (regions: [CGRect], share: CGFloat) {
            if let coarse { return coarse }
            let found = Self.coarseInk(page: page, size: size, lines: allLines)
            coarse = found
            return found
        }

        // A picture behind everything that fills the page.
        if plan.backgroundPhoto(pageArea: size.width * size.height) != nil {
            // A page exported as one picture with its text on top (things with blank paper around them), or a
            // scan with a text layer: what's in the picture can only be found in its pixels, as before.
            let letters = allLines.reduce(0) { $0 + $1.runs.reduce(0) { $0 + $1.text.count(where: { !$0.isWhitespace }) } }
            if letters >= 400 || !coarseInk().regions.isEmpty { return nil }
            // A photo filling the page (a cover): the page without its text, as one picture. A gradient or a
            // flat color stored as a picture is a plain background like any other.
            // Both copies come from one reading of the page, so the photo is decoded once.
            let background = Set(plan.background)
            let copies = try TextlessPDF.documents(for: page, [(keeping: { background.contains($0) }, annotations: false), (keeping: nil, annotations: true)])
            if let backgroundPage = copies[0].page(at: 0), hasDetail(backgroundPage) {
                guard let copy = copies[1].page(at: 0) else { return nil }
                items.append((pageRect, .image(file: try save(ImageConversion.render(copy, scale: scale), true), size: size)))
                return finish()
            }
        }

        // Shapes this small are rules, underlines and bullets; an image only needs to be a small icon.
        let candidates = plan.groups.filter { group in
            group.hasImage ? max(group.frame.width, group.frame.height) >= minPicture && min(group.frame.width, group.frame.height) >= 8
                : group.frame.width >= minPicture && group.frame.height >= minPicture
        }
        // What the background draws besides a color or gradient filling the page (a logo or a band in a
        // page template): the coarse regions the groups don't cover. Long thin ones (rules, bands, a page
        // edge) are decoration.
        let backgroundRegions = plan.background.isEmpty ? [] : coarseInk().regions.filter { region in
            let short = min(region.width, region.height), long = max(region.width, region.height)
            return !(short < 36 && long > short * 6) && !plan.groups.contains { $0.frame.insetBy(dx: -6, dy: -6).intersects(region) }
        }
        guard !candidates.isEmpty || !backgroundRegions.isEmpty else { return finish() }
        // Shapes (charts, diagrams, grids) alone, without text, drawn on a clear background: for their exact
        // bounds and to tell a ruled grid from a picture. Photos have their bounds already, and only need
        // drawing when there's a colored page background to take out from around them (a logo with a
        // clear background on a dark slide).
        let coloredPage = !plan.background.isEmpty && coarseInk().share > 0.75
        let shapes = Set(candidates.filter { !$0.hasImage || coloredPage }.flatMap(\.steps))
        var drawing = try shapes.isEmpty ? nil : autoreleasepool {
            try TextlessPDF.document(for: page, keeping: { shapes.contains($0) }, annotations: false).page(at: 0).map { try ClearDrawing($0, scale: scale) }
        }
        let pagePixels = CGRect(x: 0, y: 0, width: Int(size.width * scale), height: Int(size.height * scale))

        // Ruled grids become tables; their text goes in their cells.
        var ruled: [SlideTable] = []
        var shown: [(group: SlideLayers.Plan.Group, pixels: CGRect, frame: CGRect)] = []
        for group in candidates {
            let pixels: CGRect
            if group.hasImage {
                pixels = CGRect(x: group.frame.minX * scale, y: group.frame.minY * scale, width: group.frame.width * scale, height: group.frame.height * scale)
                    .integral.intersection(pagePixels)
                guard !pixels.isEmpty else { continue }
            } else {
                guard let drawing, let shown = drawing.shownPixels(in: group.frame.insetBy(dx: -1, dy: -1)) else { continue }
                pixels = shown
            }
            if !group.hasImage, let drawing, let table = SlideTable.detect(in: pixels, of: drawing, page: page, lines: allLines) {
                ruled.append(table)
            } else {
                shown.append((group, pixels, CGRect(x: pixels.minX / scale, y: pixels.minY / scale, width: pixels.width / scale, height: pixels.height / scale)))
            }
        }
        lines.removeAll { line in ruled.contains { $0.frame.contains(CGPoint(x: line.frame.midX, y: line.frame.midY)) } }
        items += ruled.map { ($0.frame, Item.table(table(from: $0))) }
        let textTables = detectTables(lines).tables.map(\.frame)
        let tableFrames = ruled.map(\.frame) + textTables

        let bodySize = commonSize(of: allLines)
        // Where each picture goes in `items`, the pixels to cut for it, and what it is.
        enum Kind { case photo, shapes, background }
        var cuts: [(index: Int, pixels: CGRect, kind: Kind, labels: [CGRect])] = []
        func add(_ frame: CGRect, _ pixels: CGRect, _ kind: Kind, labels: [CGRect] = []) {
            cuts.append((items.count, pixels, kind, labels))
            items.append((frame, .image(file: "", size: frame.size)))
        }
        for (number, picture) in shown.enumerated() {
            let found = picture.frame
            // A table's borders and shading aren't a picture. A photo is, even where text that lines up in
            // columns around it was taken for a table.
            let tables = picture.group.hasImage ? ruled.map(\.frame) : tableFrames
            if tables.reduce(0, { $0 + $1.intersection(found).area }) > found.area * 0.3 { continue }
            func pixels(_ rect: CGRect) -> CGRect {
                CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral.intersection(pagePixels)
            }
            if picture.group.hasImage {
                // Text on a photo (a caption over it, labels on a product shot) stays in it, as before;
                // a photo under paragraphs of text is a background to them and is left out.
                let on = lines.filter { line in line.frame.intersection(found).area > line.frame.area * 0.5 }
                if on.reduce(0, { $0 + $1.runs.reduce(0) { $0 + $1.text.count } }) > 150 { continue }
                lines.removeAll { line in on.contains { $0.frame == line.frame } }
                let tight = on.reduce(found) { $0.union($1.frame) }
                add(tight, tight == found ? picture.pixels : pixels(tight), .photo)
                continue
            }
            let others = shown.indices.filter { $0 != number }.map { shown[$0].frame }
            // Chart titles and axis labels sit just outside the drawing: take in small text that touches it,
            // but not so far that the picture would reach into another one.
            var region = found
            for line in lines where line.fontSize < bodySize * 0.95 || line.runs.reduce(0, { $0 + $1.text.count }) < 40 {
                guard found.insetBy(dx: -14, dy: -14).intersects(line.frame) else { continue }
                let grown = region.union(line.frame)
                if !others.contains(where: { $0.intersects(grown) }) { region = grown }
            }
            region = region.insetBy(dx: -3, dy: -3).intersection(pageRect)
            // Headings and captions stay editable text even when they sit on the picture.
            let inside = lines.filter { line in
                region.insetBy(dx: -2, dy: -2).contains(line.frame) && line.fontSize < bodySize * 1.15
                    && line.runs.first.map({ $0.text.prefixMatch(of: /\s*(Figure|Fig\.|Table|Chart)\s*\d/) == nil }) != false
            }
            if inside.isEmpty {
                add(found, picture.pixels, .shapes)
                continue
            }
            // A plain box behind some text (a callout, a colored heading bar) keeps its text editable, and so
            // does a shape with paragraphs of ordinary text in it.
            let bodyText = inside.filter { $0.fontSize >= bodySize * 0.9 }.reduce(0) { $0 + $1.runs.reduce(0) { $0 + $1.text.count } }
            let plainBox = picture.group.steps.allSatisfy { plan.areas[$0].map { $0.insetBy(dx: -2, dy: -2).contains(picture.group.frame) } ?? true }
            if bodyText > 150 || plainBox { continue }
            lines.removeAll { line in inside.contains { $0.frame == line.frame } }
            let tight = inside.reduce(found) { $0.union($1.frame) }.insetBy(dx: -2, dy: -2).intersection(pageRect)
            add(tight, pixels(tight), .shapes, labels: inside.map { pixels($0.frame.insetBy(dx: -1, dy: -1)) })
        }
        // The background's own pieces, where nothing else is.
        let taken = shown.map(\.frame) + tableFrames
        for region in backgroundRegions where !taken.contains(where: { $0.intersects(region) }) {
            add(region, CGRect(x: region.minX * scale, y: region.minY * scale, width: region.width * scale, height: region.height * scale)
                .integral.intersection(pagePixels), .background)
        }
        guard !cuts.isEmpty else { return finish() }

        // The pictures are cut from one more drawing of the page, with its text, only where they are: text
        // that belongs to a picture (labels, and text the page's text layer doesn't list, like a chart's
        // numbers drawn as text in a nested drawing) stays in it. The page's other text that reaches into a
        // chart or diagram is cleared, and so is a colored page background around what it shows.
        let area = cuts.reduce(CGRect.null) { $0.union($1.pixels) }
            .intersection(pagePixels)
        let left = Int(area.minX), top = Int(area.minY), width = Int(area.width), height = Int(area.height)
        // Only where the shapes show is still needed from their drawing, for clearing a colored background:
        // keep that, for the pictures' area, and let the whole drawing go before making another.
        var shapeAlpha: [UInt8] = []
        if let drawing, !plan.background.isEmpty, width > 0, height > 0 {
            shapeAlpha = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width { shapeAlpha[y * width + x] = drawing.pixels[((top + y) * drawing.width + left + x) * 4 + 3] }
            }
        }
        drawing = nil
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        // Pixels of the page from the top left → this bitmap's coordinates (bottom-left origin).
        func local(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX - CGFloat(left), y: CGFloat(height) - (rect.maxY - CGFloat(top)), width: rect.width, height: rect.height)
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.clip(to: cuts.map { local($0.pixels) })
        context.translateBy(x: -CGFloat(left), y: CGFloat(height + top) - size.height * scale)
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        context.restoreGState()
        for line in lines {
            let pixels = CGRect(x: line.frame.minX * scale, y: line.frame.minY * scale, width: line.frame.width * scale, height: line.frame.height * scale)
                .insetBy(dx: -scale, dy: -scale)
            if cuts.contains(where: { $0.kind != .photo && $0.pixels.intersects(pixels) }) { context.clear(local(pixels)) }
        }
        let memory = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        if !shapeAlpha.isEmpty {
            for cut in cuts where cut.kind == .shapes || (cut.kind == .photo && coloredPage) {
                clearBackground(memory, width: width, origin: (left, top), in: cut.pixels.intersection(area), labels: cut.labels, shapes: shapeAlpha)
            }
        }
        guard let image = context.makeImage() else { return nil }
        for cut in cuts {
            let rect = cut.pixels.offsetBy(dx: -CGFloat(left), dy: -CGFloat(top)).intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard var piece = image.cropping(to: rect) else { continue }
            // Without a clear part (most photos), it's written without transparency, which is much quicker.
            if isOpaque(memory, width: width, in: rect), let opaque = withoutAlpha(piece) { piece = opaque }
            if case .image(_, let size) = items[cut.index].1 { items[cut.index].1 = .image(file: try save(piece, false), size: size) }
        }
        items.removeAll { if case .image(let file, _) = $0.1 { file.isEmpty } else { false } }
        return finish()
    }

    /// Whether every pixel of `rect` in `memory` (RGBA rows `width` pixels wide) is fully opaque.
    private static func isOpaque(_ memory: UnsafeMutablePointer<UInt8>, width: Int, in rect: CGRect) -> Bool {
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) where memory[(y * width + x) * 4 + 3] != 255 { return false }
        }
        return true
    }

    private static func withoutAlpha(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Clears the page's background from `rect` (pixels of the page) in `memory`, a drawing of the page
    /// from `origin`, where the picture's own shapes show nothing (`shapes` is their alpha, laid out like
    /// `memory`). When the background there is clear (a page template that only draws a logo) or white,
    /// nothing changes. Otherwise only the picture's `labels` keep what's around its shapes, less their
    /// own background color, found in each label's small area so a gradient doesn't matter.
    private static func clearBackground(_ memory: UnsafeMutablePointer<UInt8>, width: Int, origin: (x: Int, y: Int), in rect: CGRect,
                                        labels: [CGRect], shapes: [UInt8]) {
        func local(_ x: Int, _ y: Int) -> Int { ((y - origin.y) * width + (x - origin.x)) * 4 }
        func isEmpty(_ x: Int, _ y: Int) -> Bool { shapes[(y - origin.y) * width + x - origin.x] == 0 }
        func clear(_ i: Int) { memory[i] = 0; memory[i + 1] = 0; memory[i + 2] = 0; memory[i + 3] = 0 }
        /// The most common color where the shapes show nothing, as RGBA.
        func dominant(_ rect: CGRect, step: Int) -> (Int, Int, Int, Int)? {
            var counts: [UInt32: Int] = [:]
            for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: step) {
                for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: step) where isEmpty(x, y) {
                    let i = local(x, y)
                    counts[UInt32(memory[i]) << 24 | UInt32(memory[i + 1]) << 16 | UInt32(memory[i + 2]) << 8 | UInt32(memory[i + 3]), default: 0] += 1
                }
            }
            return counts.max { $0.value < $1.value }.map { key in (Int(key.key >> 24), Int(key.key >> 16 & 0xFF), Int(key.key >> 8 & 0xFF), Int(key.key & 0xFF)) }
        }
        // Clear or white around the shapes: nothing to take out (and text the page's text layer doesn't
        // list stays).
        guard rect.width >= 1, rect.height >= 1, let color = dominant(rect, step: 3), color.3 > 0,
              min(color.0, color.1, color.2) < 245 || color.3 < 255 else { return }
        let labels = labels.map { $0.intersection(rect).integral.intersection(rect) }.filter { !$0.isEmpty }
        let x0 = Int(rect.minX), y0 = Int(rect.minY), columns = Int(rect.maxX) - x0, rows = Int(rect.maxY) - y0
        var kept = [Bool](repeating: false, count: columns * rows)
        for label in labels {
            for y in Int(label.minY)..<Int(label.maxY) {
                for x in Int(label.minX)..<Int(label.maxX) { kept[(y - y0) * columns + x - x0] = true }
            }
        }
        for y in y0..<(y0 + rows) {
            for x in x0..<(x0 + columns) where !kept[(y - y0) * columns + x - x0] && isEmpty(x, y) { clear(local(x, y)) }
        }
        for label in labels {
            guard let color = dominant(label, step: 1) else { continue }
            for y in Int(label.minY)..<Int(label.maxY) {
                for x in Int(label.minX)..<Int(label.maxX) where isEmpty(x, y) {
                    let i = local(x, y)
                    if abs(Int(memory[i]) - color.0) + abs(Int(memory[i + 1]) - color.1) + abs(Int(memory[i + 2]) - color.2) + abs(Int(memory[i + 3]) - color.3) <= 32 {
                        clear(i)
                    }
                }
            }
        }
    }

    /// Whether `copy` (a page's background), drawn small, shows the detail of a photo rather than a smooth
    /// gradient or a flat color. Kept low: a soft, misty photo has little detail too, and keeping a
    /// background costs less than losing a photo.
    private static func hasDetail(_ copy: PDFPage) -> Bool {
        let bounds = copy.bounds(for: .cropBox)
        let width = 128, height = max(8, Int(128 * bounds.height / max(bounds.width, 1)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return false }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
        copy.draw(with: .cropBox, to: context)
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        // How much each pixel differs from the average of its neighbors on either side: nothing in a
        // gradient (it changes evenly), grain and edges in a photo, however soft.
        var total = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let here = 2 * Int(pixels[y * width + x])
                total += abs(Int(pixels[y * width + x - 1]) + Int(pixels[y * width + x + 1]) - here)
                    + abs(Int(pixels[(y - 1) * width + x]) + Int(pixels[(y + 1) * width + x]) - here)
            }
        }
        let detail = Double(total) / Double(2 * (width - 2) * (height - 2))
        return detail > 0.4
    }

    /// The pictures and text of a page that couldn't be split into its drawings: whatever isn't text in
    /// `rendered` (the whole page) is cut out as pictures.
    private static func maskedItems(_ page: PDFPage, size: CGSize, lines allLines: [TextLine], rendered: CGImage, scale: CGFloat,
                                    save: (CGImage, Bool) throws -> String) throws -> [(CGRect, Item)] {
        var lines = allLines
        var items: [(CGRect, Item)] = []
        let (tables, tableLines) = detectTables(lines)
        lines = lines.enumerated().filter { !tableLines.contains($0.offset) }.map(\.element)
        items += tables.map { ($0.frame, Item.table($0.table)) }

        let bodySize = commonSize(of: allLines)
        for found in graphicRegions(page: page, size: size, lines: allLines) {
            // Chart titles and axis labels sit just outside the drawing: take in small text that touches it.
            var region = found
            for line in lines where line.fontSize < bodySize * 0.95 || line.runs.reduce(0, { $0 + $1.text.count }) < 40 {
                if found.insetBy(dx: -14, dy: -14).intersects(line.frame) { region = region.union(line.frame) }
            }
            region = region.insetBy(dx: -3, dy: -3).intersection(CGRect(origin: .zero, size: size))
            // Tables keep their text editable; their borders aren't pictures.
            if tables.reduce(0, { $0 + $1.frame.intersection(found).area }) > found.area * 0.3 { continue }
            // Text inside a picture (chart labels, captions in a diagram) stays part of the picture,
            // but a box of ordinary paragraph text keeps its text editable.
            let inside = lines.filter { region.insetBy(dx: -2, dy: -2).contains($0.frame) }
            let bodyText = inside.filter { $0.fontSize >= bodySize * 0.9 }.reduce(0) { $0 + $1.runs.reduce(0) { $0 + $1.text.count } }
            if bodyText > 150 { continue }
            lines.removeAll { line in inside.contains { $0.frame == line.frame } }
            let pixels = CGRect(x: region.minX * scale, y: region.minY * scale, width: region.width * scale, height: region.height * scale).integral
            guard let image = rendered.cropping(to: pixels) else { continue }
            items.append((region, .image(file: try save(image, false), size: region.size)))
        }
        items += PDFText.group(lines).map { ($0.frame, Item.paragraph($0)) }
        return items
    }

    private static func commonSize(of lines: [TextLine]) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        for run in lines.flatMap(\.runs) { counts[(run.size * 2).rounded() / 2, default: 0] += run.text.count }
        return counts.max { $0.value < $1.value }?.key ?? 11
    }

    // MARK: Tables

    /// A ruled grid found in the page's drawing, as a Word table.
    private static func table(from grid: SlideTable) -> Table {
        Table(rows: grid.cells.map { $0.map { joinedRuns($0.lines) } }, columnWidths: grid.columnWidths,
              ruling: Table.Ruling(rowHeights: grid.rowHeights, fills: grid.cells.map { $0.map(\.fill) },
                                   alignments: grid.cells.map { $0.map(\.alignment) }, anchors: grid.cells.map { $0.map(\.anchor) },
                                   color: grid.lineColor, width: grid.lineWidth))
    }

    /// Finds text arranged in a grid: several rows in a row whose pieces line up in the same columns.
    /// Returns the tables and the indexes of the lines they use.
    private static func detectTables(_ lines: [TextLine]) -> (tables: [(frame: CGRect, table: Table)], used: Set<Int>) {
        // Rows: lines whose vertical centers match.
        var rows: [[Int]] = []
        for index in lines.indices.sorted(by: { lines[$0].frame.midY < lines[$1].frame.midY }) {
            let line = lines[index]
            if let last = rows.last, let first = last.first,
               abs(lines[first].frame.midY - line.frame.midY) < min(lines[first].frame.height, line.frame.height) * 0.5 {
                rows[rows.count - 1].append(index)
            } else {
                rows.append([index])
            }
        }
        rows = rows.map { $0.sorted { lines[$0].frame.minX < lines[$1].frame.minX } }

        func isTabular(_ row: [Int]) -> Bool {
            guard row.count >= 2 else { return false }
            return zip(row, row.dropFirst()).allSatisfy { lines[$1].frame.minX - lines[$0].frame.maxX > 6 }
        }

        var tables: [(CGRect, Table)] = []
        var used = Set<Int>()
        var start = 0
        while start < rows.count {
            guard isTabular(rows[start]) else { start += 1; continue }
            // Extend over the following tabular rows that are close below.
            // A short one-piece row (a wrapped cell, a section title) can sit between table rows.
            var end = start
            func close(_ a: Int, _ b: Int) -> Bool {
                lines[rows[b][0]].frame.minY - lines[rows[a][0]].frame.maxY < lines[rows[a][0]].frame.height * 2.5
            }
            func isShort(_ row: [Int]) -> Bool { row.count == 1 && lines[row[0]].runs.reduce(0) { $0 + $1.text.count } < 40 }
            while end + 1 < rows.count {
                if isTabular(rows[end + 1]), close(end, end + 1) {
                    end += 1
                } else if end + 2 < rows.count, isShort(rows[end + 1]), isTabular(rows[end + 2]), close(end, end + 1), close(end + 1, end + 2) {
                    end += 2
                } else if end + 3 < rows.count, isShort(rows[end + 1]), isShort(rows[end + 2]), isTabular(rows[end + 3]),
                          close(end, end + 1), close(end + 1, end + 2), close(end + 2, end + 3) {
                    end += 3
                } else { break }
            }
            let run = Array(rows[start...end])
            start = end + 1

            // Columns: the cells' horizontal extents, merged where they overlap.
            var bands: [ClosedRange<CGFloat>] = []
            for interval in run.flatMap({ $0.map { lines[$0].frame.minX...lines[$0].frame.maxX } }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let last = bands.last, interval.lowerBound <= last.upperBound + 2 {
                    bands[bands.count - 1] = last.lowerBound...max(last.upperBound, interval.upperBound)
                } else {
                    bands.append(interval)
                }
            }
            let cellCount = run.reduce(0) { $0 + $1.count }
            let averageLength = Double(run.flatMap { $0 }.reduce(0) { $0 + lines[$1].runs.reduce(0) { $0 + $1.text.count } }) / Double(cellCount)
            // Two columns of running text aren't a table; neither are two lines that happen to share a row.
            guard bands.count >= 2, run.count >= 3 || (run.count >= 2 && bands.count >= 3),
                  bands.count >= 3 || averageLength < 40 else { continue }

            var table = Table(rows: [], columnWidths: [], ruling: nil)
            for (i, band) in bands.enumerated() {
                let next = i + 1 < bands.count ? bands[i + 1].lowerBound : band.upperBound + 6
                table.columnWidths.append(next - band.lowerBound)
            }
            // Cells whose text wraps put a line above or below the rest of their row ("Buenos" / "Aires").
            // Rows with only a few cells filled are folded into the nearest full row.
            var frame = CGRect.null
            var built: [(mid: CGFloat, cells: [[(y: CGFloat, runs: [TextRun])]])] = []
            for row in run {
                var cells = [[(y: CGFloat, runs: [TextRun])]](repeating: [], count: bands.count)
                for index in row {
                    let line = lines[index]
                    // By the left edge, so a title spanning several columns lands in the first one.
                    let column = bands.firstIndex { $0.contains(line.frame.minX + 1) } ?? bands.firstIndex { $0.contains(line.frame.midX) } ?? 0
                    cells[column].append((line.frame.midY, line.runs))
                    frame = frame.union(line.frame)
                    used.insert(index)
                }
                built.append((lines[row[0]].frame.midY, cells))
            }
            let isPartial = { (cells: [[(y: CGFloat, runs: [TextRun])]]) in cells.filter { !$0.isEmpty }.count * 2 < bands.count }
            var merged: [(mid: CGFloat, cells: [[(y: CGFloat, runs: [TextRun])]])] = []
            for row in built where !isPartial(row.cells) || built.count < 3 { merged.append(row) }
            for row in built where isPartial(row.cells) && built.count >= 3 {
                guard let target = merged.indices.min(by: { abs(merged[$0].mid - row.mid) < abs(merged[$1].mid - row.mid) }) else { continue }
                for column in row.cells.indices { merged[target].cells[column] += row.cells[column] }
            }
            table.rows = merged.sorted { $0.mid < $1.mid }.map { row in
                row.cells.map { pieces in
                    var runs: [TextRun] = []
                    for piece in pieces.sorted(by: { $0.y < $1.y }) {
                        if var last = runs.popLast() { last.text += " "; runs.append(last) }
                        runs += piece.runs
                    }
                    return runs
                }
            }
            tables.append((frame, table))
        }
        return (tables, used)
    }

    /// Areas of the page with drawing or pictures but no text, merged into rectangles (in page points,
    /// top-left origin). Thin rules, underlines and table borders are ignored.
    private static func graphicRegions(page: PDFPage, size: CGSize, lines: [TextLine]) -> [CGRect] {
        coarseInk(page: page, size: size, lines: lines).regions
    }

    /// The regions of `graphicRegions`, and how much of the page has ink (0–1): nearly all of it when
    /// the page has a colored background.
    private static func coarseInk(page: PDFPage, size: CGSize, lines: [TextLine]) -> (regions: [CGRect], share: CGFloat) {
        let cell: CGFloat = 4                     // Grid resolution in points
        let columns = Int(size.width / cell) + 1, rows = Int(size.height / cell) + 1
        guard let context = CGContext(data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return ([], 0) }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: columns, height: rows))
        context.scaleBy(x: 1 / cell, y: 1 / cell)
        page.draw(with: .cropBox, to: context)
        // Mask the text (drawn in page coordinates, origin at the bottom left).
        context.setFillColor(gray: 1, alpha: 1)
        for line in lines {
            context.fill(CGRect(x: line.frame.minX - 1, y: size.height - line.frame.maxY - 1, width: line.frame.width + 2, height: line.frame.height + 2))
        }

        let pixels = data.bindMemory(to: UInt8.self, capacity: columns * rows)
        var ink = [Bool](repeating: false, count: columns * rows)
        for row in 0..<rows {
            // Bitmap memory starts at the top row, which matches the top-left origin used here.
            for column in 0..<columns where pixels[row * columns + column] < 235 {
                ink[row * columns + column] = true
            }
        }

        // Group touching ink (with a small gap allowed) into regions.
        var seen = [Bool](repeating: false, count: ink.count)
        var regions: [CGRect] = []
        let gap = 3
        for start in ink.indices where ink[start] && !seen[start] {
            var stack = [start], minX = columns, minY = rows, maxX = 0, maxY = 0
            seen[start] = true
            while let index = stack.popLast() {
                let x = index % columns, y = index / columns
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for dy in -gap...gap {
                    for dx in -gap...gap {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < columns, ny < rows else { continue }
                        let next = ny * columns + nx
                        if ink[next] && !seen[next] { seen[next] = true; stack.append(next) }
                    }
                }
            }
            let rect = CGRect(x: CGFloat(minX) * cell, y: CGFloat(minY) * cell,
                              width: CGFloat(maxX - minX + 1) * cell, height: CGFloat(maxY - minY + 1) * cell)
            regions.append(rect.intersection(CGRect(origin: .zero, size: size)))
        }

        let pageArea = size.width * size.height
        return (regions.filter { $0.width >= 24 && $0.height >= 24 && $0.width * $0.height < pageArea * 0.9 },
                CGFloat(ink.count { $0 }) / CGFloat(max(1, ink.count)))
    }

    // MARK: Ordering

    /// Pages in order; within a page, top to bottom, with two-column stretches read left column first.
    /// Repeated headers and footers and bare page numbers are dropped.
    private static func readingOrder(_ pages: [Page]) -> [Item] {
        var marginTexts: [String: Int] = [:]
        func marginKey(_ block: TextBlock) -> String {
            block.lines.flatMap(\.runs).map(\.text).joined().replacing(/\d+/, with: "#").trimmingCharacters(in: .whitespaces)
        }
        func inMargin(_ frame: CGRect, _ size: CGSize) -> Bool {
            frame.maxY < size.height * 0.08 || frame.minY > size.height * 0.92
        }
        // A logo in the header or footer repeats on every page, in the same place.
        func pictureKey(_ frame: CGRect) -> String {
            "\(Int(frame.minX / 2)) \(Int(frame.minY / 2)) \(Int(frame.width / 2)) \(Int(frame.height / 2))"
        }
        var marginPictures: [String: Int] = [:]
        for page in pages {
            for case let (frame, .paragraph(block)) in page.items where inMargin(frame, page.size) {
                marginTexts[marginKey(block), default: 0] += 1
            }
            for case let (frame, .image) in page.items where inMargin(frame, page.size) {
                marginPictures[pictureKey(frame), default: 0] += 1
            }
        }
        let repeats = max(2, pages.count / 3)

        var result: [Item] = []
        for page in pages {
            let items = page.items.filter { frame, item in
                guard inMargin(frame, page.size) else { return true }
                if case .image = item { return pages.count < 3 || marginPictures[pictureKey(frame), default: 0] < repeats }
                guard case .paragraph(let block) = item else { return true }
                let key = marginKey(block)
                let isPageNumber = key.wholeMatch(of: /(page\s*)?(#|[ivxlc]+)(\s*(of|\/)\s*#)?/.ignoresCase()) != nil
                return !isPageNumber && (pages.count < 3 || marginTexts[key, default: 0] < repeats)
            }
            var ordered = columnOrder(pictureRows(items), width: page.size.width).map(\.item)
            // A paragraph that runs onto the next page continues there: join the two halves.
            if case .paragraph(var previous)? = result.last, case .paragraph(let next)? = ordered.first,
               let end = previous.lines.last?.runs.last?.text.trimmingCharacters(in: .whitespaces).last,
               let start = next.lines.first?.runs.first?.text.first,
               !".!?:;\"”)".contains(end), start.isLowercase || end == "-" || end == "," {
                previous.lines += next.lines
                result[result.count - 1] = .paragraph(previous)
                ordered.removeFirst()
            }
            result += ordered
        }
        return result
    }

    /// Pictures side by side on the page (a grid of photos, a chart beside a diagram) go in one row, so
    /// they stay side by side in Word, unless there's text beside them.
    private static func pictureRows(_ items: [(frame: CGRect, item: Item)]) -> [(frame: CGRect, item: Item)] {
        let pictures = items.indices.filter { if case .image = items[$0].item { true } else { false } }
            .sorted { items[$0].frame.minY < items[$1].frame.minY }
        var rows: [[Int]] = []
        for index in pictures {
            let frame = items[index].frame
            if let row = rows.last, let band = Optional(row.reduce(CGRect.null) { $0.union(items[$1].frame) }),
               min(band.maxY, frame.maxY) - max(band.minY, frame.minY) >= min(band.height, frame.height) * 0.5,
               !row.contains(where: { items[$0].frame.intersects(frame) }) {
                rows[rows.count - 1].append(index)
            } else {
                rows.append([index])
            }
        }
        var result = items
        var merged = Set<Int>()
        for row in rows where row.count > 1 {
            let band = row.reduce(CGRect.null) { $0.union(items[$1].frame) }
            let besideText = items.contains { entry in
                if case .image = entry.item { return false }
                return entry.frame.intersects(band.insetBy(dx: 0, dy: min(4, band.height / 4)))
            }
            guard !besideText else { continue }
            let ordered = row.sorted { items[$0].frame.minX < items[$1].frame.minX }
            let row = ordered.compactMap { index -> (file: String, size: CGSize)? in
                if case .image(let file, let size) = items[index].item { (file, size) } else { nil }
            }
            result[ordered[0]] = (band, .pictures(row))
            merged.formUnion(ordered.dropFirst())
        }
        return result.indices.filter { !merged.contains($0) }.map { result[$0] }
    }

    private static func columnOrder(_ items: [(frame: CGRect, item: Item)], width: CGFloat) -> [(frame: CGRect, item: Item)] {
        let middle = width / 2
        let sorted = items.sorted { $0.frame.minY < $1.frame.minY || ($0.frame.minY == $1.frame.minY && $0.frame.minX < $1.frame.minX) }
        var result: [(frame: CGRect, item: Item)] = []
        var band: [(frame: CGRect, item: Item)] = []
        func flush() {
            // Inside a band between full-width items: the left column, then the right.
            result += band.filter { $0.frame.midX < middle } + band.filter { $0.frame.midX >= middle }
            band = []
        }
        for entry in sorted {
            let spansMiddle = entry.frame.minX < middle - 10 && entry.frame.maxX > middle + 10
            if spansMiddle { flush(); result.append(entry) } else { band.append(entry) }
        }
        flush()
        return result
    }

    // MARK: Writing the .docx

    private static func writePackage(_ package: URL, items: [Item], pageSize: CGSize, title: String) throws {
        let fileManager = FileManager.default
        for dir in ["_rels", "word/_rels", "docProps"] {
            try fileManager.createDirectory(at: package.appending(path: dir), withIntermediateDirectories: true)
        }
        let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        func write(_ path: String, _ xml: String) throws {
            try (header + xml).write(to: package.appending(path: path), atomically: true, encoding: .utf8)
        }

        let bodySize = commonSize(items)
        let margin: CGFloat = 72
        let textWidth = pageSize.width - margin * 2
        var body = ""
        var images: [String] = []
        func picture(_ file: String, size: CGSize, fit: CGFloat) -> String {
            images.append(file)
            let number = images.count
            let cx = Int(size.width * fit * 12_700), cy = Int(size.height * fit * 12_700)
            return #"""
                <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">\#
                <wp:extent cx="\#(cx)" cy="\#(cy)"/><wp:docPr id="\#(number)" name="Picture \#(number)"/>\#
                <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\#
                <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>\#
                <pic:nvPicPr><pic:cNvPr id="\#(number)" name="\#(file)"/><pic:cNvPicPr/></pic:nvPicPr>\#
                <pic:blipFill><a:blip r:embed="rIdImage\#(number)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\#
                <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\#(cx)" cy="\#(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\#
                </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
                """#
        }
        for item in items {
            switch item {
            case .paragraph(let block):
                body += paragraph(block, bodySize: bodySize)
            case .text(let text):
                body += "<w:p><w:r><w:t xml:space=\"preserve\">\(Spreadsheets.escape(text))</w:t></w:r></w:p>"
            case .table(let table):
                body += tableXML(table, textWidth: textWidth)
            case .image(let file, let size):
                body += #"<w:p><w:pPr><w:jc w:val="center"/></w:pPr>\#(picture(file, size: size, fit: min(1, textWidth / max(size.width, 1))))</w:p>"#
            case .pictures(let row):
                // Side by side, a few points apart, scaled together to fit the page.
                let gap: CGFloat = 6
                let total = row.reduce(0) { $0 + $1.size.width } + gap * CGFloat(row.count - 1)
                let fit = min(1, textWidth / max(total, 1))
                let spacer = #"<w:r><w:t xml:space="preserve"> </w:t></w:r>"#
                body += #"<w:p><w:pPr><w:jc w:val="center"/></w:pPr>\#(row.map { picture($0.file, size: $0.size, fit: fit) }.joined(separator: spacer))</w:p>"#
            }
        }

        let twips = { (points: CGFloat) in Int(points * 20) }
        try write("word/document.xml", #"""
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="\#(rel)" \#
            xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \#
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \#
            xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\#(body)\#
            <w:sectPr><w:pgSz w:w="\#(twips(pageSize.width))" w:h="\#(twips(pageSize.height))"/>\#
            <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>\#
            </w:body></w:document>
            """#)

        let halfPoints = Int((bodySize * 2).rounded())
        func heading(_ id: String, _ name: String, _ level: Int, _ size: Int) -> String {
            #"""
            <w:style w:type="paragraph" w:styleId="\#(id)"><w:name w:val="\#(name)"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/>\#
            <w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="80"/><w:outlineLvl w:val="\#(level)"/></w:pPr>\#
            <w:rPr><w:b/><w:sz w:val="\#(size)"/></w:rPr></w:style>
            """#
        }
        try write("word/styles.xml", #"""
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\#
            <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/>\#
            <w:sz w:val="\#(halfPoints)"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="264" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\#
            <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\#
            \#(heading("Heading1", "heading 1", 0, halfPoints * 2))\#(heading("Heading2", "heading 2", 1, halfPoints * 3 / 2))\#
            \#(heading("Heading3", "heading 3", 2, halfPoints * 6 / 5))</w:styles>
            """#)

        try write("word/_rels/document.xml.rels", #"""
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#
            <Relationship Id="rIdStyles" Type="\#(rel)/styles" Target="styles.xml"/>\#
            \#(images.enumerated().map { #"<Relationship Id="rIdImage\#($0.offset + 1)" Type="\#(rel)/image" Target="media/\#($0.element)"/>"# }.joined())\#
            </Relationships>
            """#)
        try write("_rels/.rels", #"""
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#
            <Relationship Id="rId1" Type="\#(rel)/officeDocument" Target="word/document.xml"/>\#
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\#
            </Relationships>
            """#)
        try write("docProps/core.xml", #"""
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \#
            xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>\#(Spreadsheets.escape(title))</dc:title></cp:coreProperties>
            """#)
        try write("[Content_Types].xml", #"""
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\#
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\#
            <Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Default Extension="jpg" ContentType="image/jpeg"/>\#
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\#
            <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\#
            <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\#
            </Types>
            """#)
    }

    /// One Word paragraph from a block of lines. Lines are joined with spaces (or without the hyphen when a
    /// word was split), and larger text becomes a heading so it shows in Word's navigation.
    private static func paragraph(_ block: TextBlock, bodySize: CGFloat) -> String {
        let runs = joinedRuns(block.lines)
        let size = block.lines.map(\.fontSize).max() ?? bodySize
        let allBold = runs.allSatisfy { $0.bold || $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let length = runs.reduce(0) { $0 + $1.text.count }
        var style = ""
        if size >= bodySize * 1.5 && length < 200 { style = "Heading1" }
        else if size >= bodySize * 1.2 && length < 200 { style = "Heading2" }
        else if allBold && size >= bodySize * 1.05 && length < 120 { style = "Heading3" }

        var properties = style.isEmpty ? "" : #"<w:pStyle w:val="\#(style)"/>"#
        if block.centered { properties += #"<w:jc w:val="center"/>"# }
        let text = runs.map { runXML($0) }.joined()
        return "<w:p>" + (properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>") + text + "</w:p>"
    }

    /// The runs of several lines as one piece of text: joined with spaces, or without the hyphen when a
    /// word was split.
    private static func joinedRuns(_ lines: [TextLine]) -> [TextRun] {
        var runs: [TextRun] = []
        for (index, line) in lines.enumerated() {
            var lineRuns = line.runs
            if index > 0, var last = runs.last {
                let text = last.text.trimmingCharacters(in: .whitespaces)
                let nextStartsLower = lineRuns.first?.text.first?.isLowercase == true
                if text.hasSuffix("-") && nextStartsLower {
                    last.text = String(text.dropLast())
                } else if !last.text.hasSuffix(" ") {
                    last.text += " "
                }
                runs[runs.count - 1] = last
            }
            if let first = lineRuns.first, let last = runs.last, same(first, last) {
                runs[runs.count - 1].text += first.text
                lineRuns.removeFirst()
            }
            runs += lineRuns
        }
        return runs
    }

    private static func tableXML(_ table: Table, textWidth: CGFloat) -> String {
        let total = table.columnWidths.reduce(0, +)
        let fit = total > textWidth ? textWidth / total : 1
        let widths = table.columnWidths.map { Int($0 * fit * 20) }
        // A ruled grid keeps its own line color and weight (in eighths of a point); text in rows and
        // columns gets light gray lines.
        let ruling = table.ruling
        let border = ruling.map { #"w:val="single" w:sz="\#(min(96, max(2, Int(($0.width * 8).rounded()))))" w:space="0" w:color="\#($0.color)""# }
            ?? #"w:val="single" w:sz="4" w:space="0" w:color="999999""#
        var xml = #"<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/><w:tblBorders><w:top \#(border)/><w:left \#(border)/><w:bottom \#(border)/><w:right \#(border)/><w:insideH \#(border)/><w:insideV \#(border)/></w:tblBorders>\#(ruling == nil ? "" : #"<w:tblLayout w:type="fixed"/>"#)<w:tblCellMar><w:left w:w="80" w:type="dxa"/><w:right w:w="80" w:type="dxa"/></w:tblCellMar></w:tblPr><w:tblGrid>"#
        xml += widths.map { #"<w:gridCol w:w="\#($0)"/>"# }.joined() + "</w:tblGrid>"
        for (r, row) in table.rows.enumerated() {
            xml += "<w:tr>"
            if let height = ruling?.rowHeights[r] { xml += #"<w:trPr><w:trHeight w:val="\#(Int(height * 20))" w:hRule="atLeast"/></w:trPr>"# }
            for (column, cell) in row.enumerated() {
                // Children of tcPr and pPr in the order Word's schema wants them.
                var cellProperties = #"<w:tcW w:w="\#(widths[column])" w:type="dxa"/>"#
                var paragraphProperties = #"<w:spacing w:after="0"/>"#
                let fill = ruling?.fills[r][column]
                if let ruling {
                    if let fill { cellProperties += #"<w:shd w:val="clear" w:color="auto" w:fill="\#(fill)"/>"# }
                    switch ruling.anchors[r][column] {
                    case "ctr": cellProperties += #"<w:vAlign w:val="center"/>"#
                    case "b": cellProperties += #"<w:vAlign w:val="bottom"/>"#
                    default: break
                    }
                    switch ruling.alignments[r][column] {
                    case "ctr": paragraphProperties += #"<w:jc w:val="center"/>"#
                    case "r": paragraphProperties += #"<w:jc w:val="right"/>"#
                    default: break
                    }
                }
                xml += #"<w:tc><w:tcPr>\#(cellProperties)</w:tcPr><w:p><w:pPr>\#(paragraphProperties)</w:pPr>\#(cell.map { runXML($0, on: fill) }.joined())</w:p></w:tc>"#
            }
            xml += "</w:tr>"
        }
        // Word needs a paragraph between a table and whatever follows.
        return xml + "</w:tbl><w:p/>"
    }

    /// One run of text; `fill` is the color behind it (RRGGBB), nil for the white page.
    private static func runXML(_ run: TextRun, on fill: String? = nil) -> String {
        let font = Spreadsheets.escape(run.font)
        var rPr = #"<w:rFonts w:ascii="\#(font)" w:hAnsi="\#(font)" w:cs="\#(font)"/>"#
        if run.bold { rPr += "<w:b/>" }
        if run.italic { rPr += "<w:i/>" }
        // Light text sat on a dark background in the PDF; on Word's white page it would vanish.
        if let color = run.color, !isLight(color) || fill.map({ !isLight($0) }) == true { rPr += #"<w:color w:val="\#(color)"/>"# }
        rPr += #"<w:sz w:val="\#(max(2, Int((run.size * 2).rounded())))"/>"#
        return #"<w:r><w:rPr>\#(rPr)</w:rPr><w:t xml:space="preserve">\#(Spreadsheets.escape(run.text))</w:t></w:r>"#
    }

    private static func isLight(_ hex: String) -> Bool {
        guard let value = Int(hex, radix: 16) else { return false }
        let r = Double(value >> 16 & 0xFF), g = Double(value >> 8 & 0xFF), b = Double(value & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.85
    }

    private static func same(_ a: TextRun, _ b: TextRun) -> Bool {
        a.font == b.font && a.size == b.size && a.bold == b.bold && a.italic == b.italic && a.color == b.color
    }

    /// The most common text size in the document, weighted by length: the body text.
    private static func commonSize(_ items: [Item]) -> CGFloat {
        var lines: [TextLine] = []
        for case .paragraph(let block) in items { lines += block.lines }
        return commonSize(of: lines)
    }
}

private extension CGRect {
    nonisolated var area: CGFloat { isNull ? 0 : width * height }
}
