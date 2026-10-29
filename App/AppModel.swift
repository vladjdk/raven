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
  private(set) var isDemo = false
  private(set) var account: String?
  private(set) var isSyncing = false
  private(set) var hasSyncedOnce = false
  /// Google rejected our token; mail is still here but nothing syncs until you sign in again.
  private(set) var needsReauth = false
  var errorMessage: String?

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
  private var keptDrafts: [String: Draft] = [:]

  private var store: MailStore?
  private var engine: SyncEngine?
  private var tokens: TokenStore?
  private var syncLoop: Task<Void, Never>?
  private var searchTask: Task<Void, Never>?
  private var signInTask: Task<Void, Never>?
  private var undoStack: [UndoEntry] = []
  private var pendingSend: (draft: Draft, task: Task<Void, Never>, toastID: UUID)?
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

  func signIn() {
    guard let oauth else { return }
    let wasReady = phase == .ready
    if !wasReady { phase = .signingIn }
    errorMessage = nil
    signInTask?.cancel()
    signInTask = Task {
      do {
        let new = try await oauth.signIn { url in
          await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
        let tokens = TokenStore(oauth: oauth, keychain: keychain, account: "google")
        try await tokens.save(new)
        NSApp.activate(ignoringOtherApps: true)
        needsReauth = false
        if wasReady, let store = self.store {
          // Re-auth keeps the local mailbox; just swap in the new tokens.
          self.tokens = tokens
          self.engine = SyncEngine(store: store, api: GmailClient(tokens: tokens))
          startSyncLoop()
        } else {
          await open(tokens: tokens)
        }
      } catch is CancellationError {
        if !wasReady { phase = .signedOut }
      } catch {
        errorMessage = error.localizedDescription
        if !wasReady { phase = .signedOut }
      }
    }
  }

  func cancelSignIn() {
    signInTask?.cancel()
    signInTask = nil
    if phase == .signingIn { phase = .signedOut }
  }

  func startDemo() async {
    do {
      let store = try MailStore(url: nil)
      try await store.upsert(SampleMail.messages())
      self.store = store
      isDemo = true
      account = "Sample mailbox"
      errorMessage = nil
      withAnimation(Motion.panel) { phase = .ready }
      await reload(newContext: true)
      // No server in demo mode, but snoozes still wake up.
      syncLoop = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(20))
          await self?.wakeDemoSnoozes()
        }
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func wakeDemoSnoozes() async {
    guard isDemo, let store, let due = try? await store.dueSnoozes(), !due.isEmpty else { return }
    for id in due { try? await store.apply(.unsnooze(threadID: id)) }
    await reload()
  }

  func requestSignOut() { isConfirmingSignOut = true }

  func signOut() async {
    await flushPendingSend()
    syncLoop?.cancel()
    searchTask?.cancel()
    signInTask?.cancel()
    try? await tokens?.clear()
    let wasDemo = isDemo
    store = nil
    engine = nil
    tokens = nil
    if !wasDemo, let url = Self.databaseURL {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
      }
    }
    threads = []
    counts = [:]
    openThread = nil
    openMessages = []
    selectedID = nil
    draft = nil
    keptDrafts = [:]
    undoStack = []
    actionGroup = nil
    toast = nil
    searchText = ""
    mailbox = .inbox
    tab = .important
    isPaletteOpen = false
    isSnoozePickerOpen = false
    errorMessage = nil
    needsReauth = false
    assistant.reset()
    isDemo = false
    hasSyncedOnce = false
    account = nil
    withAnimation(Motion.panel) { phase = .signedOut }
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
      hasSyncedOnce = try await store.meta("historyId") != nil
      withAnimation(Motion.panel) { phase = .ready }
      await reload(newContext: true)
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
    guard let engine, !isSyncing, !needsReauth else { return }
    isSyncing = true
    defer { isSyncing = false }
    do {
      try await engine.sync()
      account = try await store?.meta("account")
      hasSyncedOnce = true
      errorMessage = nil
    } catch is CancellationError {
    } catch let error as OAuthError where error.needsSignIn {
      reauthRequired()
    } catch let error as GmailError where error.isAuth {
      reauthRequired()
    } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
      errorMessage = "You're offline. Changes will sync when you're back."
    } catch {
      errorMessage = error.localizedDescription
    }
    await reload()
  }

  private func reauthRequired() {
    needsReauth = true
    errorMessage = "Your Google sign-in expired. Your changes are saved and will sync after you sign in again."
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
    let task = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.undoSendSeconds))
      guard !Task.isCancelled, let self, self.pendingSend?.toastID == toast.id else { return }
      self.pendingSend = nil
      await self.deliver(outgoing)
    }
    pendingSend = (outgoing, task, toast.id)
  }

  /// Sends anything waiting in the undo window right away (quitting, signing out).
  func flushPendingSend() async {
    guard let pending = pendingSend else { return }
    pending.task.cancel()
    pendingSend = nil
    await deliver(pending.draft)
  }

  private func deliver(_ outgoing: Draft) async {
    do {
      if let engine {
        try await engine.send(outgoing, from: me)
      } else if let store {
        try await store.upsert([demoSentMessage(outgoing)])
      }
      show(Toast(text: isDemo ? "Sent · sample mailbox" : "Sent", canUndo: false), for: 2)
    } catch {
      // Put it back so nothing is lost.
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
