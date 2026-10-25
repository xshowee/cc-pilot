// 系统自带 SQLite（libsqlite3）的最小封装，只给 Token 用量账本用。
// 一个连接只在一个线程（或一个串行队列）上使用；不跨线程共享。

import Foundation
import SQLite3

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "SQLite 错误 \(code)：\(message)" }
}

/// 可以绑定到语句参数上的值
enum SQLiteValue {
    case int(Int64)
    case real(Double)
    case text(String)
    case null

    static func int(_ value: Int) -> SQLiteValue { .int(Int64(value)) }
    static func text(_ value: String?) -> SQLiteValue { value.map { .text($0) } ?? .null }
}

final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// 打开（不存在时创建）数据库文件
    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError(code: code, message: message)
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit { sqlite3_close_v2(handle) }

    /// 执行一段（可以是多条）不需要参数、不取结果的 SQL
    func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
        return SQLiteStatement(statement!, database: self)
    }

    /// 执行一条带参数的语句，丢弃结果
    func run(_ sql: String, _ values: [SQLiteValue] = []) throws {
        try prepare(sql).run(values)
    }

    /// 上一条语句修改的行数
    var changes: Int { Int(sqlite3_changes(handle)) }

    /// 在一个事务里执行 body；body 抛错时回滚
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    fileprivate func check(_ code: Int32) throws {
        guard code == SQLITE_OK || code == SQLITE_ROW || code == SQLITE_DONE else {
            throw SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)))
        }
    }
}

final class SQLiteStatement {
    private let statement: OpaquePointer
    private let database: SQLiteDatabase

    fileprivate init(_ statement: OpaquePointer, database: SQLiteDatabase) {
        self.statement = statement
        self.database = database
    }

    deinit { sqlite3_finalize(statement) }

    /// 重置语句并按顺序绑定参数（?1、?2……）
    func bind(_ values: [SQLiteValue]) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .int(let v): try database.check(sqlite3_bind_int64(statement, index, v))
            case .real(let v): try database.check(sqlite3_bind_double(statement, index, v))
            case .text(let v): try database.check(sqlite3_bind_text(statement, index, v, -1, Self.transient))
            case .null: try database.check(sqlite3_bind_null(statement, index))
            }
        }
    }

    /// 绑定参数后执行到底，丢弃结果（语句可以反复用）
    func run(_ values: [SQLiteValue]) throws {
        try bind(values)
        while try step() {}
    }

    /// 前进一行；有结果行时返回 true，执行完毕返回 false
    func step() throws -> Bool {
        let code = sqlite3_step(statement)
        try database.check(code)
        return code == SQLITE_ROW
    }

    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func text(_ column: Int32) -> String? {
        guard let p = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: p)
    }
    /// 从 column 起连续四列：输入、输出、缓存写入、缓存读取
    func tokenCounts(from column: Int32) -> TokenCounts {
        TokenCounts(input: int(column), output: int(column + 1),
                    cacheWrite: int(column + 2), cacheRead: int(column + 3))
    }

    /// 让 SQLite 自己复制绑定的字符串
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
