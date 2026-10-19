import SwiftUI

@main struct MyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        // Menu-bar only: no Dock icon (LSUIElement) and no main window.
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            Image(systemName: model.hasActiveJobs ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath")
        }
        .menuBarExtraStyle(.window)
    }
}
