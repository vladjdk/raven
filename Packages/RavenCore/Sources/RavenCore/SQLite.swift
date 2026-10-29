import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
  public let code: Int32
  public let message: String
  public var description: String { "SQLite error \(code): \(message)" }
}

public enum SQLValue: Sendable, Equatable {
  case null
  case int(Int64)
  case double(Double)
  case text(String)
}

extension SQLValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByNilLiteral {
  public init(stringLiteral value: String) { self = .text(value) }
  public init(integerLiteral value: Int64) { self = .int(value) }
  public init(nilLiteral: ()) { self = .null }

  public init(_ string: String?) { self = string.map(SQLValue.text) ?? .null }
  public init(_ date: Date?) { self = date.map { .double($0.timeIntervalSince1970) } ?? .null }
  public init(_ bool: Bool) { self = .int(bool ? 1 : 0) }
}

public struct Row: Sendable {
  fileprivate var values: [String: SQLValue]

  public subscript(_ column: String) -> SQLValue { values[column] ?? .null }

  public func string(_ column: String) -> String? {
    switch self[column] {
    case .text(let s): s
    case .int(let i): String(i)
    case .double(let d): String(d)
    case .null: nil
    }
  }

  public func int(_ column: String) -> Int64? {
    switch self[column] {
    case .int(let i): i
    case .double(let d): Int64(d)
    case .text(let s): Int64(s)
    case .null: nil
    }
  }

  public func date(_ column: String) -> Date? {
    switch self[column] {
    case .double(let d): Date(timeIntervalSince1970: d)
    case .int(let i): Date(timeIntervalSince1970: TimeInterval(i))
    default: nil
    }
  }

  public func bool(_ column: String) -> Bool { (int(column) ?? 0) != 0 }
}

/// A minimal wrapper over the system SQLite. Not thread-safe: own it from one actor.
public final class Database {
  private var handle: OpaquePointer?

  /// `path: nil` opens a private in-memory database.
  public init(path: String?) throws {
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
    let rc = sqlite3_open_v2(path ?? ":memory:", &handle, flags, nil)
    guard rc == SQLITE_OK else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
      sqlite3_close(handle)
      throw SQLiteError(code: rc, message: message)
    }
    try execute("PRAGMA journal_mode = WAL")
    try execute("PRAGMA foreign_keys = ON")
  }

  deinit { sqlite3_close(handle) }

  public func execute(_ sql: String, _ arguments: [SQLValue] = []) throws {
    let statement = try prepare(sql, arguments)
    defer { sqlite3_finalize(statement) }
    while true {
      let rc = sqlite3_step(statement)
      if rc == SQLITE_DONE { return }
      if rc != SQLITE_ROW { throw error(rc) }
    }
  }

  /// Runs several `;`-separated statements without arguments (for schema setup).
  public func executeScript(_ sql: String) throws {
    let rc = sqlite3_exec(handle, sql, nil, nil, nil)
    guard rc == SQLITE_OK else { throw error(rc) }
  }

  public func query(_ sql: String, _ arguments: [SQLValue] = []) throws -> [Row] {
    let statement = try prepare(sql, arguments)
    defer { sqlite3_finalize(statement) }
    var rows: [Row] = []
    let columns = sqlite3_column_count(statement)
    while true {
      let rc = sqlite3_step(statement)
      if rc == SQLITE_DONE { break }
      guard rc == SQLITE_ROW else { throw error(rc) }
      var values: [String: SQLValue] = [:]
      for i in 0..<columns {
        let name = String(cString: sqlite3_column_name(statement, i))
        switch sqlite3_column_type(statement, i) {
        case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(statement, i))
        case SQLITE_FLOAT: values[name] = .double(sqlite3_column_double(statement, i))
        case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(statement, i)))
        default: values[name] = .null
        }
      }
      rows.append(Row(values: values))
    }
    return rows
  }

  public func transaction<T>(_ body: () throws -> T) throws -> T {
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

  private func prepare(_ sql: String, _ arguments: [SQLValue]) throws -> OpaquePointer? {
    var statement: OpaquePointer?
    let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
    guard rc == SQLITE_OK else { throw error(rc) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (index, value) in arguments.enumerated() {
      let position = Int32(index + 1)
      switch value {
      case .null: sqlite3_bind_null(statement, position)
      case .int(let i): sqlite3_bind_int64(statement, position, i)
      case .double(let d): sqlite3_bind_double(statement, position, d)
      case .text(let s): sqlite3_bind_text(statement, position, s, -1, transient)
      }
    }
    return statement
  }

  private func error(_ rc: Int32) -> SQLiteError {
    SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
  }
}
