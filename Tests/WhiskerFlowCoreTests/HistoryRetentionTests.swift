import XCTest
@testable import WhiskerFlowCore

final class HistoryRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func record(ageDays: Double, status: TranscriptStatus = .transcribed, audio: String = "") -> TranscriptRecord {
        TranscriptRecord(text: status == .transcribed ? "words" : "", audioFilePath: audio,
                         createdAt: now.addingTimeInterval(-ageDays * day), status: status)
    }

    func testDefaultIsNinetyDays() {
        XCTAssertEqual(HistoryRetention.defaultValue, .ninetyDays)
        XCTAssertEqual(TranscriptStore(fileURL: URL(fileURLWithPath: "/tmp/unused.json")).retention, .ninetyDays)
    }

    func testEveryOptionHasItsMaximumAge() {
        let expected: [HistoryRetention: TimeInterval?] = [
            .forever: nil, .oneYear: 365 * day, .ninetyDays: 90 * day, .thirtyDays: 30 * day,
            .sevenDays: 7 * day, .twentyFourHours: day, .off: 0
        ]
        XCTAssertEqual(HistoryRetention.allCases.count, expected.count)
        for option in HistoryRetention.allCases {
            XCTAssertEqual(option.maximumAge, expected[option]!, "\(option)")
            XCTAssertFalse(option.displayName.isEmpty)
        }
        XCTAssertEqual(HistoryRetention.off.displayName, "Don't save history")
        XCTAssertEqual(HistoryRetention.forever.displayName, "Keep forever")
    }

    func testEveryOptionRemovesExactlyTheRecordsOlderThanItsWindow() {
        let ages: [Double] = [0.01, 0.9, 1.1, 6.9, 7.1, 29.9, 30.1, 89.9, 90.1, 364, 366, 2_000]
        let records = ages.map { record(ageDays: $0) }
        let kept: [HistoryRetention: Int] = [
            .forever: 12, .oneYear: 10, .ninetyDays: 8, .thirtyDays: 6, .sevenDays: 4, .twentyFourHours: 2, .off: 0
        ]
        for option in HistoryRetention.allCases {
            let plan = HistoryRetentionPlan(records: records, retention: option, now: now)
            XCTAssertEqual(records.count - plan.expiredIDs.count, kept[option], "\(option)")
            let expiredAges = records.filter { plan.expiredIDs.contains($0.id) }.map { now.timeIntervalSince($0.createdAt) / day }
            if let maximum = option.maximumAge, option != .off {
                XCTAssertTrue(expiredAges.allSatisfy { $0 * day > maximum }, "\(option) removed a record inside its window")
            }
        }
    }

    func testDontSaveHistoryKeepsFailedRecordingsForRetryUntilTheGraceEnds() {
        let failedRecent = record(ageDays: 0.5, status: .failed(errorMessage: "timed out"), audio: "/tmp/a.wav")
        let failedOld = record(ageDays: 1.5, status: .failed(errorMessage: "timed out"), audio: "/tmp/b.wav")
        let transcribing = record(ageDays: 0, status: .transcribing, audio: "/tmp/c.wav")
        let transcribed = record(ageDays: 0, audio: "/tmp/d.wav")
        let plan = HistoryRetentionPlan(records: [failedRecent, failedOld, transcribing, transcribed], retention: .off, now: now)
        XCTAssertEqual(plan.expiredIDs, [failedOld.id, transcribed.id])
    }

    func testShorterComparisonOrdersEveryOption() {
        let ordered: [HistoryRetention] = [.forever, .oneYear, .ninetyDays, .thirtyDays, .sevenDays, .twentyFourHours, .off]
        for (index, option) in ordered.enumerated() {
            for (otherIndex, other) in ordered.enumerated() {
                XCTAssertEqual(option.isLonger(than: other), index < otherIndex, "\(option) vs \(other)")
            }
        }
    }

    func testStandardAudioBoundKeepsOnlyNewest25SuccessfulRecordingsWithin30Days() {
        var records = (0..<30).map { record(ageDays: Double($0) * 0.1, audio: "/tmp/\($0).wav") }
        records.append(record(ageDays: 31, audio: "/tmp/old.wav"))
        let failed = record(ageDays: 40, status: .failed(errorMessage: "x"), audio: "/tmp/failed.wav")
        records.append(failed)
        let plan = HistoryRetentionPlan(records: records, retention: .forever, now: now)
        XCTAssertTrue(plan.expiredIDs.isEmpty)
        XCTAssertEqual(plan.releasedAudioIDs.count, 6)
        XCTAssertFalse(plan.releasedAudioIDs.contains(failed.id), "retry needs a failed recording's audio")
        XCTAssertFalse(plan.releasedAudioIDs.contains(records[0].id))
    }

    func testFourteenDayAudioKeepsEveryRecentRecording() {
        let records = (0..<40).map { record(ageDays: Double($0) * 0.5, audio: "/tmp/\($0).wav") }
        let plan = HistoryRetentionPlan(records: records, retention: .forever, audio: .fourteenDays, now: now)
        XCTAssertEqual(plan.releasedAudioIDs.count, records.filter { now.timeIntervalSince($0.createdAt) > 14 * day }.count)
    }

    // MARK: - Store

    private func storeURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhiskerFlowRetention-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("transcripts.json")
    }

    func testStoreHasNoRecordCap() throws {
        let store = TranscriptStore(fileURL: storeURL(), now: { self.now }, retention: .forever, removeAudioFile: { _ in })
        try store.replaceAll((0..<300).map { record(ageDays: Double($0)) })
        try store.pruneExpired()
        XCTAssertEqual(store.records.count, 300)
    }

    func testRemovalCountMatchesWhatApplyingDeletes() throws {
        var removed: [String] = []
        let url = storeURL()
        let store = TranscriptStore(fileURL: url, now: { self.now }, retention: .forever, removeAudioFile: { removed.append($0) })
        try store.replaceAll([record(ageDays: 1), record(ageDays: 10, audio: "/tmp/10.wav"), record(ageDays: 100)])

        XCTAssertEqual(store.removalCount(for: .forever), 0)
        XCTAssertEqual(store.removalCount(for: .thirtyDays), 1)
        XCTAssertEqual(store.removalCount(for: .sevenDays), 2)
        XCTAssertEqual(store.removalCount(for: .off), 3)

        try store.applyRetention(.sevenDays)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(removed, ["/tmp/10.wav", ""])

        let reloaded = TranscriptStore(fileURL: url, now: { self.now }, retention: .forever)
        try reloaded.load()
        XCTAssertEqual(reloaded.records.map(\.id), store.records.map(\.id), "the deletion must reach disk")
    }

    func testDontSaveHistoryNeverPersistsATranscript() throws {
        let url = storeURL()
        let store = TranscriptStore(fileURL: url, now: { self.now }, retention: .off, removeAudioFile: { _ in })
        let pending = TranscriptRecord(text: "", audioFilePath: "/tmp/p.wav", createdAt: now, status: .transcribing)
        try store.add(pending)
        XCTAssertEqual(store.records.map(\.id), [pending.id], "in-progress audio stays recoverable")

        try store.markTranscribed(id: pending.id, text: "private words")
        XCTAssertTrue(store.records.isEmpty)
        try store.add(TranscriptRecord(text: "streamed words", audioFilePath: "", createdAt: now, status: .transcribed))
        XCTAssertTrue(store.records.isEmpty)

        let reloaded = TranscriptStore(fileURL: url, retention: .forever)
        try reloaded.load()
        XCTAssertTrue(reloaded.records.isEmpty)
    }

    func testRecordsStayNewestFirstWhenAddedOutOfOrder() throws {
        let store = TranscriptStore(fileURL: storeURL(), now: { self.now }, retention: .forever)
        let older = record(ageDays: 3)
        let newest = record(ageDays: 1)
        let middle = record(ageDays: 2)
        for item in [older, newest, middle] { try store.add(item) }
        XCTAssertEqual(store.records.map(\.id), [newest.id, middle.id, older.id])
    }
}
