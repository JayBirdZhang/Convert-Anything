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
        guard let selection = page.selection(for: crop) else { return [] }

        var lines: [TextLine] = []
        for lineSelection in selection.selectionsByLine() {
            guard let attributed = lineSelection.attributedString else { continue }
            let bounds = lineSelection.bounds(for: page)
            let runs = styledRuns(attributed, lineHeight: bounds.height)
            guard !runs.isEmpty else { continue }
            lines.append(TextLine(
                frame: CGRect(x: bounds.minX - crop.minX, y: crop.maxY - bounds.maxY, width: bounds.width, height: bounds.height),
                runs: runs,
                fontSize: runs.map(\.size).max() ?? 12))
        }
        return lines
    }

    static func styledRuns(_ attributed: NSAttributedString, lineHeight: CGFloat) -> [TextRun] {
        var runs: [TextRun] = []
        let string = attributed.string as NSString
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
            let text = cleaned(string.substring(with: range))
            guard !text.isEmpty else { return }

            let font = attributes[.font] as? NSFont
            let name = (font?.fontName ?? "").lowercased()
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            var family = font?.familyName ?? "Helvetica"
            if let plus = family.firstIndex(of: "+") { family = String(family[family.index(after: plus)...]) }  // Embedded subsets: "ABCDEF+Calibri"

            let run = TextRun(
                text: text,
                font: family,
                size: font?.pointSize ?? lineHeight * 0.8,
                bold: traits.contains(.boldFontMask) || ["bold", "black", "heavy", "semibold"].contains { name.contains($0) },
                italic: traits.contains(.italicFontMask) || name.contains("italic") || name.contains("oblique"),
                color: (attributes[.foregroundColor] as? NSColor).flatMap(hex))
            if let last = runs.last, last.font == run.font, last.size == run.size, last.bold == run.bold,
               last.italic == run.italic, last.color == run.color {
                runs[runs.count - 1].text += text
            } else {
                runs.append(run)
            }
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
