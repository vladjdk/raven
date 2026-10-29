import Foundation

/// The Gmail calls the sync engine needs. `GmailClient` talks to Google; tests use a fake.
public protocol GmailAPI: Sendable {
  func profile() async throws -> Gmail.Profile
  func listThreads(query: String, pageToken: String?, maxResults: Int) async throws -> Gmail.ThreadList
  func thread(id: String) async throws -> Gmail.Thread
  func history(startHistoryID: String, pageToken: String?) async throws -> Gmail.HistoryList
  func modifyThread(id: String, add: Set<String>, remove: Set<String>) async throws
  /// Sends a base64url-encoded RFC 822 message, optionally into an existing thread.
  func send(raw: String, threadID: String?) async throws -> Gmail.SentMessage
}

public enum GmailError: Error, LocalizedError {
  case http(status: Int, body: String)
  /// history.list returns 404 once the start id is too old; the caller must do a full sync.
  case historyExpired

  public var errorDescription: String? {
    switch self {
    case .http(let status, let body): "Gmail returned \(status): \(body.prefix(300))"
    case .historyExpired: "Gmail history expired; resyncing."
    }
  }

  /// Worth retrying later (rate limits, server trouble, no network).
  public var isTransient: Bool {
    if case .http(let status, let body) = self {
      return status == 429 || status >= 500 || (status == 403 && body.contains("ateLimitExceeded"))
    }
    return false
  }

  /// The token was rejected; the user needs to sign in again.
  public var isAuth: Bool {
    if case .http(401, _) = self { return true }
    return false
  }
}

public struct GmailClient: GmailAPI {
  private let tokens: TokenStore
  private let session: URLSession
  private let base = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!

  public init(tokens: TokenStore, session: URLSession = .shared) {
    self.tokens = tokens
    self.session = session
  }

  public func profile() async throws -> Gmail.Profile {
    try await get("profile")
  }

  public func listThreads(query: String, pageToken: String?, maxResults: Int) async throws -> Gmail.ThreadList {
    var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "maxResults", value: String(maxResults))]
    if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
    return try await get("threads", items)
  }

  public func thread(id: String) async throws -> Gmail.Thread {
    try await get("threads/\(id)", [URLQueryItem(name: "format", value: "full")])
  }

  public func history(startHistoryID: String, pageToken: String?) async throws -> Gmail.HistoryList {
    var items = [URLQueryItem(name: "startHistoryId", value: startHistoryID)]
    if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
    do {
      return try await get("history", items)
    } catch GmailError.http(404, _) {
      throw GmailError.historyExpired
    }
  }

  public func modifyThread(id: String, add: Set<String>, remove: Set<String>) async throws {
    struct Body: Encodable {
      let addLabelIds: [String]
      let removeLabelIds: [String]
    }
    let body = try JSONEncoder().encode(Body(addLabelIds: add.sorted(), removeLabelIds: remove.sorted()))
    let _: Gmail.Thread = try await send("threads/\(id)/modify", method: "POST", body: body)
  }

  public func send(raw: String, threadID: String?) async throws -> Gmail.SentMessage {
    struct Body: Encodable {
      let raw: String
      let threadId: String?
    }
    return try await send("messages/send", method: "POST", body: try JSONEncoder().encode(Body(raw: raw, threadId: threadID)))
  }

  private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
    try await send(path, method: "GET", query: query, body: nil)
  }

  private func send<T: Decodable>(
    _ path: String, method: String, query: [URLQueryItem] = [], body: Data?
  ) async throws -> T {
    var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    if !query.isEmpty { components.queryItems = query }
    var request = URLRequest(url: components.url!)
    request.httpMethod = method
    request.httpBody = body
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    request.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      throw GmailError.http(status: status, body: String(decoding: data, as: UTF8.self))
    }
    return try JSONDecoder().decode(T.self, from: data)
  }
}
