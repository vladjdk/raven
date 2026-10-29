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
      Group {
        if model.openThread != nil {
          ThreadDetailView()
        } else {
          InboxView(searchFocused: $searchFocused)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.black.opacity(0.05)))
      .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
      .padding([.top, .bottom, .trailing], 8)
    }
    .ignoresSafeArea()
    .focusable()
    .focused($listFocused)
    .focusEffectDisabled()
    .onKeyPress(phases: .down) { press in handle(press) }
    .onAppear { listFocused = true }
    .onChange(of: model.isPaletteOpen) { _, open in if !open { listFocused = true } }
    .overlay {
      if model.isPaletteOpen {
        CommandPaletteView()
      } else if model.isSnoozePickerOpen {
        SnoozePickerView()
      }
    }
    .overlay(alignment: .bottom) {
      if let toast = model.toast {
        ToastView(toast: toast).padding(.bottom, 24)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.snappy(duration: 0.2), value: model.toast)
  }

  /// Single-key shortcuts. They only fire when no text field has focus.
  private func handle(_ press: KeyPress) -> KeyPress.Result {
    guard !searchFocused, !model.isPaletteOpen, !model.isSnoozePickerOpen else { return .ignored }
    if press.modifiers.contains(.command) { return .ignored }
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
    case "e": Task { await model.archive() }
    case "#": Task { await model.trash() }
    case "u": Task { await model.toggleRead() }
    case "h": model.isSnoozePickerOpen = true
    case "z": Task { await model.undo() }
    case "/": searchFocused = true
    case "1", "2", "3", "4":
      guard model.openThread == nil, model.mailbox == .inbox, let index = Int(press.characters) else { return .ignored }
      model.select(tab: InboxTab.allCases[index - 1])
    default: return .ignored
    }
    return .handled
  }
}

struct SidebarView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Spacer().frame(height: 44)  // Room for the window's traffic lights.
      ForEach(Mailbox.allCases) { box in
        SidebarRow(
          title: box.title, systemImage: icon(box), count: model.counts[box],
          isSelected: model.mailbox == box && model.searchText.isEmpty
        ) {
          model.searchText = ""
          model.closeThread()
          model.mailbox = box
        }
      }
      Spacer()
      HStack(spacing: 8) {
        Circle()
          .fill(model.errorMessage == nil ? Color.green.opacity(0.8) : Color.orange)
          .frame(width: 7, height: 7)
        Text(model.account ?? "Signed in")
          .lineLimit(1)
          .truncationMode(.middle)
        if model.isSyncing { ProgressView().controlSize(.mini) }
      }
      .font(.system(size: 12))
      .foregroundStyle(Theme.tertiary)
      .padding(.horizontal, 10)
      .padding(.bottom, 14)
      .help(model.errorMessage ?? (model.isDemo ? "Sample mailbox, nothing is synced" : "Synced"))
    }
    .padding(.horizontal, 12)
  }

  private func icon(_ box: Mailbox) -> String {
    switch box {
    case .inbox: "tray"
    case .snoozed: "clock"
    case .done: "checkmark"
    case .sent: "paperplane"
    case .trash: "trash"
    }
  }
}

struct SidebarRow: View {
  let title: String
  let systemImage: String
  let count: Int?
  let isSelected: Bool
  let action: () -> Void

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
            .foregroundStyle(isSelected ? Theme.accent : Theme.tertiary)
        }
      }
      .padding(.horizontal, 10)
      .frame(height: 32)
      .background {
        if isSelected {
          RoundedRectangle(cornerRadius: 8).fill(.white).shadow(color: .black.opacity(0.06), radius: 1, y: 1)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

struct ToastView: View {
  @Environment(AppModel.self) private var model
  let toast: AppModel.Toast

  var body: some View {
    HStack(spacing: 14) {
      Text(toast.text).font(.system(size: 13, weight: .medium))
      Button {
        Task { await model.undo() }
      } label: {
        HStack(spacing: 6) {
          Text("Undo").font(.system(size: 13, weight: .semibold))
          Text("Z").font(.system(size: 11, weight: .medium)).opacity(0.7)
        }
      }
      .buttonStyle(.plain)
      .foregroundStyle(Color(hex: 0xC7C7F5))
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 16)
    .frame(height: 40)
    .background(Theme.ink, in: Capsule())
    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
  }
}
