import CryptoKit
import Foundation
import Network

/// Google OAuth 2.0 for installed apps: system browser, PKCE, loopback redirect.
/// https://developers.google.com/identity/protocols/oauth2/native-app
public struct GoogleOAuth: Sendable {
  public static let scopes = [
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/gmail.send",
  ]

  public let clientID: String
  /// Google issues desktop clients a "secret" that is not confidential; it still stays out of the repo.
  public let clientSecret: String

  public init(clientID: String, clientSecret: String) {
    self.clientID = clientID
    self.clientSecret = clientSecret
  }

  public struct Tokens: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public var isExpired: Bool { expiresAt.timeIntervalSinceNow < 60 }
  }

  public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
      self.verifier = verifier
      challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func random() -> PKCE {
      var bytes = [UInt8](repeating: 0, count: 32)
      _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
      return PKCE(verifier: base64URL(Data(bytes)))
    }

    static func base64URL(_ data: Data) -> String {
      data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    }
  }

  public func authorizationURL(redirectURI: String, pkce: PKCE, state: String) -> URL {
    var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    c.queryItems = [
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
      URLQueryItem(name: "code_challenge", value: pkce.challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "access_type", value: "offline"),
      URLQueryItem(name: "prompt", value: "consent"),
    ]
    return c.url!
  }

  /// Runs the whole sign-in: opens `openURL` with Google's consent page, waits for the redirect,
  /// exchanges the code for tokens.
  public func signIn(openURL: @Sendable (URL) async -> Void) async throws -> Tokens {
    let pkce = PKCE.random()
    let state = UUID().uuidString
    let server = try await LoopbackServer.start()
    defer { server.stop() }
    let redirectURI = "http://127.0.0.1:\(server.port)"
    await openURL(authorizationURL(redirectURI: redirectURI, pkce: pkce, state: state))
    let query = try await server.waitForRedirect()
    if let error = query["error"] { throw OAuthError.denied(error) }
    guard query["state"] == state else { throw OAuthError.stateMismatch }
    guard let code = query["code"] else { throw OAuthError.missingCode }
    return try await exchange(code: code, redirectURI: redirectURI, verifier: pkce.verifier)
  }

  public func refresh(_ tokens: Tokens) async throws -> Tokens {
    let response = try await tokenRequest([
      "client_id": clientID,
      "client_secret": clientSecret,
      "refresh_token": tokens.refreshToken,
      "grant_type": "refresh_token",
    ])
    return Tokens(
      accessToken: response.access_token,
      refreshToken: response.refresh_token ?? tokens.refreshToken,
      expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in)))
  }

  func exchange(code: String, redirectURI: String, verifier: String) async throws -> Tokens {
    let response = try await tokenRequest([
      "client_id": clientID,
      "client_secret": clientSecret,
      "code": code,
      "code_verifier": verifier,
      "redirect_uri": redirectURI,
      "grant_type": "authorization_code",
    ])
    guard let refresh = response.refresh_token else { throw OAuthError.missingRefreshToken }
    return Tokens(
      accessToken: response.access_token, refreshToken: refresh,
      expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in)))
  }

  private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int
  }

  private func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
    var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var body = URLComponents()
    body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
    request.httpBody = Data((body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw OAuthError.tokenEndpoint(String(decoding: data, as: UTF8.self))
    }
    return try JSONDecoder().decode(TokenResponse.self, from: data)
  }
}

public enum OAuthError: Error, LocalizedError {
  case denied(String)
  case stateMismatch
  case missingCode
  case missingRefreshToken
  case tokenEndpoint(String)
  case notSignedIn

  /// The refresh token was revoked or expired: only signing in again fixes it.
  public var needsSignIn: Bool {
    switch self {
    case .notSignedIn: true
    case .tokenEndpoint(let body): body.contains("invalid_grant")
    default: false
    }
  }

  public var errorDescription: String? {
    switch self {
    case .denied(let reason): "Google sign-in was cancelled (\(reason))."
    case .stateMismatch: "Sign-in response didn't match the request. Try again."
    case .missingCode: "Google didn't return an authorization code."
    case .missingRefreshToken: "Google didn't return a refresh token."
    case .tokenEndpoint(let body): "Google rejected the sign-in: \(body)"
    case .notSignedIn: "Not signed in."
    }
  }
}

/// Holds the account's tokens in the Keychain and hands out a fresh access token on demand.
public actor TokenStore {
  private let oauth: GoogleOAuth
  private let keychain: Keychain
  private let account: String
  private var tokens: GoogleOAuth.Tokens?

  public init(oauth: GoogleOAuth, keychain: Keychain, account: String) {
    self.oauth = oauth
    self.keychain = keychain
    self.account = account
    if let data = try? keychain.get(account) {
      tokens = try? JSONDecoder().decode(GoogleOAuth.Tokens.self, from: data)
    }
  }

  public var hasTokens: Bool { tokens != nil }

  public func save(_ new: GoogleOAuth.Tokens) throws {
    tokens = new
    try keychain.set(try JSONEncoder().encode(new), for: account)
  }

  public func accessToken() async throws -> String {
    guard var current = tokens else { throw OAuthError.notSignedIn }
    if current.isExpired {
      current = try await oauth.refresh(current)
      try save(current)
    }
    return current.accessToken
  }

  public func clear() throws {
    tokens = nil
    try keychain.delete(account)
  }
}

/// One-shot HTTP listener on 127.0.0.1 that catches Google's redirect.
final class LoopbackServer: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "raven.oauth.loopback")
  private let lock = NSLock()
  private var continuation: CheckedContinuation<[String: String], Error>?
  private var received: [String: String]?
  private(set) var port: UInt16 = 0

  private init(listener: NWListener) {
    self.listener = listener
  }

  static func start() async throws -> LoopbackServer {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let server = LoopbackServer(listener: try NWListener(using: parameters))
    try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
      let once = Once()
      server.listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          server.port = server.listener.port?.rawValue ?? 0
          once.run { ready.resume() }
        case .failed(let error):
          once.run { ready.resume(throwing: error) }
        default: break
        }
      }
      server.listener.newConnectionHandler = { server.handle($0) }
      server.listener.start(queue: server.queue)
    }
    return server
  }

  func waitForRedirect() async throws -> [String: String] {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { c in
        lock.lock()
        if let received {
          lock.unlock()
          c.resume(returning: received)
        } else if Task.isCancelled {
          lock.unlock()
          c.resume(throwing: CancellationError())
        } else {
          continuation = c
          lock.unlock()
        }
      }
    } onCancel: {
      lock.lock()
      let c = continuation
      continuation = nil
      lock.unlock()
      c?.resume(throwing: CancellationError())
    }
  }

  func stop() { listener.cancel() }

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
      guard let self else { return }
      let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
      // "GET /?code=...&state=... HTTP/1.1"
      let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
      let items = URLComponents(string: "http://127.0.0.1\(target)")?.queryItems ?? []
      let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
      let isRedirect = query["code"] != nil || query["error"] != nil
      let page = isRedirect
        ? "<html><body style=\"font:16px -apple-system;padding:48px\">Signed in. You can close this tab and return to Raven.</body></html>"
        : "<html><body></body></html>"
      let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
      connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
      guard isRedirect else { return }
      self.lock.lock()
      let c = self.continuation
      self.continuation = nil
      if c == nil { self.received = query }
      self.lock.unlock()
      c?.resume(returning: query)
    }
  }
}

private final class Once: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false
  func run(_ body: () -> Void) {
    lock.lock()
    defer { lock.unlock() }
    guard !done else { return }
    done = true
    body()
  }
}
