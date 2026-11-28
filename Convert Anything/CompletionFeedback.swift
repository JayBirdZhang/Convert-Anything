import AppKit
import Observation
import SwiftUI
import UserNotifications

/// Quiet signs that conversions finished: a checkmark in the menu-bar icon for a moment, and a one-time
/// note in the menu when notifications are off, so people who never see banners still know.
@Observable final class CompletionFeedback {
    /// The menu-bar icon shows a checkmark while this is true.
    private(set) var showsCheck = false
    /// The menu shows "Notifications are off" while this is true.
    private(set) var showsNotificationNote = false

    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var status: UNAuthorizationStatus?
    @ObservationIgnored private var keyObserver: NSObjectProtocol?
    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Keys {
        static let conversions = "completedConversions"   // Counts up to `noteAfter`, then stops being written
        static let dismissed = "notificationNoteDismissed"
        static let notifyWhenDone = "showNotifications"     // AppModel's "Notify when done" setting
        static let debugStatus = "debugNotificationStatus" // Debug builds only: denied, notDetermined or authorized
    }
    private static let noteAfter = 3

    init() {
        // The menu panel becoming key is the menu opening (Welcome.swift relies on the same thing).
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNote() }
        }
    }

    // MARK: Checkmark

    /// Everything that was converting has finished. Shows the checkmark for 2 seconds when it all worked;
    /// a later success restarts the 2 seconds rather than adding a second checkmark.
    func conversionsFinished(succeeded: Bool) {
        guard succeeded else { return }
        checkTask?.cancel()
        showsCheck = true
        checkTask = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }   // Cancelled: a newer one owns the flag
            showsCheck = false
            checkTask = nil
        }
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
        defaults.set(true, forKey: Keys.dismissed)
        showsNotificationNote = false
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
    }

    /// Cheap checks first; asks the notification center only once the note could actually show.
    private func refreshNote() {
        guard !defaults.bool(forKey: Keys.dismissed), defaults.object(forKey: Keys.notifyWhenDone) as? Bool ?? true,
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

/// Menu-bar icon for a moment after conversions finish: a checkmark drawn like the idle prism
/// (same canvas, stroke weight and round ends), as a template image.
enum DoneIcon {
    static let image: NSImage = {
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
