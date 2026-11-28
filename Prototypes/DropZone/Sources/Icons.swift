import AppKit

/// The menu-bar icons. The prism is copied from the real StatusIcon.swift; the checkmark uses the same
/// canvas, stroke weight and template style so the swap doesn't jump.
enum Icons {
    static let prism: NSImage = {
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
        image.accessibilityDescription = "Drop Zone Prototype"
        return image
    }()

    static let check: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 5.5, y: 8.5))
            path.line(to: NSPoint(x: 9.3, y: 4.8))
            path.line(to: NSPoint(x: 16.8, y: 13.2))
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Converted"
        return image
    }()
}

/// Every drag-state change goes to ~/Library/Logs/DropZoneProto.log, so a session can be read back afterwards.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DropZoneProto.log")
    private static let start = Date()

    static func write(_ message: String) {
        let line = String(format: "%8.3f  ", Date().timeIntervalSince(start)) + message + "\n"
        FileHandle.standardError.write(Data(line.utf8))
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    }
}
