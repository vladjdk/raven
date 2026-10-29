import Foundation

/// The local mail database. Every read the UI does comes from here, so it is fast and works offline.
public actor MailStore {
  private let db: Database
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  /// `url: nil` keeps everything in memory (tests, demo mode).
  public init(url: URL?) throws {
    if let url {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    db = try Database(path: url?.path)
    try db.executeScript(Self.schema)
    // Columns added after v0.1's first schema; ignore "duplicate column" on newer databases.
    for column in ["message_id_header TEXT", "refs TEXT", "attachments_json TEXT"] {
      try? db.execute("ALTER TABLE messages ADD COLUMN \(column)")
    }
  }

  private static let schema = """
    CREATE TABLE IF NOT EXISTS messages (
      id TEXT PRIMARY KEY,
      thread_id TEXT NOT NULL,
      from_name TEXT, from_email TEXT NOT NULL,
      to_json TEXT NOT NULL, cc_json TEXT NOT NULL,
      date REAL NOT NULL,
      subject TEXT NOT NULL, snippet TEXT NOT NULL,
      body_text TEXT, body_html TEXT,
      labels TEXT NOT NULL,
      list_id TEXT,
      message_id_header TEXT, refs TEXT, attachments_json TEXT
    );
    CREATE INDEX IF NOT EXISTS messages_thread ON messages(thread_id, date);
    CREATE TABLE IF NOT EXISTS threads (
      id TEXT PRIMARY KEY,
      subject TEXT NOT NULL, snippet TEXT NOT NULL,
      last_from_name TEXT, last_from_email TEXT NOT NULL,
      last_date REAL NOT NULL,
      message_count INTEGER NOT NULL,
      labels TEXT NOT NULL,
      is_newsletter INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS threads_date ON threads(last_date DESC);
    CREATE TABLE IF NOT EXISTS snoozes (thread_id TEXT PRIMARY KEY, until REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS outbox (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      action TEXT NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(message_id UNINDEXED, thread_id UNINDEXED, subject, sender, body);
    """

  // MARK: Writing messages

  public func upsert(_ messages: [Message]) throws {
    guard !messages.isEmpty else { return }
    try db.transaction {
      for m in messages {
        try db.execute(
          """
          INSERT OR REPLACE INTO messages
            (id, thread_id, from_name, from_email, to_json, cc_json, date, subject, snippet, body_text, body_html, labels, list_id,
             message_id_header, refs, attachments_json)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
          [
            .text(m.id), .text(m.threadID), SQLValue(m.from.name), .text(m.from.email),
            .text(try json(m.to)), .text(try json(m.cc)), SQLValue(m.date),
            .text(m.subject), .text(m.snippet), SQLValue(m.bodyText), SQLValue(m.bodyHTML),
            .text(Self.encode(m.labels)), SQLValue(m.listID),
            SQLValue(m.messageIDHeader), SQLValue(m.references), .text(try json(m.attachments)),
          ])
        try db.execute("DELETE FROM search WHERE message_id = ?", [.text(m.id)])
        try db.execute(
          "INSERT INTO search (message_id, thread_id, subject, sender, body) VALUES (?, ?, ?, ?, ?)",
          [
            .text(m.id), .text(m.threadID), .text(m.subject),
            .text("\(m.from.name ?? "") \(m.from.email)"),
            .text(m.bodyText ?? m.snippet),
          ])
      }
      for threadID in Set(messages.map(\.threadID)) {
        try refreshThread(threadID)
      }
    }
  }

  /// Replaces a message's labels (from a server history update).
  public func setLabels(messageID: String, labels: Set<String>) throws {
    let rows = try db.query("SELECT thread_id FROM messages WHERE id = ?", [.text(messageID)])
    guard let threadID = rows.first?.string("thread_id") else { return }
    try db.execute("UPDATE messages SET labels = ? WHERE id = ?", [.text(Self.encode(labels)), .text(messageID)])
    try refreshThread(threadID)
  }

  public func deleteMessages(ids: [String]) throws {
    try db.transaction {
      var threads = Set<String>()
      for id in ids {
        if let t = try db.query("SELECT thread_id FROM messages WHERE id = ?", [.text(id)]).first?.string("thread_id") {
          threads.insert(t)
        }
        try db.execute("DELETE FROM messages WHERE id = ?", [.text(id)])
        try db.execute("DELETE FROM search WHERE message_id = ?", [.text(id)])
      }
      for t in threads { try refreshThread(t) }
    }
  }

  // MARK: Local actions

  /// Applies an action to the local copy immediately (optimistic UI).
  public func apply(_ action: MailAction) throws {
    let id = action.threadID
    let (add, remove) = action.labelChanges
    try db.transaction {
      let rows = try db.query("SELECT id, labels FROM messages WHERE thread_id = ?", [.text(id)])
      for row in rows {
        guard let messageID = row.string("id") else { continue }
        var labels = Self.decode(row.string("labels") ?? "")
        // Only the newest-in-thread state matters for INBOX, but Gmail applies label
        // changes to every message in a thread, so we do too.
        labels.formUnion(add)
        labels.subtract(remove)
        try db.execute("UPDATE messages SET labels = ? WHERE id = ?", [.text(Self.encode(labels)), .text(messageID)])
      }
      switch action {
      case .snooze(_, let until):
        try db.execute("INSERT OR REPLACE INTO snoozes (thread_id, until) VALUES (?, ?)", [.text(id), SQLValue(until)])
      case .unsnooze, .archive, .trash, .clearSnooze:
        try db.execute("DELETE FROM snoozes WHERE thread_id = ?", [.text(id)])
      default:
        break
      }
      try refreshThread(id)
    }
  }

  /// Raw labels of each message in a thread plus its snooze, so undo can put things back exactly.
  public struct ThreadState: Sendable, Hashable {
    public let labels: [String: Set<String>]
    public let snoozedUntil: Date?
  }

  public func state(threadID: String) throws -> ThreadState {
    let rows = try db.query("SELECT id, labels FROM messages WHERE thread_id = ?", [.text(threadID)])
    var labels: [String: Set<String>] = [:]
    for row in rows { if let id = row.string("id") { labels[id] = Self.decode(row.string("labels") ?? "") } }
    let until = try db.query("SELECT until FROM snoozes WHERE thread_id = ?", [.text(threadID)]).first?.date("until")
    return ThreadState(labels: labels, snoozedUntil: until)
  }

  /// Snoozed threads whose time has come.
  public func dueSnoozes(now: Date = Date()) throws -> [String] {
    try db.query("SELECT thread_id FROM snoozes WHERE until <= ?", [SQLValue(now)]).compactMap { $0.string("thread_id") }
  }

  // MARK: Outbox

  public struct PendingAction: Sendable {
    public let id: Int64
    public let action: MailAction
    public let attempts: Int
  }

  public func enqueue(_ action: MailAction) throws {
    try db.execute("INSERT INTO outbox (action) VALUES (?)", [.text(try json(action))])
  }

  public func pendingActions() throws -> [PendingAction] {
    try db.query("SELECT id, action, attempts FROM outbox ORDER BY id").compactMap { row in
      guard let id = row.int("id"), let text = row.string("action"),
        let action = try? decoder.decode(MailAction.self, from: Data(text.utf8))
      else { return nil }
      return PendingAction(id: id, action: action, attempts: Int(row.int("attempts") ?? 0))
    }
  }

  public func completeAction(id: Int64) throws {
    try db.execute("DELETE FROM outbox WHERE id = ?", [.int(id)])
  }

  public func failAction(id: Int64) throws {
    try db.execute("UPDATE outbox SET attempts = attempts + 1 WHERE id = ?", [.int(id)])
  }

  // MARK: Reading

  public func threads(in mailbox: Mailbox, limit: Int = 500) throws -> [MailThread] {
    let condition: String
    switch mailbox {
    case .inbox:
      condition = "t.labels LIKE '% INBOX %' AND t.labels NOT LIKE '% TRASH %' AND s.thread_id IS NULL"
    case .snoozed:
      condition = "s.thread_id IS NOT NULL"
    case .done:
      condition = "t.labels NOT LIKE '% INBOX %' AND t.labels NOT LIKE '% TRASH %' AND s.thread_id IS NULL"
    case .sent:
      condition = "t.labels LIKE '% SENT %'"
    case .trash:
      condition = "t.labels LIKE '% TRASH %'"
    }
    let order = mailbox == .snoozed ? "s.until ASC" : "t.last_date DESC"
    return try db.query(
      """
      SELECT t.*, s.until FROM threads t LEFT JOIN snoozes s ON s.thread_id = t.id
      WHERE \(condition) ORDER BY \(order) LIMIT ?
      """, [.int(Int64(limit))]
    ).map(Self.thread)
  }

  public func thread(id: String) throws -> MailThread? {
    try db.query("SELECT t.*, s.until FROM threads t LEFT JOIN snoozes s ON s.thread_id = t.id WHERE t.id = ?", [.text(id)])
      .first.map(Self.thread)
  }

  public func messages(threadID: String) throws -> [Message] {
    try db.query("SELECT * FROM messages WHERE thread_id = ? ORDER BY date ASC", [.text(threadID)]).map(message)
  }

  /// Full-text search over subject, sender and body. Each word matches as a prefix.
  public func search(_ text: String, limit: Int = 100) throws -> [MailThread] {
    let terms = text.split(whereSeparator: \.isWhitespace)
      .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
      .map { word in
      "\"" + word.replacingOccurrences(of: "\"", with: "\"\"") + "\"*"
    }
    guard !terms.isEmpty else { return [] }
    return try db.query(
      """
      SELECT t.*, s.until FROM threads t LEFT JOIN snoozes s ON s.thread_id = t.id
      WHERE t.id IN (SELECT thread_id FROM search WHERE search MATCH ?)
      ORDER BY t.last_date DESC LIMIT ?
      """, [.text(terms.joined(separator: " ")), .int(Int64(limit))]
    ).map(Self.thread)
  }

  public func counts() throws -> [Mailbox: Int] {
    var result: [Mailbox: Int] = [:]
    let unreadInbox = try db.query(
      """
      SELECT COUNT(*) AS n FROM threads t LEFT JOIN snoozes s ON s.thread_id = t.id
      WHERE t.labels LIKE '% INBOX %' AND t.labels LIKE '% UNREAD %' AND t.labels NOT LIKE '% TRASH %' AND s.thread_id IS NULL
      """)
    result[.inbox] = Int(unreadInbox.first?.int("n") ?? 0)
    result[.snoozed] = Int(try db.query("SELECT COUNT(*) AS n FROM snoozes").first?.int("n") ?? 0)
    return result
  }

  // MARK: Metadata

  public func meta(_ key: String) throws -> String? {
    try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?.string("value")
  }

  public func setMeta(_ key: String, _ value: String?) throws {
    if let value {
      try db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [.text(key), .text(value)])
    } else {
      try db.execute("DELETE FROM meta WHERE key = ?", [.text(key)])
    }
  }

  // MARK: Helpers

  private func refreshThread(_ id: String) throws {
    let messages = try db.query("SELECT * FROM messages WHERE thread_id = ?", [.text(id)]).map(message)
    guard let thread = MailThread(messages: messages) else {
      try db.execute("DELETE FROM threads WHERE id = ?", [.text(id)])
      return
    }
    try db.execute(
      """
      INSERT OR REPLACE INTO threads
        (id, subject, snippet, last_from_name, last_from_email, last_date, message_count, labels, is_newsletter)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        .text(thread.id), .text(thread.subject), .text(thread.snippet),
        SQLValue(thread.lastFrom.name), .text(thread.lastFrom.email), SQLValue(thread.lastDate),
        .int(Int64(thread.messageCount)), .text(Self.encode(thread.labels)), SQLValue(thread.isNewsletter),
      ])
  }

  private func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  private func message(_ row: Row) -> Message {
    func addresses(_ column: String) -> [Address] {
      guard let text = row.string(column) else { return [] }
      return (try? decoder.decode([Address].self, from: Data(text.utf8))) ?? []
    }
    return Message(
      id: row.string("id") ?? "",
      threadID: row.string("thread_id") ?? "",
      from: Address(name: row.string("from_name"), email: row.string("from_email") ?? ""),
      to: addresses("to_json"),
      cc: addresses("cc_json"),
      date: row.date("date") ?? .distantPast,
      subject: row.string("subject") ?? "",
      snippet: row.string("snippet") ?? "",
      bodyText: row.string("body_text"),
      bodyHTML: row.string("body_html"),
      labels: Self.decode(row.string("labels") ?? ""),
      listID: row.string("list_id"),
      messageIDHeader: row.string("message_id_header"),
      references: row.string("refs"),
      attachments: row.string("attachments_json").flatMap { try? decoder.decode([Attachment].self, from: Data($0.utf8)) } ?? []
    )
  }

  private static func thread(_ row: Row) -> MailThread {
    MailThread(
      id: row.string("id") ?? "",
      subject: row.string("subject") ?? "",
      snippet: row.string("snippet") ?? "",
      lastFrom: Address(name: row.string("last_from_name"), email: row.string("last_from_email") ?? ""),
      lastDate: row.date("last_date") ?? .distantPast,
      messageCount: Int(row.int("message_count") ?? 1),
      labels: decode(row.string("labels") ?? ""),
      isNewsletter: row.bool("is_newsletter"),
      snoozedUntil: row.date("until")
    )
  }

  /// Labels are stored as " A B C " so `LIKE '% A %'` matches whole labels.
  static func encode(_ labels: Set<String>) -> String { " " + labels.sorted().joined(separator: " ") + " " }
  static func decode(_ text: String) -> Set<String> { Set(text.split(separator: " ").map(String.init)) }
}
