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
        let package = request.workDir.appending(path: "xlsx")
        try await Tools.run("/usr/bin/unzip", ["-q", "-o", request.input.path, "-d", package.path])
        let sheets = try read(package).filter { !$0.rows.isEmpty }
        guard !sheets.isEmpty else { throw ConversionError.failed("This spreadsheet is empty.") }

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
        let rows = try parseCSV(at: request.input)
        guard !rows.isEmpty else { throw ConversionError.failed("This CSV file is empty.") }
        let package = request.workDir.appending(path: "xlsx-out")
        let fileManager = FileManager.default
        for dir in ["_rels", "xl/_rels", "xl/worksheets"] {
            try fileManager.createDirectory(at: package.appending(path: dir), withIntermediateDirectories: true)
        }
        let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let sheetName = String(request.title.filter { !"[]:*?/\\".contains($0) }.prefix(31))

        func write(_ path: String, _ xml: String) throws {
            try (header + xml).write(to: package.appending(path: path), atomically: true, encoding: .utf8)
        }
        try write("[Content_Types].xml", #"""
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\#
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\#
            <Default Extension="xml" ContentType="application/xml"/>\#
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\#
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\#
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\#
            </Types>
            """#)
        try write("_rels/.rels", #"""
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#
            <Relationship Id="rId1" Type="\#(rel)/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """#)
        try write("xl/workbook.xml", #"""
            <workbook xmlns="\#(main)" xmlns:r="\#(rel)"><sheets>\#
            <sheet name="\#(escape(sheetName.isEmpty ? "Sheet1" : sheetName))" sheetId="1" r:id="rId1"/></sheets></workbook>
            """#)
        try write("xl/_rels/workbook.xml.rels", #"""
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#
            <Relationship Id="rId1" Type="\#(rel)/worksheet" Target="worksheets/sheet1.xml"/>\#
            <Relationship Id="rId2" Type="\#(rel)/styles" Target="styles.xml"/></Relationships>
            """#)
        try write("xl/styles.xml", #"""
            <styleSheet xmlns="\#(main)"><fonts count="1"><font><sz val="12"/><name val="Calibri"/></font></fonts>\#
            <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\#
            <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\#
            <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\#
            <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>\#
            <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
            """#)

        var sheet = "<worksheet xmlns=\"\(main)\"><sheetData>"
        for (r, row) in rows.enumerated() {
            sheet += "<row r=\"\(r + 1)\">"
            for (c, value) in row.enumerated() where !value.isEmpty {
                let ref = columnName(c) + String(r + 1)
                if isNumber(value) {
                    sheet += "<c r=\"\(ref)\"><v>\(value)</v></c>"
                } else {
                    let space = value.first == " " || value.last == " " ? " xml:space=\"preserve\"" : ""
                    sheet += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t\(space)>\(escape(value))</t></is></c>"
                }
            }
            sheet += "</row>"
        }
        try write("xl/worksheets/sheet1.xml", sheet + "</sheetData></worksheet>")

        try await Tools.run("/usr/bin/zip", ["-q", "-X", "-D", "-nw", "-r", output.path, "[Content_Types].xml", "_rels", "xl"],
                            currentDirectory: package)
    }

    /// Plain numbers only: "007", "1,000" and "+5" stay text, as a spreadsheet would show them.
    private static func isNumber(_ value: String) -> Bool {
        value.wholeMatch(of: /-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?/) != nil && value.count < 16
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
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let firstLine = body.prefix { $0 != "\n" }
        let separator: Character = [",", ";", "\t"].max { a, b in
            firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count
        } ?? ","

        var rows: [[String]] = [], row: [String] = [], field = ""
        var inQuotes = false
        var iterator = body.makeIterator()
        var pending: Character? = nil
        while let char = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else { inQuotes = false }
                } else { field.append(char) }
            } else if char == "\"" && field.isEmpty {
                inQuotes = true
            } else if char == separator {
                row.append(field); field = ""
            } else if char == "\n" || char == "\r\n" || char == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(char)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
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
        let date = epoch.addingTimeInterval((serial * 86_400).rounded())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        switch kind {
        case .date: formatter.dateFormat = "yyyy-MM-dd"
        case .time: formatter.dateFormat = "HH:mm:ss"
        case .dateTime: formatter.dateFormat = serial == serial.rounded() ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss"
        }
        return formatter.string(from: date)
    }
}
