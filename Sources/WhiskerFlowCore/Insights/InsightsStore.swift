import Foundation

/// Lifetime dictation aggregates, kept apart from History so they survive any
/// retention setting. The database holds counts, days, hours, bundle IDs and
/// engine names only — never transcript text.
public final class InsightsStore {
    public let databaseURL: URL
    private let calendar: () -> Calendar
    private let now: () -> Date
    private var database: SQLiteDatabase?
    private var bucketIndex: [InsightsBucket.Key: InsightsBucket] = [:]

    public private(set) var recentSamples: [DictationSample] = []
    public private(set) var hasBackfilled = false

    public init(
        databaseURL: URL,
        calendar: @escaping () -> Calendar = { .autoupdatingCurrent },
        now: @escaping () -> Date = Date.init
    ) {
        self.databaseURL = databaseURL
        self.calendar = calendar
        self.now = now
    }

    public var buckets: [InsightsBucket] { Array(bucketIndex.values) }

    public func load() throws {
        let db = try connection()
        var index: [InsightsBucket.Key: InsightsBucket] = [:]
        let rows = try db.prepare("""
            SELECT day, hour, app, engine, dictations, words, speaking_seconds, vocabulary_replacements, self_corrections
            FROM buckets
            """)
        while try rows.step() {
            guard let dayKey = rows.text(0), let day = LocalDay(key: dayKey) else { continue }
            let key = InsightsBucket.Key(day: day, hour: rows.int(1), appBundleID: rows.text(2) ?? "", engine: rows.text(3) ?? "")
            index[key] = InsightsBucket(key: key, dictations: rows.int(4), words: rows.int(5),
                                        speakingSeconds: rows.double(6), vocabularyReplacements: rows.int(7),
                                        selfCorrections: rows.int(8))
        }
        bucketIndex = index
        var samples: [DictationSample] = []
        let recent = try db.prepare("SELECT words, speaking_seconds FROM recent_dictations ORDER BY seq")
        while try recent.step() { samples.append(DictationSample(words: recent.int(0), speakingSeconds: recent.double(1))) }
        recentSamples = samples
        hasBackfilled = try db.scalarText("SELECT value FROM meta WHERE key = 'backfilled'") == "1"
    }

    public func record(_ insight: DictationInsight) throws {
        try record([insight])
    }

    /// Imports existing History once, so Insights start from what the user has
    /// already dictated. Returns false when an earlier launch already did it.
    /// Backfilled dictations have no destination app or correction counts.
    @discardableResult
    public func backfillIfNeeded(from records: [TranscriptRecord]) throws -> Bool {
        guard !hasBackfilled else { return false }
        let insights = records
            .filter { $0.status == .transcribed }
            .sorted { $0.createdAt < $1.createdAt }
            .map { record in
                DictationInsight(date: record.createdAt, words: record.wordCount,
                                 speakingSeconds: record.durationSeconds ?? 0, appBundleID: nil,
                                 engine: record.engine ?? "")
            }
        try record(insights, markBackfilled: true)
        return true
    }

    /// Clears every aggregate. History is not re-imported afterwards: a reset
    /// means starting the counts from zero.
    public func reset() throws {
        let db = try connection()
        try db.transaction {
            try db.execute("DELETE FROM buckets")
            try db.execute("DELETE FROM recent_dictations")
            try db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('backfilled', '1')")
        }
        bucketIndex = [:]
        recentSamples = []
        hasBackfilled = true
    }

    public func summary(
        typingWordsPerMinute: Int = InsightsSummary.defaultTypingWordsPerMinute,
        appGrouping: any InsightsAppGrouping = BundleIDAppGrouping()
    ) -> InsightsSummary {
        InsightsSummary(buckets: buckets, recentSamples: recentSamples, typingWordsPerMinute: typingWordsPerMinute,
                        now: now(), calendar: calendar(), appGrouping: appGrouping)
    }

    private func record(_ insights: [DictationInsight], markBackfilled: Bool = false) throws {
        let db = try connection()
        let calendar = calendar()
        var changed: [InsightsBucket.Key: InsightsBucket] = [:]
        for insight in insights {
            let key = InsightsBucket.key(for: insight, calendar: calendar)
            var bucket = changed[key] ?? bucketIndex[key] ?? InsightsBucket(key: key)
            bucket.add(insight)
            changed[key] = bucket
        }
        let samples = insights.map { DictationSample(words: max(0, $0.words), speakingSeconds: max(0, $0.speakingSeconds)) }
            .filter { $0.speakingSeconds > 0 }
            .suffix(InsightsSummary.speakingSampleLimit)
        try db.transaction {
            let upsert = try db.prepare("""
                INSERT OR REPLACE INTO buckets
                    (day, hour, app, engine, dictations, words, speaking_seconds, vocabulary_replacements, self_corrections)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for bucket in changed.values {
                try upsert.bind(.text(bucket.key.day.key), .int(bucket.key.hour), .text(bucket.key.appBundleID),
                                .text(bucket.key.engine), .int(bucket.dictations), .int(bucket.words),
                                .double(bucket.speakingSeconds), .int(bucket.vocabularyReplacements),
                                .int(bucket.selfCorrections)).run()
            }
            let insert = try db.prepare("INSERT INTO recent_dictations (words, speaking_seconds) VALUES (?, ?)")
            for sample in samples { try insert.bind(.int(sample.words), .double(sample.speakingSeconds)).run() }
            try db.execute("""
                DELETE FROM recent_dictations WHERE seq NOT IN
                    (SELECT seq FROM recent_dictations ORDER BY seq DESC LIMIT \(InsightsSummary.speakingSampleLimit))
                """)
            if markBackfilled {
                try db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('backfilled', '1')")
            }
        }
        bucketIndex.merge(changed) { _, new in new }
        recentSamples = Array((recentSamples + samples).suffix(InsightsSummary.speakingSampleLimit))
        if markBackfilled { hasBackfilled = true }
    }

    private func connection() throws -> SQLiteDatabase {
        if let database { return database }
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db: SQLiteDatabase
        do {
            db = try Self.openSchema(at: databaseURL)
        } catch let error as SQLiteError where error.isCorruption {
            // Aggregates can't be rebuilt from History once it has expired, so a
            // damaged file is kept for inspection rather than overwritten.
            let stamp = Int(now().timeIntervalSince1970)
            let backup = databaseURL.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).sqlite")
            guard SQLiteDatabase.backUpDamagedFile(
                at: databaseURL, to: backup,
                moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
                copyItem: { try FileManager.default.copyItem(at: $0, to: $1) }
            ) else { throw error }
            db = try Self.openSchema(at: databaseURL)
        }
        database = db
        return db
    }

    private static let schemaVersion = 1

    private static func openSchema(at url: URL) throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(url: url)
        guard try db.scalarInt("PRAGMA user_version") < schemaVersion else { return db }
        try db.transaction {
            try db.execute("""
                CREATE TABLE IF NOT EXISTS buckets (
                    day TEXT NOT NULL,
                    hour INTEGER NOT NULL,
                    app TEXT NOT NULL,
                    engine TEXT NOT NULL,
                    dictations INTEGER NOT NULL,
                    words INTEGER NOT NULL,
                    speaking_seconds REAL NOT NULL,
                    vocabulary_replacements INTEGER NOT NULL,
                    self_corrections INTEGER NOT NULL,
                    PRIMARY KEY (day, hour, app, engine)
                )
                """)
            try db.execute("""
                CREATE TABLE IF NOT EXISTS recent_dictations (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    words INTEGER NOT NULL,
                    speaking_seconds REAL NOT NULL
                )
                """)
            try db.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
            try db.execute("PRAGMA user_version = \(schemaVersion)")
        }
        return db
    }
}
