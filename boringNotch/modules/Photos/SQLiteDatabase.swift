//
//  SQLiteDatabase.swift
//  boringNotch
//
//  A thin wrapper over the system SQLite, just enough for the photo library: open, run statements with bound values, read
//  columns, transactions. Not thread-safe by itself: the photo store keeps every call on one serial queue.
//

import Foundation
import SQLite3

struct SQLiteError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

enum SQLiteValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open the database"
            sqlite3_close(handle)
            throw SQLiteError(message: message)
        }
        // Another connection (a second window, a background job) may be writing: wait for it instead of failing at once.
        sqlite3_busy_timeout(handle, 8000)
        try exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON; PRAGMA temp_store = MEMORY;")
    }

    deinit { sqlite3_close(handle) }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw SQLiteError(message: message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(handle)) + " in: " + sql)
        }
        return SQLiteStatement(statement, database: self)
    }

    /// Runs a statement that returns nothing.
    @discardableResult
    func run(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int {
        let statement = try prepare(sql)
        try statement.bind(values)
        _ = try statement.step()
        return Int(sqlite3_changes(handle))
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Rows changed by the statement that finished last (0 for an INSERT OR IGNORE that was ignored).
    var changes: Int { Int(sqlite3_changes(handle)) }

    var userVersion: Int {
        get { (try? prepare("PRAGMA user_version").firstRow { Int($0.int(0)) }) ?? 0 }
        set { try? exec("PRAGMA user_version = \(newValue)") }
    }

    fileprivate var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }
}

final class SQLiteStatement {
    private let statement: OpaquePointer
    private unowned let database: SQLiteDatabase

    fileprivate init(_ statement: OpaquePointer, database: SQLiteDatabase) {
        self.statement = statement
        self.database = database
    }

    deinit { sqlite3_finalize(statement) }

    func bind(_ values: [SQLiteValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null: code = sqlite3_bind_null(statement, index)
            case .int(let v): code = sqlite3_bind_int64(statement, index, v)
            case .double(let v): code = sqlite3_bind_double(statement, index, v)
            case .text(let v): code = sqlite3_bind_text(statement, index, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .blob(let v):
                code = v.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(v.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            }
            guard code == SQLITE_OK else { throw SQLiteError(message: database.errorMessage) }
        }
    }

    /// True when a row is available, false when the statement is done.
    @discardableResult
    func step() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError(message: database.errorMessage)
        }
    }

    func reset() { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }

    /// Runs the statement and maps each row.
    func rows<T>(_ values: [SQLiteValue] = [], _ map: (SQLiteStatement) -> T) throws -> [T] {
        try bind(values)
        var result: [T] = []
        while try step() { result.append(map(self)) }
        return result
    }

    func firstRow<T>(_ values: [SQLiteValue] = [], _ map: (SQLiteStatement) -> T) throws -> T? {
        try bind(values)
        return try step() ? map(self) : nil
    }

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
    func blob(_ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
}
