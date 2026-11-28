import Foundation

/// OpenDocument spreadsheets (.ods) are a zip whose content.xml holds every sheet. Only the cells are read;
/// the rest of the app's spreadsheet code (CSV, JSON and Excel writers) takes it from there.
nonisolated enum OpenDocumentSheets {
    static func read(_ contentXML: URL) throws -> [Spreadsheets.Sheet] {
        guard let data = try? Data(contentsOf: contentXML) else { throw ConversionError.failed("Couldn't read this spreadsheet.") }
        return ODSParser(data).sheets
    }
}

/// Reads the cells of every sheet. LibreOffice pads sheets to their full size with "repeated" empty cells and
/// rows (16,384 columns by a million rows), so empty runs are only counted and become real cells or rows when
/// something comes after them.
nonisolated private final class ODSParser: NSObject, XMLParserDelegate {
    var sheets: [Spreadsheets.Sheet] = []
    private var rows: [[String]] = []
    private var row: [String] = []
    private var emptyRows = 0, emptyCells = 0
    private var rowRepeat = 1, cellRepeat = 1
    private var cell = "", cellValue: String?, paragraphs = 0
    private var inCell = false, inParagraph = false, skipDepth = 0
    private var currentName = ""

    init(_ data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if skipDepth > 0 { skipDepth += 1; return }
        switch name {
        case "table:table":
            rows = []; emptyRows = 0
            currentName = attributes["table:name"] ?? "Sheet\(sheets.count + 1)"
        case "table:table-row":
            row = []; emptyCells = 0
            rowRepeat = attributes["table:number-rows-repeated"].flatMap(Int.init) ?? 1
        case "table:table-cell", "table:covered-table-cell":
            inCell = true
            cell = ""; paragraphs = 0
            cellRepeat = attributes["table:number-columns-repeated"].flatMap(Int.init) ?? 1
            cellValue = Self.value(attributes)
        case "office:annotation":   // A comment on the cell, not its content
            skipDepth = 1
        case "text:p" where inCell, "text:h" where inCell:
            if paragraphs > 0 { cell += "\n" }
            paragraphs += 1
            inParagraph = true
        case "text:s" where inParagraph:
            cell += String(repeating: " ", count: attributes["text:c"].flatMap(Int.init) ?? 1)
        case "text:tab" where inParagraph: cell += "\t"
        case "text:line-break" where inParagraph: cell += "\n"
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if skipDepth == 0 && inParagraph { cell += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if skipDepth > 0 { skipDepth -= 1; return }
        switch name {
        case "text:p", "text:h": inParagraph = false
        case "table:table-cell", "table:covered-table-cell":
            inCell = false
            let text = cellValue ?? cell
            if text.isEmpty {
                emptyCells += cellRepeat
            } else {
                if emptyCells > 0 { row += repeatElement("", count: emptyCells); emptyCells = 0 }
                row += repeatElement(text, count: min(cellRepeat, 16_384))
            }
        case "table:table-row":
            if row.isEmpty {
                emptyRows += rowRepeat
            } else {
                if emptyRows > 0 { rows += repeatElement([], count: emptyRows); emptyRows = 0 }
                rows += repeatElement(row, count: min(rowRepeat, 1_048_576))
            }
        case "table:table":
            sheets.append(Spreadsheets.Sheet(name: currentName, rows: rows))
        default: break
        }
    }

    /// The cell's value as the Excel reader would show it: plain numbers, ISO dates, TRUE/FALSE. Text cells
    /// (and anything unexpected) use their displayed text instead.
    private static func value(_ attributes: [String: String]) -> String? {
        switch attributes["office:value-type"] {
        case "float", "percentage", "currency":
            guard let text = attributes["office:value"], let number = Double(text) else { return nil }
            if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
            return String(format: "%.15g", number)
        case "boolean":
            return attributes["office:boolean-value"] == "true" ? "TRUE" : "FALSE"
        case "date":
            // "2024-03-01" or "2024-03-01T14:30:00.123"; midnight reads as just the date, like Excel's reader.
            guard let text = attributes["office:date-value"] else { return nil }
            let parts = text.split(separator: "T", maxSplits: 1)
            guard parts.count == 2 else { return text }
            let time = parts[1].prefix(8)
            return time == "00:00:00" ? String(parts[0]) : "\(parts[0]) \(time)"
        case "time":
            // "PT14H30M00S" (hours can run past 24 for durations).
            guard let text = attributes["office:time-value"],
                  let match = text.wholeMatch(of: /-?PT(\d+)H(\d+)M(\d+)(?:[.,]\d+)?S/) else { return nil }
            func two(_ part: Substring) -> String { part.count < 2 ? "0" + part : String(part) }
            return "\(two(match.1)):\(two(match.2)):\(two(match.3))"
        default:
            return nil
        }
    }
}

extension OpenDocumentSheets {
    /// Every sheet of the .ods as an Excel workbook, written without Numbers. Returns `output`.
    @discardableResult
    static func writeXLSX(_ request: Converter.Request, output: URL) async throws -> URL {
        let sheets = try await Spreadsheets.sheets(of: request)
        let parts = try await background { sheets.map { (name: $0.name, xml: Spreadsheets.sheetXML($0.rows)) } }
        try await Spreadsheets.writeXLSX(sheets: parts, request: request, output: output)
        return output
    }
}
