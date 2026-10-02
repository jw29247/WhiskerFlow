import XCTest
@testable import WhiskerFlowCore

final class TranscriptStoreMigrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhiskerFlowMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var jsonURL: URL { directory.appendingPathComponent("transcripts.json") }

    private func backups(_ prefix: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    func testLegacyJSONHistoryIsImportedAndKeptAsABackup() throws {
        let now = Date()
        let records = [
            TranscriptRecord(text: "First words", audioFilePath: "", createdAt: now.addingTimeInterval(-60),
                             status: .transcribed, durationSeconds: 4, model: "tiny", engine: "parakeetTDTv3",
                             language: "en", updatedAt: now, rawRecognition: "first words"),
            TranscriptRecord(text: "", audioFilePath: directory.appendingPathComponent("f.wav").path,
                             createdAt: now.addingTimeInterval(-120), status: .failed(errorMessage: "Timed out"))
        ]
        let original = try JSONEncoder.whiskerFlow.encode(records)
        try original.write(to: jsonURL)

        let store = TranscriptStore(fileURL: jsonURL)
        try store.load()

        XCTAssertEqual(store.records.map(\.id), records.map(\.id))
        XCTAssertEqual(store.records[0].rawRecognition, "first words")
        XCTAssertEqual(store.records[0].engine, "parakeetTDTv3")
        XCTAssertEqual(store.records[1].status, .failed(errorMessage: "Timed out"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: jsonURL.path))
        let backup = try XCTUnwrap(try backups("transcripts.migrated-").first)
        XCTAssertEqual(try Data(contentsOf: backup), original, "the old file must survive byte for byte")

        let reloaded = TranscriptStore(fileURL: jsonURL)
        try reloaded.load()
        XCTAssertEqual(reloaded.records, store.records)
    }

    func testExistingUsersKeepEveryRecordAfterMovingToNinetyDays() throws {
        // The old build kept at most 25 records, none older than 30 days.
        let now = Date()
        let records = (0..<25).map {
            TranscriptRecord(text: "record \($0)", audioFilePath: "", createdAt: now.addingTimeInterval(-Double($0) * 29 * 3600),
                             status: .transcribed)
        }
        try JSONEncoder.whiskerFlow.encode(records).write(to: jsonURL)
        let store = TranscriptStore(fileURL: jsonURL, retention: .defaultValue)
        try store.load()
        XCTAssertEqual(store.records.count, 25)
    }

    func testReimportingALegacyFileDoesNotDuplicateRecords() throws {
        let record = TranscriptRecord(text: "once", audioFilePath: "", status: .transcribed)
        try JSONEncoder.whiskerFlow.encode([record]).write(to: jsonURL)
        try TranscriptStore(fileURL: jsonURL).load()

        // A downgraded build writes transcripts.json again, including the old record.
        let later = TranscriptRecord(text: "from the old build", audioFilePath: "", status: .transcribed)
        try JSONEncoder.whiskerFlow.encode([later, record]).write(to: jsonURL)
        let store = TranscriptStore(fileURL: jsonURL)
        try store.load()
        XCTAssertEqual(Set(store.records.map(\.id)), [record.id, later.id])
    }

    func testDamagedDatabaseIsMovedAsideAndHistoryStartsFresh() throws {
        let store = TranscriptStore(fileURL: jsonURL, now: { Date(timeIntervalSince1970: 42) })
        let garbage = Data(repeating: 0x5A, count: 4096)
        try garbage.write(to: store.databaseURL)

        try store.load()
        XCTAssertTrue(store.records.isEmpty)
        let backup = directory.appendingPathComponent("transcripts.corrupt-42.sqlite")
        XCTAssertEqual(try Data(contentsOf: backup), garbage)
        try store.add(TranscriptRecord(text: "fresh", audioFilePath: "", status: .transcribed))
        XCTAssertEqual(store.records.count, 1)
    }

    func testUnbackedUpDamagedDatabaseBlocksWrites() throws {
        let store = TranscriptStore(fileURL: jsonURL, now: { Date(timeIntervalSince1970: 42) },
                                    moveItem: { _, _ in throw CocoaError(.fileWriteNoPermission) },
                                    copyItem: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        let garbage = Data(repeating: 0x5A, count: 4096)
        try garbage.write(to: store.databaseURL)

        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.add(TranscriptRecord(text: "new", audioFilePath: "", status: .transcribed)))
        XCTAssertEqual(try Data(contentsOf: store.databaseURL), garbage)
    }

    func testEditsAndStatusChangesPersistRowByRow() throws {
        let store = TranscriptStore(fileURL: jsonURL)
        try store.load()
        let record = TranscriptRecord(text: "", audioFilePath: "", status: .transcribing)
        try store.add(record)
        try store.markTranscribed(id: record.id, text: "hello", durationSeconds: 2, engine: "appleSpeech")
        try store.setText(id: record.id, text: "hello there")
        let failed = TranscriptRecord(text: "", audioFilePath: "", status: .transcribing)
        try store.add(failed)
        try store.markFailed(id: failed.id, message: "boom")

        let reloaded = TranscriptStore(fileURL: jsonURL)
        try reloaded.load()
        XCTAssertEqual(reloaded.records.first { $0.id == record.id }?.text, "hello there")
        XCTAssertEqual(reloaded.records.first { $0.id == record.id }?.durationSeconds, 2)
        XCTAssertEqual(reloaded.records.first { $0.id == failed.id }?.status, .failed(errorMessage: "boom"))
        try reloaded.delete(id: record.id)
        let again = TranscriptStore(fileURL: jsonURL)
        try again.load()
        XCTAssertEqual(again.records.map(\.id), [failed.id])
    }

    func testAppCategoryRoundTripsThroughTheDatabaseAndLegacyImport() throws {
        let legacy = TranscriptRecord(text: "old", audioFilePath: "", createdAt: Date().addingTimeInterval(-60),
                                      status: .transcribed, appCategory: .email)
        try JSONEncoder.whiskerFlow.encode([legacy]).write(to: jsonURL)
        let store = TranscriptStore(fileURL: jsonURL)
        try store.load()
        let pending = TranscriptRecord(text: "", audioFilePath: "", status: .transcribing, appCategory: .code)
        try store.add(pending)
        try store.markTranscribed(id: pending.id, text: "new", appCategory: .aiPrompts)
        try store.add(TranscriptRecord(text: "none", audioFilePath: "", status: .transcribed))

        let reloaded = TranscriptStore(fileURL: jsonURL)
        try reloaded.load()
        XCTAssertEqual(reloaded.records.first { $0.id == legacy.id }?.appCategory, .email)
        XCTAssertEqual(reloaded.records.first { $0.id == pending.id }?.appCategory, .aiPrompts)
        XCTAssertNil(reloaded.records.first { $0.text == "none" }?.appCategory)
    }

    func testCaptureIntentIsKeptAndAVersion1DatabaseIsUpgraded() throws {
        // A history written by the first SQLite builds, before capture intents.
        let existing = UUID()
        let v1 = try SQLiteDatabase(url: directory.appendingPathComponent("transcripts.sqlite"))
        try v1.execute("""
            CREATE TABLE transcripts (
                id TEXT PRIMARY KEY NOT NULL, created_at REAL NOT NULL, updated_at REAL, status TEXT NOT NULL,
                error_message TEXT, text TEXT NOT NULL, raw_recognition TEXT, audio_path TEXT NOT NULL, duration REAL,
                model TEXT, engine TEXT, language TEXT, app_category TEXT
            )
            """)
        try v1.execute("""
            INSERT INTO transcripts (id, created_at, status, text, audio_path)
            VALUES ('\(existing.uuidString)', \(Date().timeIntervalSince1970 - 60), 'transcribed', 'kept', '')
            """)
        try v1.execute("PRAGMA user_version = 1")
        v1.close()

        let store = TranscriptStore(fileURL: jsonURL)
        try store.load()
        XCTAssertEqual(store.records.map(\.id), [existing])
        XCTAssertNil(store.records.first?.captureIntent, "Records from before intents are dictation")
        let intent = TranscriptCaptureIntent(purpose: .quickCapture, quickKind: .taskDraft, clientReference: "client-7")
        let capture = TranscriptRecord(text: "", audioFilePath: "", status: .failed(errorMessage: "Timed out"), captureIntent: intent)
        try store.add(capture)

        let reloaded = TranscriptStore(fileURL: jsonURL)
        try reloaded.load()
        XCTAssertEqual(reloaded.records.first { $0.id == capture.id }?.captureIntent, intent)
        XCTAssertEqual(reloaded.records.first { $0.id == existing.id }?.text, "kept")
    }

    // MARK: - Scale

    private func largeHistory(count: Int, now: Date) -> [TranscriptRecord] {
        let sentence = "We should move the quarterly planning review to Thursday and invite the design team too."
        return (0..<count).map { index in
            TranscriptRecord(text: "\(sentence) Item \(index).", audioFilePath: "", createdAt: now.addingTimeInterval(-Double(index) * 600),
                             status: .transcribed, durationSeconds: 6, engine: "parakeetTDTv3", rawRecognition: sentence)
        }
    }

    /// A 10,000-record history must stay responsive: launch load, the per-dictation
    /// write on the release-to-paste path, and a search keystroke. Bounds are
    /// generous for debug builds on CI; typical numbers are an order lower.
    func testTenThousandRecordsStayResponsive() throws {
        let now = Date()
        let store = TranscriptStore(fileURL: jsonURL, now: { now }, retention: .forever)
        try store.replaceAll(largeHistory(count: 10_000, now: now))

        let reloaded = TranscriptStore(fileURL: jsonURL, now: { now }, retention: .forever)
        var started = CFAbsoluteTimeGetCurrent()
        try reloaded.load()
        let loadSeconds = CFAbsoluteTimeGetCurrent() - started
        XCTAssertEqual(reloaded.records.count, 10_000)
        XCTAssertLessThan(loadSeconds, 2.0)

        started = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 {
            let pending = TranscriptRecord(text: "", audioFilePath: "", createdAt: now, status: .transcribing)
            try reloaded.add(pending)
            try reloaded.markTranscribed(id: pending.id, text: "fresh words", durationSeconds: 1)
        }
        let perDictation = (CFAbsoluteTimeGetCurrent() - started) / 20
        XCTAssertLessThan(perDictation, 0.1, "each dictation must not rewrite the whole history")

        started = CFAbsoluteTimeGetCurrent()
        let matches = reloaded.records.matching("item 9999")
        let searchSeconds = CFAbsoluteTimeGetCurrent() - started
        XCTAssertEqual(matches.count, 1)
        XCTAssertLessThan(searchSeconds, 0.5)
    }
}
