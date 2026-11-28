import AppKit
import SwiftUI

/// `--selftest` prints the tiles for sample drags; `--snapshot <folder>` renders each menu state as a PNG.
/// Neither opens a window or touches the remembered choices.
enum SelfTest {
    static let cases: [(String, [String], [String: String])] = [
        ("one HEIC", ["IMG_2041.heic"], [:]),
        ("one HEIC, WebP remembered", ["IMG_2041.heic"], ["heic": "webp"]),
        ("one JPEG", ["photo.jpg"], [:]),
        ("one MP4", ["Interview.mp4"], [:]),
        ("one MOV", ["clip.mov"], [:]),
        ("one MP3", ["song.mp3"], [:]),
        ("one M4A", ["memo.m4a"], [:]),
        ("one DOCX", ["Essay.docx"], [:]),
        ("one PDF", ["Paper.pdf"], [:]),
        ("one PPTX", ["Deck.pptx"], [:]),
        ("one XLSX", ["Budget.xlsx"], [:]),
        ("three images", ["a.heic", "b.png", "c.jpg"], [:]),
        ("three images, combine remembered", ["a.heic", "b.png", "c.jpg"], ["heic+jpeg+png": "combine"]),
        ("image + video", ["a.heic", "b.mp4"], [:]),
        ("mp4 + mov", ["a.mp4", "b.mov"], [:]),
        ("docx + pdf", ["a.docx", "b.pdf"], [:]),
        ("unknown", ["thing.xyz"], [:]),
        ("no extension", ["Makefile"], [:]),
        ("mixed with unknown", ["a.png", "thing.xyz"], [:]),
        ("folder", ["/tmp/Folder/"], [:]),
    ]

    static func urls(_ names: [String]) -> [URL] {
        names.map { $0.hasSuffix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : URL(fileURLWithPath: "/tmp/" + $0) }
    }

    static func run() {
        for (title, names, memory) in cases {
            let plan = DropPlan.make(for: urls(names), memory: memory)
            let tiles = plan.tiles.map { tile -> String in
                let label: String = switch tile {
                case .format(let f): "." + f.preferredExtension
                case .combine: "Combine into PDF"
                case .more: "More…"
                }
                return plan.remembered == tile ? "[\(label)]" : label
            }
            print(title.padding(toLength: 34, withPad: " ", startingAt: 0),
                  plan.message ?? tiles.joined(separator: "  "),
                  plan.message == nil ? "   (\(plan.all.count) in More)" : "")
        }
    }

    static func snapshots(to folder: String) {
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func render(_ name: String, _ configure: (Model) -> Void) {
            let model = Model()
            model.memory = [:]
            configure(model)
            for dark in [false, true] {
                let view = MenuView(model: model)
                    .background(dark ? Color(white: 0.16) : Color(white: 0.94))
                    .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.cgImage else { print("could not render \(name)"); continue }
                let rep = NSBitmapImageRep(cgImage: image)
                let url = dir.appendingPathComponent("\(name)\(dark ? "-dark" : "").png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print(url.path)
            }
        }
        let saved = UserDefaults.standard.dictionary(forKey: "lastChoice")
        render("idle") { _ in }
        render("drag-heic") { $0.beginDrag(urls(["IMG_2041.heic"])); $0.hovered = .format(.png) }
        render("drag-heic-remembered") { m in m.beginDrag(urls(["IMG_2041.heic"])); m.plan = DropPlan.make(for: urls(["IMG_2041.heic"]), memory: ["heic": "webp"]) }
        render("drag-images") { $0.beginDrag(urls(["a.heic", "b.png", "c.jpg"])); $0.hovered = .combine }
        render("drag-unknown") { $0.beginDrag(urls(["thing.xyz"])) }
        render("chooser") { $0.beginDrag(urls(["Interview.mp4"])); $0.phase = .chooser }
        render("converting") { $0.beginDrag(urls(["IMG_2041.heic"])); $0.phase = .converting("IMG_2041.heic → .jpg") }
        UserDefaults.standard.set(saved, forKey: "lastChoice")
    }
}
