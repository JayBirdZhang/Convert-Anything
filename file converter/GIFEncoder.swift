import CoreGraphics
import Foundation

/// Writes animated GIFs with one palette chosen for the whole video and dithered frames, the way
/// ffmpeg's palettegen/paletteuse does. macOS's own GIF writer picks colors per frame without
/// dithering, which leaves banding in gradients and blotchy skin tones.
nonisolated final class GIFEncoder {
    let width: Int, height: Int
    private let palette: [(r: Int, g: Int, b: Int)]
    private var data = Data()
    private var lookup = [Int16](repeating: -1, count: 64 * 64 * 64)   // 6 bits per channel → palette index
    private var elapsed = 0.0          // seconds written so far
    private var elapsedCentiseconds = 0
    private var previousIndices: [UInt8]?   // What's on screen after the last frame
    private var reference: [UInt8]?         // The source color each pixel had when it was last drawn
    private static let transparent: UInt8 = 255

    /// `palette` should have at most 255 colors; index 255 is kept for "unchanged since the last frame".
    init(width: Int, height: Int, palette: [(r: Int, g: Int, b: Int)]) {
        self.width = width
        self.height = height
        var colors = Array(palette.prefix(255))
        while colors.count < 256 { colors.append((0, 0, 0)) }
        self.palette = colors

        data.append(contentsOf: Array("GIF89a".utf8))
        appendShort(width)
        appendShort(height)
        data.append(0xF7)            // Global color table, 8 bits per color, 256 entries
        data.append(0)               // Background color index
        data.append(0)               // Square pixels
        for color in self.palette { data.append(contentsOf: [UInt8(color.r), UInt8(color.g), UInt8(color.b)]) }
        // Loop forever (NETSCAPE2.0 application extension).
        data.append(contentsOf: [0x21, 0xFF, 0x0B])
        data.append(contentsOf: Array("NETSCAPE2.0".utf8))
        data.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])
    }

    /// Adds one frame, shown for `duration` seconds. `rgba` is width × height × 4 bytes.
    /// Only the part that changed is stored: pixels that look the same as before are left transparent,
    /// and the frame is cropped to the changed area. That keeps files small and stops still areas from shimmering.
    func addFrame(rgba: [UInt8], duration: Double) {
        // Delays are in hundredths of a second; carry the rounding so the total stays in sync with the video.
        elapsed += duration
        let delay = max(2, Int((elapsed * 100).rounded()) - elapsedCentiseconds)
        elapsedCentiseconds += delay

        var (indices, changed) = dither(rgba)
        var left = 0, top = 0, right = width - 1, bottom = height - 1
        if let previous = previousIndices {
            // The rectangle around everything that changed.
            left = width; top = height; right = -1; bottom = -1
            for y in 0..<height {
                for x in 0..<width where changed[y * width + x] {
                    left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                }
            }
            if right < 0 { left = 0; top = 0; right = 0; bottom = 0 }   // Nothing changed: one transparent pixel
            for i in indices.indices where !changed[i] { indices[i] = Self.transparent }
            var screen = previous
            for i in indices.indices where changed[i] { screen[i] = indices[i] }
            previousIndices = screen
        } else {
            previousIndices = indices
        }
        let frameWidth = right - left + 1, frameHeight = bottom - top + 1
        var cropped = [UInt8]()
        cropped.reserveCapacity(frameWidth * frameHeight)
        for y in top...bottom { cropped.append(contentsOf: indices[(y * width + left)...(y * width + right)]) }

        data.append(contentsOf: [0x21, 0xF9, 0x04, 0x05])   // Graphic control: keep the frame, index 255 transparent
        appendShort(delay)
        data.append(contentsOf: [Self.transparent, 0x00])
        data.append(0x2C)                                     // Image descriptor
        appendShort(left); appendShort(top); appendShort(frameWidth); appendShort(frameHeight)
        data.append(0)                                        // No local color table
        data.append(8)                                        // LZW minimum code size
        appendSubBlocks(lzw(cropped))
    }

    func finish() -> Data {
        data.append(0x3B)
        return data
    }

    // MARK: Dithering

    /// Floyd–Steinberg error diffusion at 75% strength, scanning rows in alternating directions
    /// (serpentine) so the dots don't line up into diagonal "worms".
    ///
    /// Still areas are kept exactly as they were, so they don't shimmer: the frame is checked in 8×8 blocks,
    /// and a block whose pixels are all close to the colors they had when last drawn is left alone. Blocks
    /// (not single pixels) keep moving textures from turning into a speckled mix of old and new dots, and
    /// comparing with the last-drawn colors (not the previous frame) stops slow changes from leaving trails.
    private func dither(_ rgba: [UInt8]) -> (indices: [UInt8], changed: [Bool]) {
        var indices = [UInt8](repeating: 0, count: width * height)
        var changed = [Bool](repeating: true, count: width * height)
        let previousIndices = self.previousIndices

        // Which 8×8 blocks changed.
        let block = 8
        let blocksWide = (width + block - 1) / block, blocksHigh = (height + block - 1) / block
        var blockChanged = [Bool](repeating: true, count: blocksWide * blocksHigh)
        if let reference, previousIndices != nil {
            for by in 0..<blocksHigh {
                for bx in 0..<blocksWide {
                    var moved = false
                    outer: for y in (by * block)..<min(height, (by + 1) * block) {
                        for x in (bx * block)..<min(width, (bx + 1) * block) {
                            let p = (y * width + x) * 4
                            let difference = abs(Int(rgba[p]) - Int(reference[p])) + abs(Int(rgba[p + 1]) - Int(reference[p + 1]))
                                + abs(Int(rgba[p + 2]) - Int(reference[p + 2]))
                            if difference > 24 { moved = true; break outer }
                        }
                    }
                    blockChanged[by * blocksWide + bx] = moved
                }
            }
        }

        var current = [Int32](repeating: 0, count: (width + 2) * 3)
        var next = [Int32](repeating: 0, count: (width + 2) * 3)
        var newReference = reference ?? rgba
        for y in 0..<height {
            let forward = y % 2 == 0
            let step = forward ? 3 : -3          // Toward the next pixel in this row's direction
            for column in 0..<width {
                let x = forward ? column : width - 1 - column
                let i = y * width + x, p = i * 4
                let e = (x + 1) * 3
                let r = clamp(Int(rgba[p]) + Int(current[e]) / 16)
                let g = clamp(Int(rgba[p + 1]) + Int(current[e + 1]) / 16)
                let b = clamp(Int(rgba[p + 2]) + Int(current[e + 2]) / 16)
                let index: Int
                if let previousIndices, !blockChanged[(y / block) * blocksWide + x / block] {
                    index = Int(previousIndices[i])
                    changed[i] = false
                } else {
                    index = nearest(r, g, b)
                    newReference[p] = rgba[p]; newReference[p + 1] = rgba[p + 1]; newReference[p + 2] = rgba[p + 2]
                }
                indices[i] = UInt8(index)
                let chosen = palette[index]
                // 16ths, scaled by 3/4: ahead 7, behind-below 3, below 5, ahead-below 1.
                let er = Int32((r - chosen.r) * 3 / 4), eg = Int32((g - chosen.g) * 3 / 4), eb = Int32((b - chosen.b) * 3 / 4)
                let ahead = e + step, behind = e - step
                current[ahead] += er * 7; current[ahead + 1] += eg * 7; current[ahead + 2] += eb * 7
                next[behind] += er * 3; next[behind + 1] += eg * 3; next[behind + 2] += eb * 3
                next[e] += er * 5; next[e + 1] += eg * 5; next[e + 2] += eb * 5
                next[ahead] += er; next[ahead + 1] += eg; next[ahead + 2] += eb
            }
            swap(&current, &next)
            next.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        }
        reference = newReference
        return (indices, changed)
    }

    private func clamp(_ value: Int) -> Int { min(255, max(0, value)) }

    private func nearest(_ r: Int, _ g: Int, _ b: Int) -> Int {
        let key = (r >> 2) << 12 | (g >> 2) << 6 | (b >> 2)
        if lookup[key] >= 0 { return Int(lookup[key]) }
        // Center of the 6-bit cell, then the closest palette color (weighted for how eyes see color).
        let cr = (r >> 2) << 2 | 2, cg = (g >> 2) << 2 | 2, cb = (b >> 2) << 2 | 2
        var best = 0, bestDistance = Int.max
        for (i, color) in palette.enumerated() where i < Int(Self.transparent) {
            let dr = cr - color.r, dg = cg - color.g, db = cb - color.b
            let distance = 2 * dr * dr + 4 * dg * dg + 3 * db * db
            if distance < bestDistance { bestDistance = distance; best = i }
        }
        lookup[key] = Int16(best)
        return best
    }

    // MARK: LZW compression

    private func lzw(_ pixels: [UInt8]) -> [UInt8] {
        let clearCode = 256, endCode = 257
        var table = [Int16](repeating: -1, count: 4096 * 256)   // (prefix code, next byte) → code
        var used: [Int] = []
        var nextCode = 258, codeSize = 9
        var output: [UInt8] = []
        output.reserveCapacity(pixels.count / 2)
        var buffer = 0, bits = 0
        func emit(_ code: Int) {
            buffer |= code << bits
            bits += codeSize
            while bits >= 8 { output.append(UInt8(buffer & 0xFF)); buffer >>= 8; bits -= 8 }
        }
        emit(clearCode)
        guard var prefix = pixels.first.map(Int.init) else { emit(endCode); return output }
        for pixel in pixels.dropFirst() {
            let key = prefix << 8 | Int(pixel)
            if table[key] >= 0 {
                prefix = Int(table[key])
                continue
            }
            emit(prefix)
            if nextCode < 4096 {
                table[key] = Int16(nextCode)
                used.append(key)
                if nextCode == 1 << codeSize && codeSize < 12 { codeSize += 1 }
                nextCode += 1
            } else {
                emit(clearCode)
                for k in used { table[k] = -1 }
                used.removeAll(keepingCapacity: true)
                nextCode = 258
                codeSize = 9
            }
            prefix = Int(pixel)
        }
        emit(prefix)
        emit(endCode)
        if bits > 0 { output.append(UInt8(buffer & 0xFF)) }
        return output
    }

    private func appendSubBlocks(_ bytes: [UInt8]) {
        var index = 0
        while index < bytes.count {
            let count = min(255, bytes.count - index)
            data.append(UInt8(count))
            data.append(contentsOf: bytes[index..<index + count])
            index += count
        }
        data.append(0)
    }

    private func appendShort(_ value: Int) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    // MARK: Palette

    /// The 255 colors that best cover the sampled pixels (median cut).
    static func palette(from samples: [(UInt8, UInt8, UInt8)]) -> [(r: Int, g: Int, b: Int)] {
        guard !samples.isEmpty else { return [(0, 0, 0), (255, 255, 255)] }
        var boxes: [[(UInt8, UInt8, UInt8)]] = [samples]
        while boxes.count < 255 {
            // Split the box with the widest color range (weighted by how many pixels it holds).
            var bestIndex = -1, bestScore = 0, bestChannel = 0
            for (i, box) in boxes.enumerated() where box.count > 1 {
                var low = [255, 255, 255], high = [0, 0, 0]
                for p in box {
                    let c = [Int(p.0), Int(p.1), Int(p.2)]
                    for k in 0..<3 { low[k] = min(low[k], c[k]); high[k] = max(high[k], c[k]) }
                }
                let ranges = (0..<3).map { high[$0] - low[$0] }
                let channel = ranges.firstIndex(of: ranges.max()!)!
                let score = ranges[channel] * Int(Double(box.count).squareRoot())
                if score > bestScore { bestScore = score; bestIndex = i; bestChannel = channel }
            }
            guard bestIndex >= 0 else { break }
            let sorted = boxes[bestIndex].sorted {
                switch bestChannel { case 0: $0.0 < $1.0; case 1: $0.1 < $1.1; default: $0.2 < $1.2 }
            }
            let middle = sorted.count / 2
            boxes[bestIndex] = Array(sorted[..<middle])
            boxes.append(Array(sorted[middle...]))
        }
        return boxes.map { box in
            var r = 0, g = 0, b = 0
            for p in box { r += Int(p.0); g += Int(p.1); b += Int(p.2) }
            let n = max(box.count, 1)
            return (r / n, g / n, b / n)
        }
    }

    /// Draws an image into a width × height RGBA buffer.
    static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }
}
