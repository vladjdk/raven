import Foundation

/// Gmail API JSON shapes (only the fields Raven reads).
public enum Gmail {
  public struct ThreadList: Decodable, Sendable {
    public struct Item: Decodable, Sendable {
      public let id: String
      public let historyId: String?
    }
    public let threads: [Item]?
    public let nextPageToken: String?
  }

  public struct Thread: Decodable, Sendable {
    public let id: String
    public let historyId: String?
    public let messages: [GMessage]?
  }

  public struct GMessage: Decodable, Sendable {
    public let id: String
    public let threadId: String
    public let labelIds: [String]?
    public let snippet: String?
    public let historyId: String?
    public let internalDate: String?
    public let payload: Part?
  }

  public struct Part: Decodable, Sendable {
    public let mimeType: String?
    public let filename: String?
    public let headers: [Header]?
    public let body: Body?
    public let parts: [Part]?
  }

  public struct Header: Decodable, Sendable {
    public let name: String
    public let value: String
  }

  public struct Body: Decodable, Sendable {
    public let size: Int?
    public let data: String?
    public let attachmentId: String?
  }

  public struct HistoryList: Decodable, Sendable {
    public struct Record: Decodable, Sendable {
      public struct MessageRef: Decodable, Sendable {
        public let message: Ref
      }
      public struct Ref: Decodable, Sendable {
        public let id: String
        public let threadId: String
        public let labelIds: [String]?
      }
      public let id: String
      public let messagesAdded: [MessageRef]?
      public let messagesDeleted: [MessageRef]?
      public let labelsAdded: [MessageRef]?
      public let labelsRemoved: [MessageRef]?
    }
    public let history: [Record]?
    public let historyId: String?
    public let nextPageToken: String?
  }

  public struct SentMessage: Decodable, Sendable {
    public let id: String
    public let threadId: String
  }

  public struct Profile: Decodable, Sendable {
    public let emailAddress: String
    public let historyId: String
  }
}

extension Message {
  /// Converts a Gmail API message (format=full) into Raven's model.
  public init(gmail m: Gmail.GMessage) {
    let headers = m.payload?.headers ?? []
    func header(_ name: String) -> String? {
      headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
    let millis = m.internalDate.flatMap(Double.init) ?? 0
    let bodies = MIME.bodies(of: m.payload)
    self.init(
      id: m.id,
      threadID: m.threadId,
      from: header("From").flatMap { MIME.addresses($0).first } ?? Address(email: "unknown"),
      to: header("To").map(MIME.addresses) ?? [],
      cc: header("Cc").map(MIME.addresses) ?? [],
      date: Date(timeIntervalSince1970: millis / 1000),
      subject: header("Subject") ?? "",
      snippet: MIME.decodeEntities(m.snippet ?? ""),
      bodyText: bodies.text,
      bodyHTML: bodies.html,
      labels: Set(m.labelIds ?? []),
      listID: header("List-Id") ?? header("List-Unsubscribe"),
      messageIDHeader: header("Message-ID") ?? header("Message-Id"),
      references: header("References"),
      attachments: MIME.attachments(of: m.payload)
    )
  }
}

public enum MIME {
  /// Finds the first text/plain and text/html parts, decoding Gmail's base64url bodies.
  public static func bodies(of part: Gmail.Part?) -> (text: String?, html: String?) {
    var text: String?
    var html: String?
    func walk(_ p: Gmail.Part) {
      let isAttachment = !(p.filename ?? "").isEmpty
      if !isAttachment, let data = p.body?.data, let decoded = base64URLDecode(data) {
        switch p.mimeType?.lowercased() {
        case "text/plain" where text == nil: text = decoded
        case "text/html" where html == nil: html = decoded
        default: break
        }
      }
      p.parts?.forEach(walk)
    }
    if let part { walk(part) }
    return (text, html)
  }

  public static func attachments(of part: Gmail.Part?) -> [Attachment] {
    var result: [Attachment] = []
    func walk(_ p: Gmail.Part) {
      if let name = p.filename, !name.isEmpty {
        result.append(Attachment(filename: name, mimeType: p.mimeType ?? "application/octet-stream", size: p.body?.size ?? 0))
      }
      p.parts?.forEach(walk)
    }
    if let part { walk(part) }
    return result
  }

  public static func base64URLDecode(_ string: String) -> String? {
    var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    s += String(repeating: "=", count: (4 - s.count % 4) % 4)
    guard let data = Data(base64Encoded: s) else { return nil }
    return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
  }

  /// Parses an address header like `"Raman, Priya" <priya@x.com>, sam@y.com`.
  public static func addresses(_ header: String) -> [Address] {
    var result: [Address] = []
    var current = ""
    var inQuotes = false
    var inAngle = false
    for ch in header {
      switch ch {
      case "\"": inQuotes.toggle(); current.append(ch)
      case "<": inAngle = true; current.append(ch)
      case ">": inAngle = false; current.append(ch)
      case "," where !inQuotes && !inAngle:
        if let a = address(current) { result.append(a) }
        current = ""
      default: current.append(ch)
      }
    }
    if let a = address(current) { result.append(a) }
    return result
  }

  static func address(_ raw: String) -> Address? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
      let email = String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
      var name = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
      if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 {
        name = String(name.dropFirst().dropLast())
      }
      return Address(name: name.isEmpty ? nil : name, email: email)
    }
    return Address(email: trimmed)
  }

  /// Gmail snippets arrive HTML-escaped.
  public static func decodeEntities(_ s: String) -> String {
    var out = s
    for (entity, char) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "] {
      out = out.replacingOccurrences(of: entity, with: char)
    }
    return out
  }
}
