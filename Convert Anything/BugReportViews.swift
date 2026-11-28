import AppKit
import SwiftUI

extension BugReport {
    nonisolated enum Destination: Sendable { case form, issue }

    static let help = "Opens a form in your browser with your app and macOS versions, Mac model and a recent log filled in. "
        + "File names and paths are left out, and you see everything before you send it."
    static let jobHelp = "Opens a form in your browser with this conversion's formats and error filled in. "
        + "File names and paths are left out, and you see everything before you send it."

    /// Gathers the details and opens the pre-filled page in the browser. Reading the log takes
    /// a second or more, so it happens off the main thread; await the task to know when it's done.
    @discardableResult
    static func open(_ destination: Destination, for job: Job? = nil) -> Task<Void, Never> {
        var report = BugReport()
        var redactor = Redactor()
        if let job {
            let urls = [job.originalURL, job.fileURL, job.resultURL].compactMap { $0 }
            redactor.names = urls.flatMap {
                [$0.lastPathComponent, $0.deletingPathExtension().lastPathComponent, $0.deletingLastPathComponent().lastPathComponent]
            }
            report.conversion = "\(shownExtension(job.originalURL)) → \(shownExtension(job.fileURL))"
            if case .failed(let message) = job.state {
                report.errorMessage = String(redactor(message).prefix(maxErrorLength))
            }
        }
        return Task.detached(priority: .userInitiated) { [report, redactor] in
            var report = report
            report.log = recentLog(redactor: redactor)
            let url = destination == .form ? report.formURL : report.issueURL
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
    }

    /// The extension as typed, if it looks like one.
    private static func shownExtension(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return !ext.isEmpty && ext.count <= 10 && ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? ext : "?"
    }
}

/// Settings' Help card: the bug report button, with a GitHub issue as the alternative below it.
struct BugReportCard: View {
    @State private var preparing = false

    var body: some View {
        Card(title: "Help") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Report a bug")
                Spacer(minLength: 8)
                if preparing { ProgressView().controlSize(.small) }
                VStack(alignment: .trailing, spacing: 4) {
                    Button("Report a Bug…") { report(.form) }
                        .help(BugReport.help)
                    Button("Have a GitHub account? Open an issue instead.") { report(.issue) }
                        .buttonStyle(.link)
                        .font(.subheadline)
                        .help("Opens a new, public GitHub issue with the same details filled in.")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .disabled(preparing)
        }
    }

    private func report(_ destination: BugReport.Destination) {
        preparing = true
        Task {
            await BugReport.open(destination).value
            preparing = false
        }
    }
}
