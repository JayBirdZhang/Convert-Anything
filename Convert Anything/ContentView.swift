import SwiftUI
import UniformTypeIdentifiers

/// The menu-bar panel: a switch for watching, recent conversions, and links to the other pages.
struct ContentView: View {
    enum Page { case main, settings, formats }

    @Bindable var model: AppModel
    @State private var page: Page

    init(model: AppModel, page: Page = .main) {
        self.model = model
        _page = State(initialValue: page)
    }

    var body: some View {
        Group {
            switch page {
            case .main: main
            case .settings: SettingsView(model: model) { page = .main }
            case .formats: FormatsView { page = .main }
            }
        }
        .frame(width: 340)
        .background(WindowReader { panelWindow = $0 })
        // Closing the panel takes it back to the first page, like Control Center. Only the panel itself
        // closing counts: a picker's menu or the folder chooser also take focus, and must leave the page be.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard let window = note.object as? NSWindow, window === panelWindow,
                  !window.occlusionState.contains(.visible) else { return }
            page = .main
        }
    }

    @State private var panelWindow: NSWindow?

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 16)
            if model.batches.isEmpty {
                emptyState
            } else {
                recent
            }
            NotificationNote(feedback: model.feedback)
            Divider().padding(.horizontal, 16)
            footer
        }
    }

    /// The other pages and Quit, as one quiet row of labelled icons.
    private var footer: some View {
        HStack(spacing: 4) {
            FooterButton("Formats", symbol: "square.grid.2x2", help: "What can I convert?") { page = .formats }
            FooterButton("Settings", symbol: "gearshape") { page = .settings }
            Spacer(minLength: 0)
            FooterButton("Quit", symbol: "power", help: "Quit Convert Anything", shortcut: "q") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(8)
    }

    // Like Control Center's modules: what the switch controls, and what it's doing right now.
    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Convert on rename").fontWeight(.medium)
                // The folders by name when they fit, else just how many.
                ViewThatFits(in: .horizontal) {
                    Text(status(named: true))
                    Text(status(named: false))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(model.watchedFolders.map(displayPath).joined(separator: "\n"))
            }
            Spacer(minLength: 8)
            Toggle("Convert on rename", isOn: $model.isWatching)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func status(named: Bool) -> String {
        let folders = model.watchedFolders
        guard model.isWatching else { return "Off · renamed files are left alone" }
        guard !folders.isEmpty else { return "No folders · add one in Settings" }
        guard named else { return "Watching \(folders.count) folder\(folders.count == 1 ? "" : "s")" }
        return "Watching " + ListFormatter.localizedString(byJoining: folders.map { URL(fileURLWithPath: $0).lastPathComponent })
    }

    /// A rename, as it looks in Finder: the same file before and after its extension changes.
    private var emptyState: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                sampleFile("notes", "md")
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                sampleFile("notes", "pdf")
            }
            Text("Change a file's extension in Finder to convert it")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .accessibilityElement(children: .combine)
    }

    private func sampleFile(_ name: String, _ ext: String) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data))
                .resizable()
                .frame(width: 40, height: 40)
            HStack(spacing: 0) {
                Text(name)
                ExtensionTag(ext, emphasized: ext == "pdf").padding(.leading, 1)
            }
            .font(.subheadline)
        }
    }

    /// Conversions grouped by day, newest first. Redrawn every minute so "2 min ago" stays true.
    private var recent: some View {
        TimelineView(.everyMinute) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(days(now: context.date).enumerated()), id: \.element.id) { index, day in
                        dayHeader(day.title, showsClear: index == 0)
                        ForEach(day.batches) { HistoryRow(batch: $0, model: model, now: context.date) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func dayHeader(_ title: String, showsClear: Bool) -> some View {
        HStack {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Spacer()
            if showsClear && model.batches.contains(where: { !$0.isActive }) {
                Button("Clear") { model.clearFinished() }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
                    .help("Remove finished conversions from this list")
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private struct Day: Identifiable {
        let id: Date
        let title: String
        var batches: [Batch]
    }

    /// "Today", "Yesterday", then "Monday, Nov 10".
    private func days(now: Date) -> [Day] {
        let calendar = Calendar.current
        var days: [Day] = []
        for batch in model.batches {
            let start = calendar.startOfDay(for: batch.lastAdded)
            if days.last?.id == start {
                days[days.count - 1].batches.append(batch)
            } else {
                let title = calendar.isDate(start, inSameDayAs: now) ? "Today"
                    : calendar.isDateInYesterday(start) ? "Yesterday"
                    : start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
                days.append(Day(id: start, title: title, batches: [batch]))
            }
        }
        return days
    }
}

/// "Just now", "12 min ago", or the time of day once it's an hour or more ago (the day is in the header).
func timeLabel(_ date: Date, now: Date) -> String {
    let seconds = now.timeIntervalSince(date)
    if seconds < 60 { return "Just now" }
    if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
    return date.formatted(date: .omitted, time: .shortened)
}

/// "~/Documents" rather than "/Users/name/Documents".
func displayPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

// MARK: - Pieces shared by the pages

/// The title bar of a secondary page, with a way back.
struct PageHeader: View {
    let title: String
    let back: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)   // Esc goes back before it closes the panel
                .help("Back")
                .accessibilityLabel("Back")
                Text(title).fontWeight(.medium)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            Divider().padding(.horizontal, 16)
        }
    }
}

/// A titled group of rows on a rounded background, like a section in System Settings.
struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
            VStack(alignment: .leading, spacing: 0) { content }
                .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

extension View {
    /// The rounded highlight behind a row under the pointer.
    func hoverHighlight(_ on: Bool) -> some View {
        background(.quaternary.opacity(on ? 1 : 0), in: RoundedRectangle(cornerRadius: 6))
    }
}

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

/// Hands back the window a view is in, once it's in one.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { WindowView(found: found) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowView: NSView {
        let found: (NSWindow) -> Void
        init(found: @escaping (NSWindow) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { found(window) }
        }
    }
}
