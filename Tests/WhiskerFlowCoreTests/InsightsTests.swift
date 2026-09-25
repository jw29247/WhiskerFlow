import XCTest
@testable import WhiskerFlowCore

final class InsightsTests: XCTestCase {
    private func calendar(_ identifier: String, firstWeekday: Int = 1) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ string: String, _ zone: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: string)!
    }

    private func insight(_ date: Date, words: Int = 10, seconds: Double = 5, app: String? = "com.apple.mail",
                         engine: String = "parakeetTDTv3") -> DictationInsight {
        DictationInsight(date: date, words: words, speakingSeconds: seconds, appBundleID: app, engine: engine)
    }

    private func buckets(_ insights: [DictationInsight], calendar: Calendar) -> [InsightsBucket] {
        var index: [InsightsBucket.Key: InsightsBucket] = [:]
        for insight in insights {
            let key = InsightsBucket.key(for: insight, calendar: calendar)
            index[key, default: InsightsBucket(key: key)].add(insight)
        }
        return Array(index.values)
    }

    // MARK: - Local days

    func testLocalDayFollowsTheUsersTimeZone() {
        let instant = date("2026-03-09 03:30", "UTC")
        XCTAssertEqual(LocalDay(instant, calendar: calendar("UTC")), LocalDay(year: 2026, month: 3, day: 9))
        XCTAssertEqual(LocalDay(instant, calendar: calendar("America/Los_Angeles")), LocalDay(year: 2026, month: 3, day: 8))
        XCTAssertEqual(LocalDay.hour(of: instant, calendar: calendar("Asia/Tokyo")), 12)
    }

    func testLocalDayArithmeticIgnoresDaylightSaving() {
        let beforeSpringForward = LocalDay(year: 2026, month: 3, day: 7)
        XCTAssertEqual(beforeSpringForward.adding(days: 2), LocalDay(year: 2026, month: 3, day: 9))
        XCTAssertEqual(LocalDay(year: 2026, month: 11, day: 2).days(since: LocalDay(year: 2026, month: 10, day: 31)), 2)
        XCTAssertEqual(LocalDay(year: 2026, month: 3, day: 1).adding(days: -1), LocalDay(year: 2026, month: 2, day: 28))
        XCTAssertEqual(LocalDay(key: "2026-09-25"), LocalDay(year: 2026, month: 9, day: 25))
        XCTAssertEqual(LocalDay(year: 2026, month: 9, day: 25).weekday, 6) // Friday
    }

    // MARK: - Streaks

    func testStreakSpansTheSpringForwardAndFallBackDays() {
        let zone = "America/New_York"
        let cal = calendar(zone)
        // 8 March 2026 is 23 hours long in New York; 1 November is 25.
        let spring = ["2026-03-07 23:50", "2026-03-08 01:30", "2026-03-08 03:10", "2026-03-09 00:05"]
        let fall = ["2026-10-31 22:00", "2026-11-01 01:30", "2026-11-02 23:59"]
        let days = Set((spring + fall).map { LocalDay(date($0, zone), calendar: cal) })

        let result = DictationStreaks.compute(activeDays: days, today: LocalDay(year: 2026, month: 11, day: 2))
        XCTAssertEqual(result.current, 3)
        XCTAssertEqual(result.longest, 3)
        XCTAssertEqual(days.count, 6)
    }

    func testDictationsEitherSideOfMidnightAreTwoDays() {
        let zone = "Europe/London"
        let cal = calendar(zone)
        let days = Set(["2026-09-24 23:59", "2026-09-25 00:01"].map { LocalDay(date($0, zone), calendar: cal) })
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(DictationStreaks.compute(activeDays: days, today: LocalDay(year: 2026, month: 9, day: 25)).current, 2)
    }

    func testCurrentStreakSurvivesUntilADayIsMissed() {
        let days: Set<LocalDay> = [LocalDay(year: 2026, month: 9, day: 22), LocalDay(year: 2026, month: 9, day: 23),
                                   LocalDay(year: 2026, month: 9, day: 24)]
        XCTAssertEqual(DictationStreaks.compute(activeDays: days, today: LocalDay(year: 2026, month: 9, day: 25)).current, 3,
                       "no dictation yet today does not break the streak")
        XCTAssertEqual(DictationStreaks.compute(activeDays: days, today: LocalDay(year: 2026, month: 9, day: 26)).current, 0)
        XCTAssertEqual(DictationStreaks.compute(activeDays: days, today: LocalDay(year: 2026, month: 9, day: 26)).longest, 3)
    }

    func testLongestStreakFindsTheBestRun() {
        let start = LocalDay(year: 2026, month: 1, day: 30)
        var days = Set((0..<5).map { start.adding(days: $0) })
        days.formUnion((10..<12).map { start.adding(days: $0) })
        let result = DictationStreaks.compute(activeDays: days, today: start.adding(days: 11))
        XCTAssertEqual(result.longest, 5)
        XCTAssertEqual(result.current, 2)
    }

    // MARK: - Summary

    func testEmptyStateHasNoInsights() {
        let summary = InsightsSummary(buckets: [], recentSamples: [], now: Date(), calendar: calendar("UTC"))
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.lifetimeWords, 0)
        XCTAssertNil(summary.speakingWordsPerMinute)
        XCTAssertEqual(summary.timeSavedSeconds, 0)
        XCTAssertEqual(summary.currentStreak, 0)
        XCTAssertEqual(summary.longestStreak, 0)
        XCTAssertEqual(summary.heatmap.maximum, 0)
        XCTAssertEqual(summary.heatmap.counts.count, 7)
        XCTAssertTrue(summary.topApps.isEmpty)
        XCTAssertEqual(summary.typingWordsPerMinute, 40)
    }

    func testWeekAndMonthFollowTheLocalCalendar() {
        let zone = "Europe/Berlin"
        let cal = calendar(zone, firstWeekday: 2) // Monday
        let now = date("2026-09-25 12:00", zone) // Friday
        let insights = [
            insight(date("2026-09-25 09:00", zone), words: 1),
            insight(date("2026-09-21 00:10", zone), words: 2), // Monday this week
            insight(date("2026-09-20 23:50", zone), words: 4), // Sunday last week
            insight(date("2026-09-01 08:00", zone), words: 8),
            insight(date("2026-08-31 23:59", zone), words: 16)
        ]
        let summary = InsightsSummary(buckets: buckets(insights, calendar: cal), recentSamples: [], now: now, calendar: cal)
        XCTAssertEqual(summary.lifetimeWords, 31)
        XCTAssertEqual(summary.wordsThisWeek, 3)
        XCTAssertEqual(summary.wordsThisMonth, 15)
        XCTAssertEqual(summary.lifetimeDictations, 5)
    }

    func testSpeakingSpeedUsesTheLast100DictationsAndDrivesTimeSaved() {
        var samples = (0..<50).map { _ in DictationSample(words: 1, speakingSeconds: 60) } // slow, then dropped
        samples += (0..<100).map { _ in DictationSample(words: 25, speakingSeconds: 10) }  // 150 wpm
        XCTAssertEqual(InsightsSummary.speakingWordsPerMinute(samples)!, 150, accuracy: 0.001)

        let cal = calendar("UTC")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let bucket = buckets([insight(now, words: 1_500, seconds: 600)], calendar: cal)
        let summary = InsightsSummary(buckets: bucket, recentSamples: samples, typingWordsPerMinute: 50, now: now, calendar: cal)
        // 1,500 words: 30 min typing at 50 wpm, 10 min speaking at 150 wpm.
        XCTAssertEqual(summary.timeSavedSeconds, 20 * 60, accuracy: 0.001)
        XCTAssertEqual(summary.typingWordsPerMinute, 50)
    }

    func testTooLittleSpeechHasNoSpeakingSpeed() {
        XCTAssertNil(InsightsSummary.speakingWordsPerMinute([DictationSample(words: 5, speakingSeconds: 2)]))
        XCTAssertNil(InsightsSummary.speakingWordsPerMinute([DictationSample(words: 0, speakingSeconds: 60)]))
    }

    func testTypingSpeedIsClamped() {
        let summary = InsightsSummary(buckets: [], recentSamples: [], typingWordsPerMinute: 0, calendar: calendar("UTC"))
        XCTAssertEqual(summary.typingWordsPerMinute, 10)
    }

    func testHeatmapPlacesDictationsByLocalWeekdayAndHour() {
        let zone = "America/New_York"
        let cal = calendar(zone, firstWeekday: 2)
        let insights = [
            insight(date("2026-09-21 09:15", zone)), insight(date("2026-09-21 09:45", zone)), // Monday 9am
            insight(date("2026-09-27 23:30", zone)) // Sunday 11pm
        ]
        let map = ActivityHeatmap(buckets: buckets(insights, calendar: cal), firstWeekday: cal.firstWeekday)
        XCTAssertEqual(map.weekdays, [2, 3, 4, 5, 6, 7, 1])
        XCTAssertEqual(map.counts[0][9], 2)
        XCTAssertEqual(map.counts[6][23], 1)
        XCTAssertEqual(map.maximum, 2)
        XCTAssertEqual(map.counts.joined().reduce(0, +), 3)
    }

    func testTopAppsRankByWordsAndAcceptAGroupingHook() {
        let cal = calendar("UTC")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let insights = [
            insight(now, words: 100, app: "com.tinyspeck.slackmacgap"),
            insight(now, words: 40, app: "com.apple.mail"),
            insight(now, words: 30, app: "com.microsoft.Outlook"),
            insight(now, words: 5, app: nil)
        ]
        let byApp = InsightsSummary(buckets: buckets(insights, calendar: cal), recentSamples: [], now: now, calendar: cal)
        XCTAssertEqual(byApp.topApps.map(\.group), [.application(bundleID: "com.tinyspeck.slackmacgap"),
                                                    .application(bundleID: "com.apple.mail"),
                                                    .application(bundleID: "com.microsoft.Outlook"), .unknown])

        struct Categories: InsightsAppGrouping {
            func group(forBundleID bundleID: String) -> InsightsAppGroup {
                ["com.apple.mail", "com.microsoft.Outlook"].contains(bundleID) ? .category("Email") : .category("Chat")
            }
        }
        let byCategory = InsightsSummary(buckets: buckets(insights, calendar: cal), recentSamples: [], now: now,
                                         calendar: cal, appGrouping: Categories())
        XCTAssertEqual(byCategory.topApps.map(\.group), [.category("Chat"), .category("Email")])
        XCTAssertEqual(byCategory.topApps.map(\.words), [105, 70])
    }

    // MARK: - Corrections

    func testCorrectionCountsCoverVocabularyAndSelfCorrections() {
        let vocabulary = Vocabulary(rules: [VocabularyRule(find: "whisker flow", replaceWith: "WhiskerFlow")])
        let counts = AssistantTextProcessing.correctionCounts(
            "Send it to Tom, sorry, Sam. I love whisker flow and whisker flow loves me.",
            tone: .legacyStandard, vocabulary: vocabulary, recognizeCorrections: true
        )
        XCTAssertEqual(counts, TextCorrectionCounts(vocabularyReplacements: 2, selfCorrections: 1))
        XCTAssertEqual(AssistantTextProcessing.correctionCounts("whisker flow", tone: .literal, vocabulary: vocabulary,
                                                               recognizeCorrections: true), TextCorrectionCounts())
        XCTAssertEqual(SpokenSelfCorrection.resolveCounting("Plain sentence.").repairs, 0)
    }

    // MARK: - Store

    private func storeURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhiskerFlowInsights-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("insights.sqlite")
    }

    func testStoreAggregatesPersistAndHoldNoText() throws {
        let url = storeURL()
        let cal = calendar("UTC")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = InsightsStore(databaseURL: url, calendar: { cal }, now: { now })
        try store.load()
        try store.record(DictationInsight(date: now, words: 12, speakingSeconds: 6, appBundleID: "com.apple.Notes",
                                          engine: "parakeetTDTv3", vocabularyReplacements: 1, selfCorrections: 2))
        try store.record(DictationInsight(date: now, words: 8, speakingSeconds: 4, appBundleID: "com.apple.Notes",
                                          engine: "parakeetTDTv3"))

        let reloaded = InsightsStore(databaseURL: url, calendar: { cal }, now: { now })
        try reloaded.load()
        XCTAssertEqual(reloaded.buckets.count, 1)
        XCTAssertEqual(reloaded.buckets.first?.dictations, 2)
        XCTAssertEqual(reloaded.buckets.first?.words, 20)
        XCTAssertEqual(reloaded.recentSamples.count, 2)
        let summary = reloaded.summary()
        XCTAssertEqual(summary.correctionsApplied, 3)
        XCTAssertEqual(summary.currentStreak, 1)

        let bytes = try Data(contentsOf: url) + ((try? Data(contentsOf: URL(fileURLWithPath: url.path + "-wal"))) ?? Data())
        XCTAssertNil(bytes.range(of: Data("secret words".utf8)))
    }

    func testRecentSamplesAreCappedAt100() throws {
        let store = InsightsStore(databaseURL: storeURL(), calendar: { self.calendar("UTC") })
        try store.load()
        for index in 0..<130 {
            try store.record(DictationInsight(date: Date(), words: index, speakingSeconds: 1, appBundleID: nil, engine: "x"))
        }
        XCTAssertEqual(store.recentSamples.count, 100)
        XCTAssertEqual(store.recentSamples.first?.words, 30)
        let reloaded = InsightsStore(databaseURL: store.databaseURL)
        try reloaded.load()
        XCTAssertEqual(reloaded.recentSamples.map(\.words), Array(30..<130))
    }

    func testBackfillRunsOnceFromHistory() throws {
        let url = storeURL()
        let cal = calendar("UTC")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = [
            TranscriptRecord(text: "one two three", audioFilePath: "", createdAt: now, status: .transcribed,
                             durationSeconds: 3, engine: "parakeetTDTv3"),
            TranscriptRecord(text: "four five", audioFilePath: "", createdAt: now.addingTimeInterval(-86_400),
                             status: .transcribed, durationSeconds: 2, engine: "appleSpeech"),
            TranscriptRecord(text: "failed words", audioFilePath: "", createdAt: now, status: .failed(errorMessage: "x"))
        ]
        let store = InsightsStore(databaseURL: url, calendar: { cal }, now: { now })
        try store.load()
        XCTAssertTrue(try store.backfillIfNeeded(from: history))
        XCTAssertFalse(try store.backfillIfNeeded(from: history))
        var summary = store.summary()
        XCTAssertEqual(summary.lifetimeWords, 5)
        XCTAssertEqual(summary.lifetimeDictations, 2)
        XCTAssertEqual(summary.currentStreak, 2)
        XCTAssertEqual(summary.topApps.map(\.group), [.unknown])

        let relaunched = InsightsStore(databaseURL: url, calendar: { cal }, now: { now })
        try relaunched.load()
        XCTAssertFalse(try relaunched.backfillIfNeeded(from: history), "the flag must persist across launches")
        summary = relaunched.summary()
        XCTAssertEqual(summary.lifetimeWords, 5)
    }

    func testResetClearsInsightsWithoutRefillingFromHistory() throws {
        let url = storeURL()
        let store = InsightsStore(databaseURL: url)
        try store.load()
        try store.record(DictationInsight(date: Date(), words: 3, speakingSeconds: 2, appBundleID: nil, engine: "x"))
        try store.reset()
        XCTAssertTrue(store.summary().isEmpty)
        let history = [TranscriptRecord(text: "kept in history", audioFilePath: "", status: .transcribed)]
        XCTAssertFalse(try store.backfillIfNeeded(from: history))

        let reloaded = InsightsStore(databaseURL: url)
        try reloaded.load()
        XCTAssertTrue(reloaded.summary().isEmpty)
    }

    func testInsightsSurviveHistoryExpiry() throws {
        let now = Date()
        let root = storeURL().deletingLastPathComponent()
        let history = TranscriptStore(fileURL: root.appendingPathComponent("transcripts.json"), now: { now },
                                      retention: .forever, removeAudioFile: { _ in })
        let insights = InsightsStore(databaseURL: root.appendingPathComponent("insights.sqlite"))
        try insights.load()
        let record = TranscriptRecord(text: "gone soon", audioFilePath: "", createdAt: now.addingTimeInterval(-3 * 86_400),
                                      status: .transcribed, durationSeconds: 2)
        try history.add(record)
        try insights.backfillIfNeeded(from: history.records)
        try history.applyRetention(.twentyFourHours)
        XCTAssertTrue(history.records.isEmpty)
        XCTAssertEqual(insights.summary().lifetimeWords, 2)
    }
}
