import AppKit
import PDFKit

/// A styled piece of text within a line.
nonisolated struct TextRun {
    var text: String
    var font: String
    var size: CGFloat       // In page points
    var bold: Bool
    var italic: Bool
    var color: String?      // RRGGBB, or nil for black
}

nonisolated struct TextLine {
    var frame: CGRect       // Page points, origin at the top left of the visible page
    var runs: [TextRun]
    var fontSize: CGFloat
    var isFormField = false     // What's typed into a form field, rather than the page's own text
}

/// Lines that belong together (a paragraph, a title), so they become one editable text box.
nonisolated struct TextBlock {
    var lines: [TextLine]
    var frame: CGRect
    var lineSpacing: CGFloat?   // Distance between line tops, when there's more than one line
    var centered: Bool
}

/// Reads a PDF page's text with its position and styling, using macOS's own PDF engine.
nonisolated enum PDFText {
    static func blocks(on page: PDFPage) -> [TextBlock] {
        group(lines(on: page))
    }

    /// Every line of text on the page, top to bottom, with its position and styling.
    static func lines(on page: PDFPage) -> [TextLine] {
        let crop = page.bounds(for: .cropBox)
        var lines: [TextLine] = []
        for lineSelection in page.selection(for: crop)?.selectionsByLine() ?? [] {
            guard let attributed = lineSelection.attributedString else { continue }
            let bounds = lineSelection.bounds(for: page)
            let runs = styledRuns(attributed, lineHeight: bounds.height, page: page, selection: lineSelection)
            guard !runs.isEmpty else { continue }
            lines.append(TextLine(
                frame: CGRect(x: bounds.minX - crop.minX, y: crop.maxY - bounds.maxY, width: bounds.width, height: bounds.height),
                runs: runs,
                fontSize: runs.map(\.size).max() ?? 12))
        }
        return lines + formLines(on: page, crop: crop)
    }

    /// What's typed into the page's form fields. It's drawn by the fields, not the page, so it isn't in the
    /// page's text, and the copies of the page made without text leave it out too.
    private static func formLines(on page: PDFPage, crop: CGRect) -> [TextLine] {
        var lines: [TextLine] = []
        for field in page.annotations where field.type == "Widget" && field.widgetFieldType == .text && field.shouldDisplay {
            let value = field.widgetStringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else { continue }
            let box = field.bounds
            let rows = value.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            // A size of 0 means "fit the field".
            let fitted = min(12, box.height * 0.7 / CGFloat(max(1, rows.count)))
            let size = field.font.map { $0.pointSize > 0 ? $0.pointSize : fitted } ?? fitted
            let font = NSFont(name: field.font?.fontName ?? "Helvetica", size: size) ?? NSFont.systemFont(ofSize: size)
            let family = font.familyName ?? "Helvetica"
            let traits = font.fontDescriptor.symbolicTraits
            let height = size * 1.2
            // Single-line fields center their text; a multiline one starts at the top.
            var top = rows.count == 1 ? crop.maxY - box.midY - height / 2 : crop.maxY - box.maxY + 2
            for row in rows {
                let width = min(box.width - 4, (row as NSString).size(withAttributes: [.font: font]).width)
                var left = box.minX + 2
                if field.alignment == .center { left = box.midX - width / 2 } else if field.alignment == .right { left = box.maxX - 2 - width }
                lines.append(TextLine(
                    frame: CGRect(x: left - crop.minX, y: top, width: max(1, width), height: height),
                    runs: [TextRun(text: row, font: family, size: size, bold: traits.contains(.bold), italic: traits.contains(.italic),
                                   color: field.fontColor.flatMap(hex))],
                    fontSize: size, isFormField: true))
                top += height
            }
        }
        return lines
    }

    /// The line's text as styled runs. With its `page` and `selection`, fonts PDFKit doesn't know come from
    /// the PDF itself (see PageFonts) and broken ligatures are repaired.
    static func styledRuns(_ attributed: NSAttributedString, lineHeight: CGFloat,
                           page: PDFPage? = nil, selection: PDFSelection? = nil) -> [TextRun] {
        var runs: [TextRun] = []
        let string = attributed.string as NSString
        // Where this text is among the page's characters, to look up the PDF's own fonts.
        var pageFonts: (fonts: PageFonts, start: Int)?
        if let page, let selection, let fonts = PageFonts.of(page), selection.numberOfTextRanges(on: page) == 1 {
            let range = selection.range(at: 0, on: page)
            // The range may also hold the line break, which the text doesn't.
            if range.length == attributed.length || range.length == attributed.length + 1 { pageFonts = (fonts, range.location) }
        }
        let document = page?.document

        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
            let font = attributes[.font] as? NSFont
            let name = (font?.fontName ?? "").lowercased()
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            var family = font?.familyName ?? "Helvetica"
            if let plus = family.firstIndex(of: "+") { family = String(family[family.index(after: plus)...]) }  // Embedded subsets: "ABCDEF+Calibri"
            let bold = traits.contains(.boldFontMask) || ["bold", "black", "heavy", "semibold"].contains { name.contains($0) }
            let italic = traits.contains(.italicFontMask) || name.contains("italic") || name.contains("oblique")
            let color = (attributes[.foregroundColor] as? NSColor).flatMap(hex)

            let pieces = pageFonts?.fonts.pieces(in: NSRange(location: pageFonts!.start + range.location, length: range.length))
                ?? [(0, nil)]
            for (number, piece) in pieces.enumerated() {
                let end = number + 1 < pieces.count ? pieces[number + 1].offset : range.length
                let text = cleaned(string.substring(with: NSRange(location: range.location + piece.offset, length: end - piece.offset)))
                guard !text.isEmpty else { continue }
                let real = piece.font
                let run = TextRun(
                    text: text,
                    font: real?.family ?? family,
                    size: font?.pointSize ?? lineHeight * 0.8,
                    bold: real?.bold ?? bold,
                    italic: real?.italic ?? italic,
                    color: color)
                if let last = runs.last, last.font == run.font, last.size == run.size, last.bold == run.bold,
                   last.italic == run.italic, last.color == run.color {
                    runs[runs.count - 1].text += text
                } else {
                    runs.append(run)
                }
            }
        }
        // After joining, so words split between PDF runs are whole.
        for i in runs.indices {
            let run = runs[i]
            runs[i].text = Ligatures.repair(run.text, font: "\(run.font)\(run.bold ? "-b" : "")\(run.italic ? "-i" : "")", document: document)
        }
        // Drop lines that are only whitespace.
        return runs.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty } ? runs : []
    }

    /// Bullets from symbol fonts (Symbol, Wingdings) come through as private-use characters that
    /// other fonts can't show; inline images come through as U+FFFC. Both are mapped or dropped.
    private static func cleaned(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x0D, 0xFFFC, 0xFFFD: continue
            case 0x09: result += " "
            case 0xF0A7: result += "▪"
            case 0xF0FC: result += "✓"
            case 0xF0D8, 0xF0E8: result += "➢"
            case 0xF000...0xF0FF: result += "•"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let r = Int(round(rgb.redComponent * 255)), g = Int(round(rgb.greenComponent * 255)), b = Int(round(rgb.blueComponent * 255))
        if r < 24 && g < 24 && b < 24 { return nil }
        return String(format: "%02X%02X%02X", r, g, b)
    }

    /// Joins consecutive lines into a block when they look like one paragraph:
    /// same text size, close together vertically, and aligned on the left or the center.
    static func group(_ lines: [TextLine]) -> [TextBlock] {
        var blocks: [TextBlock] = []
        for line in lines {
            let size = line.fontSize
            if var block = blocks.last, let previous = block.lines.last, let first = block.lines.first,
               abs(previous.fontSize - size) < 0.6,
               (-0.3 * size...0.9 * size).contains(line.frame.minY - previous.frame.maxY),
               line.frame.minX < block.frame.maxX, line.frame.maxX > block.frame.minX,
               abs(line.frame.minX - first.frame.minX) < size || abs(line.frame.midX - previous.frame.midX) < size {
                block.lines.append(line)
                block.frame = block.frame.union(line.frame)
                blocks[blocks.count - 1] = block
            } else {
                blocks.append(TextBlock(lines: [line], frame: line.frame, lineSpacing: nil, centered: false))
            }
        }
        return blocks.map { block in
            var block = block
            guard block.lines.count > 1 else { return block }
            let tops = block.lines.map(\.frame.minY)
            block.lineSpacing = (tops.last! - tops.first!) / CGFloat(tops.count - 1)
            let lefts = block.lines.map(\.frame.minX), middles = block.lines.map(\.frame.midX)
            let size = block.lines[0].fontSize
            block.centered = (lefts.max()! - lefts.min()!) > size && (middles.max()! - middles.min()!) < size
            return block
        }
    }
}
