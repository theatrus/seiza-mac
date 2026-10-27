import Foundation

/// Paths remain in list order. Validation and alias deduplication belong to ImageCollection.
enum ImagePathList {
    struct Entry: Sendable {
        let value: String
        let line: Int
    }

    struct InvalidCSV: LocalizedError {
        let line: Int
        var errorDescription: String? { "Invalid CSV at line \(line). Check the field quoting." }
    }

    static func isSupported(_ url: URL) -> Bool {
        ["txt", "csv"].contains(url.pathExtension.lowercased())
    }

    static func read(_ url: URL) throws -> [Entry] {
        try Task.checkCancellation()
        let data = try Data(contentsOf: url)
        let encoding: String.Encoding = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
            ? .utf16 : .utf8
        guard var text = String(data: data, encoding: encoding) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        try Task.checkCancellation()
        if url.pathExtension.lowercased() != "csv" {
            return try text.components(separatedBy: "\n").enumerated().compactMap { index, line in
                try Task.checkCancellation()
                var value = line.trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.first == "\"", value.last == "\"" {
                    value = String(value.dropFirst().dropLast())
                }
                return value.trimmingCharacters(in: .whitespaces).isEmpty
                    ? nil : Entry(value: value, line: index + 1)
            }
        }

        let headers: Set<String> = ["path", "filepath", "file_path", "file", "filename"]
        var entries: [Entry] = []
        var column = 0
        var lookingForHeader = true
        try readCSV(text) { fields, line in
            if lookingForHeader, let header = fields.firstIndex(where: {
                headers.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }) {
                column = header
                lookingForHeader = false
                entries.removeAll() // PixInsight settings above the table are not image entries.
                return
            }
            let value = fields.indices.contains(column) ? fields[column] : ""
            entries.append(Entry(value: value, line: line))
            // Do not reinterpret a later metadata cell named "File" as a header.
            // Filesystem validation happens later, but a supported path identifies data.
            if ImageCollection.isSupportedImage(resolve(value, relativeTo: url)) { lookingForHeader = false }
        }
        return entries
    }

    static func resolve(_ value: String, relativeTo list: URL) -> URL {
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path, relativeTo: list.deletingLastPathComponent()).standardizedFileURL
    }

    private static func readCSV(_ text: String, row: ([String], Int) throws -> Void) throws {
        enum State { case unquoted, quoted, afterQuote, afterQuoteWhitespace }
        var state = State.unquoted
        var fields: [String] = []
        var field = ""
        var line = 1
        var rowLine = 1
        var hasContent = false

        func finishRow() throws {
            if hasContent || !fields.isEmpty || !field.trimmingCharacters(in: .whitespaces).isEmpty {
                fields.append(field.trimmingCharacters(in: .whitespaces))
                try row(fields, rowLine)
            }
            fields.removeAll(keepingCapacity: true)
            field = ""
            hasContent = false
            state = .unquoted
        }

        for (offset, scalar) in text.unicodeScalars.enumerated() {
            if offset & 1023 == 0 { try Task.checkCancellation() }
            if state == .quoted {
                if scalar == "\"" { state = .afterQuote }
                else { field.unicodeScalars.append(scalar) }
                if scalar == "\n" { line += 1 }
                continue
            }
            switch scalar {
            case "\"":
                if state == .afterQuote {
                    field.append("\"")
                    state = .quoted
                } else if state == .unquoted, field.trimmingCharacters(in: .whitespaces).isEmpty {
                    field = ""
                    state = .quoted
                    hasContent = true
                } else { throw InvalidCSV(line: rowLine) }
            case ",":
                fields.append(field.trimmingCharacters(in: .whitespaces))
                field = ""
                hasContent = true
                state = .unquoted
            case "\n":
                try finishRow()
                line += 1
                rowLine = line
            default:
                if state == .afterQuote || state == .afterQuoteWhitespace {
                    guard scalar == " " || scalar == "\t" else { throw InvalidCSV(line: rowLine) }
                    state = .afterQuoteWhitespace
                    continue
                }
                field.unicodeScalars.append(scalar)
            }
        }
        try Task.checkCancellation()
        guard state != .quoted else { throw InvalidCSV(line: rowLine) }
        try finishRow()
    }
}
