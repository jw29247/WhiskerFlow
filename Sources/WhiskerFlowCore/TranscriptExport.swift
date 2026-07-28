import Foundation

public enum TranscriptExportFormat: String, CaseIterable, Sendable {
    case markdown
    case csv
    case json

    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .csv: return "csv"
        case .json: return "json"
        }
    }
}

public enum TranscriptExporter {
    public static func export(
        _ records: [TranscriptRecord],
        as format: TranscriptExportFormat,
        timeZone: TimeZone = .current
    ) throws -> Data {
        switch format {
        case .markdown: return Data(markdown(records, timeZone: timeZone).utf8)
        case .csv: return Data(csv(records).utf8)
        case .json: return try json(records)
        }
    }

    public static func markdown(_ records: [TranscriptRecord], timeZone: TimeZone = .current) -> String {
        let formatter = headingFormatter(timeZone: timeZone)
        var lines = ["# WhiskerFlow Transcripts", ""]
        for record in completed(records) {
            lines.append("## \(formatter.string(from: record.createdAt))")
            lines.append("")
            lines.append(record.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func csv(_ records: [TranscriptRecord]) -> String {
        let header = ["Created", "Words", "Duration Seconds", "Model", "Engine", "Language", "Text"]
        var rows = [header.joined(separator: ",")]
        let formatter = ISO8601DateFormatter()
        for record in completed(records) {
            let fields = [
                formatter.string(from: record.createdAt),
                String(record.wordCount),
                record.durationSeconds.map { String(format: "%.2f", $0) } ?? "",
                record.model ?? "",
                record.engine ?? "",
                record.language ?? "",
                record.text
            ]
            rows.append(fields.map(quoted).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    public static func json(_ records: [TranscriptRecord]) throws -> Data {
        try JSONEncoder.whiskerFlow.encode(completed(records).map(ExportedTranscript.init))
    }

    /// Export-specific shape. The storage model carries an absolute audio path
    /// under the user's home and, for a failed record, the raw error message —
    /// neither belongs in a file the user shares, and the diagnostics sanitizer
    /// strips exactly this kind of detail everywhere else.
    private struct ExportedTranscript: Encodable {
        let id: UUID
        let createdAt: Date
        let updatedAt: Date?
        let text: String
        let wordCount: Int
        let durationSeconds: Double?
        let model: String?
        let engine: String?
        let language: String?

        init(_ record: TranscriptRecord) {
            id = record.id
            createdAt = record.createdAt
            updatedAt = record.updatedAt
            text = record.text
            wordCount = record.wordCount
            durationSeconds = record.durationSeconds
            model = record.model
            engine = record.engine
            language = record.language
        }
    }

    private static func completed(_ records: [TranscriptRecord]) -> [TranscriptRecord] {
        newestFirst(records.filter { $0.status == .transcribed })
    }

    private static func newestFirst(_ records: [TranscriptRecord]) -> [TranscriptRecord] {
        records.sorted { $0.createdAt > $1.createdAt }
    }

    private static func headingFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }

    /// RFC 4180: any field carrying a delimiter, quote, or line break must be
    /// wrapped, and quotes inside it doubled.
    private static func quoted(_ field: String) -> String {
        let needsQuoting = field.contains(",")
            || field.contains("\"")
            || field.contains("\n")
            || field.contains("\r")
        guard needsQuoting else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
