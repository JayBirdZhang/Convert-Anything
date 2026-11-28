import SwiftUI

struct MyApp: App {   // Started by `Entry` (CommandLineTool.swift) unless run as a command
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var launch = BackgroundLaunch.shared

    var body: some Scene {
        // Menu-bar only: no Dock icon (LSUIElement) and no main window.
        // The icon waits while a Shortcuts-only launch is possible (BackgroundLaunch.swift).
        MenuBarExtra(isInserted: Binding(get: { launch.showsIcon }, set: { _ in })) {
            ContentView(model: model)
        } label: {
            if model.hasActiveJobs {
                Image(nsImage: StatusIcon.ring(progress: model.activeProgress, pulse: model.pulsePhase))
            } else {
                Image(nsImage: IdleIcon.image)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
