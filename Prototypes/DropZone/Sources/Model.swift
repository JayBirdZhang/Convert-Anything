import Foundation
import Observation

/// Everything the menu shows. Nothing here touches the real app: defaults live in this prototype's own
/// domain (its bundle id), and nothing watches folders or converts anything.
@Observable final class Model {
    enum Phase: Equatable {
        case idle                    // The plain menu
        case dragging                // A drag is over the menu: tiles on top
        case chooser                 // Dropped on More…: every format as chips
        case converting(String)      // The fake progress line
    }

    struct Recent: Identifiable {
        let id = UUID()
        let name: String
        let from: String
        let to: String
        let date: Date
    }

    var phase: Phase = .idle
    var files: [URL] = []
    var plan = DropPlan()
    var hovered: Tile?
    @ObservationIgnored var tileFrames: [Tile: CGRect] = [:]

    var convertOnRename = true   // Fake: does nothing
    var recent: [Recent] = [
        Recent(name: "IMG_2041.jpg", from: "heic", to: "jpg", date: Date().addingTimeInterval(-60 * 14)),
        Recent(name: "Interview.m4a", from: "mp4", to: "m4a", date: Date().addingTimeInterval(-60 * 52)),
        Recent(name: "Essay.pdf", from: "docx", to: "pdf", date: Date().addingTimeInterval(-60 * 60 * 3)),
    ]

    var springDelay: Double = UserDefaults.standard.object(forKey: "springDelay") as? Double ?? 0.3 {
        didSet { UserDefaults.standard.set(springDelay, forKey: "springDelay") }
    }

    /// How far below the menu bar a dragged file opens the menu.
    var openDistance: Double = UserDefaults.standard.object(forKey: "openDistance") as? Double ?? 90 {
        didSet { UserDefaults.standard.set(openDistance, forKey: "openDistance") }
    }

    /// Last chosen target per source type ("heic" → "jpeg", "heic+png" → "combine").
    var memory: [String: String] = UserDefaults.standard.dictionary(forKey: "lastChoice") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(memory, forKey: "lastChoice") }
    }

    var sourceFormat: Format? { files.first.flatMap { Format(fileExtension: $0.pathExtension) } }

    var dragTitle: String {
        if files.count == 1 { return "Convert \(files[0].lastPathComponent) to…" }
        return "Convert \(files.count) files to…"
    }

    func beginDrag(_ urls: [URL]) {
        files = urls
        plan = DropPlan.make(for: urls, memory: memory)
        hovered = nil
        phase = .dragging
        Log.write("plan for \(urls.map(\.lastPathComponent)): tiles=\(plan.tiles.map(label(for:))) message=\(plan.message ?? "-")")
    }

    /// The tile under a point in the panel's SwiftUI coordinates (top-left origin).
    func tile(at point: CGPoint) -> Tile? {
        guard phase == .dragging else { return nil }
        return tileFrames.first { plan.tiles.contains($0.key) && $0.value.contains(point) }?.key
    }

    func remember(_ tile: Tile) {
        guard let value = tile.memoryValue, !plan.memoryKey.isEmpty else { return }
        memory[plan.memoryKey] = value
    }

    /// Adds the fake results to Recent.
    func addRecent(for tile: Tile) {
        let now = Date()
        switch tile {
        case .combine:
            let from = files.first?.pathExtension.lowercased() ?? "jpg"
            recent.insert(Recent(name: "Combined.pdf", from: from, to: "pdf", date: now), at: 0)
        case .format(let f):
            for url in files.reversed() {
                let name = url.deletingPathExtension().lastPathComponent + "." + f.preferredExtension
                recent.insert(Recent(name: name, from: url.pathExtension.lowercased(), to: f.preferredExtension, date: now), at: 0)
            }
        case .more: return
        }
        recent = Array(recent.prefix(8))
    }

    func label(for tile: Tile) -> String {
        switch tile {
        case .format(let f): "." + f.preferredExtension
        case .combine: "Combine into PDF"
        case .more: "More…"
        }
    }

    func reset() {
        phase = .idle
        files = []
        plan = DropPlan()
        hovered = nil
    }
}
