import Foundation
import SQLite3

/// A SQLite failure. It carries the result code and a fixed operation name only:
/// SQLite's own messages can quote SQL or values, and these errors reach
/// diagnostics.
public struct SQLiteError: Error, Equatable, CustomStringConvertible {
    public let code: Int32
    public let operation: String

    public var description: String { "SQLite \(operation) failed (\(code))" }

    /// The file is not a database, or its pages are damaged. Only these justify
    /// moving the file aside; anything else (permissions, I/O) is left alone.
    var isCorruption: Bool {
        let primary = code & 0xFF
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }
}

/// A minimal single-connection wrapper. Callers own the threading: every store
/// that uses it is confined to one actor.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    let url: URL

    init(url: URL) throws {
        self.url = url
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(url.path, &db, flags, nil)
        guard result == SQLITE_OK, let db else {
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError(code: result, operation: "open")
        }
        handle = db
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, 2_000)
        do {
            // WAL keeps each commit to an append instead of rewriting pages, so a
            // dictation's history write stays off the release-to-paste budget.
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            try execute("PRAGMA foreign_keys=OFF")
            let check = try scalarText("PRAGMA quick_check")
            guard check == "ok" else { throw SQLiteError(code: SQLITE_CORRUPT, operation: "quick_check") }
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func close() {
        guard let handle else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    func execute(_ sql: String) throws {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, operation: "closed") }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw SQLiteError(code: result, operation: "exec") }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, operation: "closed") }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteError(code: result, operation: "prepare")
        }
        return SQLiteStatement(statement)
    }

    /// Runs `body` in one transaction, rolling back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func scalarText(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        guard try statement.step() else { return nil }
        return statement.text(0)
    }

    func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        guard try statement.step() else { return 0 }
        return statement.int(0)
    }

    /// Moves a damaged database (and its WAL sidecars) aside. Success is the
    /// move/copy result, never a `fileExists` probe, for the same reason as the
    /// transcript JSON backup: an occupied destination must not read as "saved".
    static func backUpDamagedFile(
        at url: URL,
        to backupURL: URL,
        moveItem: (URL, URL) throws -> Void,
        copyItem: (URL, URL) throws -> Void
    ) -> Bool {
        do {
            try moveItem(url, backupURL)
        } catch {
            do { try copyItem(url, backupURL) } catch { return false }
            try? FileManager.default.removeItem(at: url)
        }
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: sidecar.path) else { continue }
            let target = URL(fileURLWithPath: backupURL.path + suffix)
            if (try? moveItem(sidecar, target)) == nil { try? FileManager.default.removeItem(at: sidecar) }
        }
        return true
    }
}

final class SQLiteStatement {
    private let statement: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(_ statement: OpaquePointer) {
        self.statement = statement
    }

    deinit { sqlite3_finalize(statement) }

    @discardableResult
    func bind(_ values: SQLiteValue...) -> SQLiteStatement {
        bind(values)
    }

    @discardableResult
    func bind(_ values: [SQLiteValue]) -> SQLiteStatement {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .int(let int): sqlite3_bind_int64(statement, index, Int64(int))
            case .double(let double): sqlite3_bind_double(statement, index, double)
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            }
        }
        return self
    }

    /// Returns true while a row is available.
    func step() throws -> Bool {
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError(code: result, operation: "step")
        }
    }

    /// Steps a statement that returns no rows.
    func run() throws {
        while try step() {}
        sqlite3_reset(statement)
    }

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    func int(_ column: Int32) -> Int {
        Int(sqlite3_column_int64(statement, column))
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    func text(_ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    func optionalDouble(_ column: Int32) -> Double? {
        isNull(column) ? nil : double(column)
    }
}

enum SQLiteValue {
    case null
    case int(Int)
    case double(Double)
    case text(String)

    static func optional(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
    static func optional(_ value: Double?) -> SQLiteValue { value.map(SQLiteValue.double) ?? .null }
}
