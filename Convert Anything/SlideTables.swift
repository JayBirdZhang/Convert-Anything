import AppKit
import PDFKit

/// A ruled table found on a page, rebuilt as a real PowerPoint table: its grid, cell colors, border and
/// each cell's text.
///
/// It's found in the drawing of a group of shapes (see SlideLayers), on a clear background: full-length
/// horizontal and vertical lines that frame the group, with every cell a single flat color (or clear).
/// Anything else (a merged cell, a line that stops partway, a cell with a picture or a pattern in it, a
/// chart with gridlines) isn't taken for a table, and the group stays a picture.
nonisolated struct SlideTable {
    struct Cell {
        var lines: [TextLine]       // Page points from the top left, like the page's other text
        var fill: String?           // RRGGBB, nil when clear
        var alignment: String       // l, ctr or r
        var anchor: String          // t, ctr or b
        var insets: (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat)
    }

    var frame: CGRect               // Page points from the top left, through the middle of the outer lines
    var columnWidths: [CGFloat]
    var rowHeights: [CGFloat]
    var cells: [[Cell]]             // Rows of cells
    var lineColor: String
    var lineWidth: CGFloat          // Points

    /// The table drawn in `box` (pixels of `drawing`), reading its text from `page`, or nil if it isn't one.
    static func detect(in box: CGRect, of drawing: ClearDrawing, page: PDFPage) -> SlideTable? {
        let left = Int(box.minX), top = Int(box.minY), width = Int(box.width), height = Int(box.height)
        let scale = drawing.scale
        guard width >= Int(20 * scale), height >= Int(10 * scale) else { return nil }
        let pixels = drawing.pixels
        typealias Color = (r: Int, g: Int, b: Int, a: Int)
        func pixel(_ x: Int, _ y: Int) -> Color {
            guard x >= 0, y >= 0, x < drawing.width, y < drawing.height else { return (0, 0, 0, 0) }
            let index = (y * drawing.width + x) * 4
            return (Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]), Int(pixels[index + 3]))
        }
        func differs(_ a: Color, _ b: Color) -> Bool {
            abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) + abs(a.a - b.a) > 60
        }
        // A line pixel is solid and unlike what's a few points away on either side across the line,
        // so a thin rule counts and the edge of a colored cell doesn't.
        let reach = max(2, Int((4 * scale).rounded()))
        func isLine(_ x: Int, _ y: Int, across: (x: Int, y: Int)) -> Bool {
            let color = pixel(x, y)
            return color.a > 128 && differs(color, pixel(x - across.x * reach, y - across.y * reach))
                && differs(color, pixel(x + across.x * reach, y + across.y * reach))
        }
        /// Bands of rows (or columns) that are line pixels almost all the way across. Nil if a line
        /// stops partway: that's a merged cell or not a table.
        func rules(count: Int, span: Int, isLine: (Int, Int) -> Bool) -> [ClosedRange<Int>]? {
            var bands: [ClosedRange<Int>] = []
            var partial: [Int] = []
            for position in 0..<count {
                var hits = 0
                for along in 0..<span where isLine(position, along) { hits += 1 }
                let fraction = Double(hits) / Double(span)
                if fraction >= 0.9 {
                    if let last = bands.last, last.upperBound == position - 1 { bands[bands.count - 1] = last.lowerBound...position }
                    else { bands.append(position...position) }
                } else if fraction >= 0.25 {
                    partial.append(position)
                }
            }
            // Anti-aliased edges of a line are partly covered; anything else partial isn't a table.
            for position in partial where !bands.contains(where: { $0.lowerBound - 2 <= position && position <= $0.upperBound + 2 }) {
                return nil
            }
            return bands
        }
        guard let rows = rules(count: height, span: width, isLine: { isLine(left + $1, top + $0, across: (0, 1)) }),
              let columns = rules(count: width, span: height, isLine: { isLine(left + $0, top + $1, across: (1, 0)) }),
              rows.count >= 2, columns.count >= 2, rows.count <= 41, columns.count <= 21,
              (rows.count - 1) * (columns.count - 1) >= 2,
              rows.first!.lowerBound <= 2, rows.last!.upperBound >= height - 3,
              columns.first!.lowerBound <= 2, columns.last!.upperBound >= width - 3 else { return nil }

        let ys = rows.map { CGFloat(top) + CGFloat($0.lowerBound + $0.upperBound + 1) / 2 }
        let xs = columns.map { CGFloat(left) + CGFloat($0.lowerBound + $0.upperBound + 1) / 2 }
        let thickness = CGFloat((rows + columns).map(\.count).reduce(0, +)) / CGFloat(rows.count + columns.count)
        let lineSample = pixel(Int((xs[0] + xs[1]) / 2), Int(ys[0]))
        guard let lineColor = hex(lineSample) else { return nil }

        // Each cell's inside must be one flat color.
        var fills: [[String?]] = []
        for row in 0..<(rows.count - 1) {
            var line: [String?] = []
            for column in 0..<(columns.count - 1) {
                let x0 = left + columns[column].upperBound + 3, x1 = left + columns[column + 1].lowerBound - 3
                let y0 = top + rows[row].upperBound + 3, y1 = top + rows[row + 1].lowerBound - 3
                guard x0 < x1, y0 < y1 else { return nil }
                let reference = pixel(x0, y0)
                var mismatches = 0, samples = 0
                for y in stride(from: y0, to: y1, by: 2) {
                    for x in stride(from: x0, to: x1, by: 2) {
                        samples += 1
                        if differs(pixel(x, y), reference) { mismatches += 1 }
                    }
                }
                guard mismatches * 200 <= samples else { return nil }
                line.append(reference.a > 128 ? hex(reference) ?? "000000" : nil)
            }
            fills.append(line)
        }

        // The text in each cell, read from the page itself.
        let crop = page.bounds(for: .cropBox)
        let inset = thickness / scale / 2
        var cells: [[Cell]] = []
        for row in 0..<(rows.count - 1) {
            var line: [Cell] = []
            for column in 0..<(columns.count - 1) {
                let rect = CGRect(x: xs[column] / scale, y: ys[row] / scale,
                                  width: (xs[column + 1] - xs[column]) / scale, height: (ys[row + 1] - ys[row]) / scale)
                line.append(cell(rect.insetBy(dx: inset, dy: inset), fill: fills[row][column], page: page, crop: crop))
            }
            cells.append(line)
        }
        // The cells must hold exactly the text the page's lines lose to the table, or text would be lost
        // or doubled: then it stays a picture with its text in text boxes.
        let frame = CGRect(x: xs.first! / scale, y: ys.first! / scale, width: (xs.last! - xs.first!) / scale, height: (ys.last! - ys.first!) / scale)
        func letters(_ lines: [TextLine]) -> [Character] {
            lines.flatMap { $0.runs.flatMap { $0.text.filter { !$0.isWhitespace } } }.sorted()
        }
        let replaced = PDFText.lines(on: page).filter { frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        guard letters(replaced) == letters(cells.flatMap { $0.flatMap(\.lines) }) else { return nil }

        return SlideTable(
            frame: CGRect(x: xs.first! / scale, y: ys.first! / scale, width: (xs.last! - xs.first!) / scale, height: (ys.last! - ys.first!) / scale),
            columnWidths: zip(xs, xs.dropFirst()).map { ($1 - $0) / scale },
            rowHeights: zip(ys, ys.dropFirst()).map { ($1 - $0) / scale },
            cells: cells, lineColor: lineColor, lineWidth: thickness / scale)
    }

    private static func cell(_ rect: CGRect, fill: String?, page: PDFPage, crop: CGRect) -> Cell {
        let pageRect = CGRect(x: crop.minX + rect.minX, y: crop.maxY - rect.maxY, width: rect.width, height: rect.height)
        var lines: [TextLine] = []
        for selection in page.selection(for: pageRect)?.selectionsByLine() ?? [] {
            guard let attributed = selection.attributedString else { continue }
            let bounds = selection.bounds(for: page)
            var runs = PDFText.styledRuns(attributed, lineHeight: bounds.height)
            guard !runs.isEmpty else { continue }
            while let last = runs.last?.text, last.hasSuffix(" ") { runs[runs.count - 1].text.removeLast() }
            lines.append(TextLine(frame: CGRect(x: bounds.minX - crop.minX, y: crop.maxY - bounds.maxY, width: bounds.width, height: bounds.height),
                                  runs: runs, fontSize: runs.map(\.size).max() ?? 12))
        }
        var result = Cell(lines: lines, fill: fill, alignment: "l", anchor: "t", insets: (3, 3, 2, 2))
        guard !lines.isEmpty else { return result }
        let text = lines.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let gaps = (left: text.minX - rect.minX, right: rect.maxX - text.maxX, top: text.minY - rect.minY, bottom: rect.maxY - text.maxY)
        let size = lines[0].fontSize
        if abs(gaps.left - gaps.right) < max(2, size * 0.3) && gaps.left > size * 0.5 {
            result.alignment = "ctr"
        } else if gaps.right < gaps.left - size {
            result.alignment = "r"
            result.insets.right = max(0, gaps.right)
        } else {
            result.insets.left = max(0, gaps.left)
        }
        if abs(gaps.top - gaps.bottom) < max(2, size * 0.3) && gaps.top > size * 0.3 {
            result.anchor = "ctr"
            result.insets.top = 0; result.insets.bottom = 0
        } else if gaps.bottom < gaps.top - size * 0.5 {
            result.anchor = "b"
            result.insets.bottom = max(0, gaps.bottom); result.insets.top = 0
        } else {
            result.insets.top = max(0, gaps.top); result.insets.bottom = 0
        }
        return result
    }

    /// RRGGBB from a premultiplied pixel.
    private static func hex(_ color: (r: Int, g: Int, b: Int, a: Int)) -> String? {
        guard color.a > 0 else { return nil }
        func channel(_ value: Int) -> Int { min(255, value * 255 / color.a) }
        return String(format: "%02X%02X%02X", channel(color.r), channel(color.g), channel(color.b))
    }
}
