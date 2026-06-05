import Foundation

public struct DailyWordCount: Equatable, Sendable, Identifiable {
    public let day: Date
    public let words: Int
    public var id: Date { day }

    public init(day: Date, words: Int) {
        self.day = day
        self.words = words
    }
}

public extension Array where Element == TranscriptRecord {
    /// Case-insensitive substring match over transcript text. Empty query returns all.
    func matching(_ query: String) -> [TranscriptRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self }
        return filter { $0.text.range(of: trimmed, options: .caseInsensitive) != nil }
    }

    /// Word totals per calendar day for the last `days` days (oldest first), zero-filled.
    func dailyWordCounts(
        days: Int = 14,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyWordCount] {
        guard days > 0 else { return [] }

        let transcribed = filter { $0.status == .transcribed }
        var totals: [Date: Int] = [:]
        for record in transcribed {
            let day = calendar.startOfDay(for: record.createdAt)
            totals[day, default: 0] += record.wordCount
        }

        let today = calendar.startOfDay(for: now)
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DailyWordCount(day: day, words: totals[day] ?? 0)
        }
    }
}
