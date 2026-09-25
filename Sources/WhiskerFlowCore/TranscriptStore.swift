import Foundation

public enum TranscriptStatus: Codable, Equatable, Hashable, Sendable {
    case recording
    case transcribing
    case transcribed
    case failed(errorMessage: String)

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    public var isInProgress: Bool {
        switch self {
        case .recording, .transcribing: return true
        case .transcribed, .failed: return false
        }
    }
}

public struct TranscriptRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var text: String
    public var rawRecognition: String?
    public var audioFilePath: String
    public var createdAt: Date
    public var status: TranscriptStatus

    // Optional metadata (added later — decode as nil for older records).
    public var durationSeconds: Double?
    public var model: String?
    public var engine: String?
    public var language: String?
    public var updatedAt: Date?
    /// The app category the dictation was written for, for per-category insights.
    public var appCategory: AppCategory?

    public init(
        id: UUID = UUID(),
        text: String,
        audioFilePath: String,
        createdAt: Date = Date(),
        status: TranscriptStatus,
        durationSeconds: Double? = nil,
        model: String? = nil,
        engine: String? = nil,
        language: String? = nil,
        updatedAt: Date? = nil,
        rawRecognition: String? = nil,
        appCategory: AppCategory? = nil
    ) {
        self.id = id
        self.text = text
        self.rawRecognition = rawRecognition
        self.audioFilePath = audioFilePath
        self.createdAt = createdAt
        self.status = status
        self.durationSeconds = durationSeconds
        self.model = model
        self.engine = engine
        self.language = language
        self.updatedAt = updatedAt
        self.appCategory = appCategory
    }

    public var wordCount: Int { text.transcriptWordCount }
}

public enum TranscriptStoreError: LocalizedError, Equatable {
    case corruptFileUnrecoverable(path: String)

    public var errorDescription: String? {
        switch self {
        case .corruptFileUnrecoverable(let path):
            return "Transcript history at \(path) could not be read and could not be backed up. "
                + "The file was left untouched; move it aside manually to start a new history."
        }
    }
}

/// Dictation history. Records live in memory, newest first, and are persisted
/// row by row to a SQLite database next to the legacy `transcripts.json`, so a
/// dictation's history write costs one row whatever the size of the history.
/// A legacy JSON history is imported on `load()` and kept as a backup.
public final class TranscriptStore {
    private let fileURL: URL
    public let databaseURL: URL
    private let now: () -> Date
    private let removeAudioFile: (String) -> Void
    private let recordingsDirectory: URL?
    private let fileManager: FileManager
    private let moveItem: (URL, URL) throws -> Void
    private let copyItem: (URL, URL) throws -> Void
    private var persistenceSuspended = false
    private var database: SQLiteDatabase?

    /// How long transcripts stay. Assigning does not prune; call
    /// `applyRetention(_:)` to act on a change immediately.
    public var retention: HistoryRetention
    public var audioRetention: TranscriptAudioRetention

    public private(set) var records: [TranscriptRecord] = []

    public init(
        fileURL: URL,
        databaseURL: URL? = nil,
        now: @escaping () -> Date = Date.init,
        retention: HistoryRetention = .defaultValue,
        audioRetention: TranscriptAudioRetention = .standard,
        recordingsDirectory: URL? = nil,
        fileManager: FileManager = .default,
        removeAudioFile: @escaping (String) -> Void = { path in
            guard !path.isEmpty else { return }
            try? FileManager.default.removeItem(atPath: path)
        },
        moveItem: @escaping (URL, URL) throws -> Void = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        },
        copyItem: @escaping (URL, URL) throws -> Void = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
    ) {
        self.fileURL = fileURL
        self.databaseURL = databaseURL ?? fileURL.deletingPathExtension().appendingPathExtension("sqlite")
        self.now = now
        self.retention = retention
        self.audioRetention = audioRetention
        self.recordingsDirectory = recordingsDirectory
        self.fileManager = fileManager
        self.removeAudioFile = removeAudioFile
        self.moveItem = moveItem
        self.copyItem = copyItem
    }

    public var retryQueue: [TranscriptRecord] {
        records.filter { $0.status.isFailed }
    }

    public func load() throws {
        persistenceSuspended = false
        database?.close()
        database = nil
        records = []
        let db = try openDatabase()
        try importLegacyHistory(into: db)
        records = try Self.fetchAll(from: db)
        try pruneExpired()
    }

    /// Runs on the release-to-paste path, so it skips the recordings-directory
    /// sweep: orphans only come from interrupted sessions, and `load()` sweeps them.
    public func add(_ record: TranscriptRecord) throws {
        insertInOrder(record)
        try write { try Self.upsert(record, into: $0) }
        try pruneExpired(sweepOrphans: false)
    }

    /// Persistence stays suspended if `load()` suspended it: an unreadable history
    /// that could not be backed up is the only copy of those bytes, and replacing
    /// the whole list is no more entitled to bury it than `add` is. Only a fresh
    /// `load()`, which re-reads the file, can clear the suspension.
    public func replaceAll(_ records: [TranscriptRecord]) throws {
        self.records = records.sortedNewestFirst()
        try write { db in
            try db.execute("DELETE FROM transcripts")
            for record in records { try Self.upsert(record, into: db) }
        }
    }

    public func update(_ record: TranscriptRecord) throws {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
        if records[index].createdAt != record.createdAt { records = records.sortedNewestFirst() }
        try write { try Self.upsert(record, into: $0) }
    }

    public func setText(id: UUID, text: String) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].text = text
        records[index].updatedAt = now()
        let record = records[index]
        try write { try Self.upsert(record, into: $0) }
    }

    public func markTranscribing(id: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == id }),
              records[index].status != .transcribing else { return }
        records[index].status = .transcribing
        let record = records[index]
        try write { try Self.upsert(record, into: $0) }
    }

    public func markTranscribed(
        id: UUID,
        text: String,
        durationSeconds: Double? = nil,
        model: String? = nil,
        engine: String? = nil,
        language: String? = nil,
        rawRecognition: String? = nil,
        appCategory: AppCategory? = nil
    ) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }

        records[index].text = text
        if let rawRecognition { records[index].rawRecognition = rawRecognition }
        records[index].status = .transcribed
        records[index].updatedAt = now()
        if let durationSeconds { records[index].durationSeconds = durationSeconds }
        if let model { records[index].model = model }
        if let engine { records[index].engine = engine }
        if let language { records[index].language = language }
        if let appCategory { records[index].appCategory = appCategory }
        let record = records[index]
        try write { try Self.upsert(record, into: $0) }
        // A transcript that just succeeded may push an older one's audio past the
        // bound, and "Don't save history" drops the transcript itself.
        try pruneExpired(sweepOrphans: false)
    }

    public func markFailed(id: UUID, message: String) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }

        records[index].status = .failed(errorMessage: message)
        records[index].updatedAt = now()
        let record = records[index]
        try write { try Self.upsert(record, into: $0) }
    }

    public func delete(id: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        removeAudioFile(records[index].audioFilePath)
        records.remove(at: index)
        try write { try Self.delete([id], from: $0) }
    }

    /// Records a switch to `retention` would delete, for the confirmation prompt.
    public func removalCount(for retention: HistoryRetention) -> Int {
        HistoryRetentionPlan(records: records, retention: retention, audio: audioRetention, now: now())
            .expiredIDs.count
    }

    public func applyRetention(_ retention: HistoryRetention, audio: TranscriptAudioRetention? = nil) throws {
        self.retention = retention
        if let audio { audioRetention = audio }
        try pruneExpired(sweepOrphans: false)
    }

    public func pruneExpired() throws {
        try pruneExpired(sweepOrphans: true)
    }

    private func pruneExpired(sweepOrphans: Bool) throws {
        let db = try connection()
        let ordered = records.sortedNewestFirst()
        let plan = HistoryRetentionPlan(records: ordered, retention: retention, audio: audioRetention, now: now())
        if !plan.isEmpty {
            // The database changes first: if it can't, no audio is deleted for a
            // record that would stay in History.
            try db.transaction {
                try Self.delete(plan.expiredIDs, from: db)
                let release = try db.prepare("UPDATE transcripts SET audio_path = '' WHERE id = ?")
                for id in plan.releasedAudioIDs { try release.bind(.text(id.uuidString)).run() }
            }
            var retained: [TranscriptRecord] = []
            retained.reserveCapacity(ordered.count - plan.expiredIDs.count)
            for var record in ordered {
                if plan.expiredIDs.contains(record.id) {
                    removeAudioFile(record.audioFilePath)
                    continue
                }
                if plan.releasedAudioIDs.contains(record.id) {
                    removeAudioFile(record.audioFilePath)
                    record.audioFilePath = ""
                }
                retained.append(record)
            }
            records = retained
        } else {
            records = ordered
        }
        // While suspended, `records` doesn't reflect the history on disk, so every
        // WAV it references would look orphaned — `connection()` has thrown by then.
        if sweepOrphans {
            removeOldOrphanedAudioFiles(cutoff: now().addingTimeInterval(-TranscriptAudioRetention.orphanSweepAge))
        }
    }

    private func insertInOrder(_ record: TranscriptRecord) {
        // Binary search: history can hold tens of thousands of records.
        var low = 0
        var high = records.count
        while low < high {
            let mid = (low + high) / 2
            if TranscriptRecord.isOrderedBefore(records[mid], record) { low = mid + 1 } else { high = mid }
        }
        records.insert(record, at: low)
    }

    private func removeOldOrphanedAudioFiles(cutoff: Date) {
        guard let recordingsDirectory,
              let urls = try? fileManager.contentsOfDirectory(
                  at: recordingsDirectory,
                  includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else { return }

        let retainedPaths = Set(records.lazy.filter { !$0.audioFilePath.isEmpty }.map { self.standardizedPath($0.audioFilePath) })
        for url in urls where url.pathExtension.lowercased() == "wav" {
            let path = standardizedPath(url.path)
            guard !retainedPaths.contains(path),
                  let values = try? url.resourceValues(
                      forKeys: [.isRegularFileKey, .contentModificationDateKey]
                  ),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < cutoff else { continue }
            removeAudioFile(url.path)
        }
    }

    private func standardizedPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // MARK: - Database

    private func write(_ body: (SQLiteDatabase) throws -> Void) throws {
        let db = try connection()
        try db.transaction { try body(db) }
    }

    /// Writes before (or without) a `load()` open the database lazily, but never
    /// while a history that couldn't be read or backed up is suspended.
    private func connection() throws -> SQLiteDatabase {
        if persistenceSuspended {
            throw TranscriptStoreError.corruptFileUnrecoverable(path: fileURL.path)
        }
        if let database { return database }
        return try openDatabase()
    }

    private func openDatabase() throws -> SQLiteDatabase {
        try fileManager.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db: SQLiteDatabase
        do {
            db = try Self.openSchema(at: databaseURL)
        } catch let error as SQLiteError where error.isCorruption {
            let stamp = Int(now().timeIntervalSince1970)
            let backupURL = databaseURL.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).sqlite")
            guard SQLiteDatabase.backUpDamagedFile(at: databaseURL, to: backupURL,
                                                   moveItem: moveItem, copyItem: copyItem) else {
                persistenceSuspended = true
                throw TranscriptStoreError.corruptFileUnrecoverable(path: databaseURL.path)
            }
            db = try Self.openSchema(at: databaseURL)
        }
        database = db
        return db
    }

    private static let schemaVersion = 1

    private static func openSchema(at url: URL) throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(url: url)
        let version = try db.scalarInt("PRAGMA user_version")
        if version < schemaVersion {
            try db.transaction {
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS transcripts (
                        id TEXT PRIMARY KEY NOT NULL,
                        created_at REAL NOT NULL,
                        updated_at REAL,
                        status TEXT NOT NULL,
                        error_message TEXT,
                        text TEXT NOT NULL,
                        raw_recognition TEXT,
                        audio_path TEXT NOT NULL,
                        duration REAL,
                        model TEXT,
                        engine TEXT,
                        language TEXT,
                        app_category TEXT
                    )
                    """)
                try db.execute("CREATE INDEX IF NOT EXISTS transcripts_created_at ON transcripts(created_at DESC, id DESC)")
                try db.execute("PRAGMA user_version = \(schemaVersion)")
            }
        }
        return db
    }

    /// Imports `transcripts.json` from before the SQLite store, then moves it to
    /// `transcripts.migrated-<timestamp>.json` as a backup. The import ignores
    /// ids already present, so a JSON that could not be moved (or one written by
    /// a downgraded build) is merged again rather than duplicated.
    private func importLegacyHistory(into db: SQLiteDatabase) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        } catch {
            // The file exists but can't be read (permissions after a restore,
            // I/O error). Its bytes may be the only copy of the history, so new
            // writes wait until a later `load()` can import it.
            persistenceSuspended = true
            throw error
        }
        let legacy: [TranscriptRecord]
        do {
            legacy = try JSONDecoder.whiskerFlow.decode([TranscriptRecord].self, from: data)
        } catch {
            // Don't silently drop a file we can't parse — preserve it so the
            // user (or a future migration) can recover, then start clean. Without
            // a backup on disk, suspend persistence rather than bury the only copy.
            guard backUpLegacyFile(suffix: "corrupt") else {
                persistenceSuspended = true
                throw TranscriptStoreError.corruptFileUnrecoverable(path: fileURL.path)
            }
            return
        }
        try db.transaction {
            let insert = try db.prepare(Self.insertSQL(orIgnore: true))
            for record in legacy { try insert.bind(Self.values(for: record)).run() }
        }
        _ = backUpLegacyFile(suffix: "migrated")
    }

    /// Success is the move/copy result, never a `fileExists` probe: an unrelated
    /// entry already sitting at the backup path would otherwise read as "backed
    /// up" and clear the way to discard the only copy of the original bytes.
    /// Nothing at that path is removed for the same reason.
    private func backUpLegacyFile(suffix: String) -> Bool {
        let stamp = Int(now().timeIntervalSince1970)
        let backupURL = fileURL.deletingPathExtension()
            .appendingPathExtension("\(suffix)-\(stamp).json")
        do {
            try moveItem(fileURL, backupURL)
            return true
        } catch {
            do {
                try copyItem(fileURL, backupURL)
            } catch {
                return false
            }
            // The copy is the backup; the original must go or the next load
            // would read it again.
            try? fileManager.removeItem(at: fileURL)
            return true
        }
    }

    private static let columns = "id, created_at, updated_at, status, error_message, text, raw_recognition, audio_path, duration, model, engine, language, app_category"

    private static func insertSQL(orIgnore: Bool) -> String {
        "INSERT OR \(orIgnore ? "IGNORE" : "REPLACE") INTO transcripts (\(columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
    }

    private static func values(for record: TranscriptRecord) -> [SQLiteValue] {
        let status: String
        var errorMessage: String?
        switch record.status {
        case .recording: status = "recording"
        case .transcribing: status = "transcribing"
        case .transcribed: status = "transcribed"
        case .failed(let message): status = "failed"; errorMessage = message
        }
        return [
            .text(record.id.uuidString),
            .double(record.createdAt.timeIntervalSince1970),
            .optional(record.updatedAt?.timeIntervalSince1970),
            .text(status),
            .optional(errorMessage),
            .text(record.text),
            .optional(record.rawRecognition),
            .text(record.audioFilePath),
            .optional(record.durationSeconds),
            .optional(record.model),
            .optional(record.engine),
            .optional(record.language),
            .optional(record.appCategory?.rawValue)
        ]
    }

    private static func upsert(_ record: TranscriptRecord, into db: SQLiteDatabase) throws {
        try db.prepare(insertSQL(orIgnore: false)).bind(values(for: record)).run()
    }

    private static func delete<S: Sequence>(_ ids: S, from db: SQLiteDatabase) throws where S.Element == UUID {
        let statement = try db.prepare("DELETE FROM transcripts WHERE id = ?")
        for id in ids { try statement.bind(.text(id.uuidString)).run() }
    }

    private static func fetchAll(from db: SQLiteDatabase) throws -> [TranscriptRecord] {
        let statement = try db.prepare("SELECT \(columns) FROM transcripts ORDER BY created_at DESC, id DESC")
        var records: [TranscriptRecord] = []
        while try statement.step() {
            guard let idText = statement.text(0), let id = UUID(uuidString: idText) else { continue }
            let status: TranscriptStatus
            switch statement.text(3) {
            case "recording": status = .recording
            case "transcribing": status = .transcribing
            case "transcribed": status = .transcribed
            default: status = .failed(errorMessage: statement.text(4) ?? "")
            }
            records.append(TranscriptRecord(
                id: id,
                text: statement.text(5) ?? "",
                audioFilePath: statement.text(7) ?? "",
                createdAt: Date(timeIntervalSince1970: statement.double(1)),
                status: status,
                durationSeconds: statement.optionalDouble(8),
                model: statement.text(9),
                engine: statement.text(10),
                language: statement.text(11),
                updatedAt: statement.optionalDouble(2).map(Date.init(timeIntervalSince1970:)),
                rawRecognition: statement.text(6),
                appCategory: statement.text(12).map { AppCategory(rawValue: $0) ?? .other }
            ))
        }
        // `uuidString` order and SQLite's text order agree, but a record written
        // with a timestamp tie by an older build is re-sorted just in case.
        return records.sortedNewestFirst()
    }
}

extension JSONDecoder {
    static var whiskerFlow: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var whiskerFlow: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
