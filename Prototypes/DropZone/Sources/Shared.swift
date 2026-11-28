import SwiftUI

// Copied from the real ContentView.swift: the extension tags, their spectrum colours, and the footer button.

/// A file extension as a small mono tag, the one place the app shows formats: ".heic", ".pdf".
/// The emphasized one is the extension a file is becoming, and it takes its kind's colour from the
/// app icon's spectrum: white light goes into the prism, colour comes out.
struct ExtensionTag: View {
    let ext: String
    var emphasized = false

    init(_ ext: String, emphasized: Bool = false) {
        self.ext = ext.lowercased()
        self.emphasized = emphasized
    }

    var body: some View {
        let kind = emphasized ? Format(fileExtension: ext)?.kind : nil
        Text("." + ext)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(kind.map { AnyShapeStyle($0.ink) } ?? AnyShapeStyle(emphasized ? .primary : .secondary))
            .padding(.horizontal, 4)
            .frame(height: 16)
            .background(kind.map { AnyShapeStyle($0.wash) } ?? AnyShapeStyle(.quinary), in: RoundedRectangle(cornerRadius: 4))
    }
}

extension Format.Kind {
    /// The icon's rays, plus violet for audio (the end of a real spectrum).
    private var hue: (light: NSColor, dark: NSColor, base: NSColor) {
        switch self {
        case .image: (NSColor(hex: 0xB0432B), NSColor(hex: 0xF59B87), NSColor(hex: 0xE8644C))
        case .video: (NSColor(hex: 0x925C0E), NSColor(hex: 0xF2C46E), NSColor(hex: 0xF0A836))
        case .spreadsheet: (NSColor(hex: 0x0D7468), NSColor(hex: 0x62D4C4), NSColor(hex: 0x22AE9E))
        case .document: (NSColor(hex: 0x2D5FC0), NSColor(hex: 0x93B6F6), NSColor(hex: 0x4A85E8))
        case .audio: (NSColor(hex: 0x6A47BF), NSColor(hex: 0xBBA5F3), NSColor(hex: 0x8A63E0))
        }
    }

    /// Text colour on the wash: dark in light mode, light in dark mode, so it stays readable.
    var ink: Color {
        let hue = hue
        return Color(nsColor: NSColor(name: nil) { $0.isDark ? hue.dark : hue.light })
    }

    /// The full-strength colour, for progress bars.
    var tint: Color { Color(nsColor: hue.base) }

    /// The tag's tinted background.
    var wash: Color {
        let base = hue.base
        return Color(nsColor: NSColor(name: nil) { base.withAlphaComponent($0.isDark ? 0.24 : 0.14) })
    }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// A small icon-and-label button for the panel's footer, highlighting under the pointer.
struct FooterButton: View {
    let title: String
    let symbol: String
    let help: String
    var shortcut: KeyEquivalent?
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, symbol: String, help: String? = nil, shortcut: KeyEquivalent? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.help = help ?? title
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
            .hoverHighlight(hovering)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut.map { KeyboardShortcut($0) })
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// ".heic → .jpg"
struct ExtensionChange: View {
    let from: String
    let to: String

    var body: some View {
        HStack(spacing: 4) {
            ExtensionTag(from)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            ExtensionTag(to, emphasized: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(from.uppercased()) to \(to.uppercased())")
    }
}


extension View {
    /// The rounded highlight behind a row under the pointer.
    func hoverHighlight(_ on: Bool) -> some View {
        background(.quaternary.opacity(on ? 1 : 0), in: RoundedRectangle(cornerRadius: 6))
    }
}
