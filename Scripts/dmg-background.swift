// Draws the background of the Convert Anything disk image window: an arrow from the app to the
// Applications folder and a short note about the first launch.
//
//   swift Scripts/dmg-background.swift out-dir
//
// Writes background.png (600×400) and background@2x.png (1200×800) to out-dir. make-dmg.sh combines
// them into one HiDPI TIFF. Icon centres in make-dmg.sh must match APP_X / APPS_X / ICON_Y here.
import AppKit

let width: CGFloat = 600, height: CGFloat = 400
let appX: CGFloat = 160, appsX: CGFloat = 440, iconY: CGFloat = 190   // from the top, like Finder

func render(scale: CGFloat, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale),
                               pixelsHigh: Int(height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Soft, slightly warm background.
    NSGradient(starting: NSColor(srgbRed: 0.985, green: 0.98, blue: 0.975, alpha: 1),
               ending: NSColor(srgbRed: 0.935, green: 0.935, blue: 0.945, alpha: 1))!
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

    let ink = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1)
    let muted = NSColor(srgbRed: 0.42, green: 0.42, blue: 0.45, alpha: 1)
    let centered = NSMutableParagraphStyle()
    centered.alignment = .center

    func text(_ s: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color, .paragraphStyle: centered,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let h = str.boundingRect(with: NSSize(width: width - 60, height: 200),
                                 options: .usesLineFragmentOrigin).height
        str.draw(with: NSRect(x: 30, y: height - y - h, width: width - 60, height: h),
                 options: .usesLineFragmentOrigin)
    }

    text("Drag Convert Anything into Applications", y: 44, size: 17, weight: .semibold, color: ink)

    // Arrow between the two icons (icons are 128 pt; leave a gap on both sides).
    let y = height - iconY
    let start = appX + 84, end = appsX - 84
    let arrowColor = NSColor(srgbRed: 0.68, green: 0.68, blue: 0.71, alpha: 1)
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: start, y: y))
    shaft.line(to: NSPoint(x: end - 14, y: y))
    shaft.lineWidth = 4
    shaft.lineCapStyle = .round
    arrowColor.setStroke()
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: end, y: y))
    head.line(to: NSPoint(x: end - 18, y: y + 11))
    head.line(to: NSPoint(x: end - 18, y: y - 11))
    head.close()
    arrowColor.setFill()
    head.fill()

    text("First time you open it, macOS blocks it because it isn't from the App Store:\n"
         + "System Settings → Privacy & Security → Open Anyway. You only do this once.",
         y: 322, size: 11.5, weight: .regular, color: muted)
    NSGraphicsContext.current?.flushGraphics()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
    let url = out.appendingPathComponent(name)
    render(scale: CGFloat(scale), to: url)
}
