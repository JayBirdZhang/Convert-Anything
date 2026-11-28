import AppKit
import SwiftUI

@main enum Main {
    static let delegate = AppDelegate()

    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { SelfTest.run(); exit(0) }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count { SelfTest.snapshots(to: args[i + 1]); exit(0) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}

/// Owns the status item and the menu panel, and runs the spring-loaded open.
///
/// SwiftUI's MenuBarExtra can't be used: it has no API to open its window, its status button isn't ours to
/// register for drags, and calling performClick on the button it creates doesn't open the window either
/// (tried on macOS 27). So this is a plain NSStatusItem plus a borderless NSPanel hosting SwiftUI.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    private var item: NSStatusItem!
    private var panel: MenuPanel!
    private var hosting: NSHostingView<MenuView>!

    private var overlay: IconDropView!
    private var springTimer: Timer?
    private var springAnchor = NSPoint.zero
    private var springFiles: [URL] = []

    /// Exists only while a drag is over the open menu: notices the mouse button going up anywhere.
    private var dragWatch: Timer?

    /// Proximity open: listens only to mouse-down, mouse-dragged and mouse-up, which macOS sends only while
    /// a button is held, so nothing runs while idle. Mouse events (unlike key events) need no permission.
    private var proximityMonitor: Any?
    private var dragChangeCountAtPress = -1
    private var pressCarriesFiles: [URL]?    // nil = not checked yet this press
    private var nearTimer: Timer?
    private var outsideClickMonitor: Any?
    private var iconGeneration = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        button.image = Icons.prism
        overlay = IconDropView(frame: button.bounds)
        overlay.owner = self
        button.addSubview(overlay)

        hosting = NSHostingView(rootView: MenuView(model: model))
        hosting.sizingOptions = []
        panel = MenuPanel(content: hosting)
        panel.onCancel = { [weak self] in self?.closePanel(reason: "Esc") }
        hosting.rootView = MenuView(model: model,
                                    onSize: { [weak self] in self?.resizePanel(to: $0) },
                                    onChoose: { [weak self] in self?.choose($0) },
                                    onCancel: { [weak self] in self?.closePanel(reason: "chooser cancelled") },
                                    onQuit: { NSApp.terminate(nil) })
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible, self.model.phase == .idle || self.model.phase == .chooser else { return }
                self.closePanel(reason: "app resigned active")
            }
        }
        Log.write("launched; spring delay \(model.springDelay)s")
        startProximityMonitor()
        if CommandLine.arguments.contains("--demo") { runDemo() }
    }

    /// `--demo`: opens the menu as if a HEIC file had paused over the icon, logs where the tiles ended up,
    /// and (no mouse button being down) lets the drag watch close it as a drop elsewhere would.
    private func runDemo() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.springFiles = [URL(fileURLWithPath: "/tmp/IMG_2041.heic")]
            self.springFired()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                Log.write("demo: status window \(self.item.button?.window?.frame ?? .zero), panel \(self.panel.frame), hosting \(self.hosting.bounds) flipped=\(self.hosting.isFlipped)")
                for (tile, frame) in self.model.tileFrames.sorted(by: { $0.value.minY * 1000 + $0.value.minX < $1.value.minY * 1000 + $1.value.minX }) {
                    let center = CGPoint(x: frame.midX, y: frame.midY)
                    let window = self.hosting.convert(center, to: nil)
                    let back = self.hosting.convert(window, from: nil)
                    Log.write("demo: \(self.model.label(for: tile)) at \(frame) → hit \(self.model.tile(at: back).map(self.model.label(for:)) ?? "nothing")")
                }
                Log.write("demo: icon overlay \(self.overlay.frame) in button \(self.item.button?.bounds ?? .zero), types \(self.overlay.registeredDraggedTypes.map(\.rawValue))")
                let hit = self.item.button?.window?.contentView?.hitTest(self.item.button!.convert(NSPoint(x: 10, y: 10), to: nil))
                Log.write("demo: a click on the icon lands on \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
            }
            // After the drag watch has closed it: open it the way a click does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.iconClicked()
                Log.write("demo: after click, panel visible=\(self.panel.isVisible) key=\(self.panel.isKeyWindow) phase=\(self.model.phase)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.iconClicked() }
            }
        }
    }

    // MARK: Clicking the icon

    func iconClicked() {
        if panel.isVisible { closePanel(reason: "icon clicked"); return }
        model.reset()
        NSApp.activate()
        showPanel()
        panel.makeKey()
        watchOutsideClicks()
    }

    // MARK: Spring-loaded open

    func iconDragEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(info)
        Log.write("icon: drag entered with \(urls.count) file(s) at \(info.draggingLocation)")
        guard !urls.isEmpty else { return [] }
        if panel.isVisible && model.phase == .dragging { return .copy }
        springFiles = urls
        startSpring(at: info.draggingLocation)
        return .copy
    }

    func iconDragUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        guard !springFiles.isEmpty || model.phase == .dragging else { return [] }
        // Like Finder: moving restarts the wait, so a drag that's just passing by never opens the menu.
        if springTimer != nil, hypot(info.draggingLocation.x - springAnchor.x, info.draggingLocation.y - springAnchor.y) > 3 {
            Log.write("spring: moved, wait restarted")
            startSpring(at: info.draggingLocation)
        }
        return .copy
    }

    func iconDragExited() {
        if springTimer != nil { Log.write("icon: drag left before the menu opened") }
        springTimer?.invalidate()
        springTimer = nil
    }

    /// Letting go on the icon itself isn't a choice, so it cancels like anywhere else.
    func iconDrop() -> Bool {
        Log.write("icon: dropped on the icon (cancel)")
        springTimer?.invalidate()
        springTimer = nil
        if model.phase == .dragging { closePanel(reason: "dropped on icon") }
        return false
    }

    private func startSpring(at point: NSPoint) {
        springAnchor = point
        springTimer?.invalidate()
        let timer = Timer(timeInterval: model.springDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.springFired() }
        }
        RunLoop.main.add(timer, forMode: .common)   // Also fires while AppKit runs the drag in a tracking mode
        springTimer = timer
    }

    private func springFired() {
        springTimer = nil
        Log.write("spring: fired after \(model.springDelay)s")
        beginDragMode(springFiles)
        if !panel.isVisible { showPanel() }
    }

    // MARK: Opening when a file comes near

    /// The area that opens the menu: under the menu bar around the icon, as wide as the menu, reaching
    /// `openDistance` down. The file never has to touch the top edge (where macOS opens Mission Control).
    private func nearZone() -> NSRect? {
        guard let icon = item.button?.window?.frame, icon.height >= 1, let screen = item.button?.window?.screen else { return nil }
        let barBottom = screen.visibleFrame.maxY
        let width: CGFloat = 340
        let x = min(max(icon.midX - width / 2, screen.frame.minX), screen.frame.maxX - width)
        return NSRect(x: x, y: barBottom - model.openDistance, width: width, height: screen.frame.maxY - barBottom + model.openDistance)
    }

    private func startProximityMonitor() {
        proximityMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.proximityEvent(event.type) }
        }
    }

    private func proximityEvent(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            // A drag writes to the drag pasteboard when it starts, so a new count later in this press means
            // something is being dragged now (not a leftover from an earlier drag).
            dragChangeCountAtPress = NSPasteboard(name: .drag).changeCount
            pressCarriesFiles = nil
        case .leftMouseUp:
            cancelNear()
            pressCarriesFiles = nil
        case .leftMouseDragged:
            let mouse = NSEvent.mouseLocation
            let inZone = nearZone().map { NSMouseInRect(mouse, $0, false) } ?? false

            // Already open from this drag: close it again if the file wanders well away without a drop.
            if model.phase == .dragging, panel.isVisible {
                let keep = panel.frame.insetBy(dx: -120, dy: -120)
                if !inZone && !NSMouseInRect(mouse, keep, false) { closePanel(reason: "file moved away") }
                return
            }
            guard inZone, !panel.isVisible || model.phase == .idle else { cancelNear(); return }
            if pressCarriesFiles == nil {
                let pasteboard = NSPasteboard(name: .drag)
                guard pasteboard.changeCount != dragChangeCountAtPress else { return }   // Not a drag session (yet)
                pressCarriesFiles = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
                Log.write("near: drag with \(pressCarriesFiles!.count) file(s) came within \(Int(model.openDistance)) pt")
            }
            guard let files = pressCarriesFiles, !files.isEmpty, nearTimer == nil else { return }
            let timer = Timer(timeInterval: model.springDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.nearTimer = nil
                    Log.write("near: opened after \(self.model.springDelay)s near the icon")
                    self.springFiles = files
                    self.springFired()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            nearTimer = timer
        default: break
        }
    }

    private func cancelNear() {
        if nearTimer != nil { Log.write("near: left the area before the menu opened") }
        nearTimer?.invalidate()
        nearTimer = nil
    }

    // MARK: Dragging over the menu

    /// Called when a drag enters the panel. A drag into a menu that was already open by click works too.
    func panelDragEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(info)
        guard !urls.isEmpty else { return [] }
        if model.phase != .dragging { beginDragMode(urls) }
        return panelDragUpdated(info)
    }

    func panelDragUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        let point = hosting.convert(info.draggingLocation, from: nil)   // NSHostingView is flipped, like SwiftUI
        let tile = model.tile(at: point)
        if tile != model.hovered {
            model.hovered = tile
            Log.write("panel: over \(tile.map(model.label(for:)) ?? "nothing")")
        }
        return tile == nil ? [] : .copy
    }

    func panelDragExited() {
        if model.hovered != nil { model.hovered = nil }
        Log.write("panel: drag left the menu")
    }

    func panelDrop() -> Bool {
        guard let tile = model.hovered else { return false }
        Log.write("panel: dropped on \(model.label(for: tile))")
        if tile == .more {
            model.hovered = nil
            model.phase = .chooser
            stopDragWatch()
            NSApp.activate()
            panel.makeKey()
            watchOutsideClicks()
        } else {
            choose(tile)
        }
        return true
    }

    private func beginDragMode(_ urls: [URL]) {
        model.beginDrag(urls)
        item.button?.highlight(true)
        startDragWatch()
    }

    /// While a drag is over the open menu, a short timer watches for the mouse button going up. A drop on
    /// a tile arrives as performDragOperation first; if none does, the drop landed elsewhere and the menu closes.
    private func startDragWatch() {
        guard dragWatch == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self.dragEnded(source: "mouse button up")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragWatch = timer
    }

    /// The drag is over, from draggingEnded or the button watch, whichever comes first. A drop on a tile has
    /// already moved the phase on by then (or does within a moment); otherwise the drop landed elsewhere.
    func dragEnded(source: String) {
        Log.write("drag ended (\(source))")
        springTimer?.invalidate()
        springTimer = nil
        springFiles = []
        guard dragWatch != nil else { return }
        stopDragWatch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if self.model.phase == .dragging { self.closePanel(reason: "drag ended elsewhere") }
        }
    }

    private func stopDragWatch() {
        dragWatch?.invalidate()
        dragWatch = nil
    }

    // MARK: Converting (fake)

    func choose(_ tile: Tile) {
        guard tile != .more else { return }
        let target = model.label(for: tile)
        let what = model.files.count == 1 ? model.files[0].lastPathComponent : "\(model.files.count) files"
        model.remember(tile)
        model.hovered = nil
        model.phase = .converting(tile == .combine ? "Combining \(what) into a PDF" : "\(what) → \(target)")
        stopDragWatch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.model.addRecent(for: tile)
            self.closePanel(reason: "converted")
            self.flashCheckmark()
        }
    }

    private func flashCheckmark() {
        iconGeneration += 1
        let generation = iconGeneration
        item.button?.image = Icons.check
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.iconGeneration == generation else { return }
            self.item.button?.image = Icons.prism
        }
    }

    // MARK: The panel

    private func showPanel() {
        // SwiftUI applies the model change on its next update, so lay out first or the menu opens at its old height.
        hosting.layoutSubtreeIfNeeded()
        resizePanel(to: hosting.fittingSize)
        panel.orderFrontRegardless()
        item.button?.highlight(true)
        Log.write("panel: shown at \(panel.frame) under icon \(item.button?.window?.frame ?? .zero) on \(panel.screen?.localizedName ?? "?")")
    }

    func closePanel(reason: String) {
        Log.write("panel: closed (\(reason))")
        springTimer?.invalidate()
        springTimer = nil
        springFiles = []
        stopDragWatch()
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
        panel.orderOut(nil)
        item.button?.highlight(false)
        model.reset()
    }

    /// Top-anchored under the status item, left edges aligned like a menu, kept on its screen.
    private func resizePanel(to size: CGSize) {
        guard size.height > 0, let buttonWindow = item.button?.window else { return }
        var anchor = buttonWindow.frame
        var screen = buttonWindow.screen
        // On macOS 27 the status item's window sometimes reports a zero frame (seen right after launch).
        // The pointer is on the icon whenever the menu opens, so fall back to it.
        if anchor.height < 1 || screen == nil {
            let mouse = NSEvent.mouseLocation
            screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            let barBottom = screen?.visibleFrame.maxY ?? mouse.y
            anchor = NSRect(x: mouse.x - 16, y: barBottom, width: 32, height: 24)
            Log.write("panel: status window frame unknown, anchoring to the pointer")
        }
        let visible = screen?.visibleFrame ?? .zero
        var x = anchor.minX
        if let screen { x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8) }
        let top = min(anchor.minY - 2, visible.maxY)
        let frame = NSRect(x: x, y: top - size.height, width: size.width, height: size.height).integral
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    private func watchOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible, self.model.phase == .idle || self.model.phase == .chooser else { return }
                // On macOS 27 a click on our own status icon also arrives here; the icon handles that one.
                if let icon = self.item.button?.window?.frame, NSMouseInRect(NSEvent.mouseLocation, icon, false) { return }
                self.closePanel(reason: "clicked outside")
            }
        }
    }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

/// Lies over the status button. It's the icon's drag destination, and since it sits on top it takes the
/// clicks too and hands them on.
final class IconDropView: NSView {
    weak var owner: AppDelegate?

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { owner?.iconClicked() }
    override func rightMouseDown(with event: NSEvent) { owner?.iconClicked() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { owner?.iconDragEntered(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { owner?.iconDragUpdated(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { owner?.iconDragExited() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { owner?.iconDrop() ?? false }
    override func draggingEnded(_ sender: NSDraggingInfo) { owner?.dragEnded(source: "icon draggingEnded") }
}

/// The menu window: borderless, doesn't activate the app when it appears (a drag from Finder keeps Finder
/// in front), shows over full-screen apps and on every Space.
final class MenuPanel: NSPanel {
    var onCancel: () -> Void = {}

    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let container = PanelDropView(frame: contentRect(forFrameRect: frame))
        container.material = .menu
        container.blendingMode = .behindWindow
        container.state = .active
        container.maskImage = Self.roundedMask(radius: 12)
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        contentView = container
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// One drag destination for the whole menu. SwiftUI only draws the tiles; this decides which one the drag
/// is over, so entering, leaving and dropping between tiles are all seen in one place.
final class PanelDropView: NSVisualEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private var owner: AppDelegate { Main.delegate }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { owner.panelDragEntered(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { owner.panelDragUpdated(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { owner.panelDragExited() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { owner.model.hovered != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { owner.panelDrop() }
    override func draggingEnded(_ sender: NSDraggingInfo) { owner.dragEnded(source: "panel draggingEnded") }
}
