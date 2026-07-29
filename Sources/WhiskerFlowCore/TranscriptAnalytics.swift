import Foundation

public struct TranscriptAnalytics: Equatable, Sendable {
    public let allTime: TranscriptStats
    public let thisWeek: TranscriptStats
    public let lastMonth: TranscriptStats

    public init(records: [TranscriptRecord], now: Date = Date()) {
        let transcribedRecords = records.filter { $0.status == .transcribed }

        allTime = TranscriptStats(records: transcribedRecords)
        thisWeek = TranscriptStats(records: transcribedRecords, since: now.addingTimeInterval(-7 * 24 * 60 * 60))
        lastMonth = TranscriptStats(records: transcribedRecords, since: now.addingTimeInterval(-30 * 24 * 60 * 60))
    }
}

public struct TranscriptStats: Equatable, Sendable {
    public let wordCount: Int

    public init(wordCount: Int) {
        self.wordCount = wordCount
    }

    public init(records: [TranscriptRecord], since cutoff: Date? = nil) {
        let scopedRecords = records.filter { record in
            guard let cutoff else { return true }
            return record.createdAt >= cutoff
        }

        wordCount = scopedRecords.reduce(0) { count, record in
            count + record.text.transcriptWordCount
        }
    }

    public func estimatedTypingMinutes(wordsPerMinute: Int = 40) -> Double {
        guard wordsPerMinute > 0 else { return 0 }
        return Double(wordCount) / Double(wordsPerMinute)
    }
}

public extension String {
    var plainTranscriptText: String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Tidy spacing for the clipboard while keeping line breaks intact — the
    /// formatter's "new line" / "new paragraph" commands only survive delivery
    /// because this preserves `\n` where `plainTranscriptText` collapses it.
    var normalizedForDelivery: String {
        replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[ \t]*\n[ \t]*", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var transcriptWordCount: Int {
        plainTranscriptText
            .split(separator: " ")
            .count
    }
}
