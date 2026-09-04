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
        // Most completed transcripts already have normal spacing. Avoid regex
        // passes and allocating another string whenever Copy is pressed.
        if hasNormalizedASCIISpacing { return self }
        let spacing = DeliveryExpressions.spaces.stringByReplacingMatches(
            in: self, range: NSRange(startIndex..., in: self), withTemplate: " "
        )
        return DeliveryExpressions.lines.stringByReplacingMatches(
            in: spacing, range: NSRange(spacing.startIndex..., in: spacing), withTemplate: "\n"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var transcriptWordCount: Int {
        // Count boundaries directly. History and Stats should not build a
        // normalized transcript and an array of every word just to count them.
        var count = 0
        var insideWord = false
        for byte in utf8 {
            if byte >= 128 { return unicodeTranscriptWordCount }
            let isSpace = byte == 32 || (9...13).contains(byte)
            if !isSpace && !insideWord { count += 1 }
            insideWord = !isSpace
        }
        return count
    }

    private var unicodeTranscriptWordCount: Int {
        var count = 0
        var insideWord = false
        for scalar in unicodeScalars {
            let isSpace = CharacterSet.whitespacesAndNewlines.contains(scalar)
            if !isSpace && !insideWord { count += 1 }
            insideWord = !isSpace
        }
        return count
    }

    private var hasNormalizedASCIISpacing: Bool {
        let bytes = utf8
        guard let first = bytes.first, let last = bytes.last else { return true }
        func isWhitespace(_ byte: UInt8) -> Bool { byte == 32 || (9...13).contains(byte) }
        guard !isWhitespace(first), !isWhitespace(last) else { return false }
        var previous: UInt8 = 0
        for byte in bytes {
            guard byte < 128, byte != 9 else { return false }
            if (byte == 32 && (previous == 32 || previous == 10)) || (byte == 10 && previous == 32) {
                return false
            }
            previous = byte
        }
        return true
    }
}

private enum DeliveryExpressions {
    static let spaces = try! NSRegularExpression(pattern: "[ \t]+")
    static let lines = try! NSRegularExpression(pattern: "[ \t]*\n[ \t]*")
}
