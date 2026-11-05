import AppKit
import WebKit

/// Lays out an HTML page with macOS's web engine (full CSS, MathML for math, images) and prints it to a
/// paginated PDF, the way Safari's File → Export as PDF does. Runs in an invisible window.
enum WebPDF {
    /// `page` is the paper size in points; `margin` the space around the content. With `file`, the page is
    /// loaded from disk (so it can use images next to it) instead of from `html`.
    static func render(html: String, baseURL: URL, output: URL, page: CGSize = CGSize(width: 612, height: 792),
                       margin: CGFloat = 54, file: URL? = nil) async throws {
        let size = NSRect(x: 0, y: 0, width: page.width, height: page.height)
        let webView = WKWebView(frame: size)
        let window = NSWindow(contentRect: size.offsetBy(dx: -20_000, dy: -20_000), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { window.close() }

        let loader = Loader()
        webView.navigationDelegate = loader
        if let file {
            webView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        } else {
            webView.loadHTMLString(html, baseURL: baseURL)
        }
        try await loader.wait()
        // Give images and MathML a moment to lay out.
        try await Task.sleep(for: .milliseconds(300))

        let info = NSPrintInfo()
        info.paperSize = page
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output

        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = size
        let finisher = Finisher()
        await withCheckedContinuation { continuation in
            finisher.continuation = continuation
            operation.runModal(for: window, delegate: finisher, didRun: #selector(Finisher.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        guard finisher.success, FileManager.default.fileExists(atPath: output.path) else {
            throw ConversionError.failed("Couldn't create the PDF.")
        }
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var result: Result<Void, Error>?

        func wait() async throws {
            if let result { return try result.get() }
            try await withCheckedThrowingContinuation { self.continuation = $0 }
        }

        private func finish(_ result: Result<Void, Error>) {
            guard self.result == nil else { return }
            self.result = result
            continuation?.resume(with: result)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    }

    private final class Finisher: NSObject {
        var continuation: CheckedContinuation<Void, Never>?
        var success = false

        @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            self.success = success
            continuation?.resume()
            continuation = nil
        }
    }
}
