import Foundation

/// Keeps the local store in step with Gmail: a recent full sync first, then incremental
/// history syncs, with local actions pushed through the outbox.
public actor SyncEngine {
  public let store: MailStore
  private let api: GmailAPI
  private let initialQuery: String
  private let initialLimit: Int

  public init(store: MailStore, api: GmailAPI, initialQuery: String = "in:inbox OR newer_than:30d", initialLimit: Int = 300) {
    self.store = store
    self.api = api
    self.initialQuery = initialQuery
    self.initialLimit = initialLimit
  }

  /// One sync pass: push pending actions, wake snoozes, then pull changes.
  public func sync() async throws {
    try await flushOutbox()
    try await wakeSnoozes()
    defer { Task { try? await self.reapplyPending() } }
    if let historyID = try await store.meta("historyId") {
      do {
        try await incremental(from: historyID)
        return
      } catch GmailError.historyExpired {
        // Fall through to a full sync.
      }
    }
    try await fullSync()
  }

  /// A pull overwrites local labels with the server's. Actions still waiting in the outbox
  /// haven't reached the server yet, so apply them again on top.
  private func reapplyPending() async throws {
    for pending in try await store.pendingActions() {
      try await store.apply(pending.action)
    }
  }

  /// Applies an action locally right away, then queues it for the server.
  public func perform(_ action: MailAction) async throws {
    try await store.apply(action)
    guard action.touchesServer else { return }
    try await store.enqueue(action)
    Task { try? await self.flushOutbox() }
  }

  /// Sends a draft and pulls the sent message back into its thread.
  public func send(_ draft: Draft, from: Address) async throws {
    let sent = try await api.send(raw: MIME.compose(draft, from: from), threadID: draft.threadID)
    // It's sent. If pulling it back fails, the next sync picks it up; never report a sent mail as failed.
    try? await fetchThreads([sent.threadId])
  }

  public func fullSync() async throws {
    let profile = try await api.profile()
    try await store.setMeta("account", profile.emailAddress)
    var ids: [String] = []
    var page: String?
    repeat {
      let list = try await api.listThreads(query: initialQuery, pageToken: page, maxResults: min(100, initialLimit))
      ids += (list.threads ?? []).map(\.id)
      page = list.nextPageToken
    } while page != nil && ids.count < initialLimit
    try await fetchThreads(Array(ids.prefix(initialLimit)))
    // Record where we are only after the data is in, so a crash mid-sync redoes it.
    try await store.setMeta("historyId", profile.historyId)
  }

  func incremental(from start: String) async throws {
    var changedThreads = Set<String>()
    var deleted: [String] = []
    var latest = start
    var page: String?
    repeat {
      let list = try await api.history(startHistoryID: start, pageToken: page)
      for record in list.history ?? [] {
        for ref in record.messagesAdded ?? [] { changedThreads.insert(ref.message.threadId) }
        for ref in record.messagesDeleted ?? [] { deleted.append(ref.message.id) }
        for ref in (record.labelsAdded ?? []) + (record.labelsRemoved ?? []) {
          if let labels = ref.message.labelIds {
            try await store.setLabels(messageID: ref.message.id, labels: Set(labels))
          } else {
            changedThreads.insert(ref.message.threadId)
          }
        }
      }
      if let id = list.historyId { latest = id }
      page = list.nextPageToken
    } while page != nil
    if !deleted.isEmpty { try await store.deleteMessages(ids: deleted) }
    try await fetchThreads(Array(changedThreads))
    try await store.setMeta("historyId", latest)
  }

  /// Fetches threads a few at a time, which keeps well under Gmail's per-user rate limits.
  private func fetchThreads(_ ids: [String]) async throws {
    let api = self.api
    for batch in stride(from: 0, to: ids.count, by: 8).map({ Array(ids[$0..<min($0 + 8, ids.count)]) }) {
      let messages = try await withThrowingTaskGroup(of: [Message].self) { group in
        for id in batch {
          group.addTask {
            do {
              return (try await api.thread(id: id).messages ?? []).map(Message.init(gmail:))
            } catch GmailError.http(404, _) {
              return []  // Deleted between list and fetch.
            }
          }
        }
        return try await group.reduce(into: []) { $0 += $1 }
      }
      try await store.upsert(messages)
    }
  }

  private var isFlushing = false

  /// Sends queued actions to Gmail in order. Transient failures stay queued for the next pass.
  public func flushOutbox() async throws {
    // Actor methods can interleave at each await; one flush at a time keeps actions in order.
    guard !isFlushing else { return }
    isFlushing = true
    defer { isFlushing = false }
    for pending in try await store.pendingActions() {
      let (add, remove) = pending.action.labelChanges
      do {
        try await api.modifyThread(id: pending.action.threadID, add: add, remove: remove)
        try await store.completeAction(id: pending.id)
      } catch let error as GmailError where error.isTransient || error.isAuth {
        try await store.failAction(id: pending.id)
        if error.isAuth { throw error }
        return
      } catch is URLError {
        try await store.failAction(id: pending.id)
        return
      } catch let error as OAuthError {
        // Can't get a token (revoked, offline): keep everything queued and let the app re-auth.
        throw error
      } catch is CancellationError {
        return
      } catch {
        // A permanent error (e.g. the thread is gone): drop it rather than block the queue.
        try await store.completeAction(id: pending.id)
      }
    }
  }

  private func wakeSnoozes() async throws {
    for id in try await store.dueSnoozes() {
      try await perform(.unsnooze(threadID: id))
    }
  }
}
