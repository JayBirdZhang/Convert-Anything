import AppKit
import PDFKit

/// PDF → Word as a normal, editable document: paragraphs with their fonts, sizes, bold/italic and colors,
/// larger text as headings, and the PDF's pictures and charts as images in reading order.
///
/// Pictures are found by rendering each page with its text masked out: whatever is left (photos, charts,
/// diagrams) is cut out of the page as an image. Labels inside a chart stay in the picture. Repeated
/// headers, footers and page numbers are left out. Scanned pages are read with text recognition.
nonisolated enum PDFToWord {
    /// Text laid out in rows and columns, rebuilt as a Word table.
    private struct Table {
        var rows: [[[TextRun]]]         // Rows → cells → styled text
        var columnWidths: [CGFloat]     // Points
    }

    private enum Item {
        case paragraph(TextBlock)
        case table(Table)
        case image(file: String, size: CGSize)      // Size in points, as on the page
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
        let pages = try await Task.detached(priority: .utility) { () throws -> [Page] in
            guard let document = PDFDocument(url: request.input), document.pageCount > 0 else {
                throw ConversionError.failed("Couldn't read this PDF.")
            }
            var pages: [Page] = []
            var imageCount = 0
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { continue }
                pages.append(try analyze(page, media: media, scale: scale, imageCount: &imageCount))
            }
            return pages
        }.value

        let items = readingOrder(pages)
        guard !items.isEmpty else { throw ConversionError.failed("No text or pictures could be found in this PDF.") }
        let pageSize = pages.first?.size ?? CGSize(width: 612, height: 792)
        try writePackage(package, items: items, pageSize: pageSize, title: request.title)
        try await Tools.run("/usr/bin/zip", ["-q", "-X", "-D", "-nw", "-r", output.path, "[Content_Types].xml", "_rels", "word", "docProps"],
                            currentDirectory: package)
    }

    // MARK: Reading a page

    private static func analyze(_ page: PDFPage, media: URL, scale: CGFloat, imageCount: inout Int) throws -> Page {
        let crop = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation) % 180 == 90
        let size = rotated ? CGSize(width: crop.height, height: crop.width) : crop.size
        let rendered = try ImageConversion.render(page, scale: scale)

        func save(_ image: CGImage) throws -> String {
            imageCount += 1
            let name = "image\(imageCount).png"
            try ImageConversion.write(image, to: media.appending(path: name), format: .png)
            return name
        }

        // Turned pages: the text positions don't line up with the picture, so the page goes in whole.
        if page.rotation != 0 {
            return Page(size: size, items: [(CGRect(origin: .zero, size: size), .image(file: try save(rendered), size: size))])
        }

        var lines = PDFText.lines(on: page)
        if lines.isEmpty {
            // A scan: recognize its text instead of copying the picture of it.
            let paragraphs = (try? TextRecognition.paragraphs(in: rendered)) ?? []
            if !paragraphs.isEmpty {
                return Page(size: size, items: paragraphs.enumerated().map { index, text in
                    (CGRect(x: 0, y: CGFloat(index), width: size.width, height: 1), .text(text))
                })
            }
        }

        var items: [(CGRect, Item)] = []
        let allLines = lines
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
            items.append((region, .image(file: try save(image), size: region.size)))
        }
        items += PDFText.group(lines).map { ($0.frame, Item.paragraph($0)) }
        return Page(size: size, items: items)
    }

    private static func commonSize(of lines: [TextLine]) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        for run in lines.flatMap(\.runs) { counts[(run.size * 2).rounded() / 2, default: 0] += run.text.count }
        return counts.max { $0.value < $1.value }?.key ?? 11
    }

    // MARK: Tables

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

            var table = Table(rows: [], columnWidths: [])
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
        let cell: CGFloat = 4                     // Grid resolution in points
        let columns = Int(size.width / cell) + 1, rows = Int(size.height / cell) + 1
        guard let context = CGContext(data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return [] }
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
        return regions.filter { $0.width >= 24 && $0.height >= 24 && $0.width * $0.height < pageArea * 0.9 }
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
        for page in pages {
            for case let (frame, .paragraph(block)) in page.items where inMargin(frame, page.size) {
                marginTexts[marginKey(block), default: 0] += 1
            }
        }

        var result: [Item] = []
        for page in pages {
            let items = page.items.filter { frame, item in
                guard case .paragraph(let block) = item, inMargin(frame, page.size) else { return true }
                let key = marginKey(block)
                let isPageNumber = key.wholeMatch(of: /(page\s*)?(#|[ivxlc]+)(\s*(of|\/)\s*#)?/.ignoresCase()) != nil
                return !isPageNumber && (pages.count < 3 || marginTexts[key, default: 0] < max(2, pages.count / 3))
            }
            var ordered = columnOrder(items, width: page.size.width).map(\.item)
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
        for item in items {
            switch item {
            case .paragraph(let block):
                body += paragraph(block, bodySize: bodySize)
            case .text(let text):
                body += "<w:p><w:r><w:t xml:space=\"preserve\">\(Spreadsheets.escape(text))</w:t></w:r></w:p>"
            case .table(let table):
                body += tableXML(table, textWidth: textWidth)
            case .image(let file, let size):
                images.append(file)
                let number = images.count
                let fit = min(1, textWidth / max(size.width, 1))
                let cx = Int(size.width * fit * 12_700), cy = Int(size.height * fit * 12_700)
                body += #"""
                    <w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">\#
                    <wp:extent cx="\#(cx)" cy="\#(cy)"/><wp:docPr id="\#(number)" name="Picture \#(number)"/>\#
                    <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\#
                    <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>\#
                    <pic:nvPicPr><pic:cNvPr id="\#(number)" name="\#(file)"/><pic:cNvPicPr/></pic:nvPicPr>\#
                    <pic:blipFill><a:blip r:embed="rIdImage\#(number)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\#
                    <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\#(cx)" cy="\#(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\#
                    </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
                    """#
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
            <Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>\#
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\#
            <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\#
            <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\#
            </Types>
            """#)
    }

    /// One Word paragraph from a block of lines. Lines are joined with spaces (or without the hyphen when a
    /// word was split), and larger text becomes a heading so it shows in Word's navigation.
    private static func paragraph(_ block: TextBlock, bodySize: CGFloat) -> String {
        var runs: [TextRun] = []
        for (index, line) in block.lines.enumerated() {
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

        let size = block.lines.map(\.fontSize).max() ?? bodySize
        let allBold = runs.allSatisfy { $0.bold || $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let length = runs.reduce(0) { $0 + $1.text.count }
        var style = ""
        if size >= bodySize * 1.5 && length < 200 { style = "Heading1" }
        else if size >= bodySize * 1.2 && length < 200 { style = "Heading2" }
        else if allBold && size >= bodySize * 1.05 && length < 120 { style = "Heading3" }

        var properties = style.isEmpty ? "" : #"<w:pStyle w:val="\#(style)"/>"#
        if block.centered { properties += #"<w:jc w:val="center"/>"# }
        let runXML = runs.map(runXML).joined()
        return "<w:p>" + (properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>") + runXML + "</w:p>"
    }

    private static func tableXML(_ table: Table, textWidth: CGFloat) -> String {
        let total = table.columnWidths.reduce(0, +)
        let fit = total > textWidth ? textWidth / total : 1
        let widths = table.columnWidths.map { Int($0 * fit * 20) }
        let border = #"w:val="single" w:sz="4" w:space="0" w:color="999999""#
        var xml = #"<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/><w:tblBorders><w:top \#(border)/><w:left \#(border)/><w:bottom \#(border)/><w:right \#(border)/><w:insideH \#(border)/><w:insideV \#(border)/></w:tblBorders><w:tblCellMar><w:left w:w="80" w:type="dxa"/><w:right w:w="80" w:type="dxa"/></w:tblCellMar></w:tblPr><w:tblGrid>"#
        xml += widths.map { #"<w:gridCol w:w="\#($0)"/>"# }.joined() + "</w:tblGrid>"
        for row in table.rows {
            xml += "<w:tr>"
            for (column, cell) in row.enumerated() {
                xml += #"<w:tc><w:tcPr><w:tcW w:w="\#(widths[column])" w:type="dxa"/></w:tcPr><w:p><w:pPr><w:spacing w:after="0"/></w:pPr>\#(cell.map(runXML).joined())</w:p></w:tc>"#
            }
            xml += "</w:tr>"
        }
        // Word needs a paragraph between a table and whatever follows.
        return xml + "</w:tbl><w:p/>"
    }

    private static func runXML(_ run: TextRun) -> String {
        let font = Spreadsheets.escape(run.font)
        var rPr = #"<w:rFonts w:ascii="\#(font)" w:hAnsi="\#(font)" w:cs="\#(font)"/>"#
        if run.bold { rPr += "<w:b/>" }
        if run.italic { rPr += "<w:i/>" }
        // Light text sat on a dark background in the PDF; on Word's white page it would vanish.
        if let color = run.color, !isLight(color) { rPr += #"<w:color w:val="\#(color)"/>"# }
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
