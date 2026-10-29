import Foundation
import XCTest

@testable import RavenCore

final class MIMETests: XCTestCase {
  func testParsesQuotedNamesWithCommas() {
    let parsed = MIME.addresses(#""Raman, Priya" <priya@example.com>, sam@example.com, Dana <dana@example.com>"#)
    XCTAssertEqual(parsed, [
      Address(name: "Raman, Priya", email: "priya@example.com"),
      Address(email: "sam@example.com"),
      Address(name: "Dana", email: "dana@example.com"),
    ])
  }

  func testDecodesBase64URLBodiesFromNestedParts() {
    let text = Data("héllo + world/?".utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    let json = """
      {"mimeType":"multipart/mixed","parts":[
        {"mimeType":"multipart/alternative","parts":[
          {"mimeType":"text/plain","body":{"data":"\(text)"}},
          {"mimeType":"text/html","body":{"data":"PGI-aGk8L2I-"}}]},
        {"mimeType":"text/plain","filename":"notes.txt","body":{"attachmentId":"a1"}}]}
      """
    let part = try! JSONDecoder().decode(Gmail.Part.self, from: Data(json.utf8))
    let bodies = MIME.bodies(of: part)
    XCTAssertEqual(bodies.text, "héllo + world/?")
    XCTAssertEqual(bodies.html, "<b>hi</b>")
  }

  func testConvertsGmailMessage() throws {
    let json = """
      {"id":"m1","threadId":"t1","labelIds":["INBOX","UNREAD"],"snippet":"Fish &amp; chips","internalDate":"1700000000000",
       "payload":{"mimeType":"text/plain","headers":[
         {"name":"From","value":"Priya Raman <priya@example.com>"},{"name":"Subject","value":"Lunch"},
         {"name":"List-Id","value":"<news.example>"}],"body":{"data":"aGk"}}}
      """
    let m = Message(gmail: try JSONDecoder().decode(Gmail.GMessage.self, from: Data(json.utf8)))
    XCTAssertEqual(m.from.displayName, "Priya Raman")
    XCTAssertEqual(m.snippet, "Fish & chips")
    XCTAssertEqual(m.bodyText, "hi")
    XCTAssertEqual(m.date, Date(timeIntervalSince1970: 1_700_000_000))
    XCTAssertTrue(m.isUnread)
    XCTAssertEqual(m.listID, "<news.example>")
  }
}

final class OAuthTests: XCTestCase {
  /// RFC 7636 appendix B test vector.
  func testPKCEChallenge() {
    let pkce = GoogleOAuth.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  }

  func testAuthorizationURLRequestsOfflinePKCE() {
    let oauth = GoogleOAuth(clientID: "abc.apps.googleusercontent.com", clientSecret: "x")
    let url = oauth.authorizationURL(redirectURI: "http://127.0.0.1:5000", pkce: .random(), state: "s")
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
    let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    XCTAssertEqual(query["code_challenge_method"], "S256")
    XCTAssertEqual(query["access_type"], "offline")
    XCTAssertEqual(query["redirect_uri"], "http://127.0.0.1:5000")
    XCTAssertTrue(query["scope"]!.contains("gmail.modify"))
  }

  func testLoopbackServerReturnsRedirectQuery() async throws {
    let server = try await LoopbackServer.start()
    defer { server.stop() }
    XCTAssertGreaterThan(server.port, 0)
    async let query = server.waitForRedirect()
    let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(server.port)/?code=42&state=abc")!)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    let result = try await query
    XCTAssertEqual(result["code"], "42")
    XCTAssertEqual(result["state"], "abc")
  }
}

final class MailStoreTests: XCTestCase {
  func testInboxSplitAndSearch() async throws {
    let store = try MailStore(url: nil)
    try await store.upsert(SampleMail.messages())
    let inbox = try await store.threads(in: .inbox)
    XCTAssertEqual(inbox.count, 9)
    XCTAssertEqual(inbox.first?.id, "t1", "newest first")
    XCTAssertEqual(inbox.first?.messageCount, 2)
    XCTAssertEqual(inbox.first?.subject, "Q4 roadmap review", "thread subject comes from the first message")

    let tabs = Dictionary(grouping: inbox, by: InboxTab.classify)
    XCTAssertEqual(tabs[.newsletters]?.map(\.id), ["t8"])
    XCTAssertEqual(Set(tabs[.updates]?.map(\.id) ?? []), ["t6", "t9"])

    let hits = try await store.search("headcount")
    XCTAssertEqual(hits.map(\.id), ["t1"])
    let prefix = try await store.search("itin")
    XCTAssertEqual(prefix.map(\.id), ["t6"])
    let counts = try await store.counts()
    XCTAssertEqual(counts[.inbox], 5)
  }

  func testArchiveSnoozeAndUndo() async throws {
    let store = try MailStore(url: nil)
    try await store.upsert(SampleMail.messages())

    try await store.apply(.archive(threadID: "t2"))
    var inboxIDs = try await store.threads(in: .inbox).map(\.id)
    XCTAssertFalse(inboxIDs.contains("t2"))
    let done = try await store.threads(in: .done).map(\.id)
    XCTAssertEqual(done, ["t2"])

    try await store.apply(MailAction.archive(threadID: "t2").inverse)
    inboxIDs = try await store.threads(in: .inbox).map(\.id)
    XCTAssertTrue(inboxIDs.contains("t2"))

    try await store.apply(.snooze(threadID: "t3", until: Date().addingTimeInterval(-1)))
    let snoozed = try await store.threads(in: .snoozed).map(\.id)
    XCTAssertEqual(snoozed, ["t3"])
    let due = try await store.dueSnoozes()
    XCTAssertEqual(due, ["t3"])
  }

  func testPersistsToDisk() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("raven-\(UUID()).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    do {
      let store = try MailStore(url: url)
      try await store.upsert(SampleMail.messages())
      try await store.setMeta("historyId", "99")
    }
    let reopened = try MailStore(url: url)
    let count = try await reopened.threads(in: .inbox).count
    XCTAssertEqual(count, 9)
    let history = try await reopened.meta("historyId")
    XCTAssertEqual(history, "99")
  }
}

/// In-memory Gmail double that records modify calls.
actor FakeGmail: GmailAPI {
  var threads: [String: Gmail.Thread] = [:]
  var historyID = "100"
  var history: Gmail.HistoryList?
  var historyExpired = false
  var modifications: [(String, Set<String>, Set<String>)] = []
  var failNextModify: GmailError?

  func set(_ thread: Gmail.Thread) { threads[thread.id] = thread }
  func setHistory(_ list: Gmail.HistoryList?, expired: Bool = false) {
    history = list
    historyExpired = expired
  }
  func failNext(_ error: GmailError) { failNextModify = error }

  func profile() async throws -> Gmail.Profile {
    try JSONDecoder().decode(Gmail.Profile.self, from: Data(#"{"emailAddress":"you@example.com","historyId":"\#(historyID)"}"#.utf8))
  }

  func listThreads(query: String, pageToken: String?, maxResults: Int) async throws -> Gmail.ThreadList {
    let items = threads.keys.sorted().map { #"{"id":"\#($0)"}"# }.joined(separator: ",")
    return try JSONDecoder().decode(Gmail.ThreadList.self, from: Data(#"{"threads":[\#(items)]}"#.utf8))
  }

  func thread(id: String) async throws -> Gmail.Thread {
    guard let t = threads[id] else { throw GmailError.http(status: 404, body: "") }
    return t
  }

  func history(startHistoryID: String, pageToken: String?) async throws -> Gmail.HistoryList {
    if historyExpired { throw GmailError.historyExpired }
    if let history { return history }
    return try JSONDecoder().decode(Gmail.HistoryList.self, from: Data(#"{"historyId":"\#(historyID)"}"#.utf8))
  }

  var sentRaw: [String] = []

  func send(raw: String, threadID: String?) async throws -> Gmail.SentMessage {
    sentRaw.append(raw)
    return try JSONDecoder().decode(Gmail.SentMessage.self, from: Data(#"{"id":"s1","threadId":"\#(threadID ?? "new")"}"#.utf8))
  }

  func modifyThread(id: String, add: Set<String>, remove: Set<String>) async throws {
    if let error = failNextModify {
      failNextModify = nil
      throw error
    }
    modifications.append((id, add, remove))
  }
}

final class SyncEngineTests: XCTestCase {
  static func thread(_ id: String, subject: String, labels: [String]) throws -> Gmail.Thread {
    let labelJSON = labels.map { "\"\($0)\"" }.joined(separator: ",")
    let json = """
      {"id":"\(id)","messages":[{"id":"\(id)-m","threadId":"\(id)","labelIds":[\(labelJSON)],"snippet":"s",
        "internalDate":"1700000000000","payload":{"mimeType":"text/plain",
        "headers":[{"name":"From","value":"A <a@example.com>"},{"name":"Subject","value":"\(subject)"}]}}]}
      """
    return try JSONDecoder().decode(Gmail.Thread.self, from: Data(json.utf8))
  }

  func testFullThenIncrementalSync() async throws {
    let gmail = FakeGmail()
    await gmail.set(try Self.thread("a", subject: "Hello", labels: ["INBOX", "UNREAD"]))
    await gmail.set(try Self.thread("b", subject: "World", labels: ["INBOX"]))
    let store = try MailStore(url: nil)
    let engine = SyncEngine(store: store, api: gmail)

    try await engine.sync()
    var inbox = try await store.threads(in: .inbox).map(\.subject).sorted()
    XCTAssertEqual(inbox, ["Hello", "World"])
    let account = try await store.meta("account")
    XCTAssertEqual(account, "you@example.com")

    // A label change arrives through history: "a" was archived elsewhere.
    let history = try JSONDecoder().decode(Gmail.HistoryList.self, from: Data("""
      {"historyId":"101","history":[{"id":"101","labelsRemoved":[{"message":{"id":"a-m","threadId":"a","labelIds":["UNREAD"]}}]}]}
      """.utf8))
    await gmail.setHistory(history)
    try await engine.sync()
    inbox = try await store.threads(in: .inbox).map(\.subject)
    XCTAssertEqual(inbox, ["World"])
    let historyID = try await store.meta("historyId")
    XCTAssertEqual(historyID, "101")
  }

  func testExpiredHistoryFallsBackToFullSync() async throws {
    let gmail = FakeGmail()
    await gmail.set(try Self.thread("a", subject: "Hello", labels: ["INBOX"]))
    let store = try MailStore(url: nil)
    try await store.setMeta("historyId", "1")
    await gmail.setHistory(nil, expired: true)
    try await SyncEngine(store: store, api: gmail).sync()
    let count = try await store.threads(in: .inbox).count
    XCTAssertEqual(count, 1)
  }

  func testActionsApplyLocallyAndRetryAfterTransientFailure() async throws {
    let gmail = FakeGmail()
    await gmail.set(try Self.thread("a", subject: "Hello", labels: ["INBOX"]))
    let store = try MailStore(url: nil)
    let engine = SyncEngine(store: store, api: gmail)
    try await engine.sync()

    await gmail.failNext(.http(status: 503, body: "busy"))
    try await store.apply(.archive(threadID: "a"))
    try await store.enqueue(.archive(threadID: "a"))
    try await engine.flushOutbox()
    let inbox = try await store.threads(in: .inbox)
    XCTAssertTrue(inbox.isEmpty, "local change is immediate")
    var pending = try await store.pendingActions()
    XCTAssertEqual(pending.count, 1, "kept for retry")
    XCTAssertEqual(pending.first?.attempts, 1)

    try await engine.flushOutbox()
    pending = try await store.pendingActions()
    XCTAssertTrue(pending.isEmpty)
    let sent = await gmail.modifications
    XCTAssertEqual(sent.count, 1)
    XCTAssertEqual(sent.first?.0, "a")
    XCTAssertEqual(sent.first?.2, ["INBOX"])
  }
}

final class ComposeTests: XCTestCase {
  let me = Address(name: "You", email: "you@example.com")

  func decode(_ raw: String) -> String {
    MIME.base64URLDecode(raw) ?? ""
  }

  func testReplyAllThreadsAndSkipsMe() {
    let original = Message(
      id: "m", threadID: "t", from: Address(name: "Priya", email: "priya@example.com"),
      to: [me, Address(email: "marcus@example.com")], cc: [Address(email: "PRIYA@example.com"), Address(email: "dana@example.com")],
      date: Date(), subject: "Q4 review", snippet: "", bodyText: "Line one\nLine two",
      messageIDHeader: "<a@mail>", references: "<root@mail>")
    let draft = Draft.reply(to: original, all: true, me: "you@example.com")
    XCTAssertEqual(draft.to.map(\.email), ["priya@example.com"])
    XCTAssertEqual(draft.cc.map(\.email), ["marcus@example.com", "dana@example.com"])
    XCTAssertEqual(draft.subject, "Re: Q4 review")
    XCTAssertEqual(draft.inReplyTo, "<a@mail>")
    XCTAssertEqual(draft.references, "<root@mail> <a@mail>")
    XCTAssertEqual(Draft.reply(to: Message(id: "x", threadID: "t", from: me, date: Date(), subject: "Re: Hi", snippet: ""), all: false, me: me.email).subject, "Re: Hi")
  }

  func testComposeBuildsValidMessage() {
    var draft = Draft(to: [Address(name: "Okafor, Dana", email: "dana@example.com")], subject: "Café ☕", body: "Hi Dana,\nSee you there.")
    draft.inReplyTo = "<a@mail>"
    let raw = decode(MIME.compose(draft, from: me, date: Date(timeIntervalSince1970: 0)))
    XCTAssertTrue(raw.contains("To: \"Okafor, Dana\" <dana@example.com>\r\n"))
    XCTAssertTrue(raw.contains("Subject: =?UTF-8?B?\(Data("Café ☕".utf8).base64EncodedString())?=\r\n"))
    XCTAssertTrue(raw.contains("In-Reply-To: <a@mail>\r\n"))
    let body = raw.components(separatedBy: "\r\n\r\n")[1].replacingOccurrences(of: "\r\n", with: "")
    XCTAssertEqual(String(data: Data(base64Encoded: body)!, encoding: .utf8), "Hi Dana,\r\nSee you there.")
  }

  func testForwardQuotesOriginal() {
    let original = Message(id: "m", threadID: "t", from: Address(name: "Sam", email: "sam@example.com"), date: Date(), subject: "Coffee", snippet: "", bodyText: "Tuesday?")
    let draft = Draft.forward(original)
    XCTAssertEqual(draft.subject, "Fwd: Coffee")
    XCTAssertNil(draft.threadID)
    XCTAssertTrue(MIME.quotedBlock(for: original, forwarding: true).contains("Tuesday?"))
    XCTAssertFalse(Draft(to: [Address(email: "not-an-address")]).canSend)
  }

  func testSendGoesThroughEngine() async throws {
    let gmail = FakeGmail()
    await gmail.set(try SyncEngineTests.thread("t", subject: "Hello", labels: ["INBOX"]))
    let engine = SyncEngine(store: try MailStore(url: nil), api: gmail)
    try await engine.send(Draft(to: [Address(email: "a@example.com")], subject: "Re: Hello", body: "Yes", threadID: "t"), from: me)
    let sent = await gmail.sentRaw
    XCTAssertEqual(sent.count, 1)
    XCTAssertTrue(decode(sent[0]).contains("Subject: Re: Hello"))
  }
}
