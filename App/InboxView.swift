import RavenCore
import SwiftUI

struct InboxView: View {
  @Environment(AppModel.self) private var model
  var searchFocused: FocusState<Bool>.Binding
  @Namespace private var tabs
  @AppStorage("showShortcutHints") private var showHints = true

  var body: some View {
    @Bindable var model = model
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text(model.searchText.isEmpty ? model.mailbox.title : "Search")
          .font(.system(size: 22, weight: .bold))
          .tracking(-0.3)
          .contentTransition(.opacity)
        Spacer()
        SearchField(text: $model.searchText, focused: searchFocused)
        Button(action: model.compose) {
          Label("Compose", systemImage: "square.and.pencil")
            .padding(.horizontal, 14)
            .frame(height: 34)
        }
        .buttonStyle(PrimaryButtonStyle())
        .help("New message (C)")
      }
      .padding(.horizontal, 24)
      .padding(.top, 28)
      .padding(.bottom, 14)

      if model.mailbox == .inbox && model.searchText.isEmpty {
        HStack(spacing: 6) {
          ForEach(Array(InboxTab.allCases.enumerated()), id: \.element) { index, tab in
            TabPill(title: tab.title, count: model.count(for: tab), isActive: model.tab == tab, namespace: tabs) {
              model.select(tab: tab)
            }
            .help("\(tab.title) (\(index + 1))")
          }
          Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }

      Divider().overlay(Theme.hairline)

      if let error = model.errorMessage {
        ErrorBanner(message: error)
          .transition(.move(edge: .top).combined(with: .opacity))
      }

      ZStack {
        if model.isFirstSync {
          SkeletonList()
            .transition(.opacity)
        } else if model.visibleThreads.isEmpty {
          EmptyStateView()
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else {
          threadList
        }
      }
      .frame(maxHeight: .infinity)
      .animation(Motion.state, value: model.visibleThreads.isEmpty)

      if showHints {
        ShortcutHints { withAnimation(Motion.state) { showHints = false } }
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(Motion.state, value: model.errorMessage)
    .animation(Motion.state, value: model.mailbox)
  }

  private var threadList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 2) {
          ForEach(model.visibleThreads) { thread in
            ThreadRow(thread: thread, isSelected: thread.id == model.selectedID)
              .id(thread.id)
              .onTapGesture { Task { await model.open(thread) } }
              .contextMenu { ThreadContextMenu(thread: thread) }
              .transition(.asymmetric(
                insertion: .opacity,
                removal: .opacity.combined(with: .move(edge: .trailing))))
          }
        }
        .padding(8)
      }
      .onChange(of: model.selectedID) { _, id in
        if let id { withAnimation(Motion.state) { proxy.scrollTo(id) } }
      }
    }
    // A new mailbox, tab or search crossfades the whole list instead of animating every row.
    .id(model.listContext)
    .transition(.opacity)
  }
}

struct SearchField: View {
  @Binding var text: String
  var focused: FocusState<Bool>.Binding

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
      TextField("Search mail", text: $text)
        .textFieldStyle(.plain)
        .focused(focused)
        .onSubmit { focused.wrappedValue = false }  // Back to the list, so J/K work on the results.
        .onKeyPress(.escape) {
          text = ""
          focused.wrappedValue = false
          return .handled
        }
      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
        .transition(.opacity)
      } else {
        KeyCap(label: "/")
      }
    }
    .font(.system(size: 13))
    .padding(.leading, 12)
    .padding(.trailing, 8)
    .frame(width: 300, height: 34)
    .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused.wrappedValue ? Theme.accent.opacity(0.5) : .clear))
    .animation(Motion.hover, value: focused.wrappedValue)
    .animation(Motion.hover, value: text.isEmpty)
  }
}

struct TabPill: View {
  let title: String
  let count: Int
  let isActive: Bool
  let namespace: Namespace.ID
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Text(title).font(.system(size: 13, weight: .medium))
        if count > 0 {
          Text("\(count)")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isActive ? Color(hex: 0xD4D4D8) : Theme.tertiary)
            .contentTransition(.numericText())
        }
      }
      .foregroundStyle(isActive ? .white : Color(hex: 0x3F3F46))
      .padding(.horizontal, 12)
      .frame(height: 30)
      .background {
        // The white pill is always there; the dark one slides between tabs on top of it.
        Capsule().fill(.white).overlay(Capsule().strokeBorder(Theme.border))
        if isActive {
          Capsule().fill(Theme.ink).matchedGeometryEffect(id: "activeTab", in: namespace)
        }
      }
      .contentShape(Capsule())
    }
    .buttonStyle(PressableStyle())
  }
}

/// Slight shrink on press, so buttons feel physical.
struct PressableStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .animation(Motion.hover, value: configuration.isPressed)
  }
}

struct ThreadRow: View {
  @Environment(AppModel.self) private var model
  let thread: MailThread
  let isSelected: Bool
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 14) {
      ZStack(alignment: .topLeading) {
        Avatar(address: thread.lastFrom)
        if thread.isUnread {
          Circle().fill(Theme.accent).frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(rowBackground == .clear ? .white : rowBackground, lineWidth: 2))
            .offset(x: -2, y: -2)
            .transition(.scale.combined(with: .opacity))
        }
      }
      Text(thread.lastFrom.displayName)
        .fontWeight(thread.isUnread ? .semibold : .regular)
        .lineLimit(1)
        .frame(width: 150, alignment: .leading)
      HStack(spacing: 8) {
        Text(thread.subject)
          .fontWeight(thread.isUnread ? .semibold : .regular)
        if thread.messageCount > 1 {
          Text("\(thread.messageCount)").foregroundStyle(Theme.tertiary)
        }
        Text(thread.snippet).foregroundStyle(Theme.tertiary)
      }
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)

      ZStack(alignment: .trailing) {
        HStack(spacing: 8) {
          if let until = thread.snoozedUntil {
            Label(until.formatted(.dateTime.weekday(.abbreviated).hour()), systemImage: "clock")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(Theme.accentInk)
          }
          Text(RowDate.format(thread.lastDate))
            .font(.system(size: 12, weight: thread.isUnread ? .semibold : .regular))
            .foregroundStyle(thread.isUnread ? Theme.ink : Theme.tertiary)
        }
        .opacity(isHovered ? 0 : 1)

        if isHovered {
          HStack(spacing: 2) {
            let primary = model.primaryActionTitle(for: thread)
            RowAction(systemName: primary.systemImage, label: primary.title == "Mark done" ? "Mark done (E): moves it out of the Inbox" : "\(primary.title) (E)") {
              model.selectedID = thread.id
              Task { await model.primaryAction() }
            }
            RowAction(systemName: "clock", label: "Snooze (H)") {
              model.selectedID = thread.id
              model.isSnoozePickerOpen = true
            }
          }
          .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
      }
      .frame(width: 96, alignment: .trailing)
    }
    .font(.system(size: 13))
    .padding(.horizontal, 14)
    .frame(height: 50)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(rowBackground)
        .strokeBorder(isSelected ? Theme.selectionRing : .clear)
    )
    .contentShape(Rectangle())
    .onHover { hovering in withAnimation(Motion.hover) { isHovered = hovering } }
    .animation(Motion.hover, value: isSelected)
    .animation(Motion.state, value: thread.isUnread)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
  }
}

extension ThreadRow {
  var rowBackground: Color { isSelected ? Theme.selection : (isHovered ? Color(hex: 0xF7F7F9) : .clear) }
}

/// Right-click on a row: every action, for people who reach for the mouse.
struct ThreadContextMenu: View {
  @Environment(AppModel.self) private var model
  let thread: MailThread

  var body: some View {
    Button("Open") { Task { await model.open(thread) } }
    Divider()
    Button("Reply") { act { model.reply(all: false) } }
    Button("Reply All") { act { model.reply(all: true) } }
    Button("Forward") { act { model.forward() } }
    Divider()
    Button(model.primaryActionTitle(for: thread).title) {
      model.selectedID = thread.id
      Task { await model.primaryAction() }
    }
    Button("Snooze…") {
      model.selectedID = thread.id
      model.isSnoozePickerOpen = true
    }
    Button(thread.isUnread ? "Mark as Read" : "Mark as Unread") {
      model.selectedID = thread.id
      Task { await model.toggleRead() }
    }
    Button("Move to Trash") {
      model.selectedID = thread.id
      Task { await model.trash() }
    }
  }

  private func act(_ body: @escaping @MainActor () -> Void) {
    Task {
      await model.open(thread)
      body()
    }
  }
}

struct RowAction: View {
  let systemName: String
  let label: String
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(hovered ? Theme.accent : Theme.secondary)
        .frame(width: 30, height: 30)
        .background(hovered ? Theme.accentSoft : .white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
    }
    .buttonStyle(PressableStyle())
    .help(label)
    .accessibilityLabel(label)
    .onHover { h in withAnimation(Motion.hover) { hovered = h } }
  }
}

enum RowDate {
  static func format(_ date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) {
      return date.formatted(date: .omitted, time: .shortened)
    }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
      return "Yesterday"
    }
    if let weekAgo = calendar.date(byAdding: .day, value: -6, to: now), date > weekAgo {
      return date.formatted(.dateTime.weekday(.abbreviated))
    }
    return date.formatted(.dateTime.month(.abbreviated).day())
  }
}

struct EmptyStateView: View {
  @Environment(AppModel.self) private var model

  private var content: (icon: String, title: String, detail: String) {
    if !model.searchText.isEmpty { return ("magnifyingglass", "No results", "Try fewer words, or a name or email address.") }
    switch model.mailbox {
    case .inbox:
      return ("checkmark.circle", "You're all caught up", "New mail will show up here. Press C to write something.")
    case .snoozed:
      return ("clock", "Nothing snoozed", "Press H on any email to bring it back later.")
    case .done:
      return ("tray", "Nothing here yet", "Emails you mark done with E land here.")
    case .sent:
      return ("paperplane", "No sent mail", "Messages you send appear here.")
    case .trash:
      return ("trash", "Trash is empty", "")
    }
  }

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: content.icon)
        .font(.system(size: 32, weight: .light))
        .foregroundStyle(Theme.accent.opacity(0.8))
        .symbolEffect(.bounce, value: model.mailbox)
      Text(content.title).font(.system(size: 16, weight: .semibold))
      Text(content.detail).font(.system(size: 13)).foregroundStyle(Theme.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Placeholder rows that shimmer while the first sync runs.
struct SkeletonList: View {
  @State private var phase = false

  var body: some View {
    VStack(spacing: 2) {
      ForEach(0..<8, id: \.self) { i in
        HStack(spacing: 14) {
          Circle().frame(width: 32, height: 32)
          RoundedRectangle(cornerRadius: 4).frame(width: 120, height: 10)
          RoundedRectangle(cornerRadius: 4).frame(width: CGFloat(260 + (i * 37) % 180), height: 10)
          Spacer()
          RoundedRectangle(cornerRadius: 4).frame(width: 48, height: 10)
        }
        .foregroundStyle(Color(hex: 0xEBEBEF))
        .padding(.horizontal, 14)
        .frame(height: 50)
      }
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Fetching your mail…").font(.system(size: 13)).foregroundStyle(Theme.tertiary)
      }
      .padding(.top, 16)
      Spacer()
    }
    .padding(8)
    .opacity(phase ? 1 : 0.55)
    .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { phase = true } }
  }
}

struct ErrorBanner: View {
  @Environment(AppModel.self) private var model
  let message: String

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: 0xD97706))
      Text(message).lineLimit(2).font(.system(size: 13))
      Spacer()
      if model.needsReauth {
        Button("Sign in again") { model.signIn() }
          .buttonStyle(SecondaryButtonStyle())
      } else if !model.isDemo {
        Button("Try again") { Task { await model.syncNow() } }
          .buttonStyle(SecondaryButtonStyle())
      }
      Button {
        model.errorMessage = nil
      } label: {
        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(Color(hex: 0xFFF7ED))
  }
}

/// The handful of keys that make the app fast, shown until you dismiss them.
struct ShortcutHints: View {
  let dismiss: () -> Void

  private let hints: [(String, String)] = [
    ("J K", "Move"), ("⏎", "Open"), ("E", "Done"), ("H", "Snooze"), ("R", "Reply"), ("C", "Compose"), ("⌘K", "All commands"),
  ]

  var body: some View {
    HStack(spacing: 16) {
      ForEach(hints, id: \.0) { key, label in
        HStack(spacing: 6) {
          KeyCap(label: key)
          Text(label)
        }
      }
      Spacer()
      Button("Hide", action: dismiss)
        .buttonStyle(.plain)
        .foregroundStyle(Theme.tertiary)
        .help("Hide these hints. Find every command in ⌘K or the menu bar.")
    }
    .font(.system(size: 12))
    .foregroundStyle(Theme.secondary)
    .padding(.horizontal, 20)
    .frame(height: 40)
    .background(Color(hex: 0xFAFAFB))
    .overlay(alignment: .top) { Divider().overlay(Theme.hairline) }
  }
}
