import AppKit
import Observation
import RavenCore
import SwiftUI

/// One signed-in Gmail account: its own local database, tokens and sync engine.
@MainActor
@Observable
final class AccountSession {
  let email: String
  let store: MailStore
  fileprivate(set) var tokens: TokenStore
  fileprivate(set) var engine: SyncEngine
  fileprivate(set) var hasSyncedOnce: Bool
  fileprivate(set) var needsReauth = false
  fileprivate(set) var isSyncing = false
  /// Unread in the inbox, for the account switcher.
  fileprivate(set) var unread = 0

  fileprivate init(email: String, store: MailStore, tokens: TokenStore, hasSyncedOnce: Bool) {
    self.email = email
    self.store = store
    self.tokens = tokens
    self.engine = SyncEngine(store: store, api: GmailClient(tokens: tokens))
    self.hasSyncedOnce = hasSyncedOnce
  }

  fileprivate func use(_ tokens: TokenStore) {
    self.tokens = tokens
    engine = SyncEngine(store: store, api: GmailClient(tokens: tokens))
    needsReauth = false
  }
}

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
    enum Style: Equatable { case info, sending }
    let id = UUID()
    let text: String
    var style: Style = .info
    var canUndo = true
  }

  /// One step of history. Mail changes are stored as the exact actions that put things back.
  private enum UndoEntry {
    case mail(label: String, restore: [MailAction])
    case discardedDraft(Draft)
  }

  private(set) var phase: Phase = .launching
  /// Sample mail, used only by debug snapshot runs. The shipped app always starts at sign-in.
  private(set) var isDemo = false
  /// Every signed-in account, in the order they were added.
  private(set) var sessions: [AccountSession] = []
  private(set) var activeEmail: String?
  /// True while the browser is open to add another account.
  private(set) var isAddingAccount = false
  var errorMessage: String?

  var active: AccountSession? { sessions.first { $0.email == activeEmail } }
  var account: String? { isDemo ? "Sample mailbox" : activeEmail }
  var isSyncing: Bool { active?.isSyncing ?? false }
  var hasSyncedOnce: Bool { active?.hasSyncedOnce ?? isDemo }
  /// Google rejected this account's token; mail is still here but nothing syncs until you sign in again.
  var needsReauth: Bool { active?.needsReauth ?? false }

  private(set) var mailbox: Mailbox = .inbox
  private(set) var tab: InboxTab = .important
  private(set) var threads: [MailThread] = []
  private(set) var counts: [Mailbox: Int] = [:]
  var selectedID: String?
  private(set) var openThread: MailThread?
  private(set) var openMessages: [Message] = []
  /// Changes whenever the list's context (mailbox, tab, search) changes, so the list crossfades
  /// instead of animating every row.
  private(set) var listContext = UUID()

  var searchText = "" {
    didSet {
      guard oldValue != searchText else { return }
      searchTask?.cancel()
      searchTask = Task {
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        await reload(newContext: true)
      }
    }
  }
  var isPaletteOpen = false
  var isSnoozePickerOpen = false
  var isConfirmingSignOut = false
  /// Bumped to ask the inbox to focus its search field (⌘F).
  private(set) var searchFocusRequest = 0
  private(set) var toast: Toast?

  /// The email being written, if the composer is open.
  var draft: Draft?
  /// Drafts closed without sending, one per thread (or "new"), restored when that composer reopens.
  /// Kept per account so switching accounts doesn't lose them.
  private var keptDraftsByAccount: [String: [String: Draft]] = [:]
  private var keptDrafts: [String: Draft] {
    get { keptDraftsByAccount[activeKey] ?? [:] }
    set { keptDraftsByAccount[activeKey] = newValue }
  }

  private var demoStore: MailStore?
  private var store: MailStore? { active?.store ?? demoStore }
  private var engine: SyncEngine? { active?.engine }
  private var activeKey: String { activeEmail ?? "demo" }
  private var syncLoop: Task<Void, Never>?
  private var searchTask: Task<Void, Never>?
  private var signInTask: Task<Void, Never>?
  private var undoStacks: [String: [UndoEntry]] = [:]
  private var undoStack: [UndoEntry] {
    get { undoStacks[activeKey] ?? [] }
    set { undoStacks[activeKey] = newValue }
  }
  private var pendingSend: (draft: Draft, account: String, task: Task<Void, Never>, toastID: UUID)?
  /// While the agent runs, its changes collect here so one Undo reverts the whole request.
  private var actionGroup: [MailAction]?

  @ObservationIgnored lazy var assistant = Assistant(app: self)

  var mailStore: MailStore? { store }

  static let undoSendSeconds = 5.0

  let oauth: GoogleOAuth? = {
    let info = Bundle.main.infoDictionary ?? [:]
    let id = (info["GoogleClientID"] as? String ?? "").trimmingCharacters(in: .whitespaces)
    let secret = (info["GoogleClientSecret"] as? String ?? "").trimmingCharacters(in: .whitespaces)
    guard !id.isEmpty, !id.hasPrefix("YOUR_"), !id.contains("$(") else { return nil }
    return GoogleOAuth(clientID: id, clientSecret: secret)
  }()

  let keychain = Keychain(service: "dev.raven.Raven")

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

  var me: Address { Address(email: isDemo ? "you@example.com" : (account ?? "")) }

  /// First sync of a new account: show placeholders instead of an empty inbox.
  var isFirstSync: Bool { !isDemo && !hasSyncedOnce && threads.isEmpty }

  /// Show who a message is from when there's more than one account to send from.
  var showsFromAccount: Bool { sessions.count > 1 }

  var canUndo: Bool { !undoStack.isEmpty || pendingSend != nil }

  var undoTitle: String {
    if pendingSend != nil { return "Undo Send" }
    switch undoStack.last {
    case .mail(let label, _): return "Undo \(label)"
    case .discardedDraft: return "Undo Discard Draft"
    case nil: return "Undo"
    }
  }

  /// Where a thread lives right now, which decides what "E" does to it.
  func location(of thread: MailThread) -> Mailbox {
    if thread.labels.contains(Label.trash) { return .trash }
    if thread.snoozedUntil != nil { return .snoozed }
    if thread.labels.contains(Label.inbox) { return .inbox }
    return .done
  }

  /// The thread the next action applies to: the open one, else the selected one.
  var targetThread: MailThread? { openThread ?? selectedThread }

  /// Inline replies belong to the open thread; anything else floats over the window.
  var showsInlineComposer: Bool {
    guard let draft, draft.kind != .new, let openThread else { return false }
    return draft.threadID == openThread.id || (draft.kind == .forward && draft.quoted?.threadID == openThread.id)
  }

  // MARK: Lifecycle

  func start() async {
    guard let oauth else {
      phase = .signedOut
      return
    }
    for email in Self.savedAccounts {
      let tokens = TokenStore(oauth: oauth, keychain: keychain, account: Self.tokenKey(email))
      guard await tokens.hasTokens, let session = try? await makeSession(email: email, tokens: tokens) else { continue }
      sessions.append(session)
    }
    saveAccountList()
    guard let first = sessions.first else {
      phase = .signedOut
      return
    }
    let last = UserDefaults.standard.string(forKey: "activeAccount")
    activeEmail = sessions.contains { $0.email == last } ? last : first.email
    withAnimation(Motion.panel) { phase = .ready }
    await reload(newContext: true)
    startSyncLoop()
  }

  /// Signs in to Google. From the sign-in screen this is the first account; once signed in it adds
  /// another, or, when that account's sign-in expired, renews it.
  func signIn(as hint: String? = nil) {
    guard let oauth else { return }
    let wasReady = phase == .ready
    if wasReady {
      isAddingAccount = true
      show(Toast(text: "Continue in your browser", canUndo: false), for: 4)
    } else {
      phase = .signingIn
    }
    errorMessage = nil
    signInTask?.cancel()
    signInTask = Task {
      defer { isAddingAccount = false }
      do {
        let new = try await oauth.signIn(loginHint: hint) { url in
          await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
        // Tokens first, then ask Gmail whose they are, then file them under that address.
        let tokens = TokenStore(oauth: oauth, keychain: keychain, account: "google:pending")
        try await tokens.save(new)
        let email = try await GmailClient(tokens: tokens).profile().emailAddress.lowercased()
        try await tokens.rename(to: Self.tokenKey(email))
        NSApp.activate(ignoringOtherApps: true)
        if let existing = sessions.first(where: { $0.email == email }) {
          existing.use(tokens)
        } else {
          sessions.append(try await makeSession(email: email, tokens: tokens))
          saveAccountList()
        }
        if wasReady {
          await switchAccount(to: email)
          show(Toast(text: "Signed in as \(email)", canUndo: false), for: 2.5)
        } else {
          activeEmail = email
          UserDefaults.standard.set(email, forKey: "activeAccount")
          withAnimation(Motion.panel) { phase = .ready }
          await reload(newContext: true)
        }
        startSyncLoop()
      } catch is CancellationError {
        if !wasReady { phase = .signedOut }
      } catch {
        errorMessage = Self.describe(signInError: error)
        if !wasReady { phase = .signedOut }
      }
    }
  }

  func cancelSignIn() {
    signInTask?.cancel()
    signInTask = nil
    isAddingAccount = false
    if phase == .signingIn { phase = .signedOut }
  }

  private static func describe(signInError error: Error) -> String {
    if case OAuthError.denied = error { return "Sign-in was cancelled in the browser." }
    if let error = error as? GmailError, case .http(403, _) = error {
      return "Google didn't allow access to Gmail. Check that the Gmail API is enabled for this app."
    }
    return error.localizedDescription
  }

  /// Switches the window to another signed-in account. Each account keeps its own drafts and undo history.
  func switchAccount(to email: String) async {
    guard email != activeEmail, sessions.contains(where: { $0.email == email }), !assistant.isRunning else { return }
    if let current = draft { keep(current) }
    withAnimation(Motion.state) { draft = nil }
    closeThread()
    searchTask?.cancel()
    searchText = ""
    isPaletteOpen = false
    isSnoozePickerOpen = false
    assistant.reset()
    selectedID = nil
    mailbox = .inbox
    tab = .important
    activeEmail = email
    UserDefaults.standard.set(email, forKey: "activeAccount")
    errorMessage = nil
    await reload(newContext: true)
  }

  /// The next account in the list, for the keyboard switcher.
  func cycleAccount() async {
    guard sessions.count > 1, let index = sessions.firstIndex(where: { $0.email == activeEmail }) else { return }
    await switchAccount(to: sessions[(index + 1) % sessions.count].email)
  }

  #if DEBUG
    func showSignInForSnapshot() { phase = .signedOut }

    /// Sample mail for snapshot runs only. Real accounts are never loaded alongside it.
    func startDemo() async {
      precondition(sessions.isEmpty, "sample mail must never share a run with real accounts")
      do {
        let store = try MailStore(url: nil)
        try await store.upsert(SampleMail.messages())
        demoStore = store
        isDemo = true
        errorMessage = nil
        withAnimation(Motion.panel) { phase = .ready }
        await reload(newContext: true)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  #endif

  func requestSignOut() { isConfirmingSignOut = true }

  /// Signs out of the account on screen. Other accounts stay signed in.
  func signOut() async {
    await flushPendingSend()
    guard let session = active, !isDemo else {
      resetToSignedOut()
      return
    }
    try? await session.tokens.clear()
    Self.removeDatabase(for: session.email)
    sessions.removeAll { $0.email == session.email }
    undoStacks[session.email] = nil
    keptDraftsByAccount[session.email] = nil
    saveAccountList()
    if let next = sessions.first {
      await switchAccount(to: next.email)
      show(Toast(text: "Signed out of \(session.email)", canUndo: false), for: 2.5)
    } else {
      resetToSignedOut()
    }
  }

  private func resetToSignedOut() {
    syncLoop?.cancel()
    searchTask?.cancel()
    signInTask?.cancel()
    demoStore = nil
    sessions = []
    activeEmail = nil
    threads = []
    counts = [:]
    openThread = nil
    openMessages = []
    selectedID = nil
    draft = nil
    keptDraftsByAccount = [:]
    undoStacks = [:]
    actionGroup = nil
    toast = nil
    searchText = ""
    mailbox = .inbox
    tab = .important
    isPaletteOpen = false
    isSnoozePickerOpen = false
    errorMessage = nil
    assistant.reset()
    isDemo = false
    saveAccountList()
    withAnimation(Motion.panel) { phase = .signedOut }
  }

  // MARK: Accounts on disk

  private static var savedAccounts: [String] { UserDefaults.standard.stringArray(forKey: "accounts") ?? [] }

  private func saveAccountList() {
    UserDefaults.standard.set(sessions.map(\.email), forKey: "accounts")
  }

  private static func tokenKey(_ email: String) -> String { "google:\(email)" }

  /// Each account's mail lives in its own folder: Application Support/Raven/Accounts/<address>/.
  private static func accountFolder(_ email: String) -> URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Raven/Accounts", isDirectory: true)
      .appendingPathComponent(email, isDirectory: true)
  }

  private static func removeDatabase(for email: String) {
    guard let folder = accountFolder(email) else { return }
    try? FileManager.default.removeItem(at: folder)
  }

  private func makeSession(email: String, tokens: TokenStore) async throws -> AccountSession {
    guard let folder = Self.accountFolder(email) else { throw CocoaError(.fileNoSuchFile) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let store = try MailStore(url: folder.appendingPathComponent("mail.sqlite"))
    let synced = try await store.meta("historyId") != nil
    let session = AccountSession(email: email, store: store, tokens: tokens, hasSyncedOnce: synced)
    session.unread = (try? await store.counts()[.inbox]) ?? 0
    return session
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

  /// Syncs every account, the one on screen first.
  func syncNow() async {
    let ordered = sessions.sorted { a, _ in a.email == activeEmail }
    for session in ordered { await sync(session) }
  }

  private func sync(_ session: AccountSession) async {
    guard !session.isSyncing, !session.needsReauth else { return }
    session.isSyncing = true
    defer { session.isSyncing = false }
    let isActive = session.email == activeEmail
    do {
      try await session.engine.sync()
      session.hasSyncedOnce = true
      if isActive { errorMessage = nil }
    } catch is CancellationError {
    } catch let error as OAuthError where error.needsSignIn {
      reauthRequired(session)
    } catch let error as GmailError where error.isAuth {
      reauthRequired(session)
    } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
      if isActive { errorMessage = "You're offline. Changes will sync when you're back." }
    } catch {
      if isActive { errorMessage = error.localizedDescription }
    }
    session.unread = (try? await session.store.counts()[.inbox]) ?? session.unread
    if session.email == activeEmail { await reload() }
  }

  private func reauthRequired(_ session: AccountSession) {
    session.needsReauth = true
    if session.email == activeEmail {
      errorMessage = "Your Google sign-in expired. Your changes are saved and will sync after you sign in again."
    }
  }

  /// Reloads from the store. In-place changes (archive, read) animate per row;
  /// a new context (mailbox, tab, search) crossfades the whole list.
  func reload(newContext: Bool = false) async {
    guard let store else { return }
    do {
      let fresh = searchText.isEmpty
        ? try await store.threads(in: mailbox)
        : try await store.search(searchText)
      let newCounts = try await store.counts()
      active?.unread = newCounts[.inbox] ?? 0
      let apply = {
        self.threads = fresh
        self.counts = newCounts
        if self.selectedID == nil || !self.visibleThreads.contains(where: { $0.id == self.selectedID }) {
          self.selectedID = self.visibleThreads.first?.id
        }
      }
      if newContext {
        listContext = UUID()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, apply)
      } else if fresh.map(\.id) == threads.map(\.id) {
        apply()  // Same rows, new contents: no row motion.
      } else {
        withAnimation(Motion.state, apply)
      }
      if let open = openThread {
        if let updated = try await store.thread(id: open.id) { openThread = updated }
        openMessages = try await store.messages(threadID: open.id)
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  // MARK: Navigation

  func go(to box: Mailbox) {
    closeThread()
    searchTask?.cancel()
    if !searchText.isEmpty {
      searchText = ""
      searchTask?.cancel()
    }
    withAnimation(Motion.state) { mailbox = box }
    Task { await reload(newContext: true) }
  }

  func focusSearch() {
    closeThread()
    searchFocusRequest += 1
  }

  func moveSelection(_ delta: Int) {
    let list = visibleThreads
    guard !list.isEmpty else { return }
    let current = list.firstIndex { $0.id == selectedID } ?? -1
    let next = max(0, min(list.count - 1, current + delta))
    selectedID = list[next].id
    if openThread != nil { Task { await open(list[next]) } }
  }

  func select(tab: InboxTab) {
    guard tab != self.tab else { return }
    withAnimation(Motion.state) { self.tab = tab }
    listContext = UUID()
    selectedID = visibleThreads.first?.id
  }

  func openSelected() async {
    guard let thread = selectedThread else { return }
    await open(thread)
  }

  func open(_ thread: MailThread) async {
    guard let store else { return }
    selectedID = thread.id
    let messages = (try? await store.messages(threadID: thread.id)) ?? []
    withAnimation(Motion.panel) {
      openThread = thread
      openMessages = messages
    }
    if thread.isUnread { await perform([.markRead(threadID: thread.id)], label: nil) }
  }

  /// Opens a thread by id even if it isn't in the current list (search results, agent drafts).
  func open(threadID: String) async -> Bool {
    guard let store, let thread = try? await store.thread(id: threadID) else { return false }
    await open(thread)
    return true
  }

  func closeThread() {
    guard openThread != nil else { return }
    withAnimation(Motion.panel) {
      openThread = nil
      openMessages = []
    }
  }

  // MARK: Actions

  /// E: the obvious "I'm finished with this" for wherever the thread is.
  func primaryAction() async {
    guard let thread = targetThread else { return }
    switch location(of: thread) {
    case .inbox, .sent: await archive()
    case .done, .trash, .snoozed: await moveToInbox()
    }
  }

  func primaryActionTitle(for thread: MailThread?) -> (title: String, systemImage: String) {
    switch thread.map(location(of:)) {
    case .done, .trash: ("Move to Inbox", "tray.and.arrow.up")
    case .snoozed: ("Unsnooze", "tray.and.arrow.up")
    default: ("Mark done", "checkmark")
    }
  }

  func archive(_ id: String? = nil) async {
    guard let id = id ?? targetThread?.id else { return }
    await advanceAfter { await perform([.archive(threadID: id)], label: "Marked done") }
  }

  func trash() async {
    guard let id = targetThread?.id else { return }
    await advanceAfter { await perform([.trash(threadID: id)], label: "Moved to Trash") }
  }

  func moveToInbox(_ id: String? = nil) async {
    guard let thread = id.flatMap({ i in threads.first { $0.id == i } }) ?? targetThread else { return }
    let action: MailAction
    switch location(of: thread) {
    case .trash: action = .untrash(threadID: thread.id)
    case .snoozed: action = .unsnooze(threadID: thread.id)
    default: action = .unarchive(threadID: thread.id)
    }
    await advanceAfter { await perform([action], label: "Moved to Inbox") }
  }

  func toggleRead() async {
    guard let thread = targetThread else { return }
    let action: MailAction = thread.isUnread ? .markRead(threadID: thread.id) : .markUnread(threadID: thread.id)
    await perform([action], label: thread.isUnread ? "Marked read" : "Marked unread")
  }

  func snooze(until date: Date, label: String, id: String? = nil) async {
    isSnoozePickerOpen = false
    guard let id = id ?? targetThread?.id else { return }
    await advanceAfter { await perform([.snooze(threadID: id, until: date)], label: "Snoozed until \(label)") }
  }

  func undo() async {
    if let pending = pendingSend {
      pending.task.cancel()
      pendingSend = nil
      if pending.account != activeKey, !isDemo { await switchAccount(to: pending.account) }
      if let current = draft { keep(current) }
      withAnimation(Motion.state) {
        toast = nil
        draft = pending.draft
      }
      if let threadID = pending.draft.threadID, openThread?.id != threadID { _ = await open(threadID: threadID) }
      return
    }
    guard let entry = undoStack.popLast() else { return }
    switch entry {
    case .mail(_, let restore):
      await apply(restore)
      await reload()
    case .discardedDraft(let restored):
      if let current = draft { keep(current) }
      withAnimation(Motion.state) { draft = restored }
    }
    show(Toast(text: "Undone", canUndo: false), for: 1.5)
  }

  /// Keeps the list position after the current thread leaves it, like moving to the next email.
  private func advanceAfter(_ body: () async -> Void) async {
    let list = visibleThreads
    let index = list.firstIndex { $0.id == selectedID }
    let wasOpen = openThread?.id
    await body()
    let remaining = visibleThreads
    if let index, !remaining.isEmpty, !remaining.contains(where: { $0.id == selectedID }) {
      selectedID = remaining[min(index, remaining.count - 1)].id
    }
    guard let wasOpen else { return }
    if remaining.contains(where: { $0.id == wasOpen }) { return }  // Still here (e.g. search results).
    if let next = selectedThread { await open(next) } else { closeThread() }
  }

  /// Applies actions and records exactly how to put things back.
  private func perform(_ actions: [MailAction], label: String?) async {
    guard let store else { return }
    var restore: [MailAction] = []
    do {
      for action in actions {
        let before = try await store.state(threadID: action.threadID)
        guard let undo = Self.restoreActions(for: action, from: before) else { continue }  // No-op.
        try await apply([action])
        restore.insert(contentsOf: undo, at: 0)
      }
      if let label, !restore.isEmpty {
        undoStack.append(.mail(label: label, restore: restore))
        show(Toast(text: label))
      }
    } catch {
      errorMessage = error.localizedDescription
    }
    await reload()
  }

  private func apply(_ actions: [MailAction]) async {
    guard let store else { return }
    for action in actions {
      do {
        if let engine { try await engine.perform(action) } else { try await store.apply(action) }
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  /// The actions that return a thread to `before` after `action` runs, or nil if `action` changes nothing.
  static func restoreActions(for action: MailAction, from before: MailStore.ThreadState) -> [MailAction]? {
    let current = before.labels.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    let (add, remove) = action.labelChanges
    let added = add.subtracting(current)
    let removed = remove.intersection(current)
    var restore: [MailAction] = []
    if !added.isEmpty || !removed.isEmpty {
      restore.append(.relabel(threadID: action.threadID, add: removed, remove: added))
    }
    let clearsSnooze: Bool
    switch action {
    case .snooze(_, let until):
      if before.snoozedUntil == until { return restore.isEmpty ? nil : restore }
      restore.append(before.snoozedUntil.map { .snooze(threadID: action.threadID, until: $0) } ?? .clearSnooze(threadID: action.threadID))
      return restore
    case .archive, .trash, .unsnooze, .clearSnooze: clearsSnooze = before.snoozedUntil != nil
    default: clearsSnooze = false
    }
    if clearsSnooze, let until = before.snoozedUntil {
      // Re-snoozing removes INBOX again; the relabel above restores the rest.
      restore.append(.snooze(threadID: action.threadID, until: until))
    }
    return restore.isEmpty ? nil : restore
  }

  // MARK: Agent support

  func beginActionGroup() { actionGroup = [] }

  /// Ends a request's changes; returns whether it changed anything (and so can be undone).
  @discardableResult
  func endActionGroup() -> Bool {
    defer { actionGroup = nil }
    guard let group = actionGroup, !group.isEmpty else { return false }
    undoStack.append(.mail(label: "Request", restore: group))
    return true
  }

  /// Applies agent actions to threads that exist; returns how many it applied.
  func performFromAssistant(_ actions: [MailAction]) async throws -> Int {
    guard let store else { return 0 }
    var applied = 0
    for action in actions {
      guard try await store.thread(id: action.threadID) != nil else { continue }
      let before = try await store.state(threadID: action.threadID)
      guard let undo = Self.restoreActions(for: action, from: before) else { applied += 1; continue }
      await apply([action])
      actionGroup?.insert(contentsOf: undo, at: 0)
      applied += 1
    }
    await reload()
    return applied
  }

  private func show(_ toast: Toast, for seconds: Double = 5) {
    withAnimation(Motion.state) { self.toast = toast }
    Task {
      try? await Task.sleep(for: .seconds(seconds))
      if self.toast?.id == toast.id { withAnimation(Motion.state) { self.toast = nil } }
    }
  }

  // MARK: Compose

  private func key(for draft: Draft) -> String {
    draft.kind == .new ? "new" : "thread:\(draft.threadID ?? draft.quoted?.threadID ?? "none")"
  }

  private func keep(_ draft: Draft) {
    guard !draft.isEmpty else { return }
    keptDrafts[key(for: draft)] = draft
  }

  func compose() {
    openComposer(keptDrafts.removeValue(forKey: "new") ?? Draft())
  }

  func reply(all: Bool) {
    guard let message = latestMessageForReply() else { return }
    if let kept = keptDrafts.removeValue(forKey: "thread:\(message.threadID)") {
      openComposer(kept)
    } else {
      openComposer(Draft.reply(to: message, all: all, me: me.email))
    }
  }

  func forward() {
    guard let message = openMessages.last else { return }
    openComposer(Draft.forward(message))
  }

  private func latestMessageForReply() -> Message? {
    // Reply to the newest message someone else sent, falling back to the newest overall.
    openMessages.last { $0.from.email.lowercased() != me.email.lowercased() } ?? openMessages.last
  }

  private func openComposer(_ new: Draft) {
    if let current = draft, current.id != new.id { keep(current) }
    withAnimation(Motion.state) { draft = new }
  }

  /// Closes the composer but keeps the text, so pressing R or C again brings it back.
  func closeComposer() {
    guard let current = draft else { return }
    withAnimation(Motion.state) { draft = nil }
    guard !current.isEmpty else { return }
    keep(current)
    let key = current.kind == .new ? "C" : "R"
    show(Toast(text: "Draft saved · press \(key) to reopen", canUndo: false), for: 3)
  }

  func discardDraft() {
    guard let current = draft else { return }
    withAnimation(Motion.state) { draft = nil }
    keptDrafts.removeValue(forKey: key(for: current))
    guard !current.isEmpty else { return }
    undoStack.append(.discardedDraft(current))
    show(Toast(text: "Draft discarded"))
  }

  /// Sends after a short delay so it can be undone, like taking a letter back out of the mailbox.
  func send() {
    guard let outgoing = draft, outgoing.canSend else { return }
    if pendingSend != nil { Task { await flushPendingSend() } }  // Only one in flight at a time.
    withAnimation(Motion.state) { draft = nil }
    keptDrafts.removeValue(forKey: key(for: outgoing))
    let toast = Toast(text: "Sending…", style: .sending)
    withAnimation(Motion.state) { self.toast = toast }
    let account = activeKey
    let task = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.undoSendSeconds))
      guard !Task.isCancelled, let self, self.pendingSend?.toastID == toast.id else { return }
      self.pendingSend = nil
      await self.deliver(outgoing, from: account)
    }
    pendingSend = (outgoing, account, task, toast.id)
  }

  /// Sends anything waiting in the undo window right away (quitting, signing out).
  func flushPendingSend() async {
    guard let pending = pendingSend else { return }
    pending.task.cancel()
    pendingSend = nil
    await deliver(pending.draft, from: pending.account)
  }

  /// Sends from the account the draft was written in, even if you've switched since.
  private func deliver(_ outgoing: Draft, from account: String) async {
    do {
      if let session = sessions.first(where: { $0.email == account }) {
        try await session.engine.send(outgoing, from: Address(email: session.email))
      } else if let store = demoStore {
        try await store.upsert([demoSentMessage(outgoing)])
      }
      show(Toast(text: isDemo ? "Sent · sample mailbox" : "Sent", canUndo: false), for: 2)
    } catch {
      // Put it back so nothing is lost.
      if account != activeKey { await switchAccount(to: account) }
      if let current = draft { keep(current) }
      withAnimation(Motion.state) {
        toast = nil
        draft = outgoing
      }
      errorMessage = "Couldn't send: \(error.localizedDescription)"
    }
    await reload()
  }

  private func demoSentMessage(_ d: Draft) -> Message {
    let body = d.body + (d.quoted.map { "\n\n" + MIME.quotedBlock(for: $0, forwarding: d.kind == .forward) } ?? "")
    return Message(
      id: UUID().uuidString, threadID: d.threadID ?? UUID().uuidString, from: Address(name: "You", email: me.email),
      to: d.to, cc: d.cc, date: Date(), subject: d.subject, snippet: String(d.body.prefix(120)), bodyText: body,
      labels: [Label.sent])
  }

  /// Opens a reply in a specific thread with given text (for agent requests). Keeps any draft in progress.
  func draftReply(threadID: String, body: String, all: Bool) async -> Bool {
    guard await open(threadID: threadID), let message = latestMessageForReply(), message.threadID == threadID else { return false }
    var new = Draft.reply(to: message, all: all, me: me.email)
    new.body = body
    openComposer(new)
    return true
  }
}

/// Shared animation timings so the whole app moves the same way.
enum Motion {
  static let hover = Animation.snappy(duration: 0.12)
  static let state = Animation.snappy(duration: 0.22)
  static let panel = Animation.smooth(duration: 0.28)
}

enum SnoozeOption: CaseIterable, Identifiable {
  case laterToday, tomorrow, weekend, nextWeek

  var id: Self { self }

  /// Options that make sense right now (no "later today" at 11pm).
  static func available(now: Date = Date(), calendar: Calendar = .current) -> [SnoozeOption] {
    let hour = calendar.component(.hour, from: now)
    return allCases.filter { $0 != .laterToday || hour < 20 }
  }

  func title(now: Date = Date(), calendar: Calendar = .current) -> String {
    switch self {
    case .laterToday: "Later today"
    case .tomorrow: "Tomorrow"
    case .weekend: calendar.isDateInWeekend(now) && !(calendar.component(.weekday, from: now) == 7 && calendar.component(.hour, from: now) < 9) ? "Next weekend" : "This weekend"
    case .nextWeek: "Next week"
    }
  }

  var systemImage: String {
    switch self {
    case .laterToday: "sun.max"
    case .tomorrow: "sunrise"
    case .weekend: "sofa"
    case .nextWeek: "calendar"
    }
  }

  func date(from now: Date = Date(), calendar: Calendar = .current) -> Date {
    func at(_ hour: Int, daysAhead: Int) -> Date {
      let day = calendar.date(byAdding: .day, value: daysAhead, to: now) ?? now
      return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }
    let weekday = calendar.component(.weekday, from: now)  // 1 = Sunday … 7 = Saturday
    switch self {
    case .laterToday:
      return now.addingTimeInterval(3 * 3600)
    case .tomorrow:
      return at(8, daysAhead: 1)
    case .weekend:
      if weekday == 7 && calendar.component(.hour, from: now) < 9 { return at(9, daysAhead: 0) }
      return at(9, daysAhead: weekday == 7 ? 7 : 7 - weekday)
    case .nextWeek:
      let toMonday = (9 - weekday) % 7
      return at(8, daysAhead: toMonday == 0 ? 7 : toMonday)
    }
  }

  func detail(from now: Date = Date()) -> String {
    date(from: now).formatted(.dateTime.weekday(.abbreviated).hour().minute())
  }
}
