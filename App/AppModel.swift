import AppKit
import Observation
import RavenCore
import SwiftUI

@MainActor
@Observable
final class AppModel {
  enum Phase: Equatable {
    case launching
    case signedOut
    case signingIn
    case ready
  }

  struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let undo: [MailAction]
  }

  private(set) var phase: Phase = .launching
  private(set) var isDemo = false
  private(set) var account: String?
  private(set) var isSyncing = false
  var errorMessage: String?

  var mailbox: Mailbox = .inbox { didSet { Task { await reload() } } }
  var tab: InboxTab = .important
  private(set) var threads: [MailThread] = []
  private(set) var counts: [Mailbox: Int] = [:]
  var selectedID: String?
  private(set) var openThread: MailThread?
  private(set) var openMessages: [Message] = []

  var searchText = "" { didSet { Task { await reload() } } }
  var isPaletteOpen = false
  var isSnoozePickerOpen = false
  private(set) var toast: Toast?

  private var store: MailStore?
  private var engine: SyncEngine?
  private var tokens: TokenStore?
  private var syncLoop: Task<Void, Never>?
  private var undoStack: [[MailAction]] = []

  let oauth: GoogleOAuth? = {
    let info = Bundle.main.infoDictionary ?? [:]
    let id = (info["GoogleClientID"] as? String ?? "").trimmingCharacters(in: .whitespaces)
    let secret = (info["GoogleClientSecret"] as? String ?? "").trimmingCharacters(in: .whitespaces)
    guard !id.isEmpty, !id.hasPrefix("YOUR_"), !id.contains("$(") else { return nil }
    return GoogleOAuth(clientID: id, clientSecret: secret)
  }()

  private let keychain = Keychain(service: "dev.raven.Raven")

  // MARK: Derived state

  /// The threads on screen: search results, the current split-inbox tab, or the mailbox.
  var visibleThreads: [MailThread] {
    if !searchText.isEmpty || mailbox != .inbox { return threads }
    return threads.filter { InboxTab.classify($0) == tab }
  }

  func count(for tab: InboxTab) -> Int {
    threads.filter { InboxTab.classify($0) == tab && $0.isUnread }.count
  }

  var selectedThread: MailThread? { visibleThreads.first { $0.id == selectedID } }

  // MARK: Lifecycle

  func start() async {
    if CommandLine.arguments.contains("--demo") {
      await startDemo()
      return
    }
    guard let oauth else {
      phase = .signedOut
      return
    }
    let tokens = TokenStore(oauth: oauth, keychain: keychain, account: "google")
    guard await tokens.hasTokens else {
      phase = .signedOut
      return
    }
    await open(tokens: tokens)
  }

  func signIn() async {
    guard let oauth else { return }
    phase = .signingIn
    errorMessage = nil
    do {
      let new = try await oauth.signIn { url in
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
      }
      let tokens = TokenStore(oauth: oauth, keychain: keychain, account: "google")
      try await tokens.save(new)
      NSApp.activate(ignoringOtherApps: true)
      await open(tokens: tokens)
    } catch {
      errorMessage = error.localizedDescription
      phase = .signedOut
    }
  }

  func startDemo() async {
    do {
      let store = try MailStore(url: nil)
      try await store.upsert(SampleMail.messages())
      self.store = store
      isDemo = true
      account = "Sample mailbox"
      phase = .ready
      await reload()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func signOut() async {
    syncLoop?.cancel()
    try? await tokens?.clear()
    if let url = Self.databaseURL { try? FileManager.default.removeItem(at: url) }
    store = nil
    engine = nil
    tokens = nil
    threads = []
    openThread = nil
    isDemo = false
    account = nil
    phase = .signedOut
  }

  private static var databaseURL: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Raven/mail.sqlite")
  }

  private func open(tokens: TokenStore) async {
    do {
      let store = try MailStore(url: Self.databaseURL)
      self.store = store
      self.tokens = tokens
      engine = SyncEngine(store: store, api: GmailClient(tokens: tokens))
      account = try await store.meta("account")
      phase = .ready
      await reload()
      startSyncLoop()
    } catch {
      errorMessage = error.localizedDescription
      phase = .signedOut
    }
  }

  private func startSyncLoop() {
    syncLoop?.cancel()
    syncLoop = Task { [weak self] in
      while !Task.isCancelled {
        await self?.syncNow()
        try? await Task.sleep(for: .seconds(45))
      }
    }
  }

  func syncNow() async {
    guard let engine, !isSyncing else { return }
    isSyncing = true
    defer { isSyncing = false }
    do {
      try await engine.sync()
      account = try await store?.meta("account")
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
    }
    await reload()
  }

  func reload() async {
    guard let store else { return }
    do {
      threads = searchText.isEmpty
        ? try await store.threads(in: mailbox)
        : try await store.search(searchText)
      counts = try await store.counts()
      if selectedID == nil || !visibleThreads.contains(where: { $0.id == selectedID }) {
        selectedID = visibleThreads.first?.id
      }
      if let open = openThread {
        openThread = try await store.thread(id: open.id)
        openMessages = try await store.messages(threadID: open.id)
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  // MARK: Navigation

  func moveSelection(_ delta: Int) {
    let list = visibleThreads
    guard !list.isEmpty else { return }
    let current = list.firstIndex { $0.id == selectedID } ?? -1
    let next = max(0, min(list.count - 1, current + delta))
    selectedID = list[next].id
    if openThread != nil { Task { await openSelected() } }
  }

  func select(tab: InboxTab) {
    self.tab = tab
    selectedID = visibleThreads.first?.id
  }

  func openSelected() async {
    guard let thread = selectedThread, let store else { return }
    openThread = thread
    openMessages = (try? await store.messages(threadID: thread.id)) ?? []
    if thread.isUnread { await perform([.markRead(threadID: thread.id)], toast: nil) }
  }

  func closeThread() {
    openThread = nil
    openMessages = []
  }

  // MARK: Actions

  /// Archive/trash/snooze the open thread, or the selected one in the list.
  private var targetIDs: [String] {
    if let openThread { return [openThread.id] }
    return selectedID.map { [$0] } ?? []
  }

  func archive() async {
    let ids = targetIDs
    guard !ids.isEmpty else { return }
    await advanceAfter { await perform(ids.map { .archive(threadID: $0) }, toast: "Marked done") }
  }

  func trash() async {
    let ids = targetIDs
    guard !ids.isEmpty else { return }
    await advanceAfter { await perform(ids.map { .trash(threadID: $0) }, toast: "Moved to Trash") }
  }

  func toggleRead() async {
    guard let thread = openThread ?? selectedThread else { return }
    let action: MailAction = thread.isUnread ? .markRead(threadID: thread.id) : .markUnread(threadID: thread.id)
    await perform([action], toast: nil)
  }

  func snooze(until date: Date, label: String) async {
    let ids = targetIDs
    isSnoozePickerOpen = false
    guard !ids.isEmpty else { return }
    await advanceAfter { await perform(ids.map { .snooze(threadID: $0, until: date) }, toast: "Snoozed until \(label)") }
  }

  func undo() async {
    guard let last = undoStack.popLast() else { return }
    await perform(last.reversed().map(\.inverse), toast: nil, recordUndo: false)
    toast = nil
  }

  /// Keeps the list position after the current thread leaves it, like moving to the next email.
  private func advanceAfter(_ body: () async -> Void) async {
    let list = visibleThreads
    let index = list.firstIndex { $0.id == selectedID }
    let wasOpen = openThread != nil
    await body()
    let remaining = visibleThreads
    if let index, !remaining.isEmpty {
      selectedID = remaining[min(index, remaining.count - 1)].id
    }
    if wasOpen {
      if remaining.isEmpty { closeThread() } else { await openSelected() }
    }
  }

  private func perform(_ actions: [MailAction], toast text: String?, recordUndo: Bool = true) async {
    guard let store else { return }
    do {
      for action in actions {
        if let engine {
          try await engine.perform(action)
        } else {
          try await store.apply(action)  // Demo mode: local only.
        }
      }
      if recordUndo, text != nil { undoStack.append(actions) }
      if let text { show(Toast(text: text, undo: actions)) }
    } catch {
      errorMessage = error.localizedDescription
    }
    await reload()
  }

  private func show(_ toast: Toast) {
    self.toast = toast
    Task {
      try? await Task.sleep(for: .seconds(5))
      if self.toast == toast { self.toast = nil }
    }
  }
}

enum SnoozeOption: CaseIterable, Identifiable {
  case laterToday, tomorrow, weekend, nextWeek

  var id: Self { self }

  var title: String {
    switch self {
    case .laterToday: "Later today"
    case .tomorrow: "Tomorrow"
    case .weekend: "This weekend"
    case .nextWeek: "Next week"
    }
  }

  var shortcut: String {
    switch self {
    case .laterToday: "1"
    case .tomorrow: "2"
    case .weekend: "3"
    case .nextWeek: "4"
    }
  }

  func date(from now: Date = Date(), calendar: Calendar = .current) -> Date {
    func at(_ hour: Int, daysAhead: Int) -> Date {
      let day = calendar.date(byAdding: .day, value: daysAhead, to: now) ?? now
      return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }
    switch self {
    case .laterToday:
      return now.addingTimeInterval(3 * 3600)
    case .tomorrow:
      return at(8, daysAhead: 1)
    case .weekend:
      let weekday = calendar.component(.weekday, from: now)  // 1 = Sunday, 7 = Saturday
      return at(9, daysAhead: weekday == 7 ? 7 : 7 - weekday)
    case .nextWeek:
      let weekday = calendar.component(.weekday, from: now)
      return at(8, daysAhead: (9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7)
    }
  }

  func detail(from now: Date = Date()) -> String {
    date(from: now).formatted(.dateTime.weekday(.abbreviated).hour().minute())
  }
}
