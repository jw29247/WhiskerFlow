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

    func testJSONSkipsFailedAndInProgressRecordsLikeTheOtherFormats() throws {
        let records = [
            record("done", secondsAgo: 30),
            record("boom", secondsAgo: 20, status: .failed(errorMessage: "boom")),
            record("", secondsAgo: 10, status: .recording),
            record("newest", secondsAgo: 0)
        ]

        let data = try TranscriptExporter.json(records)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]

        XCTAssertEqual(decoded?.count, 2)
        XCTAssertEqual(decoded?.compactMap { $0["text"] as? String }, ["newest", "done"])
        XCTAssertEqual(decoded?.compactMap { $0["wordCount"] as? Int }, [1, 1])
    }

    func testJSONOmitsLocalAudioPaths() throws {
        let data = try TranscriptExporter.json([record("done", secondsAgo: 0)])
        let text = String(decoding: data, as: UTF8.self)

        // An absolute path under the user's home has no business in a file the user
        // shares — the same detail the diagnostics sanitizer strips elsewhere.
        XCTAssertFalse(text.contains("audioFilePath"), text)
        XCTAssertFalse(text.contains(".m4a"), text)
        XCTAssertFalse(text.contains("errorMessage"), text)
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
