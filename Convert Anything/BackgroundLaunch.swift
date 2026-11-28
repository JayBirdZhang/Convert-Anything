import AppKit
import Observation

/// When Shortcuts runs Convert File while the app isn't running, macOS starts the app just for that. Such a
/// launch converts and quits, instead of leaving a menu-bar app watching folders that the user had quit.
///
/// Until it's clear how the app was opened, the menu-bar icon, folder watching, the update check and the
/// welcome panel wait. A normal open (login item, Finder, Dock, Spotlight) is recognised at once; any other
/// launch waits up to `grace` for an action and becomes a normal launch if none comes.
@Observable
final class BackgroundLaunch {
    static let shared = BackgroundLaunch()

    private enum State { case deciding, holding, normal }
    private static let grace: TimeInterval = 5
    /// Lets Shortcuts collect the result, and a following action in the same shortcut start, before quitting.
    private static let quitDelay: TimeInterval = 2

    private(set) var showsIcon = false
    @ObservationIgnored private var state = State.deciding
    @ObservationIgnored private var startedByAction = false
    @ObservationIgnored private var running = 0
    @ObservationIgnored private var pendingQuit: DispatchWorkItem?
    @ObservationIgnored private var onRelease: [() -> Void] = []

    /// Whether folder watching should wait.
    var isHolding: Bool { state != .normal }

    /// Runs `work` once the launch turns out to be a normal one (right away if it already has).
    func whenNormal(_ work: @escaping () -> Void) {
        if state == .normal { work() } else { onRelease.append(work) }
    }

    /// From `applicationDidFinishLaunching`.
    func launched(_ notification: Notification) {
        let isDefault = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        guard state == .deciding else { return }
        if isDefault && !startedByAction { release(); return }
        state = .holding
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace) { [weak self] in
            guard let self, !self.startedByAction else { return }
            self.release()
        }
    }

    /// The user opened the app (again): it stays, whatever started it.
    func openedByUser() { release() }

    func actionStarted() {
        pendingQuit?.cancel()
        pendingQuit = nil
        if state != .normal { startedByAction = true }
        running += 1
    }

    func actionFinished() {
        running -= 1
        guard running == 0, startedByAction, state != .normal else { return }
        let quit = DispatchWorkItem { [weak self] in
            guard let self, self.running == 0, self.state != .normal else { return }
            NSApp.terminate(nil)
        }
        pendingQuit = quit
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitDelay, execute: quit)
    }

    private func release() {
        guard state != .normal else { return }
        state = .normal
        pendingQuit?.cancel()
        pendingQuit = nil
        showsIcon = true
        let work = onRelease
        onRelease = []
        work.forEach { $0() }
    }
}
