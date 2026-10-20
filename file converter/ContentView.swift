import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            if model.jobs.isEmpty {
                emptyState
            } else {
                jobList
            }
            Divider()
            DisclosureGroup("Settings", isExpanded: $showSettings) {
                settings.padding(.top, 6)
            }
            Divider()
            HStack {
                if model.jobs.contains(where: { !$0.isActive }) {
                    Button("Clear History") { model.clearFinished() }
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("File Converter").font(.headline)
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
        }
        .padding(.vertical, 4)
    }

    private var jobList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.jobs) { job in
                    JobRow(job: job, model: model)
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
            Toggle("Move originals to Trash", isOn: $model.moveOriginalsToTrash)
                .help("Keeps a backup of each original file in the Trash. Turn off to delete originals.")
            Picker("PDF → PowerPoint", selection: $model.editableSlides) {
                Text("Editable text").tag(true)
                Text("Page pictures").tag(false)
            }
            .pickerStyle(.menu)
            .help("Editable text: text you can change, laid over the page's images and shapes. Page pictures: each page as an exact, non-editable image.")
            Toggle("Export every page of PDFs and slides", isOn: $model.exportAllPages)
                .help("When a multi-page PDF or PowerPoint is renamed to an image format, save every page as an image in a folder. Off: only the first page.")
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
                if job.state == .done && job.originalInTrash != nil {
                    Button { model.undo(job) } label: { Image(systemName: "arrow.uturn.backward") }
                        .help("Undo: bring back the original from the Trash")
                }
                Button { model.reveal(job) } label: { Image(systemName: "magnifyingglass") }
                    .help("Show in Finder")
            }
        }
        .buttonStyle(.borderless)
    }
}
