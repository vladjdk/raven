import Foundation

/// An email being written. Replies carry the thread and headers that keep them threaded.
public struct Draft: Hashable, Sendable, Identifiable {
  public enum Kind: Hashable, Sendable {
    case new, reply, replyAll, forward
  }

  public var id = UUID()
  public var kind: Kind
  public var to: [Address]
  public var cc: [Address]
  public var subject: String
  public var body: String
  public var threadID: String?
  public var inReplyTo: String?
  public var references: String?
  /// The message being replied to or forwarded, shown quoted below the editor.
  public var quoted: Message?

  public init(
    kind: Kind = .new, to: [Address] = [], cc: [Address] = [], subject: String = "", body: String = "",
    threadID: String? = nil, inReplyTo: String? = nil, references: String? = nil, quoted: Message? = nil
  ) {
    self.kind = kind
    self.to = to
    self.cc = cc
    self.subject = subject
    self.body = body
    self.threadID = threadID
    self.inReplyTo = inReplyTo
    self.references = references
    self.quoted = quoted
  }

  public var isEmpty: Bool {
    to.isEmpty && cc.isEmpty && subject.isEmpty && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  public var canSend: Bool { !(to + cc).isEmpty && (to + cc).allSatisfy(\.looksValid) }

  /// Reply (or reply-all) to `message`. `me` is the signed-in address, left out of reply-all.
  public static func reply(to message: Message, all: Bool, me: String?) -> Draft {
    let mine = me?.lowercased()
    let sender = message.from
    // Replying to your own message goes back to the people you sent it to.
    let isFromMe = sender.email.lowercased() == mine
    let to = isFromMe ? message.to : [sender]
    var cc: [Address] = []
    if all {
      let others = (isFromMe ? message.cc : message.to + message.cc).filter { $0.email.lowercased() != mine }
      cc = others.filter { other in !to.contains { $0.email.lowercased() == other.email.lowercased() } }
    }
    return Draft(
      kind: all ? .replyAll : .reply, to: to, cc: dedupe(cc),
      subject: prefixed("Re:", message.subject), threadID: message.threadID,
      inReplyTo: message.messageIDHeader,
      references: [message.references, message.messageIDHeader].compactMap { $0 }.joined(separator: " "),
      quoted: message)
  }

  public static func forward(_ message: Message) -> Draft {
    Draft(kind: .forward, subject: prefixed("Fwd:", message.subject), quoted: message)
  }

  static func prefixed(_ prefix: String, _ subject: String) -> String {
    subject.lowercased().hasPrefix(prefix.lowercased()) ? subject : "\(prefix) \(subject)"
  }

  static func dedupe(_ list: [Address]) -> [Address] {
    var seen = Set<String>()
    return list.filter { seen.insert($0.email.lowercased()).inserted }
  }
}

extension Address {
  var looksValid: Bool {
    let parts = email.split(separator: "@")
    return parts.count == 2 && parts[1].contains(".") && !email.contains(" ")
  }

  /// `"Priya Raman" <priya@example.com>`, with the name RFC 2047-encoded when needed.
  var headerValue: String {
    guard let name, !name.isEmpty else { return email }
    return "\(MIME.encodeHeaderWord(name, quoteIfASCII: true)) <\(email)>"
  }
}

extension MIME {
  /// Builds the RFC 822 message Gmail's send endpoint takes, base64url-encoded.
  public static func compose(_ draft: Draft, from: Address, date: Date = Date()) -> String {
    var text = draft.body
    if let quoted = draft.quoted {
      text += "\n\n" + quotedBlock(for: quoted, forwarding: draft.kind == .forward)
    }
    var headers = [
      "From: \(from.headerValue)",
      "To: \(draft.to.map(\.headerValue).joined(separator: ", "))",
    ]
    if !draft.cc.isEmpty { headers.append("Cc: \(draft.cc.map(\.headerValue).joined(separator: ", "))") }
    headers += [
      "Subject: \(encodeHeaderWord(draft.subject, quoteIfASCII: false))",
      "Date: \(rfc822Date(date))",
      "MIME-Version: 1.0",
    ]
    if let inReplyTo = draft.inReplyTo { headers.append("In-Reply-To: \(inReplyTo)") }
    if let references = draft.references, !references.isEmpty { headers.append("References: \(references)") }
    headers += [
      "Content-Type: text/plain; charset=UTF-8",
      "Content-Transfer-Encoding: base64",
    ]
    let body = Data(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8)
      .base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    let message = headers.joined(separator: "\r\n") + "\r\n\r\n" + body + "\r\n"
    return Data(message.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public static func quotedBlock(for message: Message, forwarding: Bool) -> String {
    let when = message.date.formatted(date: .abbreviated, time: .shortened)
    let original = message.bodyText ?? message.snippet
    if forwarding {
      return """
        ---------- Forwarded message ----------
        From: \(message.from.headerValue)
        Date: \(when)
        Subject: \(message.subject)
        To: \(message.to.map(\.headerValue).joined(separator: ", "))

        \(original)
        """
    }
    let quoted = original.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
    return "On \(when), \(message.from.displayName) wrote:\n\(quoted)"
  }

  /// RFC 2047 encoded-word for non-ASCII header text.
  static func encodeHeaderWord(_ text: String, quoteIfASCII: Bool) -> String {
    if text.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 }) {
      guard quoteIfASCII, text.contains(where: { ",;<>@\"()[]:".contains($0) }) else { return text }
      return "\"" + text.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    return "=?UTF-8?B?\(Data(text.utf8).base64EncodedString())?="
  }

  static func rfc822Date(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    return f.string(from: date)
  }
}
