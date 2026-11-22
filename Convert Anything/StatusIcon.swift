import AppKit

/// Menu-bar icon when idle: the app's prism, with white light going in and three rays coming out
/// (lighter and lighter, like a spectrum). A template image, so macOS tints it for light and dark menu bars.
enum IdleIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let beam = NSBezierPath()
            beam.move(to: NSPoint(x: 0.9, y: 12.1))
            beam.line(to: NSPoint(x: 6.9, y: 10.6))
            beam.lineWidth = 1.6
            beam.lineCapStyle = .round
            beam.stroke()

            let prism = NSBezierPath()
            prism.move(to: NSPoint(x: 10.5, y: 16.2))
            prism.line(to: NSPoint(x: 16.8, y: 3.8))
            prism.line(to: NSPoint(x: 4.2, y: 3.8))
            prism.close()
            prism.lineWidth = 1.6
            prism.lineJoinStyle = .round
            prism.stroke()

            let rays: [(from: NSPoint, to: NSPoint, alpha: CGFloat)] = [
                (NSPoint(x: 14.4, y: 10.6), NSPoint(x: 21.2, y: 10.4), 1),
                (NSPoint(x: 15.1, y: 9.0), NSPoint(x: 21.2, y: 7.2), 0.7),
                (NSPoint(x: 15.8, y: 7.4), NSPoint(x: 21.2, y: 4.0), 0.45),
            ]
            for ray in rays {
                let path = NSBezierPath()
                path.move(to: ray.from)
                path.line(to: ray.to)
                path.lineWidth = 1.4
                path.lineCapStyle = .round
                NSColor.black.withAlphaComponent(ray.alpha).setStroke()
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Convert Anything"
        return image
    }()
}

/// Menu-bar icon while converting: a ring that fills with progress (just the track when progress
/// isn't known) around a dot that breathes to show work is happening.
enum StatusIcon {
    /// Frames already drawn. The pulse ticks about 12 times a second, so rather than drawing a new image
    /// each tick, progress and breath are rounded to steps too small to see and each frame is drawn once.
    private static var frames: [Int: NSImage] = [:]

    /// `pulse` is a phase in radians; one full cycle is one breath.
    static func ring(progress: Double?, pulse: Double) -> NSImage {
        let progressStep = progress.map { Int(($0 * 60).rounded()) } ?? -1   // 1/60 of the ring is well under a point
        let breathStep = Int(((0.5 - 0.5 * cos(pulse)) * 12).rounded())     // 0 → 12 → 0
        let key = (progressStep + 1) * 16 + breathStep
        if let frame = frames[key] { return frame }
        let frame = draw(progress: progress == nil ? nil : Double(progressStep) / 60, breath: Double(breathStep) / 12)
        frames[key] = frame
        return frame
    }

    private static func draw(progress: Double?, breath: Double) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 6.2
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 2.8
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()

            if let progress {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * max(0.04, progress), clockwise: true)
                arc.lineWidth = 3.1
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }

            let dotRadius = 1.2 + 1.3 * breath
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - dotRadius, y: center.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
            NSColor.black.withAlphaComponent(0.45 + 0.55 * breath).setFill()
            dot.fill()
            return true
        }
        image.isTemplate = true   // Lets macOS tint it to match the menu bar
        return image
    }
}
