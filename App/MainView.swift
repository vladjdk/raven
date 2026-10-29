import RavenCore
import SwiftUI

struct MainView: View {
  @Environment(AppModel.self) private var model
  @FocusState private var listFocused: Bool
  @FocusState private var searchFocused: Bool

  var body: some View {
    @Bindable var model = model
    HStack(spacing: 0) {
      SidebarView()
        .frame(width: 224)
      ZStack {
        // The inbox stays mounted under an open thread so its scroll position survives.
        InboxView(searchFocused: $searchFocused)
          .opacity(model.openThread == nil ? 1 : 0)
          .allowsHitTesting(model.openThread == nil)
          .accessibilityHidden(model.openThread != nil)
        if model.openThread != nil {
          ThreadDetailView()
            .background(Theme.panel)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .zIndex(1)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(Theme.panel)
          .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
      )
      .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.black.opacity(0.05)))
      .padding([.top, .bottom, .trailing], 8)
    }
    .ignoresSafeArea()
    .focusable()
    .focused($listFocused)
    .focusEffectDisabled()
    .onKeyPress(phases: .down) { press in handle(press) }
    .onAppear { listFocused = true }
    // Whenever an overlay or field lets go, the list gets the keyboard back so J/K/E keep working.
    .onChange(of: model.isPaletteOpen) { _, open in if !open { listFocused = true } }
    .onChange(of: model.isSnoozePickerOpen) { _, open in if !open { listFocused = true } }
    .onChange(of: model.draft == nil) { _, closed in if closed { listFocused = true } }
    .onChange(of: searchFocused) { _, focused in if !focused { listFocused = true } }
    .onChange(of: model.searchFocusRequest) { searchFocused = true }
    .overlay(alignment: .bottomTrailing) {
      // New messages, and replies to a thread that isn't open, float over the window.
      if let draft = model.draft, !model.showsInlineComposer {
        ComposerView(draft: Binding(get: { model.draft ?? draft }, set: { model.draft = $0 }), inline: false)
          .id(draft.id)
          .frame(width: 560, height: 460)
          .padding(24)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .overlay {
      ZStack {
        if model.isPaletteOpen || model.isSnoozePickerOpen {
          Color.black.opacity(0.12)
            .ignoresSafeArea()
            .onTapGesture {
              model.isPaletteOpen = false
              model.isSnoozePickerOpen = false
            }
            .transition(.opacity)
        }
        if model.isPaletteOpen {
          CommandPaletteView()
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 110)
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        } else if model.isSnoozePickerOpen {
          SnoozePickerView()
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
      }
      .animation(Motion.state, value: model.isPaletteOpen)
      .animation(Motion.state, value: model.isSnoozePickerOpen)
    }
    .overlay(alignment: .bottom) {
      if let toast = model.toast {
        ToastView(toast: toast)
          .id(toast.id)
          .padding(.bottom, 64)  // Clear of the shortcut hints and the composer's Send button.
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .confirmationDialog(
      model.isDemo ? "Leave the sample mailbox?" : "Sign out of \(model.account ?? "Gmail")?",
      isPresented: $model.isConfirmingSignOut
    ) {
      Button(model.isDemo ? "Leave" : "Sign Out", role: .destructive) { Task { await model.signOut() } }
    } message: {
      Text(model.isDemo ? "Changes you made to the sample mail won't be kept." : "Mail stored on this Mac will be removed. It stays in your Gmail account.")
    }
  }

  /// Single-key shortcuts. They only fire when no text field has focus.
  private func handle(_ press: KeyPress) -> KeyPress.Result {
    guard !searchFocused, !model.isPaletteOpen, !model.isSnoozePickerOpen, model.draft == nil else { return .ignored }
    if press.modifiers.contains(.command) || press.modifiers.contains(.control) { return .ignored }
    switch press.key {
    case .downArrow: model.moveSelection(1); return .handled
    case .upArrow: model.moveSelection(-1); return .handled
    case .return: Task { await model.openSelected() }; return .handled
    case .escape:
      if model.openThread != nil { model.closeThread(); return .handled }
      if !model.searchText.isEmpty { model.searchText = ""; return .handled }
      return .ignored
    default: break
    }
    switch press.characters {
    case "j": model.moveSelection(1)
    case "k": model.moveSelection(-1)
    case "o": Task { await model.openSelected() }
    case "e": Task { await model.primaryAction() }
    case "#": Task { await model.trash() }
    case "u": Task { await model.toggleRead() }
    case "h": if model.targetThread != nil { model.isSnoozePickerOpen = true }
    case "z": Task { await model.undo() }
    case "/": searchFocused = true
    case "c": model.compose()
    case "r", "a", "f":
      let key = press.characters
      Task {
        // From the list, open the thread first so the reply has context.
        if model.openThread == nil { await model.openSelected() }
        if key == "f" { model.forward() } else { model.reply(all: key == "a") }
      }
    case "?": model.isPaletteOpen = true
    case "1", "2", "3", "4":
      guard model.openThread == nil, model.mailbox == .inbox, model.searchText.isEmpty, let index = Int(press.characters) else { return .ignored }
      model.select(tab: InboxTab.allCases[index - 1])
    default: return .ignored
    }
    return .handled
  }
}

struct SidebarView: View {
  @Environment(AppModel.self) private var model
  @Namespace private var selection

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Spacer().frame(height: 30)  // Room for the window's traffic lights; aligns with the panel's title.
      ForEach(Array(Mailbox.allCases.enumerated()), id: \.element) { index, box in
        SidebarRow(
          title: box.title, systemImage: icon(box), count: model.counts[box],
          isSelected: model.mailbox == box && model.searchText.isEmpty, namespace: selection
        ) {
          model.go(to: box)
        }
        .help("\(box.title) (⌘\(index + 1))")
      }
      Spacer()
      AccountMenu()
    }
    .padding(.horizontal, 12)
    .animation(Motion.state, value: model.mailbox)
  }

  private func icon(_ box: Mailbox) -> String {
    switch box {
    case .inbox: "tray"
    case .snoozed: "clock"
    case .done: "checkmark.circle"
    case .sent: "paperplane"
    case .trash: "trash"
    }
  }
}

/// The account line at the bottom of the sidebar doubles as the way to Settings and signing out.
struct AccountMenu: View {
  @Environment(AppModel.self) private var model
  @State private var hovered = false

  var body: some View {
    Menu {
      SettingsLink { Text("Settings…") }
      if model.isDemo, model.oauth != nil {
        Button("Sign in to Gmail…") { Task { await model.signOut() } }
      }
      Divider()
      Button(model.isDemo ? "Leave Sample Mailbox" : "Sign Out…") { model.requestSignOut() }
    } label: {
      HStack(spacing: 8) {
        Circle()
          .fill(model.needsReauth || model.errorMessage != nil ? Color.orange : Color.green.opacity(0.8))
          .frame(width: 7, height: 7)
        Text(model.account ?? "Signed in")
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
        if model.isSyncing {
          ProgressView().controlSize(.mini)
        } else {
          Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
        }
      }
      .font(.system(size: 12))
      .foregroundStyle(Theme.secondary)
      .padding(.horizontal, 10)
      .frame(height: 32)
      .background(hovered ? Color.black.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 8))
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .onHover { h in withAnimation(Motion.hover) { hovered = h } }
    .help(model.isDemo ? "Sample mailbox. Nothing is synced." : (model.needsReauth ? "Sign in again to keep syncing" : "Account, Settings and sign out"))
    .padding(.bottom, 12)
  }
}

struct SidebarRow: View {
  let title: String
  let systemImage: String
  let count: Int?
  let isSelected: Bool
  let namespace: Namespace.ID
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: systemImage)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(isSelected ? Theme.accent : Theme.secondary)
          .frame(width: 18)
        Text(title)
          .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
          .foregroundStyle(isSelected ? Theme.ink : Theme.secondary)
        Spacer()
        if let count, count > 0 {
          Text("\(count)")
            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Theme.accent : Theme.secondary)
            .contentTransition(.numericText())
        }
      }
      .padding(.horizontal, 10)
      .frame(height: 32)
      .background {
        if isSelected {
          RoundedRectangle(cornerRadius: 8)
            .fill(.white)
            .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
            .matchedGeometryEffect(id: "sidebarSelection", in: namespace)
        } else if hovered {
          RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.04))
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(PressableStyle())
    .onHover { h in withAnimation(Motion.hover) { hovered = h } }
  }
}

struct ToastView: View {
  @Environment(AppModel.self) private var model
  let toast: AppModel.Toast

  var body: some View {
    HStack(spacing: 14) {
      if toast.style == .sending {
        SendProgress(seconds: AppModel.undoSendSeconds)
      }
      Text(toast.text).font(.system(size: 13, weight: .medium))
      if toast.canUndo {
        Button {
          Task { await model.undo() }
        } label: {
          HStack(spacing: 6) {
            Text("Undo").font(.system(size: 13, weight: .semibold))
            Text("Z")
              .font(.system(size: 11, weight: .semibold))
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
          }
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(Color(hex: 0xC7C7F5))
      }
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 16)
    .frame(height: 40)
    .background(Theme.ink, in: Capsule())
    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
  }
}

/// A ring that empties over the undo-send window, so you can see how long you have.
struct SendProgress: View {
  let seconds: Double
  @State private var remaining: CGFloat = 1

  var body: some View {
    Circle()
      .trim(from: 0, to: remaining)
      .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
      .rotationEffect(.degrees(-90))
      .frame(width: 14, height: 14)
      .onAppear { withAnimation(.linear(duration: seconds)) { remaining = 0 } }
  }
}
