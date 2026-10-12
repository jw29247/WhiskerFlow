import Foundation

/// One successful dictation, reduced to counts. Insights never see transcript
/// text: the words are counted before this is built.
public struct DictationInsight: Equatable, Sendable {
    public var date: Date
    public var words: Int
    public var speakingSeconds: Double
    /// The app the text was delivered to; nil when unknown (retries, backfill).
    public var appBundleID: String?
    public var engine: String
    public var vocabularyReplacements: Int
    public var selfCorrections: Int

    public init(date: Date, words: Int, speakingSeconds: Double, appBundleID: String?, engine: String,
                vocabularyReplacements: Int = 0, selfCorrections: Int = 0) {
        self.date = date
        self.words = words
        self.speakingSeconds = speakingSeconds
        self.appBundleID = appBundleID
        self.engine = engine
        self.vocabularyReplacements = vocabularyReplacements
        self.selfCorrections = selfCorrections
    }
}

/// Totals for one local day and hour, per app and engine.
public struct InsightsBucket: Equatable, Sendable {
    public struct Key: Hashable, Sendable {
        public let day: LocalDay
        public let hour: Int
        /// Empty when the destination app is unknown.
        public let appBundleID: String
        public let engine: String

        public init(day: LocalDay, hour: Int, appBundleID: String, engine: String) {
            self.day = day
            self.hour = hour
            self.appBundleID = appBundleID
            self.engine = engine
        }
    }

    public let key: Key
    public var dictations: Int
    public var words: Int
    public var speakingSeconds: Double
    public var vocabularyReplacements: Int
    public var selfCorrections: Int

    public init(key: Key, dictations: Int = 0, words: Int = 0, speakingSeconds: Double = 0,
                vocabularyReplacements: Int = 0, selfCorrections: Int = 0) {
        self.key = key
        self.dictations = dictations
        self.words = words
        self.speakingSeconds = speakingSeconds
        self.vocabularyReplacements = vocabularyReplacements
        self.selfCorrections = selfCorrections
    }

    public static func key(for insight: DictationInsight, calendar: Calendar) -> Key {
        Key(day: LocalDay(insight.date, calendar: calendar),
            hour: LocalDay.hour(of: insight.date, calendar: calendar),
            appBundleID: insight.appBundleID ?? "",
            engine: insight.engine)
    }

    public mutating func add(_ insight: DictationInsight) {
        dictations += 1
        words += max(0, insight.words)
        speakingSeconds += max(0, insight.speakingSeconds)
        vocabularyReplacements += max(0, insight.vocabularyReplacements)
        selfCorrections += max(0, insight.selfCorrections)
    }
}

/// Words and speaking time of a single dictation, kept for the rolling WPM.
public struct DictationSample: Equatable, Sendable {
    public let words: Int
    public let speakingSeconds: Double

    public init(words: Int, speakingSeconds: Double) {
        self.words = words
        self.speakingSeconds = speakingSeconds
    }
}

// MARK: - App grouping

/// What Top apps aggregates by. Today every bundle ID is its own group; the App
/// categories feature can supply an `InsightsAppGrouping` that maps bundle IDs to
/// `.category` groups without touching the store or the calculator.
public enum InsightsAppGroup: Hashable, Sendable {
    case application(bundleID: String)
    case category(String)
    case unknown
}

public protocol InsightsAppGrouping: Sendable {
    func group(forBundleID bundleID: String) -> InsightsAppGroup
}

public struct BundleIDAppGrouping: InsightsAppGrouping {
    public init() {}

    public func group(forBundleID bundleID: String) -> InsightsAppGroup {
        bundleID.isEmpty ? .unknown : .application(bundleID: bundleID)
    }
}

public struct AppUsage: Equatable, Sendable, Identifiable {
    public let group: InsightsAppGroup
    public let words: Int
    public let dictations: Int
    public var id: InsightsAppGroup { group }
}

// MARK: - Calculations

public enum DictationStreaks {
    /// Consecutive local days with at least one dictation. The current streak is
    /// still alive until a full day passes without dictating, so it counts back
    /// from today or, if today has none yet, from yesterday. A day later than
    /// `today` (recorded before flying west) anchors it too.
    public static func compute(activeDays: Set<LocalDay>, today: LocalDay) -> (current: Int, longest: Int) {
        guard !activeDays.isEmpty else { return (0, 0) }
        let sorted = activeDays.sorted()
        var longest = 1
        var run = 1
        for index in sorted.indices.dropFirst() {
            run = sorted[index].days(since: sorted[index - 1]) == 1 ? run + 1 : 1
            longest = max(longest, run)
        }

        guard let latest = sorted.last, latest.days(since: today) >= -1 else { return (0, longest) }
        var current = 0
        var day = latest
        while activeDays.contains(day) {
            current += 1
            day = day.adding(days: -1)
        }
        return (current, longest)
    }
}

/// Dictations by day of week and hour of day, in the user's local time.
public struct ActivityHeatmap: Equatable, Sendable {
    /// Weekday numbers (1 = Sunday) in display order, starting at the locale's
    /// first weekday.
    public let weekdays: [Int]
    /// `counts[row][hour]`, rows in `weekdays` order.
    public let counts: [[Int]]
    public let maximum: Int

    public init(buckets: [InsightsBucket], firstWeekday: Int) {
        let weekdays = (0..<7).map { (firstWeekday - 1 + $0) % 7 + 1 }
        var counts = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for bucket in buckets where (0..<24).contains(bucket.key.hour) {
            guard let row = weekdays.firstIndex(of: bucket.key.day.weekday) else { continue }
            counts[row][bucket.key.hour] += bucket.dictations
        }
        self.weekdays = weekdays
        self.counts = counts
        maximum = counts.joined().max() ?? 0
    }
}

public struct InsightsSummary: Equatable, Sendable {
    public static let defaultTypingWordsPerMinute = 40
    public static let typingWordsPerMinuteRange = 10...200
    /// Speaking WPM uses at most this many recent dictations.
    public static let speakingSampleLimit = 100
    /// Below this much speech the WPM is too noisy to show.
    public static let minimumSpeakingSeconds: Double = 10

    public let lifetimeWords: Int
    public let lifetimeDictations: Int
    public let lifetimeSpeakingSeconds: Double
    public let wordsThisWeek: Int
    public let wordsThisMonth: Int
    public let speakingWordsPerMinute: Double?
    public let typingWordsPerMinute: Int
    public let timeSavedSeconds: Double
    public let currentStreak: Int
    public let longestStreak: Int
    public let heatmap: ActivityHeatmap
    public let topApps: [AppUsage]
    public let vocabularyReplacements: Int
    public let selfCorrections: Int

    public var isEmpty: Bool { lifetimeDictations == 0 }
    public var correctionsApplied: Int { vocabularyReplacements + selfCorrections }

    public init(
        buckets: [InsightsBucket],
        recentSamples: [DictationSample],
        typingWordsPerMinute requestedTypingSpeed: Int = defaultTypingWordsPerMinute,
        now: Date = Date(),
        calendar: Calendar = .current,
        appGrouping: any InsightsAppGrouping = BundleIDAppGrouping(),
        topAppLimit: Int = 5
    ) {
        let today = LocalDay(now, calendar: calendar)
        let weekStart = today.startOfWeek(firstWeekday: calendar.firstWeekday)
        let monthStart = today.startOfMonth

        var words = 0, dictations = 0, seconds = 0.0, week = 0, month = 0, replacements = 0, repairs = 0
        var activeDays = Set<LocalDay>()
        var apps: [InsightsAppGroup: (words: Int, dictations: Int)] = [:]
        for bucket in buckets {
            words += bucket.words
            dictations += bucket.dictations
            seconds += bucket.speakingSeconds
            replacements += bucket.vocabularyReplacements
            repairs += bucket.selfCorrections
            if bucket.key.day >= weekStart { week += bucket.words }
            if bucket.key.day >= monthStart { month += bucket.words }
            if bucket.dictations > 0 { activeDays.insert(bucket.key.day) }
            let group = appGrouping.group(forBundleID: bucket.key.appBundleID)
            apps[group, default: (0, 0)].words += bucket.words
            apps[group, default: (0, 0)].dictations += bucket.dictations
        }

        let typing = min(max(requestedTypingSpeed, Self.typingWordsPerMinuteRange.lowerBound),
                         Self.typingWordsPerMinuteRange.upperBound)
        let speaking = Self.speakingWordsPerMinute(recentSamples)
        let typingSeconds = Double(words) / Double(typing) * 60
        let spokenSeconds = speaking.map { Double(words) / $0 * 60 } ?? seconds
        let streaks = DictationStreaks.compute(activeDays: activeDays, today: today)

        lifetimeWords = words
        lifetimeDictations = dictations
        lifetimeSpeakingSeconds = seconds
        wordsThisWeek = week
        wordsThisMonth = month
        speakingWordsPerMinute = speaking
        typingWordsPerMinute = typing
        timeSavedSeconds = max(0, typingSeconds - spokenSeconds)
        currentStreak = streaks.current
        longestStreak = streaks.longest
        heatmap = ActivityHeatmap(buckets: buckets, firstWeekday: calendar.firstWeekday)
        topApps = apps
            .filter { $0.value.dictations > 0 }
            .map { AppUsage(group: $0.key, words: $0.value.words, dictations: $0.value.dictations) }
            .sorted { lhs, rhs in
                if lhs.words != rhs.words { return lhs.words > rhs.words }
                return lhs.dictations > rhs.dictations
            }
            .prefix(max(0, topAppLimit))
            .map { $0 }
        vocabularyReplacements = replacements
        selfCorrections = repairs
    }

    /// Words ÷ speaking time over the most recent dictations (samples oldest first).
    public static func speakingWordsPerMinute(_ samples: [DictationSample]) -> Double? {
        let recent = samples.suffix(speakingSampleLimit).filter { $0.speakingSeconds > 0 }
        let seconds = recent.reduce(0) { $0 + $1.speakingSeconds }
        guard seconds >= minimumSpeakingSeconds else { return nil }
        let words = recent.reduce(0) { $0 + $1.words }
        guard words > 0 else { return nil }
        return Double(words) / seconds * 60
    }
}
