import XCTest
@testable import WhiskerFlowCore

final class TranscriptExportTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func record(
        _ text: String,
        secondsAgo: Int = 0,
        status: TranscriptStatus = .transcribed
    ) -> TranscriptRecord {
        TranscriptRecord(
            text: text,
            audioFilePath: "/tmp/\(UUID().uuidString).m4a",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(secondsAgo)),
            status: status
        )
    }

    func testMarkdownIsNewestFirstWithDateHeadings() {
        let records = [
            record("older", secondsAgo: 3600),
            record("newest", secondsAgo: 0)
        ]

        let markdown = TranscriptExporter.markdown(records, timeZone: utc)

        XCTAssertEqual(
            markdown,
            """
            # WhiskerFlow Transcripts

            ## 2023-11-14 22:13

            newest

            ## 2023-11-14 21:13

            older

            """
        )
    }

    func testMarkdownAndCSVSkipFailedAndInProgressRecords() {
        let records = [
            record("kept", secondsAgo: 0),
            record("boom", secondsAgo: 10, status: .failed(errorMessage: "boom")),
            record("", secondsAgo: 20, status: .recording),
            record("half", secondsAgo: 30, status: .transcribing)
        ]

        let markdown = TranscriptExporter.markdown(records, timeZone: utc)
        XCTAssertTrue(markdown.contains("kept"))
        XCTAssertFalse(markdown.contains("boom"))
        XCTAssertFalse(markdown.contains("half"))

        let csv = TranscriptExporter.csv(records)
        XCTAssertEqual(csv.split(separator: "\n").count, 2, "header plus the single completed record")
        XCTAssertTrue(csv.contains("kept"))
        XCTAssertFalse(csv.contains("half"))
    }

    func testCSVQuotesCommasQuotesAndNewlines() {
        let records = [
            record("plain text", secondsAgo: 0),
            record("one, two", secondsAgo: 10),
            record("she said \"hi\"", secondsAgo: 20),
            record("first line\nsecond line", secondsAgo: 30)
        ]

        let lines = TranscriptExporter.csv(records).components(separatedBy: "\n")

        XCTAssertEqual(lines[0], "Created,Words,Duration Seconds,Model,Engine,Language,Text")
        XCTAssertTrue(lines[1].hasSuffix(",plain text"), "unremarkable fields stay unquoted")
        XCTAssertTrue(lines[2].hasSuffix(",\"one, two\""))
        XCTAssertTrue(lines[3].hasSuffix(",\"she said \"\"hi\"\"\""))
        XCTAssertTrue(lines[4].hasSuffix(",\"first line"), "the embedded break splits the physical line")
        XCTAssertEqual(lines[5], "second line\"")
    }

    func testJSONIncludesEveryStatusAndRoundTrips() throws {
        let records = [
            record("done", secondsAgo: 30),
            record("boom", secondsAgo: 20, status: .failed(errorMessage: "boom")),
            record("", secondsAgo: 10, status: .recording),
            record("half", secondsAgo: 0, status: .transcribing)
        ]

        let data = try TranscriptExporter.json(records)
        let decoded = try JSONDecoder.whiskerFlow.decode([TranscriptRecord].self, from: data)

        XCTAssertEqual(decoded.count, 4)
        XCTAssertEqual(decoded, records.sorted { $0.createdAt > $1.createdAt })
        XCTAssertEqual(decoded.map(\.text), ["half", "", "boom", "done"])
    }

    func testExportRoutesFormatsAndNamesFiles() throws {
        let records = [record("hello", secondsAgo: 0)]

        let markdown = try TranscriptExporter.export(records, as: .markdown, timeZone: utc)
        let csv = try TranscriptExporter.export(records, as: .csv)
        let json = try TranscriptExporter.export(records, as: .json)

        XCTAssertEqual(String(decoding: markdown, as: UTF8.self), TranscriptExporter.markdown(records, timeZone: utc))
        XCTAssertEqual(String(decoding: csv, as: UTF8.self), TranscriptExporter.csv(records))
        XCTAssertEqual(json, try TranscriptExporter.json(records))
        XCTAssertEqual(TranscriptExportFormat.allCases.map(\.fileExtension), ["md", "csv", "json"])
    }
}
