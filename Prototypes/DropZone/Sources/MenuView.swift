import SwiftUI
import UniformTypeIdentifiers

struct TileFramesKey: PreferenceKey {
    static let defaultValue: [Tile: CGRect] = [:]
    static func reduce(value: inout [Tile: CGRect], nextValue: () -> [Tile: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The prototype's menu: drop tiles on top while dragging, then the usual header, toggle and Recent list,
/// and a small tuning section.
struct MenuView: View {
    @Bindable var model: Model
    var onSize: (CGSize) -> Void = { _ in }
    var onChoose: (Tile) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onQuit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.phase {
            case .idle: EmptyView()
            case .dragging: dropSection
            case .chooser: chooser
            case .converting(let title): ProgressSection(title: title)
            }
            if model.phase != .idle { Divider().padding(.horizontal, 16) }
            header
            Divider().padding(.horizontal, 16)
            if model.phase == .idle {   // Not while a file is being dropped
                recent
                Divider().padding(.horizontal, 16)
            }
            tuning
            Divider().padding(.horizontal, 16)
            HStack {
                Spacer()
                FooterButton("Quit", symbol: "power", help: "Quit the prototype", shortcut: "q", action: onQuit)
            }
            .padding(8)
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .coordinateSpace(name: "panel")
        .onPreferenceChange(TileFramesKey.self) { model.tileFrames = $0 }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
    }

    // MARK: Drop tiles

    private var dropSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.dragTitle).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
            if let message = model.plan.message {
                HStack(spacing: 8) {
                    Image(systemName: "nosign").foregroundStyle(.secondary)
                    Text(message)
                }
                .frame(maxWidth: .infinity, minHeight: 62)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 9))
            } else {
                let formats = model.plan.tiles.filter { if case .format = $0 { true } else { false } }
                if model.plan.remembered == .combine { tile(.combine, height: 44) }
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(Array(stride(from: 0, to: formats.count, by: 2)), id: \.self) { i in
                        GridRow {
                            tile(formats[i], height: 62)
                            if i + 1 < formats.count { tile(formats[i + 1], height: 62) } else { Color.clear.frame(height: 62) }
                        }
                    }
                }
                if model.plan.canCombine && model.plan.remembered != .combine { tile(.combine, height: 44) }
                if model.plan.tiles.contains(.more) { tile(.more, height: 32) }
            }
            Text(model.plan.message == nil ? "Let go anywhere else to cancel" : "Let go to cancel")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(12)
    }

    private func tile(_ tile: Tile, height: CGFloat) -> some View {
        TileView(model: model, tile: tile, height: height)
            .background(GeometryReader { geo in
                Color.clear.preference(key: TileFramesKey.self, value: [tile: geo.frame(in: .named("panel"))])
            })
    }

    // MARK: More… chooser

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.dragTitle).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(.borderless).font(.subheadline)
            }
            FlowLayout(spacing: 6) {
                if model.plan.canCombine { Chip(text: "Combine into PDF", kind: .document) { onChoose(.combine) } }
                ForEach(model.plan.all, id: \.self) { f in
                    Chip(text: "." + f.preferredExtension, kind: f.kind) { onChoose(.format(f)) }
                }
            }
        }
        .padding(12)
    }

    // MARK: The usual menu

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Convert Anything").fontWeight(.semibold)
                Text("drop zone prototype")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 4))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Convert on rename").fontWeight(.medium)
                    Text(model.convertOnRename ? "Watching Downloads and Desktop" : "Off · renamed files are left alone")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("Convert on rename", isOn: $model.convertOnRename)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
            ForEach(model.recent.prefix(5)) { item in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: item.to) ?? .data))
                        .resizable().frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Text(timeLabel(item.date)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    ExtensionChange(from: item.from, to: item.to)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
        .padding(.bottom, 8)
    }

    private var tuning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Prototype tuning").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            HStack {
                Text("Wait before opening")
                Spacer()
                Text(String(format: "%.2f s", model.springDelay)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { model.springDelay }, set: { model.springDelay = ($0 * 20).rounded() / 20 }), in: 0...1.0).controlSize(.small)
            HStack {
                Text("Opens within")
                Spacer()
                Text("\(Int(model.openDistance)) pt below the menu bar").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { model.openDistance }, set: { model.openDistance = ($0 / 10).rounded() * 10 }), in: 20...300).controlSize(.small)
            HStack {
                Text(model.memory.isEmpty ? "No remembered formats" : "\(model.memory.count) remembered format\(model.memory.count == 1 ? "" : "s")")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { model.memory = [:] }.controlSize(.small).disabled(model.memory.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func timeLabel(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// A drop target. Dashed until it matters: solid and tinted for the remembered choice, filled with the
/// accent colour while the drag is over it (as in mockup B).
private struct TileView: View {
    let model: Model
    let tile: Tile
    let height: CGFloat

    var body: some View {
        let hovered = model.hovered == tile
        let remembered = model.plan.remembered == tile
        let format: Format? = if case .format(let f) = tile { f } else { nil }
        let shape = RoundedRectangle(cornerRadius: 9)
        Group {
            switch tile {
            case .format(let f):
                VStack(spacing: 2) {
                    Text("." + f.preferredExtension)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(hovered ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(f.kind.ink))
                    Text(remembered ? "Last used" : f.tileName(from: model.sourceFormat))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .combine:
                Label("Combine into PDF", systemImage: "doc.on.doc").fontWeight(.medium)
                    .foregroundStyle(hovered ? Color.accentColor : .primary)
            case .more:
                Text("More…").foregroundStyle(hovered ? Color.accentColor : .secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(shape.fill(hovered ? AnyShapeStyle(Color.accentColor.opacity(0.16))
                                : remembered ? AnyShapeStyle(format?.kind.wash ?? Color.accentColor.opacity(0.1))
                                : AnyShapeStyle(Color.primary.opacity(0.04))))
        .overlay(shape.strokeBorder(hovered ? AnyShapeStyle(Color.accentColor)
                                    : remembered ? AnyShapeStyle(format?.kind.tint ?? Color.accentColor)
                                    : AnyShapeStyle(Color.secondary.opacity(0.45)),
                                    style: StrokeStyle(lineWidth: 1.5, dash: hovered || remembered ? [] : [4, 3])))
        .scaleEffect(hovered ? 1.03 : 1)
        .animation(.easeOut(duration: 0.1), value: hovered)
    }
}

private struct Chip: View {
    let text: String
    let kind: Format.Kind
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(hovering ? Color.accentColor : kind.ink)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(hovering ? Color.accentColor.opacity(0.14) : kind.wash, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The ~1 s fake conversion.
private struct ProgressSection: View {
    let title: String
    @State private var progress = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
            Capsule().fill(.quaternary).frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule().fill(Color.accentColor).frame(width: geo.size.width * progress)
                    }
                }
        }
        .padding(12)
        .onAppear { withAnimation(.linear(duration: 0.95)) { progress = 1 } }
    }
}

/// Lays views out left to right, wrapping like words.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 316
        let rows = arrange(width: width, subviews: subviews)
        return CGSize(width: width, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            for (index, x) in row.items {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row { var items: [(Int, CGFloat)] = []; var y: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        var x: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
                x = 0
            }
            rows[rows.count - 1].items.append((index, x))
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            x += size.width + spacing
        }
        return rows
    }
}
