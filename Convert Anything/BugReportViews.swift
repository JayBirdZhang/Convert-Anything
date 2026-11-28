import AppKit
import SwiftUI

extension BugReport {
    nonisolated enum Destination: Sendable { case form, issue }

    static let help = "Opens a form in your browser with your app and macOS versions, Mac model and a recent log filled in. "
        + "File names and paths are left out, and you see everything before you send it."
    static let jobHelp = "Opens a form in your browser with this conversion's formats and error filled in. "
        + "File names and paths are left out, and you see everything before you send it."

    /// The report being prepared, so pressing again while it's on its way doesn't open a second tab.
    private static var preparing: Task<Void, Never>?

    /// Gathers the details and opens the pre-filled page in the browser. Reading the log takes
    /// a second or more, so it happens off the main thread; await the task to know when it's done.
    @discardableResult
    static func open(_ destination: Destination, model: AppModel, for job: Job? = nil) -> Task<Void, Never> {
        if let preparing { return preparing }
        var report = BugReport()
        var redactor = Redactor()
        // Every file and folder name the app knows, so names with spaces go too, not only their last word.
        let urls = model.jobs.flatMap { [$0.originalURL, $0.fileURL, $0.resultURL].compactMap { $0 } }
        redactor.names = urls.flatMap {
            [$0.lastPathComponent, $0.deletingPathExtension().lastPathComponent, $0.deletingLastPathComponent().lastPathComponent]
        } + model.watchedFolders.map { URL(fileURLWithPath: $0).lastPathComponent }
        if let job {
            report.conversion = "\(shownExtension(job.originalURL)) → \(shownExtension(job.fileURL))"
            if case .failed(let message) = job.state {
                report.errorMessage = String(redactor(message).prefix(maxErrorLength))
            }
        }
        let task = Task {
            let url = await Task.detached(priority: .userInitiated) { [report, redactor] in
                var report = report
                report.log = recentLog(redactor: redactor)
                return destination == .form ? report.formURL : report.issueURL
            }.value
            NSWorkspace.shared.open(url)
            preparing = nil
        }
        preparing = task
        return task
    }

    /// The extension as typed, if it looks like one.
    private static func shownExtension(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return !ext.isEmpty && ext.count <= 10 && ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? ext : "?"
    }
}

/// Settings' Help card: the bug report button, with a GitHub issue as the alternative below it.
struct BugReportCard: View {
    let model: AppModel
    @State private var preparing = false

    var body: some View {
        Card(title: "Help") {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Report a bug")
                    Spacer(minLength: 8)
                    if preparing { ProgressView().controlSize(.small) }
                    Button("Report a Bug…") { report(.form) }
                        .help(BugReport.help)
                }
                Button("Have a GitHub account? Open an issue instead.") { report(.issue) }
                    .buttonStyle(.link)
                    .font(.subheadline)
                    .help("Opens a new, public GitHub issue with the same details filled in. Issues are public.")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .disabled(preparing)
        }
    }

    private func report(_ destination: BugReport.Destination) {
        preparing = true
        Task {
            await BugReport.open(destination, model: model).value
            preparing = false
        }
    }
}
