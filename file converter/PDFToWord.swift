import AppKit
import PDFKit

/// PDF → Word. (First version: the text only; images come next.)
enum PDFToWord {
    static func convert(_ request: Converter.Request, output: URL) async throws {
        let text = try await DocumentConversion.extractPDFText(request.input)
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11)])
        let data = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                       documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try data.write(to: output)
    }
}
