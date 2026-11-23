import CoreGraphics
import Foundation
import PDFKit

/// Splits what an editable slide shows behind its text into separate pictures, so each photo, chart or
/// shape on the page can be moved on its own instead of the whole page being one picture.
///
/// TextlessPDF says where each of the page's drawing steps lands. Steps that cover most of the page
/// (a background color or full-page photo), and the full-width or full-height bands drawn before
/// anything else (a gradient drawn as strips, a header bar), make up the background. The rest are
/// grouped by distance: shapes that touch or nearly touch belong to the same thing (a chart's bars and
/// axes, a photo and its frame); two photos only when they overlap, so a tight grid of photos stays
/// apart. A long thin line (a divider or rule) only joins what it touches or crosses, so a divider next
/// to a photo stays its own piece while a chart's axes and gridlines stay with its bars. Groups whose boxes overlap are merged, so the groups never overlap, and each one is
/// cut from a drawing of everything but the background, on a clear background. Every step is drawn in
/// exactly one picture, so moving a picture never uncovers a copy of it.
nonisolated enum SlideLayers {
    struct Picture {
        var frame: CGRect       // Page points, origin at the top left of the visible page
        var image: CGImage?     // A picture of it, cut from the page's drawing (or the photo's own pixels)
        var jpeg: Data? = nil   // Or, for a photo drawn plainly, its own JPEG file
        var shape: TextlessPDF.Shape? = nil     // Or a simple shape, rebuilt as one (page points from the top left)
        var hasImage = false    // Shows a photo (rather than only shapes: a chart, a diagram)
    }

    struct Layers {
        var background: CGImage?    // Whole page; nil when it's plain white
        var pictures: [Picture]     // In drawing order
        var tables: [SlideTable] = []
    }

    private static let maxPictures = 40
    private static let maxSteps = 4000

    /// The page's background and pictures, or nil when there's nothing worth splitting (one thing or none,
    /// or too many small pieces), in which case the page stays one picture.
    static func split(_ page: PDFPage, scale: CGFloat) throws -> Layers? {
        guard let source = page.pageRef else { return nil }
        let crop = page.bounds(for: .cropBox)
        let pageArea = crop.width * crop.height
        let steps = try TextlessPDF.paintedAreas(on: source)
        let areas = steps.map { step -> CGRect? in
            let visible = step.area.intersection(crop)
            guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
            return CGRect(x: visible.minX - crop.minX, y: crop.maxY - visible.maxY, width: visible.width, height: visible.height)
        }

        var foreground: [Int] = []
        var bands: [Int] = []
        for (index, area) in areas.enumerated() {
            guard let area else { continue }
            if area.width * area.height >= pageArea * 0.75 {
                // Something covering the page goes behind everything drawn before it too, so nothing
                // that was under it ends up on top.
                foreground.removeAll()
                bands.removeAll()
            } else if foreground.isEmpty && (area.width >= crop.width * 0.9 || area.height >= crop.height * 0.9) {
                bands.append(index)
            } else {
                foreground.append(index)
            }
        }
        // Leading bands are a background only when together they fill most of the page (a gradient
        // drawn as strips); a lone rule or a striped table's first rows stay things of their own.
        let banded = bands.reduce(CGRect.null) { $0.union(areas[$1]!) }
        if !bands.isEmpty && banded.width * banded.height < pageArea * 0.5 { foreground = bands + foreground }
        guard !foreground.isEmpty, foreground.count <= maxSteps else { return nil }

        // Group nearby steps; when that leaves too many pieces (a map or a diagram drawn as many small
        // shapes), group more loosely.
        let longLine = max(crop.width, crop.height) * 0.1
        let parts = foreground.map { index -> Part in
            let area = areas[index]!
            return Part(area: area, isImage: steps[index].isImage,
                        isLine: min(area.width, area.height) <= 4 && max(area.width, area.height) >= longLine)
        }
        var gap = max(4, max(crop.width, crop.height) * 0.012)
        var groups = group(parts, gap: gap)
        for _ in 0..<3 where groups.frames.count > maxPictures {
            gap *= 2
            groups = group(parts, gap: gap)
        }
        guard groups.frames.count <= maxPictures else { return nil }

        var groupOf: [Int: Int] = [:]
        for (position, index) in foreground.enumerated() { groupOf[index] = groups.member[position] }

        // The background: everything that isn't in a group, with the page's markup (highlights, ink).
        // A page with nothing behind its pieces has none (a white slide).
        let hasBackground = areas.indices.contains { areas[$0] != nil && groupOf[$0] == nil } || TextlessPDF.hasMarkup(page)
        let documents = try TextlessPDF.documents(for: page, [(keeping: { groupOf[$0] != nil }, annotations: false)]
                                                     + (hasBackground ? [(keeping: { groupOf[$0] == nil }, annotations: true)] : []))
        guard let foregroundPage = documents[0].page(at: 0) else { return nil }
        let drawing = try ClearDrawing(foregroundPage, scale: scale)
        let background = try documents.dropFirst().first?.page(at: 0).map { try ImageConversion.render($0, scale: scale) }

        // One picture per group, in the order the groups first draw, trimmed to what it actually shows.
        // A group of shapes that draws a ruled grid becomes a real table instead.
        var order: [Int] = [], seen = Set<Int>()
        for index in foreground where seen.insert(groupOf[index]!).inserted { order.append(groupOf[index]!) }
        var withImages = Set<Int>()
        for (position, part) in parts.enumerated() where part.isImage { withImages.insert(groups.member[position]) }
        // Groups that are a single drawing step: a photo drawn plainly is embedded at its own resolution.
        var members = [Int](repeating: 0, count: groups.frames.count), only = [Int: Int]()
        for (position, index) in foreground.enumerated() { members[groups.member[position]] += 1; only[groups.member[position]] = index }
        let longSide = max(crop.width, crop.height) * scale
        var layers = Layers(background: background.flatMap { isWhite($0) ? nil : $0 }, pictures: [])
        for id in order {
            if members[id] == 1, let index = only[id], let name = steps[index].plainImage,
               crop.insetBy(dx: -0.01, dy: -0.01).contains(steps[index].area),
               let picture = nativePicture(name, placed: steps[index].area, on: source, crop: crop, scale: scale),
               drawing.showsAnything(in: picture.frame) {
                layers.pictures.append(picture)
                continue
            }
            // A lone line, box or circle becomes a real shape.
            if members[id] == 1, let index = only[id], var shape = steps[index].shape,
               crop.insetBy(dx: -0.01, dy: -0.01).contains(steps[index].area) {
                func flip(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - crop.minX, y: crop.maxY - point.y) }
                shape.bounds = CGRect(x: shape.bounds.minX - crop.minX, y: crop.maxY - shape.bounds.maxY, width: shape.bounds.width, height: shape.bounds.height)
                if case .line(let from, let to) = shape.kind { shape.kind = .line(flip(from), flip(to)) }
                if isDrawn(shape, in: drawing) {
                    layers.pictures.append(Picture(frame: groups.frames[id], image: nil, shape: shape))
                    continue
                }
            }
            let box = groups.frames[id].insetBy(dx: -1, dy: -1)
            guard let pixels = drawing.shownPixels(in: box) else { continue }
            if !withImages.contains(id), let table = SlideTable.detect(in: pixels, of: drawing, page: page) {
                layers.tables.append(table)
            } else if let image = drawing.image.cropping(to: pixels) {
                layers.pictures.append(Picture(frame: CGRect(x: pixels.minX / scale, y: pixels.minY / scale,
                                                             width: pixels.width / scale, height: pixels.height / scale),
                                               image: image, hasImage: withImages.contains(id)))
            }
        }
        guard !layers.pictures.isEmpty || !layers.tables.isEmpty else { return nil }
        return layers
    }

    /// Whether the drawing shows the shape in its colors where it should be: its fill in the middle, its
    /// outline at the middle of a line or of the top edge. Catches a shape in a hidden layer, and a color
    /// space that isn't the standard RGB the colors were taken as.
    private static func isDrawn(_ shape: TextlessPDF.Shape, in drawing: ClearDrawing) -> Bool {
        func shows(_ color: UInt32, at point: CGPoint) -> Bool {
            let (red, green, blue) = (Int(color >> 16), Int(color >> 8 & 255), Int(color & 255))
            return drawing.pixel(near: point) { r, g, b, alpha in
                alpha >= 48 && abs(r - red) <= 10 && abs(g - green) <= 10 && abs(b - blue) <= 10
            }
        }
        let box = shape.bounds
        if let fill = shape.fill, !shows(fill, at: CGPoint(x: box.midX, y: box.midY)) { return false }
        if let stroke = shape.stroke {
            let point: CGPoint
            if case .line(let from, let to) = shape.kind { point = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2) }
            else { point = CGPoint(x: box.midX, y: box.minY) }
            if !shows(stroke, at: point) { return false }
        }
        return true
    }

    /// A photo the page draws plainly (see `TextlessPDF.Step.plainImage`), taken from the PDF itself rather
    /// than from a picture of the page: sharper when it has more pixels than the page picture would give it,
    /// and when it's a JPEG, embedded as it is. Up to twice the page picture's sharpness, or 3000 pixels
    /// (whichever is more, so it's never less sharp than the page picture).
    private static func nativePicture(_ name: String, placed: CGRect, on page: CGPDFPage, crop: CGRect, scale: CGFloat) -> Picture? {
        let rendered = Int((max(placed.width, placed.height) * scale).rounded(.up))
        let maxPixels = max(min(3000, rendered * 2), rendered)
        guard rendered > 0, let native = TextlessPDF.image(named: name, on: page, maxPixels: maxPixels, minPixels: rendered + rendered / 20) else { return nil }
        let frame = CGRect(x: placed.minX - crop.minX, y: crop.maxY - placed.maxY, width: placed.width, height: placed.height)
        switch native {
        case .jpeg(let data): return Picture(frame: frame, image: nil, jpeg: data, hasImage: true)
        case .image(let image): return Picture(frame: frame, image: image, hasImage: true)
        }
    }

    /// Which group each area belongs to (an index into `frames`), and each group's box. Areas closer than
    /// `gap` share a group, unless both are images, which only share one when they overlap. Groups whose
    /// boxes overlap are then merged, so no two boxes (each grown by a point when cut out) overlap.
    private struct Part {
        var area: CGRect
        var isImage: Bool
        var isLine: Bool        // Long and thin: a divider, a rule, an axis
    }

    private static func group(_ parts: [Part], gap: CGFloat) -> (member: [Int], frames: [CGRect]) {
        let areas = parts.map(\.area)
        var parent = Array(areas.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index { parent[index] = parent[parent[index]]; index = parent[index] }
            return index
        }
        let padded = areas.map { $0.insetBy(dx: -gap / 2, dy: -gap / 2) }
        // Sweep left to right: only areas whose padded spans overlap horizontally can touch.
        let byLeft = areas.indices.sorted { padded[$0].minX < padded[$1].minX }
        for (position, first) in byLeft.enumerated() {
            for second in byLeft[(position + 1)...] {
                guard padded[second].minX <= padded[first].maxX else { break }
                let touching: Bool
                if parts[first].isImage && parts[second].isImage {
                    let overlap = areas[first].intersection(areas[second])
                    touching = overlap.width * overlap.height > 1
                } else if parts[first].isLine || parts[second].isLine {
                    touching = areas[first].insetBy(dx: -1, dy: -1).intersects(areas[second].insetBy(dx: -1, dy: -1))
                } else {
                    touching = padded[first].intersects(padded[second])
                }
                if touching { parent[root(second)] = root(first) }
            }
        }
        // Merge groups until no two boxes overlap (with a point to spare on each side). A merged box can
        // reach new neighbors, so passes repeat until one merges nothing.
        var roots: [Int] = [], frames: [CGRect] = []
        var slot: [Int: Int] = [:]
        for index in areas.indices {
            let group = root(index)
            if let existing = slot[group] { frames[existing] = frames[existing].union(areas[index]) }
            else { slot[group] = roots.count; roots.append(group); frames.append(areas[index]) }
        }
        var merged = true
        while merged {
            merged = false
            var a = 0
            while a < roots.count {
                var b = a + 1
                while b < roots.count {
                    if frames[a].insetBy(dx: -1.5, dy: -1.5).intersects(frames[b].insetBy(dx: -1.5, dy: -1.5)) {
                        frames[a] = frames[a].union(frames[b])
                        parent[roots[b]] = roots[a]
                        roots.remove(at: b); frames.remove(at: b)
                        merged = true
                    } else {
                        b += 1
                    }
                }
                a += 1
            }
        }
        let ids = Dictionary(uniqueKeysWithValues: roots.enumerated().map { ($1, $0) })
        return (areas.indices.map { ids[root($0)]! }, frames)
    }

    private static func isWhite(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              image.bitsPerPixel == 32, image.bitsPerComponent == 8 else { return false }
        // noneSkipLast RGBX: every color byte at 255. The padding byte, and any padding at the end of a
        // row, doesn't matter.
        for y in 0..<image.height {
            let row = bytes + y * image.bytesPerRow
            for x in 0..<image.width where row[x * 4] & row[x * 4 + 1] & row[x * 4 + 2] != 255 { return false }
        }
        return true
    }
}

/// A page drawn on a clear background, so what each group shows can be found from its pixels' alpha.
nonisolated final class ClearDrawing {
    let image: CGImage
    let pixels: UnsafePointer<UInt8>   // RGBA, premultiplied, rows from the top; lives as long as `context`
    private let context: CGContext
    let width: Int, height: Int
    let scale: CGFloat

    init(_ page: PDFPage, scale: CGFloat) throws {
        let size = page.bounds(for: .cropBox).size
        width = Int(size.width * scale)
        height = Int(size.height * scale)
        self.scale = scale
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.failed("Couldn't render this PDF.")
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage(), let data = context.data else { throw ConversionError.failed("Couldn't render this PDF.") }
        self.image = image
        self.context = context
        // Rows run top to bottom in the bitmap's memory.
        pixels = UnsafePointer(data.bindMemory(to: UInt8.self, capacity: width * height * 4))
    }

    /// Whether the drawing shows something at a few points spread over `box` (page points from the top
    /// left): false for something that's drawn but hidden (in a layer that's off).
    func showsAnything(in box: CGRect) -> Bool {
        [(0.5, 0.5), (0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].contains { fx, fy in
            pixel(near: CGPoint(x: box.minX + box.width * fx, y: box.minY + box.height * fy)) { _, _, _, alpha in alpha > 0 }
        }
    }

    /// Whether a pixel within about a pixel of `point` (page points from the top left; a page with a
    /// fractional height is drawn up to a pixel higher) passes `test`, given its color (not premultiplied)
    /// and alpha.
    func pixel(near point: CGPoint, _ test: (_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int) -> Bool) -> Bool {
        let x = Int(point.x * scale), y = Int(point.y * scale)
        let top = max(0, y - 1), bottom = min(height - 1, y + 1), left = max(0, x - 1), right = min(width - 1, x + 1)
        guard top <= bottom, left <= right else { return false }
        for row in top...bottom {
            for column in left...right {
                let index = (row * width + column) * 4
                let alpha = Int(pixels[index + 3])
                func plain(_ value: UInt8) -> Int { alpha == 0 ? 0 : min(255, (Int(value) * 255 + alpha / 2) / alpha) }
                if test(plain(pixels[index]), plain(pixels[index + 1]), plain(pixels[index + 2]), alpha) { return true }
            }
        }
        return false
    }

    /// The smallest pixel rectangle inside `box` (page points, from the top left) holding every pixel that
    /// shows something, or nil if none does.
    func shownPixels(in box: CGRect) -> CGRect? {
        let left = max(0, Int((box.minX * scale).rounded(.down))), right = min(width, Int((box.maxX * scale).rounded(.up)))
        let top = max(0, Int((box.minY * scale).rounded(.down))), bottom = min(height, Int((box.maxY * scale).rounded(.up)))
        guard left < right, top < bottom else { return nil }
        var minX = right, maxX = left - 1, minY = bottom, maxY = top - 1
        for y in top..<bottom {
            let row = y * width
            for x in left..<right where pixels[(row + x) * 4 + 3] > 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
