import AppKit

/// Menu-bar icon when idle: the circling arrows, drawn bold so they read clearly in the menu bar.
enum IdleIcon {
    static let image: NSImage = {
        let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Convert Everything")!
        let image = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13.5, weight: .bold)) ?? symbol
        image.isTemplate = true
        return image
    }()
}

/// Menu-bar icon while converting: a ring that fills with progress (just the track when progress
/// isn't known) around a dot that breathes to show work is happening.
enum StatusIcon {
    /// `pulse` is a phase in radians; one full cycle is one breath.
    static func ring(progress: Double?, pulse: Double) -> NSImage {
        let breath = 0.5 - 0.5 * cos(pulse)   // 0 → 1 → 0
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
