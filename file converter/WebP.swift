import CoreGraphics
import Foundation

/// Writes WebP images with Google's libwebp, which is built into the app (macOS can read WebP but not write it).
nonisolated enum WebP {
    static func write(_ image: CGImage, to url: URL, quality: Quality) throws {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ConversionError.failed("Couldn't process this image.") }

        // Core Graphics premultiplies by alpha; WebP expects plain colors.
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[i + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for c in 0..<3 { pixels[i + c] = UInt8(min(255, Int(pixels[i + c]) * 255 / alpha)) }
        }

        var output: UnsafeMutablePointer<UInt8>?
        let size = WebPEncodeRGBA(pixels, Int32(width), Int32(height), Int32(width * 4), Float(quality.webpQuality), &output)
        guard size > 0, let output else { throw ConversionError.failed("Couldn't write the WebP file.") }
        defer { WebPFree(output) }
        try Data(bytes: output, count: size).write(to: url)
    }

    /// Any image macOS can read → WebP, with its EXIF rotation applied and scaled down for "Smaller files".
    static func write(imageAt input: URL, to url: URL, quality: Quality) throws {
        try write(ImageConversion.load(input, quality: quality), to: url, quality: quality)
    }
}
