import SwiftUI

struct MyApp: App {   // Started by `Entry` (CommandLineTool.swift) unless run as a command
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // Menu-bar only: no Dock icon (LSUIElement) and no main window.
        MenuBarExtra {
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
