import CoreGraphics
import Foundation
import ImageIO

/// Writes animated GIFs one frame at a time, straight to a file.
///
/// Colors come from a 255-color palette made from the picture itself (median cut, polished with k-means).
/// A palette is kept for as long as it still fits the frames, and rebuilt from the current frame when the
/// picture changes too much for it, as at a scene cut.
///
/// Dithering is ordered, not error diffusion: a color that falls between two palette colors is drawn as a
/// mix of the two, and which one a pixel gets depends only on its color and a fixed threshold at its position.
/// So still areas come out identical in every frame (no shimmer), and only pixels whose source color really
/// changed have to be redrawn. Everything else is left transparent, which is what keeps GIFs of video small.
nonisolated final class GIFEncoder {
    let width: Int, height: Int
    private let noise: Int                  // Changes up to this (|Δr|+|Δg|+|Δb|) are treated as video noise
    private let keepsTransparency: Bool
    private var handle: FileHandle?
    private let context: CGContext          // Draws each frame into `pixels`
    private let pixels: UnsafeMutablePointer<UInt8>   // RGBA

    private let reference: UnsafeMutableBufferPointer<UInt8>   // The source color each pixel had when last drawn (RGBA)
    private let screen: UnsafeMutableBufferPointer<UInt32>     // The color currently shown at each pixel
    private let indices: UnsafeMutableBufferPointer<UInt8>     // The frame being encoded
    private var hasDrawn = false
    private var repairing = false           // A new palette just came: redraw still pixels the old one got badly wrong

    // The palette: r, g, b and the three packed into one number, for each color.
    private let palette = UnsafeMutableBufferPointer<Int>.allocate(capacity: 256 * 4)
    private var paletteCount = 0
    private var palettesBuilt = 0
    private var paletteFit = 0.0            // The palette's error on the frame it was made from
    private var paletteMisses = 0           // How many pixels of that frame it had no close color for
    private var neighbors: [[Int]] = []     // For each color, the nearby colors it can be mixed with
    // For each color (6 bits per channel), the two palette colors to dither between, worked out when first needed.
    private let pairs = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: 1 << 18)
    private static let unknownPair: UInt16 = 0xFFFF

    // The frame's colors in 64×64×64 bins: pixel count and r, g, b sums (all weighted, see `countColors`).
    private let histogram = UnsafeMutableBufferPointer<Int>.allocate(capacity: (1 << 18) * 4)
    private var occupied: [Int] = []
    private var counted = 0

    private let lzwTable = UnsafeMutableBufferPointer<Int16>.allocate(capacity: 4096 * 256)   // (prefix code, byte) → code
    private var lzwUsed: [Int] = []
    private var codes: [UInt8] = []

    private var output: [UInt8] = []        // Written to the file in large pieces
    private var pending: [UInt8] = []       // The last frame, held back until its delay is known
    private var elapsed = 0.0               // Seconds of video added so far
    private var writtenCentiseconds = 0
    private var frames = 0
    private static let transparent = 255

    /// `noise` is how much a pixel's color may drift before it's redrawn. With `keepsTransparency`, pixels less
    /// than half opaque stay transparent; every frame is then stored whole and cleared before the next.
    init(url: URL, width: Int, height: Int, noise: Int, keepsTransparency: Bool = false) throws {
        let alpha: CGImageAlphaInfo = keepsTransparency ? .premultipliedLast : .noneSkipLast
        guard width > 0, height > 0, width < 65_536, height < 65_536,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue),
              let data = context.data else {
            throw ConversionError.failed("This picture is too big for a GIF.")
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        self.width = width
        self.height = height
        self.noise = noise
        self.keepsTransparency = keepsTransparency
        self.context = context
        context.interpolationQuality = .high
        pixels = data.assumingMemoryBound(to: UInt8.self)
        reference = .allocate(capacity: width * height * 4)
        screen = .allocate(capacity: width * height)
        screen.initialize(repeating: .max)      // Not a color: nothing is on screen yet
        indices = .allocate(capacity: width * height)
        histogram.initialize(repeating: 0)
        lzwTable.initialize(repeating: -1)
    }

    /// Dropping an encoder without calling `finish` (after an error or cancellation) closes the half-written file.
    deinit {
        try? handle?.close()
        reference.deallocate()
        screen.deallocate()
        indices.deallocate()
        palette.deallocate()
        pairs.deallocate()
        histogram.deallocate()
        lzwTable.deallocate()
    }

    /// Adds a frame shown for `duration` seconds.
    func addFrame(_ image: CGImage, duration: Double) throws {
        let start = elapsed
        elapsed += duration
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if keepsTransparency {
            context.clear(rect)
        } else {
            context.setFillColor(CGColor(gray: 1, alpha: 1))   // Shows through where a picture has transparent parts
            context.fill(rect)
        }
        context.draw(image, in: rect)
        if keepsTransparency { separateTransparency() }

        // A new palette when this frame's colors have drifted well away from the ones it was made for, or when
        // something small but colorful appears that it has nothing close to (a green icon would turn gray).
        countColors()
        if paletteCount == 0 {
            buildPalette()
        } else {
            let fit = paletteError()
            if fit.error > 1.6 * paletteFit + 8 || fit.misses > 2 * paletteMisses + Self.minimumMisses { buildPalette() }
        }

        // A frame where nothing changed isn't stored; the previous one just stays up longer. Transparent
        // pictures can't do that, since each frame is cleared away before the next.
        let changed = drawChanges()
        repairing = false
        if changed == nil && !pending.isEmpty && !keepsTransparency { return }
        try flush(until: start)
        encode(changed ?? (0, 0, 0, 0))
    }

    /// Shows the last frame for longer (when a frame of the video couldn't be read).
    func extend(by duration: Double) {
        elapsed += duration
    }

    func finish() throws {
        guard frames > 0 else { throw ConversionError.failed("There were no frames to save.") }
        try flush(until: elapsed)
        output.append(0x3B)
        try handle?.write(contentsOf: output)
        try handle?.close()
        handle = nil
    }

    // MARK: Drawing

    /// GIF pixels are either opaque or transparent. Pixels at least half opaque keep their full color
    /// (undoing the premultiplied alpha); the rest are marked transparent with alpha 0.
    private func separateTransparency() {
        for p in stride(from: 0, to: width * height * 4, by: 4) {
            let alpha = Int(pixels[p + 3])
            if alpha < 128 {
                pixels[p + 3] = 0
            } else if alpha < 255 {
                for k in 0..<3 { pixels[p + k] = UInt8(min(255, Int(pixels[p + k]) * 255 / alpha)) }
            }
        }
    }

    /// Picks palette colors for every pixel that changed, and returns the rectangle around them.
    /// Unchanged pixels, and pixels whose new color is the one already on screen, are left transparent.
    private func drawChanges() -> (left: Int, top: Int, right: Int, bottom: Int)? {
        let everything = keepsTransparency || !hasDrawn
        hasDrawn = true
        var left = width, top = -1, right = -1, bottom = -1
        Self.thresholds.withUnsafeBufferPointer { thresholds in
            for y in 0..<height {
                let thresholdRow = (y % Self.thresholdSize) * Self.thresholdSize
                var rowLeft = -1, rowRight = -1
                for x in 0..<width {
                    let i = y * width + x, p = i * 4
                    indices[i] = UInt8(Self.transparent)
                    let r = Int(pixels[p]), g = Int(pixels[p + 1]), b = Int(pixels[p + 2])
                    if keepsTransparency {
                        if pixels[p + 3] == 0 { continue }
                    } else if !everything {
                        let change = abs(r - Int(reference[p])) + abs(g - Int(reference[p + 1])) + abs(b - Int(reference[p + 2]))
                        // Still pixels keep what's on screen, unless a new palette came because the old one
                        // drew them in a color far from their own (a green icon left gray).
                        if change <= noise && !(repairing && isMiss(shown: screen[i], p)) { continue }
                    }
                    reference[p] = pixels[p]; reference[p + 1] = pixels[p + 1]; reference[p + 2] = pixels[p + 2]

                    // Mix the pair's two colors in the right proportion: the second one wins where its share
                    // (how far along the line between them the color is) is above this pixel's threshold.
                    let pair = pair(r, g, b)
                    var index = pair & 0xFF
                    let other = pair >> 8
                    if other != index {
                        let a = index * 4, o = other * 4
                        let dr = palette[o] - palette[a], dg = palette[o + 1] - palette[a + 1], db = palette[o + 2] - palette[a + 2]
                        let along = 2 * (r - palette[a]) * dr + 4 * (g - palette[a + 1]) * dg + 3 * (b - palette[a + 2]) * db
                        let length = 2 * dr * dr + 4 * dg * dg + 3 * db * db
                        if along * Self.thresholdScale > thresholds[thresholdRow + x % Self.thresholdSize] * length { index = other }
                    }
                    let color = UInt32(palette[index * 4 + 3])
                    if color == screen[i] && !keepsTransparency { continue }
                    screen[i] = color
                    indices[i] = UInt8(index)
                    if rowLeft < 0 { rowLeft = x }
                    rowRight = x
                }
                if rowRight >= 0 {
                    left = min(left, rowLeft); right = max(right, rowRight)
                    if top < 0 { top = y }
                    bottom = y
                }
            }
        }
        return right >= 0 ? (left, top, right, bottom) : nil
    }

    /// Whether the color shown at a pixel is a miss for the color it should be. Dithered pixels show one of
    /// two neighbors at most about 40 levels apart, so they don't count.
    private func isMiss(shown: UInt32, _ p: Int) -> Bool {
        guard shown != .max else { return false }
        let dr = Int(shown >> 16 & 0xFF) - Int(reference[p]), dg = Int(shown >> 8 & 0xFF) - Int(reference[p + 1])
        let db = Int(shown & 0xFF) - Int(reference[p + 2])
        return 2 * dr * dr + 4 * dg * dg + 3 * db * db > Self.missDistance
    }

    /// The palette colors to dither a color between: the nearest one, and the neighbor of it that mixes best
    /// with it into the color. Packed as nearest | neighbor << 8.
    private func pair(_ r: Int, _ g: Int, _ b: Int) -> Int {
        let key = (r >> 2) << 12 | (g >> 2) << 6 | b >> 2
        if pairs[key] != Self.unknownPair { return Int(pairs[key]) }
        // Worked out once for the middle of the 6-bit cell; the mix itself uses each pixel's exact color.
        let cr = (r >> 2) << 2 | 2, cg = (g >> 2) << 2 | 2, cb = (b >> 2) << 2 | 2
        var nearest = 0, nearestDistance = Int.max
        for i in 0..<paletteCount {
            let d = distance(cr, cg, cb, i)
            if d < nearestDistance { nearestDistance = d; nearest = i }
        }
        // A neighbor's score is how far the best mix with it still is from the color, plus a penalty for the
        // graininess of the mix (largest for an even mix of distant colors), which favors close neighbors.
        var other = nearest, bestCost = Double.infinity
        let n = nearest * 4
        for j in neighbors[nearest] {
            let o = j * 4
            let dr = Double(palette[o] - palette[n]), dg = Double(palette[o + 1] - palette[n + 1]), db = Double(palette[o + 2] - palette[n + 2])
            let pr = Double(cr - palette[n]), pg = Double(cg - palette[n + 1]), pb = Double(cb - palette[n + 2])
            let length = 2 * dr * dr + 4 * dg * dg + 3 * db * db
            let t = min(1, max(0, (2 * pr * dr + 4 * pg * dg + 3 * pb * db) / length))
            let er = pr - t * dr, eg = pg - t * dg, eb = pb - t * db
            let cost = 2 * er * er + 4 * eg * eg + 3 * eb * eb + t * (1 - t) * length / 8
            if cost < bestCost { bestCost = cost; other = j }
        }
        let pair = nearest | other << 8
        pairs[key] = UInt16(pair)
        return pair
    }

    /// Squared distance to a palette color, weighted for how sensitive eyes are to each channel.
    private func distance(_ r: Int, _ g: Int, _ b: Int, _ index: Int) -> Int {
        let dr = r - palette[index * 4], dg = g - palette[index * 4 + 1], db = b - palette[index * 4 + 2]
        return 2 * dr * dr + 4 * dg * dg + 3 * db * db
    }

    // MARK: Thresholds

    private static let thresholdSize = 64
    private static let thresholdScale = 2 * thresholdSize * thresholdSize

    /// A 64×64 tile of blue noise made with the void-and-cluster method: each position's rank in an order that
    /// spreads points as evenly as possible, stored as 2·rank + 1 out of `thresholdScale`. Blue noise dithers
    /// into a fine, even grain, where a Bayer matrix shows a crosshatch (for no real saving in file size).
    private static let thresholds: [Int] = {
        let size = thresholdSize, count = size * size, mask = size - 1
        // How much a point crowds the positions around it: a Gaussian that wraps around the edges.
        var kernel = [Double](repeating: 0, count: count)
        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(min(x, size - x)), dy = Double(min(y, size - y))
                kernel[y * size + x] = exp(-(dx * dx + dy * dy) / (2 * 1.5 * 1.5))
            }
        }
        var energy = [Double](repeating: 0, count: count)
        var on = [Bool](repeating: false, count: count)
        func set(_ i: Int, _ value: Bool) {
            on[i] = value
            let sign = value ? 1.0 : -1.0, ix = i % size, iy = i / size
            for y in 0..<size {
                let row = ((y - iy) & mask) * size
                for x in 0..<size { energy[y * size + x] += sign * kernel[row + ((x - ix) & mask)] }
            }
        }
        func tightestCluster() -> Int {
            var best = 0, most = -Double.infinity
            for i in 0..<count where on[i] && energy[i] > most { most = energy[i]; best = i }
            return best
        }
        func largestVoid() -> Int {
            var best = 0, least = Double.infinity
            for i in 0..<count where !on[i] && energy[i] < least { least = energy[i]; best = i }
            return best
        }

        // Scatter a tenth of the points (with a fixed seed, so every GIF gets the same tile), then move points
        // from the most crowded spot to the emptiest until that changes nothing.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        var initial = 0
        while initial < count / 10 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let i = Int(seed >> 33) % count
            if !on[i] { set(i, true); initial += 1 }
        }
        while true {
            let cluster = tightestCluster()
            set(cluster, false)
            let void = largestVoid()
            set(void, true)
            if void == cluster { break }
        }
        // Rank those points by taking them away most crowded first, then fill the emptiest spots one by one.
        var rank = [Int](repeating: 0, count: count)
        let startOn = on, startEnergy = energy
        for r in stride(from: initial - 1, through: 0, by: -1) {
            let cluster = tightestCluster()
            set(cluster, false)
            rank[cluster] = r
        }
        on = startOn
        energy = startEnergy
        for r in initial..<count {
            let void = largestVoid()
            set(void, true)
            rank[void] = r
        }
        return rank.map { 2 * $0 + 1 }
    }()

    // MARK: Palette

    /// Sorts the frame's colors into bins. Pixels in smooth areas count 8 times: dithering shows most there,
    /// so they deserve more (and closer) palette colors than busy texture does.
    private func countColors() {
        for bin in occupied { for k in 0..<4 { histogram[bin * 4 + k] = 0 } }
        occupied.removeAll(keepingCapacity: true)
        let end = width * height * 4, below = width * 4
        for p in stride(from: 0, to: end, by: 4) {
            if keepsTransparency && pixels[p + 3] == 0 { continue }
            let r = Int(pixels[p]), g = Int(pixels[p + 1]), b = Int(pixels[p + 2])
            let right = p + 4 < end ? p + 4 : p, down = p + below < end ? p + below : p
            let texture = abs(r - Int(pixels[right])) + abs(g - Int(pixels[right + 1])) + abs(b - Int(pixels[right + 2]))
                + abs(r - Int(pixels[down])) + abs(g - Int(pixels[down + 1])) + abs(b - Int(pixels[down + 2]))
            let weight = texture <= 12 ? 8 : 1
            let bin = ((r >> 2) << 12 | (g >> 2) << 6 | b >> 2) * 4
            if histogram[bin] == 0 { occupied.append(bin / 4) }
            histogram[bin] += weight
            histogram[bin + 1] += r * weight; histogram[bin + 2] += g * weight; histogram[bin + 3] += b * weight
        }
        counted = occupied.reduce(0) { $0 + histogram[$1 * 4] }
    }

    /// Colors further than this from every palette color (about 40 levels per channel, so a green icon drawn
    /// in gray) count as misses. Video noise and gradients stay well within it.
    private static let missDistance = 9 * 40 * 40
    /// Misses on this many pixels (smooth ones count 8 times) make a new palette worthwhile: a small icon's worth.
    private static let minimumMisses = 150

    /// How far the frame's colors are from the palette, on average, and how many pixels have no close color.
    private func paletteError() -> (error: Double, misses: Int) {
        guard counted > 0 else { return (0, 0) }
        var total = 0, misses = 0
        for bin in occupied {
            let n = histogram[bin * 4]
            let r = histogram[bin * 4 + 1] / n, g = histogram[bin * 4 + 2] / n, b = histogram[bin * 4 + 3] / n
            let d = distance(r, g, b, pair(r, g, b) & 0xFF)
            total += n * d
            if d > Self.missDistance { misses += n }
        }
        return (Double(total) / Double(counted), misses)
    }

    /// Up to 255 colors for the frame: median cut (splitting the box with the most error, along its most varied
    /// channel, at the mean), then two rounds of k-means to settle the colors where the pixels are.
    private func buildPalette() {
        let weights = SIMD3<Double>(2, 4, 3)
        var points = occupied.map { bin in
            let n = Double(histogram[bin * 4])
            return (count: n, color: SIMD3<Double>(Double(histogram[bin * 4 + 1]), Double(histogram[bin * 4 + 2]),
                                                   Double(histogram[bin * 4 + 3])) / n)
        }
        if points.isEmpty { points = [(1, SIMD3(0, 0, 0))] }   // A fully transparent picture

        struct Box { var start, end: Int; var error: Double; var axis: Int; var mean: SIMD3<Double> }
        func box(_ start: Int, _ end: Int) -> Box {
            var n = 0.0, sum = SIMD3<Double>(), squares = SIMD3<Double>()
            for point in points[start..<end] {
                n += point.count
                sum += point.count * point.color
                squares += point.count * point.color * point.color
            }
            let spread = weights * (squares - sum * sum / n)
            let axis = spread.x >= spread.y && spread.x >= spread.z ? 0 : spread.y >= spread.z ? 1 : 2
            return Box(start: start, end: end, error: end - start > 1 ? spread.sum() : 0, axis: axis, mean: sum / n)
        }
        var boxes = [box(0, points.count)]
        while boxes.count < 255 {
            guard let worst = boxes.indices.max(by: { boxes[$0].error < boxes[$1].error }), boxes[worst].error > 0 else { break }
            let split = boxes[worst]
            let middle = points[split.start..<split.end].partition { $0.color[split.axis] >= split.mean[split.axis] }
            if middle == split.start || middle == split.end {   // Rounding: nothing to split after all
                boxes[worst].error = 0
                continue
            }
            boxes[worst] = box(split.start, middle)
            boxes.append(box(middle, split.end))
        }

        var centers = boxes.map(\.mean)
        for _ in 0..<2 {
            var sums = [SIMD3<Double>](repeating: .zero, count: centers.count)
            var totals = [Double](repeating: 0, count: centers.count)
            for point in points {
                var nearest = 0, nearestDistance = Double.infinity
                for (j, center) in centers.enumerated() {
                    let d = point.color - center
                    let distance = (weights * d * d).sum()
                    if distance < nearestDistance { nearestDistance = distance; nearest = j }
                }
                sums[nearest] += point.count * point.color
                totals[nearest] += point.count
            }
            for j in centers.indices where totals[j] > 0 { centers[j] = sums[j] / totals[j] }
        }

        paletteCount = centers.count
        for (i, center) in centers.enumerated() {
            let r = Int(center.x.rounded()), g = Int(center.y.rounded()), b = Int(center.z.rounded())
            palette[i * 4] = r; palette[i * 4 + 1] = g; palette[i * 4 + 2] = b
            palette[i * 4 + 3] = r << 16 | g << 8 | b
        }
        // Each color's 8 closest others; colors further apart than about 40 levels per channel are never mixed,
        // since their dots would look like salt and pepper.
        neighbors = (0..<paletteCount).map { i in
            let close = (0..<paletteCount).compactMap { j -> (j: Int, distance: Int)? in
                let d = distance(palette[j * 4], palette[j * 4 + 1], palette[j * 4 + 2], i)
                return j != i && d > 0 && d <= 9 * 40 * 40 ? (j, d) : nil
            }
            return close.sorted { $0.distance < $1.distance }.prefix(8).map(\.j)
        }
        pairs.initialize(repeating: Self.unknownPair)
        palettesBuilt += 1
        repairing = hasDrawn
        (paletteFit, paletteMisses) = paletteError()
    }

    // MARK: File

    /// Writes the held-back frame, now that it's known to last until `time`.
    private func flush(until time: Double) throws {
        guard !pending.isEmpty else { return }
        // Delays are in hundredths of a second; carry the rounding so the total stays in sync with the video.
        let delay = max(2, Int((time * 100).rounded()) - writtenCentiseconds)
        writtenCentiseconds += delay
        pending[4] = UInt8(delay & 0xFF)
        pending[5] = UInt8(delay >> 8 & 0xFF)
        output += pending
        pending.removeAll(keepingCapacity: true)
        if output.count > 1 << 20 {
            try handle?.write(contentsOf: output)
            output.removeAll(keepingCapacity: true)
        }
    }

    /// Compresses the frame into `pending`, cropped to `area`.
    private func encode(_ area: (left: Int, top: Int, right: Int, bottom: Int)) {
        if frames == 0 { writeHeader() }
        frames += 1
        // Graphic control: the delay (filled in by `flush`), index 255 transparent, and either keep the frame
        // for the next one to draw over or, for transparent pictures, clear it away.
        pending += [0x21, 0xF9, 0x04, keepsTransparency ? 0x09 : 0x05, 0, 0, UInt8(Self.transparent), 0]
        pending.append(0x2C)
        for value in [area.left, area.top, area.right - area.left + 1, area.bottom - area.top + 1] { appendShort(value, to: &pending) }
        // Frames drawn with a later palette than the first carry it along; the rest use the global one.
        if palettesBuilt > 1 {
            pending.append(0x87)
            appendPalette(to: &pending)
        } else {
            pending.append(0)
        }
        pending.append(8)                   // LZW minimum code size
        lzw(area)
        var index = 0
        while index < codes.count {
            let count = min(255, codes.count - index)
            pending.append(UInt8(count))
            pending += codes[index..<index + count]
            index += count
        }
        pending.append(0)
    }

    private func writeHeader() {
        output += Array("GIF89a".utf8)
        appendShort(width, to: &output)
        appendShort(height, to: &output)
        output += [0xF7, 0, 0]              // Global color table of 256 colors; background 0; square pixels
        appendPalette(to: &output)
        // Loop forever (NETSCAPE2.0 application extension).
        output += [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [0x03, 0x01, 0x00, 0x00, 0x00]
    }

    private func appendPalette(to bytes: inout [UInt8]) {
        for i in 0..<256 {
            if i < paletteCount {
                bytes += [UInt8(palette[i * 4]), UInt8(palette[i * 4 + 1]), UInt8(palette[i * 4 + 2])]
            } else {
                bytes += [0, 0, 0]
            }
        }
    }

    private func appendShort(_ value: Int, to bytes: inout [UInt8]) {
        bytes += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]
    }

    /// Compresses the indices inside `area` into `codes`.
    private func lzw(_ area: (left: Int, top: Int, right: Int, bottom: Int)) {
        let clearCode = 256, endCode = 257
        for key in lzwUsed { lzwTable[key] = -1 }
        lzwUsed.removeAll(keepingCapacity: true)
        codes.removeAll(keepingCapacity: true)
        var nextCode = 258, codeSize = 9
        var buffer = 0, bits = 0
        func emit(_ code: Int) {
            buffer |= code << bits
            bits += codeSize
            while bits >= 8 { codes.append(UInt8(buffer & 0xFF)); buffer >>= 8; bits -= 8 }
        }
        emit(clearCode)
        var prefix = -1
        for y in area.top...area.bottom {
            for x in area.left...area.right {
                let pixel = Int(indices[y * width + x])
                if prefix < 0 { prefix = pixel; continue }
                let key = prefix << 8 | pixel
                if lzwTable[key] >= 0 {
                    prefix = Int(lzwTable[key])
                    continue
                }
                emit(prefix)
                if nextCode < 4096 {
                    lzwTable[key] = Int16(nextCode)
                    lzwUsed.append(key)
                    if nextCode == 1 << codeSize && codeSize < 12 { codeSize += 1 }
                    nextCode += 1
                } else {
                    emit(clearCode)
                    for key in lzwUsed { lzwTable[key] = -1 }
                    lzwUsed.removeAll(keepingCapacity: true)
                    nextCode = 258
                    codeSize = 9
                }
                prefix = pixel
            }
        }
        emit(prefix)
        emit(endCode)
        if bits > 0 { codes.append(UInt8(buffer & 0xFF)) }
    }
}

// MARK: - Pictures

nonisolated extension GIFEncoder {
    /// A picture as a GIF. Animated pictures (GIF, animated PNG and WebP, HEIC sequences) keep every frame
    /// and its timing, and transparent parts stay transparent.
    static func write(imageAt input: URL, to output: URL, quality: Quality) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ConversionError.failed("Couldn't read this image.")
        }
        let count = CGImageSourceGetCount(source)
        guard count > 1, frameDelay(source, 0) != nil else {
            let image = try ImageConversion.load(input, quality: quality)   // With its EXIF rotation applied
            let encoder = try GIFEncoder(url: output, width: image.width, height: image.height, noise: 0,
                                         keepsTransparency: hasAlpha(image))
            try encoder.addFrame(image, duration: 0)
            try encoder.finish()
            return
        }

        guard let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ConversionError.failed("Couldn't decode this image.") }
        var width = first.width, height = first.height
        if let side = quality.maxImageSide, max(width, height) > side {
            let scale = Double(side) / Double(max(width, height))
            width = max(1, Int((Double(width) * scale).rounded()))
            height = max(1, Int((Double(height) * scale).rounded()))
        }
        let encoder = try GIFEncoder(url: output, width: width, height: height, noise: quality.gifSettings.noise,
                                     keepsTransparency: hasAlpha(first))
        for index in 0..<count {
            let delay = frameDelay(source, index) ?? 0.1
            if let image = index == 0 ? first : CGImageSourceCreateImageAtIndex(source, index, nil) {
                try encoder.addFrame(image, duration: delay)
            } else {
                encoder.extend(by: delay)
            }
        }
        try encoder.finish()
    }

    /// How long a frame of an animated picture is shown, or nil when the picture isn't animated.
    static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let keys: [(dictionary: CFString, unclamped: CFString, delay: CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        for key in keys {
            guard let frame = properties[key.dictionary] as? [CFString: Any],
                  let value = (frame[key.unclamped] as? Double) ?? (frame[key.delay] as? Double) else { continue }
            return value < 0.02 ? 0.1 : value   // Browsers treat tiny delays as 0.1 s too
        }
        return nil
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
    }
}
