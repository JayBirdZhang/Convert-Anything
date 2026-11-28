import SwiftUI
import UniformTypeIdentifiers

/// One entry in the Recent list: a single conversion, or several files renamed together.
struct HistoryRow: View {
    let batch: Batch
    let model: AppModel
    var now = Date()
    var expanded = false
    var hovering = false

    var body: some View {
        if batch.jobs.count == 1, let job = batch.jobs.first {
            JobRow(job: job, model: model, now: now, hovering: hovering)
        } else {
            BatchRow(batch: batch, model: model, now: now, expanded: expanded, hovering: hovering)
        }
    }
}

/// A file being converted, or the result. Clicking a finished one shows it in Finder.
private struct JobRow: View {
    let job: Job
    let model: AppModel
    var now: Date?        // Shows when it happened; nil inside an expanded batch, which shows it once
    var compact = false   // Inside an expanded batch
    @State private var hovering: Bool

    init(job: Job, model: AppModel, now: Date? = nil, compact: Bool = false, hovering: Bool = false) {
        self.job = job
        self.model = model
        self.now = now
        self.compact = compact
        _hovering = State(initialValue: hovering)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            FileIcon(type: type, size: compact ? 20 : 28, dimmed: isDimmed, failed: isFailure)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if hovering && !job.isActive { actions }
                }
                detail
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 4 : 8)
        .contentShape(Rectangle())
        .hoverHighlight(hovering && !job.isActive)
        .onHover { hovering = $0 }
        .onTapGesture { if !job.isActive { model.reveal(job) } }
        .contextMenu {
            if !job.isActive {
                Button("Show in Finder") { model.reveal(job) }
                if job.state == .done && job.canUndo { Button("Undo") { model.undo(job) } }
                if isFailure { Button("Report…") { BugReport.open(.form, model: model, for: job) }.help(BugReport.jobHelp) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Show in Finder") { model.reveal(job) }
    }

    /// The file as it is on disk now: the result once converted, the original name again if it wasn't.
    private var url: URL {
        switch job.state {
        case .done: job.resultURL ?? job.fileURL
        case .waiting, .converting: job.fileURL
        case .failed, .cancelled, .undone: job.originalURL
        }
    }

    private var type: UTType {
        job.state == .done && job.pageCount != nil ? .folder : UTType(filenameExtension: url.pathExtension) ?? .data
    }

    private var isFailure: Bool {
        if case .failed = job.state { true } else { false }
    }

    private var isDimmed: Bool {
        [.waiting, .cancelled, .undone].contains(job.state) || isMissing
    }

    /// Done, but showing it in Finder found nothing there.
    private var isMissing: Bool {
        job.state == .done && job.resultMissing
    }

    @ViewBuilder private var detail: some View {
        switch job.state {
        case .converting(let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress).controlSize(.small).tint(job.to.kind.tint)   // A nil value makes it indeterminate
                cancelButton
            }
        case .waiting:
            HStack(spacing: 8) {
                change
                Text("Waiting").font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                cancelButton
            }
        case .done:
            HStack(spacing: 8) {
                change
                Text(([job.pageCount.map { "\($0) \(job.to.kind == .image ? "images" : "files")" },
                       isMissing ? "Moved or deleted" : nil,
                       now.map { timeLabel(job.started, now: $0) }].compactMap { $0 }).joined(separator: " · "))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .failed(let message):
            DetailText(message)
        case .cancelled:
            DetailText("Cancelled · name restored")
        case .undone:
            DetailText("Undone · original restored")
        }
    }

    /// The extensions as typed: the one the file had and the one it was renamed to.
    private var change: some View {
        ExtensionChange(from: job.originalURL.pathExtension, to: job.fileURL.pathExtension)
    }

    private var cancelButton: some View {
        IconButton("Cancel", symbol: "xmark.circle.fill", help: "Cancel and restore the original name") { model.cancel(job) }
    }

    @ViewBuilder private var actions: some View {
        if job.state == .done && job.canUndo {
            IconButton("Undo", symbol: "arrow.uturn.backward",
                       help: "Bring back the original (you can also rename the file back, or press ⌘Z in Finder)") { model.undo(job) }
        }
        if isFailure {
            IconButton("Report…", symbol: "exclamationmark.bubble", help: BugReport.jobHelp) { BugReport.open(.form, model: model, for: job) }
        }
        IconButton("Show in Finder", symbol: "magnifyingglass") { model.reveal(job) }
    }
}

/// Several files renamed together: combined progress, expandable to the individual files.
private struct BatchRow: View {
    let batch: Batch
    let model: AppModel
    let now: Date
    @State private var expanded: Bool
    @State private var hovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(batch: Batch, model: AppModel, now: Date, expanded: Bool = false, hovering: Bool = false) {
        self.batch = batch
        self.model = model
        self.now = now
        _expanded = State(initialValue: expanded)
        _hovering = State(initialValue: hovering)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                FileIcon(type: type, stacked: batch.combinedURL == nil, dimmed: !batch.isActive && done == 0,
                         failed: failed > 0)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if let combined = batch.combinedURL {
                            Text(combined.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("\(batch.jobs.count) files to")
                            ExtensionTag(batch.to.preferredExtension, emphasized: true)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Spacer(minLength: 0)
                        if hovering && !batch.isActive { actions }
                    }
                    detail
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .hoverHighlight(hovering)
            .onHover { hovering = $0 }
            .onTapGesture {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { expanded.toggle() }
            }
            .contextMenu {
                if !batch.isActive {
                    Button("Show in Finder") { model.reveal(batch) }
                    if batch.jobs.contains(where: { $0.state == .done && $0.canUndo }) {
                        Button("Undo All") { model.undoAll(batch) }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: expanded ? "Hide files" : "Show files") { expanded.toggle() }

            if expanded {
                VStack(spacing: 0) {
                    ForEach(batch.jobs) { JobRow(job: $0, model: model, compact: true) }
                }
                .padding(.leading, 36)   // Child icons line up with the batch's title
            }
        }
    }

    private var type: UTType {
        UTType(filenameExtension: batch.combinedURL?.pathExtension ?? batch.to.preferredExtension) ?? .data
    }

    private func count(_ matches: (Job.State) -> Bool) -> Int { batch.jobs.count { matches($0.state) } }
    private var done: Int { count { $0 == .done } }
    private var failed: Int { count { if case .failed = $0 { true } else { false } } }

    @ViewBuilder private var detail: some View {
        if batch.isActive {
            HStack(spacing: 6) {
                ProgressView(value: batch.progress).controlSize(.small).tint(batch.to.kind.tint)
                Text("\(batch.finishedCount) of \(batch.jobs.count)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                IconButton("Cancel", symbol: "xmark.circle.fill", help: "Cancel the rest and restore their original names") {
                    model.cancel(batch)
                }
            }
        } else {
            DetailText(summary)
        }
    }

    private var summary: String {
        var parts = [batch.combinedURL != nil ? "\(done) files combined" : "\(done) converted"]
        if failed > 0 { parts.append("\(failed) failed") }
        let cancelled = count { $0 == .cancelled }, undone = count { $0 == .undone }
        if cancelled > 0 { parts.append("\(cancelled) cancelled") }
        if undone > 0 { parts.append("\(undone) undone") }
        return parts.joined(separator: ", ") + " · " + batch.folder.lastPathComponent + " · " + timeLabel(batch.lastAdded, now: now)
    }

    @ViewBuilder private var actions: some View {
        if batch.jobs.contains(where: { $0.state == .done && $0.canUndo }) {
            IconButton("Undo All", symbol: "arrow.uturn.backward", help: "Bring back every original from the Trash") {
                model.undoAll(batch)
            }
        }
        IconButton("Show in Finder", symbol: "magnifyingglass") { model.reveal(batch) }
    }
}

/// The quiet second line of a row. Wraps, so error messages can be read in full.
private struct DetailText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small borderless symbol button, labeled for VoiceOver and with a tooltip.
private struct IconButton: View {
    let title: String
    let symbol: String
    let help: String
    let action: () -> Void

    init(_ title: String, symbol: String, help: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.help = help ?? title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

/// The Finder icon for a kind of file, dimmed when nothing happened to it and badged when it failed.
private struct FileIcon: View {
    let type: UTType
    var size: CGFloat = 28
    var stacked = false   // Several files
    var dimmed = false
    var failed = false

    var body: some View {
        let icon = Image(nsImage: NSWorkspace.shared.icon(for: type)).resizable()
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                if stacked {
                    icon.frame(width: size * 0.8, height: size * 0.8).offset(x: -size * 0.14, y: -size * 0.1)
                }
                icon.frame(width: size * (stacked ? 0.8 : 1), height: size * (stacked ? 0.8 : 1))
                    .offset(x: stacked ? size * 0.1 : 0, y: stacked ? size * 0.1 : 0)
            }
            .opacity(dimmed ? 0.45 : 1)
            if failed {
                Image(systemName: "exclamationmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
                    .font(.system(size: size * 0.42))
                    .offset(x: 2, y: 1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
