import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showSettings = false
    @State private var showFormats = false

    var body: some View {
        Group {
            if showFormats {
                FormatsView { showFormats = false }
            } else {
                main
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            if model.batches.isEmpty {
                emptyState
            } else {
                jobList
            }
            Divider()
            // One footer row: the Settings toggle on the left, small Clear History and Quit controls on the right.
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showSettings.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(showSettings ? 90 : 0))
                        Text("Settings")
                    }
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if model.batches.contains(where: { !$0.isActive }) {
                    Button("Clear History") { model.clearFinished() }
                        .font(.caption)
                }
                Button {
                    showFormats = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .help("What can I convert?")
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .keyboardShortcut("q")
                .help("Quit Convert Everything")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            if showSettings {
                settings.padding(.top, 2)
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Convert Everything").font(.headline)
                Text(model.isWatching ? "Watching \(model.watchedFolders.count) folder\(model.watchedFolders.count == 1 ? "" : "s")" : "Paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Watching", isOn: $model.isWatching)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Rename a file's extension to convert it.")
            Text("notes.md → notes.docx  ·  photo.heic → photo.jpg")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Many files: select them in Finder, right-click → Rename…, and replace the extension.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var jobList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.batches) { batch in
                    if batch.jobs.count == 1, let job = batch.jobs.first {
                        JobRow(job: job, model: model)
                    } else {
                        BatchRow(batch: batch, model: model)
                    }
                }
            }
        }
        .frame(maxHeight: 260)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Watched folders").font(.caption).foregroundStyle(.secondary)
            ForEach(model.watchedFolders, id: \.self) { path in
                HStack {
                    Image(systemName: "folder")
                    Text(displayPath(path)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button {
                        model.removeFolder(path)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Stop watching this folder")
                }
            }
            Button("Add Folder…") { model.addFolder() }
                .buttonStyle(.borderless)

            Divider()
            Picker("Originals", selection: $model.originals) {
                ForEach(OriginalsMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .help("Move to Trash keeps a backup you can restore by renaming the file back (or ⌘Z in Finder).")
            Picker("Quality", selection: $model.quality) {
                ForEach(Quality.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .help("Smaller files: lower-quality photos (resized to at most 2560 px), audio and video (at most 1080p). Documents aren't affected.")
            Picker("PDF → PowerPoint", selection: $model.editableSlides) {
                Text("Editable text").tag(true)
                Text("Page pictures").tag(false)
            }
            .pickerStyle(.menu)
            .help("Editable text: text you can change, laid over the page's images and shapes. Page pictures: each page as an exact, non-editable image.")
            Toggle("Export every page of PDFs and slides", isOn: $model.exportAllPages)
                .help("When a multi-page PDF or PowerPoint is renamed to an image format, save every page as an image in a folder. Off: only the first page.")
            Toggle("Combine files renamed to PDF together into one", isOn: $model.combinePDFs)
                .help("When several files are renamed to .pdf at once, merge them into a single Combined.pdf in name order.")
            Toggle("Notify when conversions finish", isOn: $model.showNotifications)
            Toggle("Open at login", isOn: $model.launchAtLogin)
        }
        .toggleStyle(.checkbox)
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

private struct JobRow: View {
    let job: Job
    let model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text((job.resultURL ?? job.fileURL).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch job.state {
                case .converting(let progress?):
                    ProgressView(value: progress).controlSize(.small)
                case .converting(nil):
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                default:
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            actions
        }
    }

    private var isFailure: Bool {
        if case .failed = job.state { true } else { false }
    }

    private var status: String {
        let conversion = "\(job.from.displayName) → \(job.to.displayName)"
        switch job.state {
        case .waiting: return "Waiting · \(conversion)"
        case .converting: return conversion
        case .done: return job.pageCount.map { "\(conversion) · \($0) images" } ?? conversion
        case .failed(let message): return message
        case .cancelled: return "Cancelled · name restored"
        case .undone: return "Undone · original restored"
        }
    }

    @ViewBuilder private var icon: some View {
        switch job.state {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .converting: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled, .undone: Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            if job.isActive {
                Button { model.cancel(job) } label: { Image(systemName: "xmark.circle") }
                    .help("Cancel and restore the original name")
            } else {
                if job.state == .done && job.canUndo {
                    Button { model.undo(job) } label: { Image(systemName: "arrow.uturn.backward") }
                        .help("Undo: bring back the original (you can also rename the file back, or press ⌘Z in Finder)")
                }
                Button { model.reveal(job) } label: { Image(systemName: "magnifyingglass") }
                    .help("Show in Finder")
            }
        }
        .buttonStyle(.borderless)
    }
}

/// Several files renamed together: one row with combined progress, expandable to the individual files.
private struct BatchRow: View {
    let batch: Batch
    let model: AppModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                icon.frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(batch.jobs.count) files → \(batch.to.displayName)")
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? "Hide files" : "Show files")

                    if batch.isActive {
                        ProgressView(value: batch.progress).controlSize(.small)
                        Text("\(batch.finishedCount) of \(batch.jobs.count) · \(batch.folder.lastPathComponent)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(failedCount > 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                actions
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(batch.jobs) { job in
                        JobRow(job: job, model: model)
                    }
                }
                .padding(.leading, 26)
            }
        }
    }

    private func count(_ matches: (Job.State) -> Bool) -> Int { batch.jobs.count { matches($0.state) } }
    private var failedCount: Int { count { if case .failed = $0 { true } else { false } } }

    private var summary: String {
        var parts = [batch.combinedURL.map { "Combined into \($0.lastPathComponent)" } ?? "\(count { $0 == .done }) converted"]
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        let cancelled = count { $0 == .cancelled }, undone = count { $0 == .undone }
        if cancelled > 0 { parts.append("\(cancelled) cancelled") }
        if undone > 0 { parts.append("\(undone) undone") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var icon: some View {
        if batch.isActive {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
        } else if failedCount > 0 {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if count({ $0 == .done }) > 0 {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            if batch.isActive {
                Button { model.cancel(batch) } label: { Image(systemName: "xmark.circle") }
                    .help("Cancel the rest and restore their original names")
            } else {
                if batch.jobs.contains(where: { $0.state == .done && $0.canUndo }) {
                    Button { model.undoAll(batch) } label: { Image(systemName: "arrow.uturn.backward") }
                        .help("Undo all: bring back every original from the Trash")
                }
                Button { model.reveal(batch) } label: { Image(systemName: "magnifyingglass") }
                    .help("Show in Finder")
            }
        }
        .buttonStyle(.borderless)
    }
}
