import Foundation

/// Excel (.xlsx) ↔ CSV without any other app. An .xlsx file is a zip of XML files: shared strings,
/// one file per sheet, and styles that say which numbers are dates.
nonisolated enum Spreadsheets {
    struct Sheet {
        var name: String
        var rows: [[String]]
    }

    // MARK: xlsx → csv

    /// One sheet becomes one CSV file; several become a folder with a CSV per sheet.
    static func xlsxToCSV(_ request: Converter.Request, output: URL) async throws -> URL {
        let sheets = try await sheets(of: request)
        return try await background {
            if sheets.count == 1 {
                try csv(sheets[0].rows).write(to: output, atomically: true, encoding: .utf8)
                return output
            }
            let folder = request.workDir.appending(path: "sheets")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for sheet in sheets {
                let name = "\(request.title) - \(sheet.name.replacingOccurrences(of: "/", with: "-")).csv"
                try csv(sheet.rows).write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
            }
            return folder
        }
    }

    /// Unpacks the workbook and reads its sheets, leaving out empty ones.
    /// OpenDocument spreadsheets (.ods) are read the same way, from their content.xml.
    static func sheets(of request: Converter.Request) async throws -> [Sheet] {
        let isODS = request.from == .ods
        let package = request.workDir.appending(path: isODS ? "ods" : "xlsx")
        try await Tools.run("/usr/bin/unzip", ["-q", "-o", request.input.path] + (isODS ? ["content.xml"] : []) + ["-d", package.path])
        // Parsing a big workbook takes a while; keep it off the main thread.
        return try await background {
            let all = isODS ? try OpenDocumentSheets.read(package.appending(path: "content.xml")) : try read(package)
            let sheets = all.filter { !$0.rows.isEmpty }
            guard !sheets.isEmpty else { throw ConversionError.failed("This spreadsheet is empty.") }
            return sheets
        }
    }

    /// Conversions that need no other app, so they can run alongside each other.
    static func runsWithoutNumbers(from: Format, to: Format) -> Bool {
        switch (from, to) {
        case (.xlsx, .csv), (.csv, .xlsx), (.csv, .json), (.xlsx, .json), (.json, .csv), (.json, .xlsx),
             (.ods, .csv), (.ods, .json), (.ods, .xlsx): true
        default: false
        }
    }

    static func read(_ package: URL) throws -> [Sheet] {
        func xml(_ path: String) -> Data? { try? Data(contentsOf: package.appending(path: path)) }
        guard let workbookData = xml("xl/workbook.xml") else { throw ConversionError.failed("Couldn't read this spreadsheet.") }

        let workbook = WorkbookParser(workbookData)
        let relationships = RelationshipParser(xml("xl/_rels/workbook.xml.rels") ?? Data()).targets
        let strings = xml("xl/sharedStrings.xml").map { SharedStringsParser($0).strings } ?? []
        let dateStyles = xml("xl/styles.xml").map { StylesParser($0).dateStyles } ?? []

        return workbook.sheets.compactMap { sheet in
            guard let target = relationships[sheet.relationshipID] else { return nil }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            guard let data = xml(path) else { return nil }
            let rows = SheetParser(data, strings: strings, dateStyles: dateStyles, date1904: workbook.date1904).rows
            return Sheet(name: sheet.name, rows: rows)
        }
    }

    static func csv(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { field in
                let needsQuotes = field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                    || field.first == " " || field.last == " "
                return needsQuotes ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
            }.joined(separator: ",")
        }.joined(separator: "\n") + "\n"
    }

    // MARK: csv → xlsx

    static func csvToXLSX(_ request: Converter.Request, output: URL) async throws {
        // Parsing and writing a big sheet takes a while; keep it off the main thread.
        let sheet = try await background { () throws -> Data in
            let rows = try parseCSV(at: request.input)
            guard !rows.isEmpty else { throw ConversionError.failed("This CSV file is empty.") }
            return sheetXML(rows)
        }
        try await writeXLSX(sheetXML: sheet, request: request, output: output)
    }

    /// Wraps a worksheet in the rest of an .xlsx package and zips it.
    static func writeXLSX(sheetXML sheet: Data, request: Converter.Request, output: URL) async throws {
        try await writeXLSX(sheets: [(request.title, sheet)], request: request, output: output)
    }

    /// The same for several worksheets (name, worksheet part), in order.
    static func writeXLSX(sheets: [(name: String, xml: Data)], request: Converter.Request, output: URL) async throws {
        let package = request.workDir.appending(path: "xlsx-out")
        let fileManager = FileManager.default
        for dir in ["_rels", "xl/_rels", "xl/worksheets"] {
            try fileManager.createDirectory(at: package.appending(path: dir), withIntermediateDirectories: true)
        }
        let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let names = sheets.enumerated().map { index, sheet in
            let name = String(sheet.name.filter { !"[]:*?/\\".contains($0) }.prefix(31))
            return escape(name.isEmpty ? "Sheet\(index + 1)" : name)
        }
        let numbers = sheets.indices.map { $0 + 1 }

        func write(_ path: String, _ xml: String) throws {
            try (header + xml).write(to: package.appending(path: path), atomically: true, encoding: .utf8)
        }
        try write("[Content_Types].xml", #"""
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\#
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\#
            <Default Extension="xml" ContentType="application/xml"/>\#
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\#
            \#(numbers.map { #"<Override PartName="/xl/worksheets/sheet\#($0).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"# }.joined())\#
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\#
            </Types>
            """#)
        try write("_rels/.rels", #"""
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#
            <Relationship Id="rId1" Type="\#(rel)/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """#)
        try write("xl/workbook.xml", #"""
            <workbook xmlns="\#(main)" xmlns:r="\#(rel)"><sheets>\#
            \#(numbers.map { #"<sheet name="\#(names[$0 - 1])" sheetId="\#($0)" r:id="rId\#($0)"/>"# }.joined())</sheets></workbook>
            """#)
        try write("xl/_rels/workbook.xml.rels", #"""
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#
            \#(numbers.map { #"<Relationship Id="rId\#($0)" Type="\#(rel)/worksheet" Target="worksheets/sheet\#($0).xml"/>"# }.joined())\#
            <Relationship Id="rIdStyles" Type="\#(rel)/styles" Target="styles.xml"/></Relationships>
            """#)
        try write("xl/styles.xml", #"""
            <styleSheet xmlns="\#(main)"><fonts count="1"><font><sz val="12"/><name val="Calibri"/></font></fonts>\#
            <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\#
            <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\#
            <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\#
            <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>\#
            <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
            """#)

        for (number, sheet) in zip(numbers, sheets) {
            try (Data(header.utf8) + sheet.xml).write(to: package.appending(path: "xl/worksheets/sheet\(number).xml"), options: .atomic)
        }

        try await Tools.run("/usr/bin/zip", ["-q", "-X", "-D", "-nw", "-r", output.path, "[Content_Types].xml", "_rels", "xl"],
                            currentDirectory: package)
    }

    /// The worksheet part, built as UTF-8 bytes directly (a big sheet is tens of megabytes of XML).
    static func sheetXML(_ rows: [[String]]) -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(rows.count * (rows[0].count * 40 + 16))
        func add(_ text: StaticString) { text.withUTF8Buffer { out.append(contentsOf: $0) } }
        func add(_ text: String) { out.append(contentsOf: text.utf8) }
        func addEscaped(_ text: String) {
            for byte in text.utf8 {
                switch byte {
                case 38: add("&amp;")
                case 60: add("&lt;")
                case 62: add("&gt;")
                case 34: add("&quot;")
                case 9, 10, 13: out.append(byte)
                case ..<0x20: continue   // Control characters aren't allowed in XML
                default: out.append(byte)
                }
            }
        }
        var columnNames: [String] = []
        add("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>")
        for (r, row) in rows.enumerated() {
            let number = String(r + 1)
            add("<row r=\""); add(number); add("\">")
            for (c, value) in row.enumerated() where !value.isEmpty {
                while columnNames.count <= c { columnNames.append(columnName(columnNames.count)) }
                add("<c r=\""); add(columnNames[c]); add(number)
                if isNumber(value) {
                    add("\"><v>"); add(value); add("</v></c>")
                } else {
                    add("\" t=\"inlineStr\"><is><t")
                    if value.first == " " || value.last == " " { add(" xml:space=\"preserve\"") }
                    add(">"); addEscaped(value); add("</t></is></c>")
                }
            }
            add("</row>")
        }
        add("</sheetData></worksheet>")
        return Data(out)
    }

    /// Plain numbers only: "007", "1,000" and "+5" stay text, as a spreadsheet would show them.
    /// Matches -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)? (a regex here was the slowest step). Whole numbers
    /// stop at 15 digits, so long IDs keep every digit as text; decimals may be longer, as in 0.14285714285714285.
    static func isNumber(_ value: String) -> Bool {
        var value = value
        return value.withUTF8 { b in
            let n = b.count
            guard n > 0, n < 40 else { return false }
            var i = 0
            func digits() -> Int {
                let start = i
                while i < n, b[i] >= 48, b[i] <= 57 { i += 1 }
                return i - start
            }
            if b[i] == 45 { i += 1 }
            guard i < n else { return false }
            if b[i] == 48 { i += 1 } else if digits() == 0 { return false }
            var isWhole = true
            if i < n, b[i] == 46 { i += 1; isWhole = false; if digits() == 0 { return false } }
            if i < n, b[i] == 69 || b[i] == 101 {
                i += 1
                isWhole = false
                if i < n, b[i] == 43 || b[i] == 45 { i += 1 }
                if digits() == 0 { return false }
            }
            return i == n && (n < 16 || !isWhole)
        }
    }

    static func columnName(_ index: Int) -> String {
        var name = "", n = index + 1
        while n > 0 {
            let remainder = (n - 1) % 26
            name = String(UnicodeScalar(65 + remainder)!) + name
            n = (n - 1) / 26
        }
        return name
    }

    static func columnIndex(_ reference: String) -> Int {
        var index = 0
        for scalar in reference.unicodeScalars {
            guard scalar.value >= 65 && scalar.value <= 90 else { break }
            index = index * 26 + Int(scalar.value - 64)
        }
        return max(index - 1, 0)
    }

    static func escape(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\t", "\n", "\r": result.unicodeScalars.append(scalar)
            case _ where scalar.value < 0x20: continue
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    // MARK: CSV parsing

    /// Reads UTF-8 (or older Windows/Mac encodings), detects comma, semicolon or tab separators,
    /// and handles quoted fields with commas and line breaks inside.
    static func parseCSV(at url: URL) throws -> [[String]] {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
                ?? String(data: data, encoding: .macOSRoman) else {
            throw ConversionError.failed("Couldn't read this CSV file.")
        }
        var body = text
        return body.withUTF8 { bytes in
            var start = 0
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { start = 3 }   // Byte order mark

            // The first line (up to a bare "\n"; "\r\n" doesn't end it) decides the separator.
            var commas = 0, semicolons = 0, tabs = 0
            var index = start
            while index < bytes.count, !(bytes[index] == 10 && (index == 0 || bytes[index - 1] != 13)) {
                switch bytes[index] {
                case 44: commas += 1
                case 59: semicolons += 1
                case 9: tabs += 1
                default: break
                }
                index += 1
            }
            // On a tie the earlier of comma, semicolon, tab wins.
            var separator = UInt8(ascii: ","), best = commas
            if semicolons > best { separator = UInt8(ascii: ";"); best = semicolons }
            if tabs > best { separator = UInt8(ascii: "\t") }

            var rows: [[String]] = [], row: [String] = [], field: [UInt8] = []
            var inQuotes = false
            var i = start
            while i < bytes.count {
                let byte = bytes[i]
                i += 1
                if inQuotes {
                    if byte != 34 {
                        field.append(byte)
                    } else if i < bytes.count, bytes[i] == 34 {
                        field.append(34)
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else if byte == 34 && field.isEmpty {
                    inQuotes = true
                } else if byte == separator {
                    row.append(String(decoding: field, as: UTF8.self)); field.removeAll(keepingCapacity: true)
                } else if byte == 10 || byte == 13 {
                    if byte == 13, i < bytes.count, bytes[i] == 10 { i += 1 }
                    row.append(String(decoding: field, as: UTF8.self)); field.removeAll(keepingCapacity: true)
                    rows.append(row); row = []
                } else {
                    field.append(byte)
                }
            }
            if !field.isEmpty || !row.isEmpty { row.append(String(decoding: field, as: UTF8.self)); rows.append(row) }
            return rows
        }
    }
}

// MARK: - XML readers

nonisolated private final class WorkbookParser: NSObject, XMLParserDelegate {
    struct Entry { var name: String; var relationshipID: String }
    var sheets: [Entry] = []
    var date1904 = false

    init(_ data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        switch name {
        case "sheet":
            let id = attributes["r:id"] ?? attributes.first { $0.key.hasSuffix(":id") }?.value ?? ""
            sheets.append(Entry(name: attributes["name"] ?? "Sheet\(sheets.count + 1)", relationshipID: id))
        case "workbookPr":
            date1904 = ["1", "true"].contains(attributes["date1904"] ?? "")
        default: break
        }
    }
}

nonisolated private final class RelationshipParser: NSObject, XMLParserDelegate {
    var targets: [String: String] = [:]

    init(_ data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] { targets[id] = target }
    }
}

/// Shared strings: plain (<si><t>) or rich text (<si><r><t>…</t></r>…); phonetic hints (<rPh>) are skipped.
nonisolated private final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var current = "", inText = false, inPhonetic = false

    init(_ data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        switch name {
        case "si": current = ""
        case "t": inText = !inPhonetic
        case "rPh": inPhonetic = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { current += string } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "si": strings.append(current)
        case "t": inText = false
        case "rPh": inPhonetic = false
        default: break
        }
    }
}

/// Which cell styles show dates or times, so their serial numbers can be written as dates.
nonisolated private final class StylesParser: NSObject, XMLParserDelegate {
    enum Kind { case date, time, dateTime }
    var dateStyles: [Kind?] = []
    private var customFormats: [Int: String] = [:]
    private var inCellXfs = false

    init(_ data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        switch name {
        case "numFmt":
            if let id = attributes["numFmtId"].flatMap(Int.init), let code = attributes["formatCode"] { customFormats[id] = code }
        case "cellXfs": inCellXfs = true
        case "xf" where inCellXfs:
            dateStyles.append(kind(attributes["numFmtId"].flatMap(Int.init) ?? 0))
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "cellXfs" { inCellXfs = false }
    }

    private func kind(_ id: Int) -> Kind? {
        switch id {
        case 14...17: return .date
        case 18...21, 45...47: return .time
        case 22: return .dateTime
        default: break
        }
        guard let code = customFormats[id] else { return nil }
        // Ignore quoted text, [colors] and escaped characters, then look for date and time letters.
        let stripped = code.replacing(/"[^"]*"|\[[^\]]*\]|\\./, with: "").lowercased()
        let hasDate = stripped.contains("y") || stripped.contains("d") || (stripped.contains("m") && !stripped.contains("h"))
        let hasTime = stripped.contains("h") || stripped.contains("s")
        switch (hasDate, hasTime) {
        case (true, true): return .dateTime
        case (true, false): return .date
        case (false, true): return .time
        default: return nil
        }
    }
}

nonisolated private final class SheetParser: NSObject, XMLParserDelegate {
    var rows: [[String]] = []
    private let strings: [String]
    private let dateStyles: [StylesParser.Kind?]
    private let epoch: Date
    private let epochOffset: Int      // Seconds from 1970-01-01 to the workbook's day zero
    private var row: [Int: String] = [:]
    private var rowIndex = 0
    private var cellColumn = 0, cellType = "", cellStyle = 0
    private var value = "", inValue = false

    init(_ data: Data, strings: [String], dateStyles: [StylesParser.Kind?], date1904: Bool) {
        self.strings = strings
        self.dateStyles = dateStyles
        var components = DateComponents(year: date1904 ? 1904 : 1899, month: date1904 ? 1 : 12, day: date1904 ? 1 : 30)
        components.timeZone = TimeZone(identifier: "UTC")
        epoch = Calendar(identifier: .gregorian).date(from: components)!
        epochOffset = Int(epoch.timeIntervalSince1970)
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        // Drop trailing empty rows.
        while rows.last?.allSatisfy(\.isEmpty) == true { rows.removeLast() }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        switch name {
        case "row":
            row = [:]
            if let r = attributes["r"].flatMap(Int.init) { rowIndex = r - 1 } else { rowIndex = rows.count }
        case "c":
            cellColumn = attributes["r"].map(Spreadsheets.columnIndex) ?? ((row.keys.max() ?? -1) + 1)
            cellType = attributes["t"] ?? "n"
            cellStyle = attributes["s"].flatMap(Int.init) ?? 0
            value = ""
        case "v", "t": inValue = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if inValue { value += string } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v", "t": inValue = false
        case "c": row[cellColumn] = display()
        case "row":
            while rows.count < rowIndex { rows.append([]) }
            let width = (row.keys.max() ?? -1) + 1
            rows.append((0..<width).map { row[$0] ?? "" })
        default: break
        }
    }

    private func display() -> String {
        switch cellType {
        case "s": return Int(value).flatMap { $0 < strings.count ? strings[$0] : nil } ?? ""
        case "b": return value == "1" ? "TRUE" : "FALSE"
        case "str", "inlineStr", "e": return value
        default:
            guard let number = Double(value) else { return value }
            if cellStyle < dateStyles.count, let kind = dateStyles[cellStyle] { return format(serial: number, kind) }
            if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
            return String(format: "%.15g", number)
        }
    }

    private func format(serial: Double, _ kind: StylesParser.Kind) -> String {
        let seconds = (serial * 86_400).rounded()
        // Real workbooks are full of dates; plain arithmetic (UTC, Gregorian) is far faster than a DateFormatter.
        // Dates before the Gregorian calendar's start (or absurdly far out) take the slow path.
        if abs(seconds) < 1e13 {
            let total = Int(seconds) + epochOffset
            let days = total >= 0 ? total / 86_400 : -((-total + 86_399) / 86_400)
            if days >= -100_000 && days <= 2_900_000 {
                let secondsOfDay = total - days * 86_400
                let (year, month, day) = Self.civil(daysSince1970: days)
                let date = Self.pad(year, 4) + "-" + Self.pad(month, 2) + "-" + Self.pad(day, 2)
                let time = Self.pad(secondsOfDay / 3600, 2) + ":" + Self.pad(secondsOfDay / 60 % 60, 2) + ":" + Self.pad(secondsOfDay % 60, 2)
                switch kind {
                case .date: return date
                case .time: return time
                case .dateTime: return serial == serial.rounded() ? date : date + " " + time
                }
            }
        }
        let formatter = Self.formatter
        let date = epoch.addingTimeInterval(seconds)
        switch kind {
        case .date: formatter.dateFormat = "yyyy-MM-dd"
        case .time: formatter.dateFormat = "HH:mm:ss"
        case .dateTime: formatter.dateFormat = serial == serial.rounded() ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss"
        }
        return formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }

    /// Year, month and day for a count of days since 1970-01-01 (proleptic Gregorian calendar).
    private static func civil(daysSince1970 days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}
