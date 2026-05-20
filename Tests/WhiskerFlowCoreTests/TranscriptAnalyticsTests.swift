import XCTest
@testable import WhiskerFlowCore

final class TranscriptAnalyticsTests: XCTestCase {
    func testWordCountsRespectAllTimeWeekAndMonthWindows() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let records = [
            TranscriptRecord(
                text: "one two three",
                audioFilePath: "/tmp/today.m4a",
                createdAt: now,
                status: .transcribed
            ),
            TranscriptRecord(
                text: "four five",
                audioFilePath: "/tmp/week.m4a",
                createdAt: now.addingTimeInterval(-6 * 24 * 60 * 60),
                status: .transcribed
            ),
            TranscriptRecord(
                text: "six seven eight nine",
                audioFilePath: "/tmp/month.m4a",
                createdAt: now.addingTimeInterval(-20 * 24 * 60 * 60),
                status: .transcribed
            ),
            TranscriptRecord(
                text: "ignored failure words",
                audioFilePath: "/tmp/failed.m4a",
                createdAt: now,
                status: .failed(errorMessage: "Nope")
            )
        ]

        let analytics = TranscriptAnalytics(records: records, now: now)

        XCTAssertEqual(analytics.allTime.wordCount, 9)
        XCTAssertEqual(analytics.thisWeek.wordCount, 5)
        XCTAssertEqual(analytics.lastMonth.wordCount, 9)
    }

    func testTypingTimeUsesAverageTypingSpeed() {
        let stats = TranscriptStats(wordCount: 200)

        XCTAssertEqual(stats.estimatedTypingMinutes(wordsPerMinute: 40), 5)
    }
}
