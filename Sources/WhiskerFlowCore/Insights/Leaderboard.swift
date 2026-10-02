import Foundation

/// One local day of usage as reported to the company leaderboard in Atlas.
/// Counts only: never text, apps or meeting titles.
public struct LeaderboardDay: Equatable, Sendable {
    public var day: LocalDay
    public var words: Int
    public var dictations: Int
    public var speakingSeconds: Int
    public var timeSavedSeconds: Int
    public var meetings: Int
    public var meetingSeconds: Int

    public init(day: LocalDay, words: Int, dictations: Int, speakingSeconds: Int, timeSavedSeconds: Int,
                meetings: Int, meetingSeconds: Int) {
        self.day = day
        self.words = words
        self.dictations = dictations
        self.speakingSeconds = speakingSeconds
        self.timeSavedSeconds = timeSavedSeconds
        self.meetings = meetings
        self.meetingSeconds = meetingSeconds
    }

    /// The `notetaker.leaderboard.report` day object.
    public var payload: [String: Any] {
        ["day": day.key, "words": words, "dictations": dictations, "speakingSeconds": speakingSeconds,
         "timeSavedSeconds": timeSavedSeconds, "meetings": meetings, "meetingSeconds": meetingSeconds]
    }
}

/// Meetings recorded per local day. Kept apart from the meeting library,
/// whose retention can delete an entry right after delivery.
public struct MeetingTally: Codable, Equatable, Sendable {
    public struct Day: Codable, Equatable, Sendable {
        public var meetings: Int
        public var seconds: Int
    }

    /// Shorter recordings are started by mistake, not meetings.
    public static let minimumSeconds = 60

    public private(set) var days: [String: Day] = [:]

    public init() {}

    public mutating func record(day: LocalDay, durationSeconds: Int) {
        guard durationSeconds >= Self.minimumSeconds else { return }
        var entry = days[day.key] ?? Day(meetings: 0, seconds: 0)
        entry.meetings += 1
        entry.seconds += durationSeconds
        days[day.key] = entry
    }
}

public enum LeaderboardReport {
    /// Time saved compares speaking with typing at the standard speed, not
    /// each person's own setting, so the board compares like with like.
    public static let typingWordsPerMinute = InsightsSummary.defaultTypingWordsPerMinute
    /// Atlas rejects days before this.
    public static let earliestDay = LocalDay(year: 2024, month: 1, day: 1)
    public static let maximumDaysPerRequest = 400

    public static func days(buckets: [InsightsBucket], meetings: MeetingTally) -> [LeaderboardDay] {
        var words: [LocalDay: Int] = [:]
        var dictations: [LocalDay: Int] = [:]
        var speaking: [LocalDay: Double] = [:]
        for bucket in buckets {
            words[bucket.key.day, default: 0] += bucket.words
            dictations[bucket.key.day, default: 0] += bucket.dictations
            speaking[bucket.key.day, default: 0] += bucket.speakingSeconds
        }
        let meetingDays = Dictionary(uniqueKeysWithValues: meetings.days.compactMap { key, value in
            LocalDay(key: key).map { ($0, value) }
        })
        let allDays = Set(words.keys).union(dictations.keys).union(meetingDays.keys)
        return allDays.sorted().map { day in
            let dayWords = words[day] ?? 0
            let spoken = speaking[day] ?? 0
            let typed = Double(dayWords) / Double(typingWordsPerMinute) * 60
            return LeaderboardDay(
                day: day,
                words: min(dayWords, 200_000),
                dictations: min(dictations[day] ?? 0, 20_000),
                speakingSeconds: min(Int(spoken.rounded()), 86_400),
                timeSavedSeconds: min(Int(max(0, typed - spoken).rounded()), 345_600),
                meetings: min(meetingDays[day]?.meetings ?? 0, 200),
                meetingSeconds: min(meetingDays[day]?.seconds ?? 0, 86_400)
            )
        }
    }

    /// The first report sends all history; later ones only yesterday and
    /// today, because Atlas keeps the last value for each day and History
    /// retention may since have trimmed older ones.
    public static func daysToSend(_ days: [LeaderboardDay], reportedThrough: LocalDay?, today: LocalDay) -> [LeaderboardDay] {
        let from = reportedThrough.map { max($0.adding(days: -1), earliestDay) } ?? earliestDay
        return days.filter { $0.day >= from && $0.day <= today }
    }
}

public enum LeaderboardWindow: String, CaseIterable, Identifiable, Sendable {
    case week, month, allTime

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .week: return "This week"
        case .month: return "This month"
        case .allTime: return "All time"
        }
    }

    /// The first day counted, or nil for all time.
    public func since(today: LocalDay, firstWeekday: Int) -> LocalDay? {
        switch self {
        case .week: return today.startOfWeek(firstWeekday: firstWeekday)
        case .month: return today.startOfMonth
        case .allTime: return nil
        }
    }
}

public enum LeaderboardMetric: String, CaseIterable, Identifiable, Sendable {
    case words, timeSaved, streak, meetings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .words: return "Words"
        case .timeSaved: return "Time saved"
        case .streak: return "Streak"
        case .meetings: return "Meetings"
        }
    }

    public func value(_ entry: LeaderboardEntry) -> Int {
        switch self {
        case .words: return entry.words
        case .timeSaved: return entry.timeSavedSeconds
        case .streak: return entry.currentStreakDays
        case .meetings: return entry.meetings
        }
    }
}

/// One person on the board, as `notetaker.leaderboard.get` returns them.
public struct LeaderboardEntry: Decodable, Equatable, Identifiable, Sendable {
    public var employeeId: String
    public var name: String
    public var avatarUrl: String?
    public var isYou: Bool
    public var words: Int
    public var dictations: Int
    public var speakingSeconds: Int
    public var timeSavedSeconds: Int
    public var meetings: Int
    public var meetingSeconds: Int
    public var currentStreakDays: Int
    public var longestStreakDays: Int
    public var lastActiveDay: String?

    public var id: String { employeeId }

    public init(employeeId: String, name: String, avatarUrl: String?, isYou: Bool, words: Int, dictations: Int,
                speakingSeconds: Int, timeSavedSeconds: Int, meetings: Int, meetingSeconds: Int,
                currentStreakDays: Int, longestStreakDays: Int, lastActiveDay: String?) {
        self.employeeId = employeeId
        self.name = name
        self.avatarUrl = avatarUrl
        self.isYou = isYou
        self.words = words
        self.dictations = dictations
        self.speakingSeconds = speakingSeconds
        self.timeSavedSeconds = timeSavedSeconds
        self.meetings = meetings
        self.meetingSeconds = meetingSeconds
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
        self.lastActiveDay = lastActiveDay
    }
}

public struct LeaderboardBoard: Decodable, Equatable, Sendable {
    public var generatedAt: Double
    public var entries: [LeaderboardEntry]

    public init(generatedAt: Double, entries: [LeaderboardEntry]) {
        self.generatedAt = generatedAt
        self.entries = entries
    }
}

public enum LeaderboardRanking {
    public struct Row: Equatable, Identifiable, Sendable {
        public var rank: Int
        public var entry: LeaderboardEntry
        public var id: String { entry.id }
    }

    /// Highest first; equal values share a rank. People with nothing in the
    /// window are left off, except you.
    public static func ranked(_ entries: [LeaderboardEntry], by metric: LeaderboardMetric) -> [Row] {
        let sorted = entries
            .filter { metric.value($0) > 0 || $0.isYou }
            .sorted { (metric.value($0), $1.name) > (metric.value($1), $0.name) }
        var rows: [Row] = []
        for (index, entry) in sorted.enumerated() {
            let tied = rows.last.map { metric.value($0.entry) == metric.value(entry) } ?? false
            rows.append(Row(rank: tied ? rows[rows.count - 1].rank : index + 1, entry: entry))
        }
        return rows
    }
}
