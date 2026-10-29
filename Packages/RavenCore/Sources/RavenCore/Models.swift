import Foundation

public struct Address: Hashable, Sendable, Codable {
  public var name: String?
  public var email: String

  public init(name: String? = nil, email: String) {
    self.name = name
    self.email = email
  }

  /// "Priya Raman" when there is a display name, else the email address.
  public var displayName: String {
    if let name, !name.isEmpty { return name }
    return email
  }

  public var initials: String {
    let parts = displayName.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" })
    return parts.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
  }
}

public struct Message: Identifiable, Hashable, Sendable {
  public var id: String
  public var threadID: String
  public var from: Address
  public var to: [Address]
  public var cc: [Address]
  public var date: Date
  public var subject: String
  public var snippet: String
  public var bodyText: String?
  public var bodyHTML: String?
  public var labels: Set<String>
  public var listID: String?

  public init(
    id: String, threadID: String, from: Address, to: [Address] = [], cc: [Address] = [],
    date: Date, subject: String, snippet: String, bodyText: String? = nil, bodyHTML: String? = nil,
    labels: Set<String> = [], listID: String? = nil
  ) {
    self.id = id
    self.threadID = threadID
    self.from = from
    self.to = to
    self.cc = cc
    self.date = date
    self.subject = subject
    self.snippet = snippet
    self.bodyText = bodyText
    self.bodyHTML = bodyHTML
    self.labels = labels
    self.listID = listID
  }

  public var isUnread: Bool { labels.contains(Label.unread) }
}

/// A conversation as shown in the inbox list. Derived from its messages.
public struct MailThread: Identifiable, Hashable, Sendable {
  public var id: String
  public var subject: String
  public var snippet: String
  public var lastFrom: Address
  public var lastDate: Date
  public var messageCount: Int
  public var labels: Set<String>
  public var isNewsletter: Bool
  public var snoozedUntil: Date?

  public init(
    id: String, subject: String, snippet: String, lastFrom: Address, lastDate: Date,
    messageCount: Int, labels: Set<String>, isNewsletter: Bool, snoozedUntil: Date? = nil
  ) {
    self.id = id
    self.subject = subject
    self.snippet = snippet
    self.lastFrom = lastFrom
    self.lastDate = lastDate
    self.messageCount = messageCount
    self.labels = labels
    self.isNewsletter = isNewsletter
    self.snoozedUntil = snoozedUntil
  }

  public var isUnread: Bool { labels.contains(Label.unread) }

  /// Builds the list row from a thread's messages (oldest first).
  public init?(messages: [Message], snoozedUntil: Date? = nil) {
    guard let last = messages.max(by: { $0.date < $1.date }) else { return nil }
    let first = messages.min(by: { $0.date < $1.date }) ?? last
    self.init(
      id: last.threadID,
      subject: first.subject.isEmpty ? "(no subject)" : first.subject,
      snippet: last.snippet,
      lastFrom: last.from,
      lastDate: last.date,
      messageCount: messages.count,
      labels: messages.reduce(into: Set<String>()) { $0.formUnion($1.labels) },
      isNewsletter: messages.contains { $0.listID != nil },
      snoozedUntil: snoozedUntil
    )
  }
}

/// Gmail system label ids.
public enum Label {
  public static let inbox = "INBOX"
  public static let unread = "UNREAD"
  public static let important = "IMPORTANT"
  public static let trash = "TRASH"
  public static let sent = "SENT"
  public static let draft = "DRAFT"
  public static let updates = "CATEGORY_UPDATES"
  public static let promotions = "CATEGORY_PROMOTIONS"
  public static let social = "CATEGORY_SOCIAL"
  public static let forums = "CATEGORY_FORUMS"
}

/// The split-inbox tabs. Each thread in the inbox lands in exactly one.
public enum InboxTab: String, CaseIterable, Sendable, Identifiable {
  case important, updates, newsletters, other

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .important: "Important"
    case .updates: "Updates"
    case .newsletters: "Newsletters"
    case .other: "Other"
    }
  }

  public static func classify(_ thread: MailThread) -> InboxTab {
    if thread.labels.contains(Label.important) && !thread.isNewsletter { return .important }
    if thread.isNewsletter || thread.labels.contains(Label.promotions) { return .newsletters }
    if thread.labels.contains(Label.updates) || thread.labels.contains(Label.forums) { return .updates }
    return .other
  }
}

public enum Mailbox: String, CaseIterable, Sendable, Identifiable {
  case inbox, snoozed, done, sent, trash

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .inbox: "Inbox"
    case .snoozed: "Snoozed"
    case .done: "Done"
    case .sent: "Sent"
    case .trash: "Trash"
    }
  }
}

/// Something the user (or later, the agent) did. Applied locally first, then sent to the server.
public enum MailAction: Codable, Hashable, Sendable {
  case archive(threadID: String)
  case unarchive(threadID: String)
  case trash(threadID: String)
  case untrash(threadID: String)
  case markRead(threadID: String)
  case markUnread(threadID: String)
  case snooze(threadID: String, until: Date)
  case unsnooze(threadID: String)

  public var threadID: String {
    switch self {
    case .archive(let id), .unarchive(let id), .trash(let id), .untrash(let id),
      .markRead(let id), .markUnread(let id), .unsnooze(let id):
      id
    case .snooze(let id, _):
      id
    }
  }

  /// The action that reverses this one, for undo.
  public var inverse: MailAction {
    switch self {
    case .archive(let id): .unarchive(threadID: id)
    case .unarchive(let id): .archive(threadID: id)
    case .trash(let id): .untrash(threadID: id)
    case .untrash(let id): .trash(threadID: id)
    case .markRead(let id): .markUnread(threadID: id)
    case .markUnread(let id): .markRead(threadID: id)
    case .snooze(let id, _): .unsnooze(threadID: id)
    case .unsnooze(let id): .archive(threadID: id)
    }
  }

  /// Gmail label changes this action makes. Snooze is local: Gmail has no snooze API,
  /// so a snoozed thread leaves the inbox on the server and comes back when it wakes.
  public var labelChanges: (add: Set<String>, remove: Set<String>) {
    switch self {
    case .archive, .snooze: ([], [Label.inbox])
    case .unarchive, .unsnooze: ([Label.inbox], [])
    case .trash: ([Label.trash], [Label.inbox])
    case .untrash: ([Label.inbox], [Label.trash])
    case .markRead: ([], [Label.unread])
    case .markUnread: ([Label.unread], [])
    }
  }
}
