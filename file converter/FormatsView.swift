import SwiftUI

/// "What can I convert?": every supported conversion, grouped by kind of file. Built from the converter's
/// own routes, so it's always accurate.
struct FormatsView: View {
    let back: () -> Void

    private struct Group: Identifiable {
        let title: String
        let symbol: String
        let sources: [Format]
        var id: String { title }
    }

    private let groups: [Group] = [
        Group(title: "Images", symbol: "photo", sources: Format.allCases.filter { $0.kind == .image }),
        Group(title: "Documents", symbol: "doc.text", sources: Format.allCases.filter { $0.kind == .document && !$0.isSlides }),
        Group(title: "Presentations", symbol: "rectangle.on.rectangle", sources: Format.allCases.filter(\.isSlides)),
        Group(title: "Spreadsheets", symbol: "tablecells", sources: Format.allCases.filter { $0.kind == .spreadsheet }),
        Group(title: "Audio", symbol: "waveform", sources: Format.allCases.filter { $0.kind == .audio }),
        Group(title: "Video", symbol: "film", sources: Format.allCases.filter { $0.kind == .video }),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: back) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.caption.weight(.semibold))
                    Text("What can I convert?").font(.headline)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(group.title, systemImage: group.symbol).font(.subheadline.weight(.semibold))
                            line("From", group.sources)
                            line("To", targets(of: group.sources))
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        tip("text.viewfinder", "Rename a photo or scanned PDF to .txt or .docx to get its text.")
                        tip("arrow.uturn.backward", "Rename a file back to undo, or press ⌘Z in Finder.")
                        tip("square.stack", "Many files: select them, right-click → Rename…, replace the extension.")
                        tip("doc.on.doc", "PowerPoint, Excel and iWork files use Keynote, Numbers or Pages (free from Apple).")
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 380)
        }
    }

    private func line(_ label: String, _ formats: [Format]) -> some View {
        Text("\(Text(label + "  ").foregroundStyle(.secondary))\(formats.map { "." + $0.preferredExtension }.joined(separator: " "))")
            .font(.caption.monospaced())
            .fixedSize(horizontal: false, vertical: true)
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Every format at least one of `sources` can become.
    private func targets(of sources: [Format]) -> [Format] {
        Format.allCases.filter { target in sources.contains { Converter.route(from: $0, to: target) != nil } }
    }
}

extension Format {
    /// The extension people usually type.
    var preferredExtension: String { self == .jpeg ? "jpg" : rawValue }
}
