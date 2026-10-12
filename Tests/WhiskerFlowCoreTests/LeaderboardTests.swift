import XCTest
@testable import WhiskerFlowCore

final class LeaderboardTests: XCTestCase {
    private let oct1 = LocalDay(year: 2026, month: 10, day: 1)
    private let oct2 = LocalDay(year: 2026, month: 10, day: 2)

    private func bucket(_ day: LocalDay, hour: Int = 9, app: String = "com.apple.Notes", words: Int, dictations: Int = 1,
                        seconds: Double) -> InsightsBucket {
        InsightsBucket(key: .init(day: day, hour: hour, appBundleID: app, engine: "parakeetTDTv3"),
                       dictations: dictations, words: words, speakingSeconds: seconds)
    }

    func testDaysSumEveryBucketOfADayAndAddMeetings() {
        var meetings = MeetingTally()
        meetings.record(day: oct2, durationSeconds: 1_800)
        meetings.record(day: oct2, durationSeconds: 600)
        let days = LeaderboardReport.days(buckets: [
            bucket(oct1, words: 100, seconds: 40),
            bucket(oct2, hour: 9, words: 200, dictations: 3, seconds: 60),
            bucket(oct2, hour: 14, app: "com.tinyspeck.slackmacgap", words: 100, dictations: 2, seconds: 30),
        ], meetings: meetings)
        XCTAssertEqual(days.map(\.day), [oct1, oct2])
        let second = days[1]
        XCTAssertEqual(second.words, 300)
        XCTAssertEqual(second.dictations, 5)
        XCTAssertEqual(second.speakingSeconds, 90)
        XCTAssertEqual(second.meetings, 2)
        XCTAssertEqual(second.meetingSeconds, 2_400)
        // 300 words at the standard 40 wpm typing speed is 450 s; spoken in 90 s.
        XCTAssertEqual(second.timeSavedSeconds, 360)
    }

    /// Everyone is measured against the same typing speed, so nobody climbs
    /// the board by setting a slow one.
    func testTimeSavedUsesTheStandardTypingSpeedAndNeverGoesNegative() {
        let slow = LeaderboardReport.days(buckets: [bucket(oct1, words: 10, seconds: 60)], meetings: MeetingTally())
        XCTAssertEqual(slow.first?.timeSavedSeconds, 0)
    }

    func testMeetingOnlyDaysAreIncludedAndShortRecordingsAreNotMeetings() {
        var meetings = MeetingTally()
        meetings.record(day: oct1, durationSeconds: 45)
        XCTAssertTrue(meetings.days.isEmpty, "under a minute is an accidental recording")
        meetings.record(day: oct1, durationSeconds: 3_600)
        let days = LeaderboardReport.days(buckets: [], meetings: meetings)
        XCTAssertEqual(days, [LeaderboardDay(day: oct1, words: 0, dictations: 0, speakingSeconds: 0, timeSavedSeconds: 0,
                                             meetings: 1, meetingSeconds: 3_600)])
    }

    func testValuesAreClampedToWhatAtlasAccepts() {
        let days = LeaderboardReport.days(buckets: [bucket(oct1, words: 900_000, dictations: 90_000, seconds: 200_000)],
                                          meetings: MeetingTally())
        XCTAssertEqual(days.first?.words, 200_000)
        XCTAssertEqual(days.first?.dictations, 20_000)
        XCTAssertEqual(days.first?.speakingSeconds, 86_400)
    }

    func testFirstReportSendsHistoryThenOnlyRecentDays() {
        let all = (0..<10).map { LeaderboardDay(day: oct2.adding(days: -$0), words: 1, dictations: 1, speakingSeconds: 1,
                                                timeSavedSeconds: 0, meetings: 0, meetingSeconds: 0) }.reversed()
        XCTAssertEqual(LeaderboardReport.daysToSend(Array(all), reportedThrough: nil, today: oct2).count, 10)
        // Yesterday is re-sent: a dictation just before midnight lands after the last report.
        XCTAssertEqual(LeaderboardReport.daysToSend(Array(all), reportedThrough: oct2, today: oct2).map(\.day), [oct1, oct2])
        XCTAssertTrue(LeaderboardReport.daysToSend(Array(all), reportedThrough: nil, today: oct1).allSatisfy { $0.day <= oct1 },
                      "never a day after today")
    }

    func testDaysBeforeAtlasAcceptsThemAreDropped() {
        let old = LeaderboardDay(day: LocalDay(year: 2023, month: 12, day: 31), words: 5, dictations: 1, speakingSeconds: 2,
                                 timeSavedSeconds: 0, meetings: 0, meetingSeconds: 0)
        XCTAssertTrue(LeaderboardReport.daysToSend([old], reportedThrough: nil, today: oct2).isEmpty)
    }

    func testReportPayloadHasExactlyTheContractKeys() {
        let day = LeaderboardDay(day: oct2, words: 3, dictations: 1, speakingSeconds: 2, timeSavedSeconds: 2,
                                 meetings: 0, meetingSeconds: 0)
        XCTAssertEqual(Set(day.payload.keys),
                       ["day", "words", "dictations", "speakingSeconds", "timeSavedSeconds", "meetings", "meetingSeconds"])
        XCTAssertEqual(day.payload["day"] as? String, "2026-10-02")
    }

    func testWindowsStartOnTheRightDay() {
        // 2 October 2026 is a Friday.
        XCTAssertEqual(LeaderboardWindow.week.since(today: oct2, firstWeekday: 2), LocalDay(year: 2026, month: 9, day: 28))
        XCTAssertEqual(LeaderboardWindow.month.since(today: oct2, firstWeekday: 2), oct1)
        XCTAssertNil(LeaderboardWindow.allTime.since(today: oct2, firstWeekday: 2))
    }

    private func entry(_ name: String, words: Int = 0, saved: Int = 0, streak: Int = 0, meetings: Int = 0,
                       you: Bool = false) -> LeaderboardEntry {
        LeaderboardEntry(employeeId: name, name: name, avatarUrl: nil, isYou: you, words: words, dictations: 0,
                         speakingSeconds: 0, timeSavedSeconds: saved, meetings: meetings, meetingSeconds: 0,
                         currentStreakDays: streak, longestStreakDays: streak, lastActiveDay: nil)
    }

    func testRankingSortsByTheChosenMetricAndSharesTies() {
        let entries = [entry("A", words: 10, streak: 5), entry("B", words: 30, streak: 1), entry("C", words: 10, streak: 9)]
        XCTAssertEqual(LeaderboardRanking.ranked(entries, by: .words).map { "\($0.rank)\($0.entry.name)" }, ["1B", "2A", "2C"])
        XCTAssertEqual(LeaderboardRanking.ranked(entries, by: .streak).map(\.entry.name), ["C", "A", "B"])
    }

    func testPeopleWithNothingInTheWindowAreLeftOffButYouStay() {
        let entries = [entry("A", words: 10), entry("B"), entry("Me", you: true)]
        XCTAssertEqual(LeaderboardRanking.ranked(entries, by: .words).map(\.entry.name), ["A", "Me"])
    }

    func testDecodesTheAtlasResponse() throws {
        let json = """
        {"generatedAt": 1759400000000, "entries": [{"employeeId": "k1", "name": "Ada", "isYou": true, "words": 12,
        "dictations": 2, "speakingSeconds": 5, "timeSavedSeconds": 13, "meetings": 1, "meetingSeconds": 60,
        "currentStreakDays": 3, "longestStreakDays": 4, "lastActiveDay": null}]}
        """
        let board = try JSONDecoder().decode(LeaderboardBoard.self, from: Data(json.utf8))
        XCTAssertEqual(board.entries.first?.name, "Ada")
        XCTAssertNil(board.entries.first?.avatarUrl)
        XCTAssertEqual(board.entries.first?.currentStreakDays, 3)
    }
}
