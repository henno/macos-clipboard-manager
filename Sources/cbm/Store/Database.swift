import Foundation
import SQLite3

/// Tells SQLite to copy the bound bytes rather than borrow them. Only ever used
/// for inline payloads, which are capped at 64 KiB, so the copy is cheap.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DBError: Error, CustomStringConvertible {
    case open(String)
    case exec(String, String)
    case prepare(String, String)
    case step(String, String)

    var description: String {
        switch self {
        case .open(let m): return "sqlite open failed: \(m)"
        case .exec(let sql, let m): return "sqlite exec failed: \(m) -- \(sql)"
        case .prepare(let sql, let m): return "sqlite prepare failed: \(m) -- \(sql)"
        case .step(let sql, let m): return "sqlite step failed: \(m) -- \(sql)"
        }
    }
}

/// Thin wrapper over the libsqlite3 C API. Not thread-safe by design: exactly
/// one serial queue in `ItemStore` owns it, which is why the handle is opened
/// NOMUTEX -- we do not pay for locking we do not need.
final class Database {
    private var handle: OpaquePointer?
    private var cache: [String: OpaquePointer] = [:]

    init(path: String) throws {
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(h)
            throw DBError.open(msg)
        }
        handle = h
        sqlite3_busy_timeout(h, 3000)
    }

    deinit { close() }

    var lastError: String {
        guard let handle else { return "closed" }
        return String(cString: sqlite3_errmsg(handle))
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int32 { sqlite3_changes(handle) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw DBError.exec(sql, msg)
        }
    }

    /// Returns a prepared statement, cached by SQL text and already reset, so
    /// callers can bind straight away. Re-preparing on a hot path is one of the
    /// few genuinely expensive things SQLite does.
    func statement(_ sql: String) throws -> Statement {
        if let cached = cache[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return Statement(sql: sql, stmt: cached, db: self)
        }
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &s, nil) == SQLITE_OK, let s else {
            throw DBError.prepare(sql, lastError)
        }
        cache[sql] = s
        return Statement(sql: sql, stmt: s, db: self)
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func close() {
        for (_, s) in cache { sqlite3_finalize(s) }
        cache.removeAll()
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }
}

struct Statement {
    let sql: String
    let stmt: OpaquePointer
    unowned let db: Database

    // MARK: binding (1-based, as SQLite counts)

    @discardableResult func bind(_ i: Int32, _ v: Int64) -> Statement {
        sqlite3_bind_int64(stmt, i, v); return self
    }

    @discardableResult func bind(_ i: Int32, _ v: Int) -> Statement {
        sqlite3_bind_int64(stmt, i, Int64(v)); return self
    }

    @discardableResult func bind(_ i: Int32, _ v: Double) -> Statement {
        sqlite3_bind_double(stmt, i, v); return self
    }

    @discardableResult func bind(_ i: Int32, _ v: String?) -> Statement {
        if let v { sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(stmt, i) }
        return self
    }

    @discardableResult func bind(_ i: Int32, _ v: Data?) -> Statement {
        guard let v else { sqlite3_bind_null(stmt, i); return self }
        if v.isEmpty {
            sqlite3_bind_blob(stmt, i, "", 0, SQLITE_TRANSIENT)
        } else {
            v.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(stmt, i, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
            }
        }
        return self
    }

    // MARK: stepping

    /// True when a row is available, false when the statement is done.
    @discardableResult func step() throws -> Bool {
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw DBError.step(sql, db.lastError)
        }
    }

    /// For statements with no result rows.
    func run() throws {
        while try step() {}
    }

    // MARK: reading (0-based, as SQLite counts)

    func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func bool(_ i: Int32) -> Bool { sqlite3_column_int64(stmt, i) != 0 }

    func string(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    func data(_ i: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, i) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, i))
        return Data(bytes: bytes, count: count)
    }
}
