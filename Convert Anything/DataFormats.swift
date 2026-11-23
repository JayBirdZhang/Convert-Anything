import Foundation

/// JSON as a spreadsheet format: a table becomes a list of objects keyed by its header row, and a list
/// of objects (or of rows) becomes a table. Excel and CSV are read and written by `Spreadsheets`; this
/// file only adds the JSON side, so there's one spreadsheet reader and one writer in the app.
///
/// Choices, so the results are predictable:
/// - Cells become JSON values: plain numbers stay numbers ("007" and long IDs stay text, as when
///   writing CSV → Excel), TRUE/FALSE become booleans, empty cells become `null`, dates stay text.
/// - A workbook with several sheets becomes a folder with one JSON file per sheet, like Excel → CSV does.
/// - A JSON value inside a cell (an object or a list) is written into the cell as JSON text, rather than
///   being spread over extra columns, so nothing is lost and the columns stay the ones you can see.
nonisolated enum DataFormats {
    // MARK: Spreadsheet → JSON

    /// CSV and Excel are read directly. Older Excel files and Numbers go through Numbers' CSV export
    /// (which makes a folder when there are several tables).
    static func tableToJSON(_ request: Converter.Request, output: URL) async throws -> URL {
        switch request.from {
        case .csv:
            return try await background {
                let rows = try Spreadsheets.parseCSV(at: request.input)
                try json(rows: rows, emptyMessage: "This CSV file is empty.").write(to: output)
                return output
            }
        case .xlsx:
            let sheets = try await Spreadsheets.sheets(of: request)
            return try await background {
                if sheets.count == 1 {
                    try json(rows: sheets[0].rows, emptyMessage: "This spreadsheet is empty.").write(to: output)
                    return output
                }
                let folder = request.workDir.appending(path: "sheets")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for sheet in sheets {
                    let name = "\(request.title) - \(sheet.name.replacingOccurrences(of: "/", with: "-")).json"
                    try json(rows: sheet.rows, emptyMessage: "This spreadsheet is empty.").write(to: folder.appending(path: name))
                }
                return folder
            }
        default:
            let exported = try await IWork.export(request.input, with: .numbers, as: .csv,
                                                  to: request.workDir.appending(path: "numbers.csv"))
            return try await background {
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: exported.path, isDirectory: &isFolder), isFolder.boolValue else {
                    let rows = try Spreadsheets.parseCSV(at: exported)
                    try json(rows: rows, emptyMessage: "This spreadsheet is empty.").write(to: output)
                    return output
                }
                let files = try FileManager.default.contentsOfDirectory(at: exported, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension.lowercased() == "csv" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                guard !files.isEmpty else { throw ConversionError.failed("This spreadsheet is empty.") }
                let folder = request.workDir.appending(path: "sheets")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for file in files {
                    let rows = try Spreadsheets.parseCSV(at: file)
                    guard rows.contains(where: { !$0.allSatisfy(\.isEmpty) }) else { continue }
                    let name = file.deletingPathExtension().lastPathComponent + ".json"
                    try json(rows: rows, emptyMessage: "").write(to: folder.appending(path: name))
                }
                return folder
            }
        }
    }

    /// The first non-blank row names the keys; the rest become one object per line, so a big file stays
    /// easy to read and to diff. Built as UTF-8 bytes directly (a 50,000-row sheet is several megabytes).
    static func json(rows: [[String]], emptyMessage: String) throws -> Data {
        guard let start = rows.firstIndex(where: { !$0.allSatisfy(\.isEmpty) }) else {
            throw ConversionError.failed(emptyMessage)
        }
        let header = rows[start]
        let width = rows[start...].reduce(0) { max($0, $1.count) }

        // Keys: the header text; blank or repeated headers get a name so every column survives.
        var used = Set<String>()
        var keys: [[UInt8]] = []
        for column in 0..<width {
            var name = column < header.count && !header[column].isEmpty ? header[column] : "Column \(column + 1)"
            if used.contains(name) {
                var n = 2
                while used.contains("\(name) \(n)") { n += 1 }
                name = "\(name) \(n)"
            }
            used.insert(name)
            var key: [UInt8] = []
            appendQuoted(name, to: &key)
            key.append(contentsOf: [58, 32])   // ": "
            keys.append(key)
        }

        var out: [UInt8] = []
        out.reserveCapacity(rows.count * (width * 24 + 8))
        out.append(91)   // [
        var wroteRow = false
        for row in rows[(start + 1)...] where !row.allSatisfy(\.isEmpty) {
            out.append(contentsOf: wroteRow ? [44, 10, 32, 32, 123] : [10, 32, 32, 123])   // ",\n  {"
            wroteRow = true
            for column in 0..<width {
                if column > 0 { out.append(contentsOf: [44, 32]) }
                out.append(contentsOf: keys[column])
                appendCell(column < row.count ? row[column] : "", to: &out)
            }
            out.append(125)   // }
        }
        out.append(contentsOf: wroteRow ? [10, 93, 10] : [93, 10])
        return Data(out)
    }

    /// A cell's text as the JSON value it looks like.
    private static func appendCell(_ text: String, to out: inout [UInt8]) {
        if text.isEmpty {
            out.append(contentsOf: Array("null".utf8))
        } else if Spreadsheets.isNumber(text) {
            out.append(contentsOf: text.utf8)
        } else if text.utf8.count <= 5, let flag = boolean(text) {
            out.append(contentsOf: Array((flag ? "true" : "false").utf8))
        } else {
            appendQuoted(text, to: &out)
        }
    }

    private static func boolean(_ text: String) -> Bool? {
        switch text {
        case "true", "TRUE", "True": true
        case "false", "FALSE", "False": false
        default: nil
        }
    }

    private static let hex = Array("0123456789abcdef".utf8)

    static func appendQuoted(_ text: String, to out: inout [UInt8]) {
        out.append(34)
        for byte in text.utf8 {
            switch byte {
            case 34: out.append(92); out.append(34)
            case 92: out.append(92); out.append(92)
            case 10: out.append(92); out.append(110)
            case 13: out.append(92); out.append(114)
            case 9: out.append(92); out.append(116)
            case ..<0x20:
                out.append(contentsOf: [92, 117, 48, 48, hex[Int(byte >> 4)], hex[Int(byte & 15)]])   // \u00XX
            default: out.append(byte)
            }
        }
        out.append(34)
    }

    // MARK: JSON → spreadsheet

    static func jsonToTable(_ request: Converter.Request, output: URL) async throws {
        switch request.to {
        case .xlsx:
            let sheet = try await background { Spreadsheets.sheetXML(try rows(fromJSONAt: request.input)) }
            try await Spreadsheets.writeXLSX(sheetXML: sheet, request: request, output: output)
        default:
            try await background {
                try Spreadsheets.csv(try rows(fromJSONAt: request.input)).write(to: output, atomically: true, encoding: .utf8)
            }
        }
    }

    /// For PDF and image output, Numbers lays the table out, so it's given the JSON as a CSV file.
    static func jsonAsCSV(_ request: Converter.Request) async throws -> URL {
        let csv = request.workDir.appending(path: "table.csv")
        try await background {
            try Spreadsheets.csv(try rows(fromJSONAt: request.input)).write(to: csv, atomically: true, encoding: .utf8)
        }
        return csv
    }

    /// The table inside a JSON file: a header row followed by one row per item.
    static func rows(fromJSONAt url: URL) throws -> [[String]] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let root = try data.withUnsafeBytes { try JSONReader.parse($0.bindMemory(to: UInt8.self)) }

        let list: [JSONReader.Value]
        switch root {
        case .array(let items):
            list = items
        case .object(let members):
            let lists = members.compactMap { member -> (String, [JSONReader.Value])? in
                if case .array(let items) = member.value { return (member.key, items) }
                return nil
            }
            guard lists.count == 1 else {
                throw ConversionError.failed(lists.isEmpty
                    ? "This JSON is a single object, not a list of rows. A spreadsheet needs a list of objects, like [{\"name\": \"Ann\"}, …]."
                    : "This JSON holds several lists (\(lists.map(\.0).prefix(4).joined(separator: ", "))). Keep just the one you want as a spreadsheet.")
            }
            list = lists[0].1
        default:
            throw ConversionError.failed("This JSON isn't a table. A spreadsheet needs a list of objects, like [{\"name\": \"Ann\"}, …].")
        }
        guard let first = list.first else { throw ConversionError.failed("This JSON has an empty list, so there are no rows.") }

        switch first {
        case .object:
            // Columns are the keys in order of first appearance; an object without a key leaves that cell empty.
            var index: [String: Int] = [:]
            var names: [String] = []
            for (n, item) in list.enumerated() {
                guard case .object(let members) = item else { throw notARow(n, "an object") }
                for member in members where index[member.key] == nil {
                    index[member.key] = names.count
                    names.append(member.key)
                }
            }
            var rows: [[String]] = [names]
            rows.reserveCapacity(list.count + 1)
            for item in list {
                guard case .object(let members) = item else { continue }
                var row = [String](repeating: "", count: names.count)
                for member in members { row[index[member.key]!] = member.value.cellText }
                rows.append(row)
            }
            return rows
        case .array:
            return try list.enumerated().map { n, item in
                guard case .array(let cells) = item else { throw notARow(n, "a list") }
                return cells.map(\.cellText)
            }
        default:
            throw ConversionError.failed("This JSON is a list of plain values. A spreadsheet needs a list of objects, like [{\"name\": \"Ann\"}, …].")
        }
    }

    private static func notARow(_ index: Int, _ expected: String) -> ConversionError {
        .failed("This JSON isn't a table: item \(index + 1) isn't \(expected) like the first one.")
    }
}

// MARK: - Reading JSON

/// A small JSON reader that keeps the order of an object's keys (Foundation's doesn't), which is what
/// decides the order of the spreadsheet's columns. Numbers are kept as the text they were written with,
/// so 1.50 and 12345678901234567890 come out unchanged.
nonisolated enum JSONReader {
    enum Value {
        case null
        case bool(Bool)
        case number(String)
        case string(String)
        case array([Value])
        case object([(key: String, value: Value)])

        /// What goes in a spreadsheet cell: plain values as text, anything nested as JSON text.
        var cellText: String {
            switch self {
            case .null: ""
            case .bool(let flag): flag ? "true" : "false"
            case .number(let text), .string(let text): text
            case .array, .object:
                String(decoding: { () -> [UInt8] in var out: [UInt8] = []; append(to: &out); return out }(), as: UTF8.self)
            }
        }

        private func append(to out: inout [UInt8]) {
            switch self {
            case .null: out.append(contentsOf: Array("null".utf8))
            case .bool(let flag): out.append(contentsOf: Array((flag ? "true" : "false").utf8))
            case .number(let text): out.append(contentsOf: text.utf8)
            case .string(let text): DataFormats.appendQuoted(text, to: &out)
            case .array(let items):
                out.append(91)
                for (n, item) in items.enumerated() {
                    if n > 0 { out.append(44) }
                    item.append(to: &out)
                }
                out.append(93)
            case .object(let members):
                out.append(123)
                for (n, member) in members.enumerated() {
                    if n > 0 { out.append(44) }
                    DataFormats.appendQuoted(member.key, to: &out)
                    out.append(58)
                    member.value.append(to: &out)
                }
                out.append(125)
            }
        }
    }

    static func parse(_ bytes: UnsafeBufferPointer<UInt8>) throws -> Value {
        var reader = Reader(bytes: bytes)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { reader.index = 3 }   // Byte order mark
        reader.skipSpace()
        let value = try reader.value(depth: 0)
        reader.skipSpace()
        if reader.index < bytes.count { throw reader.fail("Unexpected text after the data") }
        return value
    }

    private struct Reader {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0

        func fail(_ what: String) -> ConversionError {
            var line = 1
            for i in 0..<min(index, bytes.count) where bytes[i] == 10 { line += 1 }
            return .failed("This isn't valid JSON (\(what) on line \(line)).")
        }

        mutating func skipSpace() {
            while index < bytes.count, bytes[index] == 32 || bytes[index] == 10 || bytes[index] == 13 || bytes[index] == 9 { index += 1 }
        }

        mutating func value(depth: Int) throws -> Value {
            guard depth < 200 else { throw fail("Nested too deeply") }
            guard index < bytes.count else { throw fail("The file ends too soon") }
            switch bytes[index] {
            case 123:   // {
                index += 1
                var members: [(key: String, value: Value)] = []
                skipSpace()
                if index < bytes.count, bytes[index] == 125 { index += 1; return .object(members) }
                while true {
                    skipSpace()
                    guard index < bytes.count, bytes[index] == 34 else { throw fail("Expected a key in quotes") }
                    let key = try string()
                    skipSpace()
                    guard index < bytes.count, bytes[index] == 58 else { throw fail("Expected a ':'") }
                    index += 1
                    skipSpace()
                    members.append((key, try value(depth: depth + 1)))
                    skipSpace()
                    guard index < bytes.count else { throw fail("The file ends too soon") }
                    if bytes[index] == 44 { index += 1; continue }
                    if bytes[index] == 125 { index += 1; return .object(members) }
                    throw fail("Expected ',' or '}'")
                }
            case 91:    // [
                index += 1
                var items: [Value] = []
                skipSpace()
                if index < bytes.count, bytes[index] == 93 { index += 1; return .array(items) }
                while true {
                    skipSpace()
                    items.append(try value(depth: depth + 1))
                    skipSpace()
                    guard index < bytes.count else { throw fail("The file ends too soon") }
                    if bytes[index] == 44 { index += 1; continue }
                    if bytes[index] == 93 { index += 1; return .array(items) }
                    throw fail("Expected ',' or ']'")
                }
            case 34: return .string(try string())
            case 116: try word("true"); return .bool(true)
            case 102: try word("false"); return .bool(false)
            case 110: try word("null"); return .null
            case 45, 48...57: return try number()
            default: throw fail("Unexpected character")
            }
        }

        mutating func word(_ text: StaticString) throws {
            let count = text.utf8CodeUnitCount
            guard index + count <= bytes.count,
                  (0..<count).allSatisfy({ bytes[index + $0] == text.utf8Start[$0] }) else { throw fail("Unexpected word") }
            index += count
        }

        mutating func number() throws -> Value {
            let start = index
            func digits() -> Int {
                let first = index
                while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 { index += 1 }
                return index - first
            }
            if bytes[index] == 45 { index += 1 }
            if index < bytes.count, bytes[index] == 48 { index += 1 } else if digits() == 0 { throw fail("Bad number") }
            if index < bytes.count, bytes[index] == 46 {
                index += 1
                if digits() == 0 { throw fail("Bad number") }
            }
            if index < bytes.count, bytes[index] == 69 || bytes[index] == 101 {
                index += 1
                if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
                if digits() == 0 { throw fail("Bad number") }
            }
            return .number(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self))
        }

        /// Reads a quoted string. Text without escapes (nearly all of it) is copied in one piece.
        mutating func string() throws -> String {
            index += 1   // Opening quote
            let start = index
            while index < bytes.count, bytes[index] != 34, bytes[index] != 92 { index += 1 }
            guard index < bytes.count else { throw fail("A string is never closed") }
            if bytes[index] == 34 {
                defer { index += 1 }
                return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
            }
            var out = Array(bytes[start..<index])
            while true {
                guard index < bytes.count else { throw fail("A string is never closed") }
                let byte = bytes[index]
                index += 1
                if byte == 34 { return String(decoding: out, as: UTF8.self) }
                guard byte == 92 else { out.append(byte); continue }
                guard index < bytes.count else { throw fail("A string is never closed") }
                let escape = bytes[index]
                index += 1
                switch escape {
                case 110: out.append(10)
                case 116: out.append(9)
                case 114: out.append(13)
                case 98: out.append(8)
                case 102: out.append(12)
                case 34, 92, 47: out.append(escape)
                case 117:
                    var scalar = try hexUnit()
                    if (0xD800..<0xDC00).contains(scalar), index + 1 < bytes.count, bytes[index] == 92, bytes[index + 1] == 117 {
                        let saved = index
                        index += 2
                        let low = try hexUnit()
                        if (0xDC00..<0xE000).contains(low) {
                            scalar = 0x10000 + (scalar - 0xD800) << 10 + (low - 0xDC00)
                        } else {
                            index = saved   // Not a pair; the lone half becomes a replacement character below
                        }
                    }
                    out.append(contentsOf: Array(String(Unicode.Scalar(scalar).map(Character.init) ?? "\u{FFFD}").utf8))
                default: throw fail("Bad escape in a string")
                }
            }
        }

        mutating func hexUnit() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw fail("Bad escape in a string") }
            var result: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                index += 1
                switch byte {
                case 48...57: result = result << 4 + UInt32(byte - 48)
                case 65...70: result = result << 4 + UInt32(byte - 55)
                case 97...102: result = result << 4 + UInt32(byte - 87)
                default: throw fail("Bad escape in a string")
                }
            }
            return result
        }
    }
}
