import RavenCore
import SwiftUI

struct PaletteCommand: Identifiable {
  let id: String
  let title: String
  let systemImage: String
  let keys: [String]
  var enabled = true
  let run: @MainActor (AppModel) async -> Void
}

struct CommandPaletteView: View {
  @Environment(AppModel.self) private var model
  @State private var query = ""
  @State private var selection = 0
  @FocusState private var focused: Bool

  private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// Every action in the app, labelled for where the current thread actually is.
  private var commands: [PaletteCommand] {
    let target = model.targetThread
    let primary = model.primaryActionTitle(for: target)
    var all: [PaletteCommand] = [
      .init(id: "compose", title: "New message", systemImage: "square.and.pencil", keys: ["C"]) { $0.compose() },
    ]
    if target != nil {
      all += [
        .init(id: "reply", title: "Reply", systemImage: "arrowshape.turn.up.left", keys: ["R"]) { model in
          if model.openThread == nil { await model.openSelected() }
          model.reply(all: false)
        },
        .init(id: "replyall", title: "Reply all", systemImage: "arrowshape.turn.up.left.2", keys: ["A"]) { model in
          if model.openThread == nil { await model.openSelected() }
          model.reply(all: true)
        },
        .init(id: "forward", title: "Forward", systemImage: "arrowshape.turn.up.right", keys: ["F"]) { model in
          if model.openThread == nil { await model.openSelected() }
          model.forward()
        },
        .init(id: "primary", title: primary.title, systemImage: primary.systemImage, keys: ["E"]) { await $0.primaryAction() },
        .init(id: "snooze", title: "Snooze…", systemImage: "clock", keys: ["H"]) { $0.isSnoozePickerOpen = true },
        .init(id: "unread", title: target?.isUnread == true ? "Mark as read" : "Mark as unread", systemImage: "envelope.badge", keys: ["U"]) {
          await $0.toggleRead()
        },
        .init(id: "trash", title: "Move to Trash", systemImage: "trash", keys: ["#"]) { await $0.trash() },
      ]
    }
    if model.canUndo {
      all.append(.init(id: "undo", title: model.undoTitle, systemImage: "arrow.uturn.backward", keys: ["Z"]) { await $0.undo() })
    }
    all.append(.init(id: "find", title: "Search mail", systemImage: "magnifyingglass", keys: ["/"]) { $0.focusSearch() })
    for (index, box) in Mailbox.allCases.enumerated() {
      all.append(.init(id: "go-\(box.rawValue)", title: "Go to \(box.title)", systemImage: "arrow.right", keys: ["⌘", "\(index + 1)"]) { $0.go(to: box) })
    }
    if !model.isDemo {
      all.append(.init(id: "refresh", title: "Refresh", systemImage: "arrow.clockwise", keys: ["⌘", "R"]) { await $0.syncNow() })
    }
    all.append(.init(id: "settings", title: "Settings", systemImage: "gearshape", keys: ["⌘", ","]) { _ in openSettings() })
    all.append(.init(id: "signout", title: model.isDemo ? "Leave sample mailbox" : "Sign out", systemImage: "rectangle.portrait.and.arrow.right", keys: []) {
      $0.requestSignOut()
    })
    return all
  }

  private var matches: [PaletteCommand] {
    let q = trimmed
    guard !q.isEmpty else { return commands }
    let filtered = commands.filter { $0.title.localizedCaseInsensitiveContains(q) }
    let search = PaletteCommand(id: "search", title: "Search mail for “\(q)”", systemImage: "magnifyingglass", keys: []) { model in
      model.closeThread()
      model.searchText = q
    }
    // A few words or more can also be a request to carry out ("archive this week's newsletters").
    guard q.split(separator: " ").count >= 3, Assistant.isAvailable else { return filtered + [search] }
    let request: PaletteCommand
    if model.assistant.hasAPIKey {
      request = .init(id: "do", title: "Do this: “\(q)”", systemImage: "bolt", keys: []) { await $0.assistant.run(q) }
    } else {
      request = .init(id: "setup", title: "Do this: “\(q)” · set up in Settings", systemImage: "bolt", keys: [], enabled: false) { _ in
        openSettings()
      }
    }
    return filtered.isEmpty ? [request, search] : filtered + [search, request]
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(Theme.tertiary)
        TextField("Search, run a command, or describe a change", text: $query)
          .textFieldStyle(.plain)
          .font(.system(size: 16, weight: .medium))
          .focused($focused)
          .onSubmit(submit)
          .onKeyPress(.downArrow) { move(1); return .handled }
          .onKeyPress(.upArrow) { move(-1); return .handled }
          .onKeyPress(.escape) { model.isPaletteOpen = false; return .handled }
          .disabled(model.assistant.isRunning)
        KeyCap(label: "esc")
      }
      .padding(.horizontal, 18)
      .frame(height: 58)
      Divider().overlay(Theme.hairline)

      if model.assistant.state != .idle {
        AssistantResultView()
          .transition(.opacity.combined(with: .move(edge: .top)))
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 2) {
              ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                PaletteRow(command: command, isSelected: index == selection) { run(index) }
                  .id(index)
                  .onHover { if $0 { selection = index } }
              }
            }
            .padding(10)
          }
          .frame(maxHeight: 380)
          .fixedSize(horizontal: false, vertical: true)
          .onChange(of: selection) { _, index in withAnimation(Motion.hover) { proxy.scrollTo(index) } }
        }
      }

      HStack(spacing: 16) {
        Text("↑↓ to move")
        Text("⏎ to run")
        Spacer()
        Text("esc to close")
      }
      .font(.system(size: 12))
      .foregroundStyle(Theme.tertiary)
      .padding(.horizontal, 18)
      .frame(height: 36)
      .background(Color(hex: 0xFAFAFB))
    }
    .frame(width: 600)
    .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
    .onAppear {
      focused = true
      model.assistant.reset()
    }
    .onChange(of: query) {
      selection = 0
      model.assistant.reset()
    }
    .animation(Motion.state, value: model.assistant.state)
  }

  /// ⏎ runs the selected command, or closes the result card once a request has finished.
  private func submit() {
    switch model.assistant.state {
    case .running: return
    case .done, .failed: model.isPaletteOpen = false
    case .idle: run(selection)
    }
  }

  private func move(_ delta: Int) {
    selection = max(0, min(matches.count - 1, selection + delta))
  }

  private func run(_ index: Int) {
    let list = matches
    guard list.indices.contains(index) else { return }
    let command = list[index]
    if command.id != "do" { model.isPaletteOpen = false }
    Task { await command.run(model) }
  }
}

@MainActor
func openSettings() {
  NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
}

private struct PaletteRow: View {
  let command: PaletteCommand
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: command.systemImage)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(isSelected ? Theme.accent : Color(hex: 0x3F3F46))
          .frame(width: 30, height: 30)
          .background(isSelected ? Theme.accentSoft : Theme.fill, in: RoundedRectangle(cornerRadius: 8))
        Text(command.title)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(command.enabled ? Theme.ink : Theme.tertiary)
          .lineLimit(1)
        Spacer()
        HStack(spacing: 4) { ForEach(command.keys, id: \.self) { KeyCap(label: $0) } }
      }
      .padding(.horizontal, 10)
      .frame(height: 44)
      .background(isSelected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .animation(Motion.hover, value: isSelected)
  }
}

struct SnoozePickerView: View {
  @Environment(AppModel.self) private var model
  @FocusState private var focused: Bool
  @State private var selection = 0

  private var options: [SnoozeOption] { SnoozeOption.available() }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Snooze until")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
      ForEach(Array(options.enumerated()), id: \.element) { index, option in
        Button { choose(option) } label: {
          HStack(spacing: 12) {
            Image(systemName: option.systemImage)
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(index == selection ? Theme.accent : Theme.secondary)
              .frame(width: 20)
            Text(option.title()).font(.system(size: 14, weight: .medium))
            Spacer()
            Text(option.detail()).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            KeyCap(label: "\(index + 1)")
          }
          .padding(.horizontal, 10)
          .frame(height: 40)
          .background(index == selection ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { selection = index } }
      }
    }
    .padding(10)
    .frame(width: 380)
    .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
    .focusable()
    .focused($focused)
    .focusEffectDisabled()
    .onKeyPress { press in
      switch press.key {
      case .escape: model.isSnoozePickerOpen = false; return .handled
      case .downArrow: selection = min(options.count - 1, selection + 1); return .handled
      case .upArrow: selection = max(0, selection - 1); return .handled
      case .return: choose(options[selection]); return .handled
      default: break
      }
      guard let n = Int(press.characters), options.indices.contains(n - 1) else { return .ignored }
      choose(options[n - 1])
      return .handled
    }
    .animation(Motion.hover, value: selection)
    .onAppear { focused = true }
  }

  private func choose(_ option: SnoozeOption) {
    Task { await model.snooze(until: option.date(), label: option.title().lowercased()) }
  }
}

/// Shows a request being carried out, then what changed, with one Undo for all of it.
struct AssistantResultView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let assistant = model.assistant
    VStack(alignment: .leading, spacing: 10) {
      switch assistant.state {
      case .running:
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text("Running…").font(.system(size: 14, weight: .medium))
        }
      case .done(let summary):
        ResultCard(icon: "checkmark", tint: Theme.success, background: Theme.successSoft, title: summary) {
          if assistant.madeChanges {
            Button("Undo") {
              Task {
                await model.undo()
                model.isPaletteOpen = false
              }
            }
            .buttonStyle(SecondaryButtonStyle())
          }
          Button("Close") { model.isPaletteOpen = false }
            .buttonStyle(SecondaryButtonStyle())
        }
      case .failed(let message):
        ResultCard(icon: "exclamationmark", tint: Color(hex: 0xB45309), background: Color(hex: 0xFFF7ED), title: message) {
          if !assistant.hasAPIKey && Assistant.isAvailable {
            Button("Open Settings") { openSettings() }.buttonStyle(SecondaryButtonStyle())
          }
          Button("Close") { model.isPaletteOpen = false }.buttonStyle(SecondaryButtonStyle())
        }
      case .idle:
        EmptyView()
      }
      ForEach(Array(assistant.steps.enumerated()), id: \.offset) { _, step in
        HStack(spacing: 8) {
          Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.tertiary)
          Text(step).font(.system(size: 13)).foregroundStyle(Theme.secondary)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ResultCard<Actions: View>: View {
  let icon: String
  let tint: Color
  let background: Color
  let title: String
  @ViewBuilder var actions: () -> Actions

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: icon)
        .font(.system(size: 15, weight: .bold))
        .foregroundStyle(tint)
        .frame(width: 34, height: 34)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
      Text(title).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
      Spacer()
      actions()
    }
    .padding(14)
    .background(background, in: RoundedRectangle(cornerRadius: 12))
  }
}
