import AppKit
import Observation
import SwiftUI
import UserNotifications

/// Quiet signs that conversions finished: a checkmark (or an exclamation mark) in the menu-bar icon, and a
/// note in the menu when notifications are off, so people who never see banners still know.
@Observable final class CompletionFeedback {
    enum Outcome { case succeeded, failed }
    /// What the idle menu-bar icon shows instead of the prism, if anything.
    private(set) var outcome: Outcome?
    /// The menu shows "Notifications are off" while this is true.
    private(set) var showsNotificationNote = false

    /// When the icon last showed a result; only conversions started after it count toward the next one.
    @ObservationIgnored private(set) var lastReported = Date.distantPast
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var status: UNAuthorizationStatus?
    @ObservationIgnored private var keyObserver: NSObjectProtocol?
    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Keys {
        static let conversions = "completedConversions"   // Counts up to `noteAfter`, then stops being written
        static let snoozedUntil = "notificationNoteSnoozedUntil"
        static let dismissals = "notificationNoteDismissals"
        static let notifyWhenDone = "showNotifications"     // AppModel's "Notify when done" setting
        static let debugStatus = "debugNotificationStatus" // Debug builds only: denied, notDetermined or authorized
    }
    private static let noteAfter = 3
    /// "Not now" hides the note for a week; the third time, for good.
    private static let snooze: TimeInterval = 7 * 24 * 3600
    private static let maxDismissals = 3

    init() {
        // The menu panel becoming key is the menu opening (Welcome.swift relies on the same thing).
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpened() }
        }
    }

    // MARK: Menu-bar icon

    /// Everything that was converting has finished. When it all worked, a checkmark for 2 seconds (a later
    /// success restarts the 2 seconds rather than adding a second checkmark). When anything failed, an
    /// exclamation mark until the menu opens or the next conversions finish.
    func conversionsFinished(succeeded: Bool) {
        lastReported = Date()
        checkTask?.cancel()
        checkTask = nil
        guard succeeded else {
            outcome = .failed
            return
        }
        outcome = .succeeded
        checkTask = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }   // Cancelled: a newer one owns the icon
            outcome = nil
            checkTask = nil
        }
    }

    /// The icon to show instead of the prism, when nothing is converting.
    var icon: NSImage? {
        switch outcome {
        case .succeeded: DoneIcon.check
        case .failed: DoneIcon.exclamation
        case nil: nil
        }
    }

    private func menuOpened() {
        if outcome == .failed { outcome = nil }   // They've seen which file failed
        refreshNote()
    }

    // MARK: Notifications-off note

    /// A batch was summarized with `converted` files done.
    func batchFinished(converted: Int) {
        let count = defaults.integer(forKey: Keys.conversions)
        if converted > 0, count < Self.noteAfter {
            defaults.set(min(count + converted, Self.noteAfter), forKey: Keys.conversions)
        }
        refreshNote()
    }

    func turnOn() {
        if status == .notDetermined {
            Task {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                await afterRequest()
            }
        } else {
            openNotificationSettings()
        }
    }

    func notNow() {
        defaults.set(defaults.integer(forKey: Keys.dismissals) + 1, forKey: Keys.dismissals)
        defaults.set(Date().addingTimeInterval(Self.snooze).timeIntervalSinceReferenceDate, forKey: Keys.snoozedUntil)
        showsNotificationNote = false
    }

    /// Cheap checks first; asks the notification center only once the note could actually show.
    private func refreshNote() {
        guard defaults.integer(forKey: Keys.dismissals) < Self.maxDismissals,
              Date().timeIntervalSinceReferenceDate >= defaults.double(forKey: Keys.snoozedUntil),
              defaults.object(forKey: Keys.notifyWhenDone) as? Bool ?? true,
              defaults.integer(forKey: Keys.conversions) >= Self.noteAfter else {
            showsNotificationNote = false
            return
        }
        Task { await update(to: Self.currentStatus()) }
    }

    private func update(to status: UNAuthorizationStatus) {
        self.status = status
        showsNotificationNote = status == .denied || status == .notDetermined
    }

    /// No prompt appeared (macOS sometimes won't ask twice): send them to System Settings instead.
    private func afterRequest() async {
        let status = await Self.currentStatus()
        update(to: status)
        if status == .notDetermined { openNotificationSettings() }
    }

    private static func currentStatus() async -> UNAuthorizationStatus {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: Keys.debugStatus) {
        case "denied": return .denied
        case "notDetermined": return .notDetermined
        case "authorized": return .authorized
        default: break
        }
        #endif
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        let pane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        if let url = URL(string: "\(pane)?id=\(id)"), NSWorkspace.shared.open(url) { return }
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }
}

/// Menu-bar icons after conversions finish, drawn like the idle prism (same canvas, stroke weight and
/// round ends) as template images: a checkmark when they worked, an exclamation mark when something failed.
enum DoneIcon {
    static let check: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            let check = NSBezierPath()
            check.move(to: NSPoint(x: 5.4, y: 9.6))
            check.line(to: NSPoint(x: 9.4, y: 5.2))
            check.line(to: NSPoint(x: 16.6, y: 13.8))
            check.lineWidth = 1.6
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.black.setStroke()
            check.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Conversion finished"
        return image
    }()

    static let exclamation: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let bar = NSBezierPath()
            bar.move(to: NSPoint(x: 11, y: 15.4))
            bar.line(to: NSPoint(x: 11, y: 7.4))
            bar.lineWidth = 1.6
            bar.lineCapStyle = .round
            bar.stroke()
            NSBezierPath(ovalIn: NSRect(x: 10, y: 2.8, width: 2, height: 2)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "A conversion failed"
        return image
    }()
}

/// One quiet line in the menu when banners can't appear: "Notifications are off · Turn On · Not now".
struct NotificationNote: View {
    let feedback: CompletionFeedback

    var body: some View {
        if feedback.showsNotificationNote {
            Divider().padding(.horizontal, 16)
            HStack(spacing: 6) {
                Image(systemName: "bell.slash").foregroundStyle(.secondary)
                Text("Notifications are off").foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Turn On") { feedback.turnOn() }
                Text("·").foregroundStyle(.tertiary)
                Button("Not now") { feedback.notNow() }.foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}
