import XCTest
@testable import WhiskerFlowCore

final class TranscriptQueryTests: XCTestCase {
    private func record(_ text: String, daysAgo: Int, from now: Date, status: TranscriptStatus = .transcribed) -> TranscriptRecord {
        TranscriptRecord(
            text: text,
            audioFilePath: "/tmp/\(UUID().uuidString).m4a",
            createdAt: now.addingTimeInterval(Double(-daysAgo) * 24 * 60 * 60),
            status: status
        )
    }

    func testMatchingIsCaseInsensitiveSubstring() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let records = [
            record("Hello World", daysAgo: 0, from: now),
            record("totally unrelated", daysAgo: 0, from: now)
        ]
        XCTAssertEqual(records.matching("hello").count, 1)
        XCTAssertEqual(records.matching("  ").count, 2, "blank query returns everything")
    }

    func testDailyWordCountsZeroFillAndScope() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_000_000)).addingTimeInterval(12 * 60 * 60)

        let records = [
            record("one two three", daysAgo: 0, from: now),
            record("four five", daysAgo: 2, from: now),
            record("ignored failure", daysAgo: 0, from: now, status: .failed(errorMessage: "x"))
        ]

        let series = records.dailyWordCounts(days: 3, now: now, calendar: calendar)
        XCTAssertEqual(series.count, 3)
        // [2 days ago = "four five", yesterday = none, today = "one two three"]
        XCTAssertEqual(series.map(\.words), [2, 0, 3], "oldest first; failed records excluded")
    }
}
