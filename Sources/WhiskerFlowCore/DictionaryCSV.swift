import Foundation

/// CSV import and export for personal dictionary entries (RFC 4180 quoting).
///
/// Columns: `type,heard,written,case_sensitive,whole_word,starred,also_heard`.
/// `type` is `word` or `replacement`; `also_heard` holds a word's absorbed
/// misspellings separated by `|`. Usage counts are deliberately not exported:
/// they describe this Mac, not the entry.
public enum DictionaryCSV {
    public static let header = ["type", "heard", "written", "case_sensitive", "whole_word", "starred", "also_heard"]

    public struct ImportReport: Equatable, Sendable {
        public var entries: [DictionaryEntry]
        /// Rows identical to an existing entry, or to an earlier row in the file.
        public var duplicateCount: Int
        /// Rows that could not be read, with the 1-based line they start on.
        public var problems: [Problem]

        public struct Problem: Equatable, Sendable {
            public var line: Int
            public var message: String
        }
    }

    public enum ImportError: Error, Equatable, LocalizedError {
        case missingHeader
        case tooLarge

        public var errorDescription: String? {
            switch self {
            case .missingHeader: return "The file needs a header row with at least “type” and “written” columns."
            case .tooLarge: return "The file is too large to be a dictionary."
            }
        }
    }

    public static let maximumBytes = 1_024 * 1_024

    public static func export(_ entries: [DictionaryEntry]) -> String {
        var lines = [header.joined(separator: ",")]
        for entry in entries {
            let fields = [
                entry.kind.rawValue,
                entry.kind == .word ? "" : entry.heard,
                entry.written,
                entry.kind == .word ? "" : String(entry.caseSensitive),
                entry.kind == .word ? "" : String(entry.wholeWord),
                String(entry.starred),
                entry.variants.joined(separator: "|")
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Reads rows into new `.imported` entries, skipping any that duplicate
    /// `existing` or an earlier row. Nothing is merged into a dictionary here;
    /// the caller decides what to do with the report.
    public static func importEntries(from text: String, existing: [DictionaryEntry] = [],
                                     at date: Date = Date()) throws -> ImportReport {
        guard text.utf8.count <= maximumBytes else { throw ImportError.tooLarge }
        let rows = parse(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        guard let headerRow = rows.first else { throw ImportError.missingHeader }
        let columns = headerRow.fields.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let writtenColumn = columns.firstIndex(of: "written") else { throw ImportError.missingHeader }
        func column(_ name: String) -> Int? { columns.firstIndex(of: name) }

        var seen = Set(existing.map(identity))
        var report = ImportReport(entries: [], duplicateCount: 0, problems: [])
        for row in rows.dropFirst() {
            let fields = row.fields
            guard fields.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            func value(_ index: Int?) -> String {
                guard let index, index < fields.count else { return "" }
                return unescape(fields[index]).trimmingCharacters(in: .whitespaces)
            }
            let heard = value(column("heard"))
            let written = value(writtenColumn)
            let typeValue = value(column("type")).lowercased()
            let kind: DictionaryEntryKind
            switch typeValue {
            case "word": kind = .word
            case "replacement": kind = .replacement
            case "": kind = heard.isEmpty ? .word : .replacement
            default:
                report.problems.append(.init(line: row.line, message: "Unknown type “\(typeValue)”."))
                continue
            }
            guard let caseSensitive = bool(value(column("case_sensitive")), default: false),
                  let wholeWord = bool(value(column("whole_word")), default: true),
                  let starred = bool(value(column("starred")), default: false) else {
                report.problems.append(.init(line: row.line, message: "Use true or false for the option columns."))
                continue
            }
            let variants = value(column("also_heard")).split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let entry = DictionaryEntry(kind: kind, heard: heard, written: written, variants: variants,
                                        caseSensitive: caseSensitive, wholeWord: wholeWord, starred: starred,
                                        origin: .imported, addedAt: date)
            if let problem = entry.validationProblem {
                report.problems.append(.init(line: row.line, message: problem.message))
                continue
            }
            guard seen.insert(identity(entry)).inserted else {
                report.duplicateCount += 1
                continue
            }
            report.entries.append(entry)
        }
        return report
    }

    /// Entries are the same when they would behave the same.
    static func identity(_ entry: DictionaryEntry) -> String {
        [entry.kind.rawValue, entry.heard.lowercased(), entry.written].joined(separator: "\u{1F}")
    }

    private static func bool(_ raw: String, default fallback: Bool) -> Bool? {
        switch raw.lowercased() {
        case "": return fallback
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    /// A spreadsheet treats a cell starting with = + - @ as a formula. Exported
    /// cells that would are prefixed with an apostrophe, which the importer
    /// strips again, so the file is safe to open and still round-trips.
    private static let formulaLeaders: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

    private static func escape(_ field: String) -> String {
        var value = field
        if let first = value.first, formulaLeaders.contains(first) { value = "'" + value }
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func unescape(_ field: String) -> String {
        guard field.hasPrefix("'"), let second = field.dropFirst().first, formulaLeaders.contains(second) else {
            return field
        }
        return String(field.dropFirst())
    }

    private struct Row {
        var fields: [String]
        var line: Int
    }

    /// Splits on commas and line breaks outside quotes; a doubled quote inside
    /// quotes is a literal quote.
    private static func parse(_ text: String) -> [Row] {
        var rows: [Row] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var line = 1
        var rowStart = 1
        var characters = Array(text)[...]
        while let character = characters.popFirst() {
            if inQuotes {
                if character == "\"" {
                    if characters.first == "\"" {
                        field.append("\"")
                        characters.removeFirst()
                    } else {
                        inQuotes = false
                    }
                } else {
                    if character == "\n" || character == "\r\n" { line += 1 }
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty:
                inQuotes = true
            case ",":
                fields.append(field)
                field = ""
            case "\n", "\r\n", "\r":
                fields.append(field)
                rows.append(Row(fields: fields, line: rowStart))
                fields = []
                field = ""
                line += 1
                rowStart = line
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !fields.isEmpty {
            fields.append(field)
            rows.append(Row(fields: fields, line: rowStart))
        }
        return rows
    }
}
