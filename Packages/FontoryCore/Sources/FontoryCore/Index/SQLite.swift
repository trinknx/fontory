import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

public enum SQLValue: Equatable, Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

/// Thin SQLite wrapper. All access is serialized by an internal lock
/// (recursive, so `transaction` bodies may call back into the database).
public final class Database: @unchecked Sendable {
    fileprivate let handle: OpaquePointer
    fileprivate let lock = NSRecursiveLock()
    private var cache: [String: Statement] = [:]
    private var transactionDepth = 0

    public let path: String
    public let isReadOnly: Bool

    /// `readOnly` opens an existing database file for reading only (a second connection beside a writer;
    /// with WAL it reads the last committed state while the writer has a transaction open).
    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        self.isReadOnly = readOnly
        var h: OpaquePointer?
        let mode = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &h, mode | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let h { sqlite3_close(h) }
            throw SQLiteError(code: rc, message: msg)
        }
        handle = h
        // Unicode-aware case folding for SQL (built-in lower() is ASCII-only); same helper as Swift-side checks.
        sqlite3_create_function_v2(h, "fontory_fold", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { ctx, argc, argv in
            guard argc == 1, let argv, let v = argv[0], sqlite3_value_type(v) == SQLITE_TEXT,
                  let c = sqlite3_value_text(v) else { sqlite3_result_null(ctx); return }
            sqlite3_result_text(ctx, TagName.fold(String(cString: c)), -1, SQLITE_TRANSIENT)
        }, nil, nil, nil)
        if readOnly {
            try execute("PRAGMA query_only=ON")
        } else {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA synchronous=NORMAL")
        }
    }

    /// Holds the connection lock for the whole body. Statements are cached per SQL string and shared, so every
    /// prepare → bind → step… → reset sequence must run inside this to keep concurrent callers from interleaving.
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        try lock.withLock(body)
    }

    deinit {
        cache.removeAll()
        sqlite3_close_v2(handle)
    }

    public var lastInsertRowID: Int64 {
        lock.withLock { sqlite3_last_insert_rowid(handle) }
    }

    /// Rows changed by the most recent INSERT, UPDATE or DELETE on this connection.
    public var changes: Int64 {
        lock.withLock { Int64(sqlite3_changes(handle)) }
    }

    fileprivate func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
    }

    public func execute(_ sql: String) throws {
        try lock.withLock {
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(handle, sql, nil, nil, &err)
            if rc != SQLITE_OK {
                let msg = err.map { String(cString: $0) } ?? "exec failed"
                sqlite3_free(err)
                throw SQLiteError(code: rc, message: msg)
            }
        }
    }

    /// Returns a statement cached by SQL string; it is reset and its bindings cleared.
    public func prepare(_ sql: String) throws -> Statement {
        try lock.withLock {
            if let s = cache[sql] {
                s.reset()
                return s
            }
            var stmt: OpaquePointer?
            let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
            guard rc == SQLITE_OK, let stmt else { throw error(rc) }
            let s = Statement(db: self, handle: stmt)
            cache[sql] = s
            return s
        }
    }

    /// Runs `body` in a transaction; commits on return, rolls back on throw.
    /// Nested calls join the outer transaction.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            if transactionDepth > 0 { return try body() }
            try execute("BEGIN IMMEDIATE")
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            do {
                let result = try body()
                try execute("COMMIT")
                return result
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }
}

public final class Statement {
    private unowned let db: Database
    private let handle: OpaquePointer

    fileprivate init(db: Database, handle: OpaquePointer) {
        self.db = db
        self.handle = handle
    }

    deinit { sqlite3_finalize(handle) }

    /// Binds values to parameters 1...n.
    public func bind(_ values: [SQLValue]) throws {
        try db.lock.withLock {
            for (i, v) in values.enumerated() {
                let idx = Int32(i + 1)
                let rc: Int32
                switch v {
                case .null: rc = sqlite3_bind_null(handle, idx)
                case .int(let n): rc = sqlite3_bind_int64(handle, idx, n)
                case .double(let d): rc = sqlite3_bind_double(handle, idx, d)
                case .text(let s): rc = sqlite3_bind_text(handle, idx, s, -1, SQLITE_TRANSIENT)
                case .blob(let d):
                    rc = d.withUnsafeBytes { buf in
                        sqlite3_bind_blob(handle, idx, buf.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(buf.count), SQLITE_TRANSIENT)
                    }
                }
                if rc != SQLITE_OK { throw db.error(rc) }
            }
        }
    }

    /// Advances one row. Returns true if a row is available, false when done.
    public func step() throws -> Bool {
        try db.lock.withLock {
            let rc = sqlite3_step(handle)
            switch rc {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw db.error(rc)
            }
        }
    }

    public func int64(_ col: Int32) -> Int64 { sqlite3_column_int64(handle, col) }
    public func double(_ col: Int32) -> Double { sqlite3_column_double(handle, col) }
    public func isNull(_ col: Int32) -> Bool { sqlite3_column_type(handle, col) == SQLITE_NULL }

    public func text(_ col: Int32) -> String {
        guard let p = sqlite3_column_text(handle, col) else { return "" }
        return String(cString: p)
    }

    public func blob(_ col: Int32) -> Data {
        guard let p = sqlite3_column_blob(handle, col) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(handle, col)))
    }

    /// Resets the statement for re-execution and clears bindings.
    public func reset() {
        db.lock.withLock {
            sqlite3_reset(handle)
            sqlite3_clear_bindings(handle)
        }
    }
}


/// Case folding shared by tag-name uniqueness (Swift) and `#tag` search (SQL `fontory_fold`), so they can't drift.
enum TagName {
    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive], locale: nil) }
}
