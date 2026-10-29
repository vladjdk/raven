import RavenCore
import SwiftUI

struct PaletteCommand: Identifiable {
  let id: String
  let title: String
  let systemImage: String
  let keys: [String]
  let run: @MainActor (AppModel) async -> Void
}

struct CommandPaletteView: View {
  @Environment(AppModel.self) private var model
  @State private var query = ""
  @State private var selection = 0
  @FocusState private var focused: Bool

  private var commands: [PaletteCommand] {
    var all: [PaletteCommand] = [
      .init(id: "done", title: "Mark done", systemImage: "checkmark", keys: ["E"]) { await $0.archive() },
      .init(id: "snooze", title: "Snooze…", systemImage: "clock", keys: ["H"]) { $0.isSnoozePickerOpen = true },
      .init(id: "unread", title: "Toggle read / unread", systemImage: "envelope.badge", keys: ["U"]) { await $0.toggleRead() },
      .init(id: "trash", title: "Move to Trash", systemImage: "trash", keys: ["#"]) { await $0.trash() },
      .init(id: "undo", title: "Undo", systemImage: "arrow.uturn.backward", keys: ["Z"]) { await $0.undo() },
    ]
    for box in Mailbox.allCases {
      all.append(.init(id: "go-\(box.rawValue)", title: "Go to \(box.title)", systemImage: "arrow.right", keys: []) { model in
        model.closeThread()
        model.searchText = ""
        model.mailbox = box
      })
    }
    if !model.isDemo {
      all.append(.init(id: "refresh", title: "Refresh", systemImage: "arrow.clockwise", keys: ["⌘", "R"]) { await $0.syncNow() })
    }
    all.append(.init(id: "signout", title: "Sign out", systemImage: "rectangle.portrait.and.arrow.right", keys: []) { await $0.signOut() })
    return all
  }

  private var matches: [PaletteCommand] {
    let q = query.trimmingCharacters(in: .whitespaces)
    let filtered = q.isEmpty ? commands : commands.filter { $0.title.localizedCaseInsensitiveContains(q) }
    guard !q.isEmpty else { return filtered }
    // Anything typed can also be a mail search.
    let search = PaletteCommand(id: "search", title: "Search mail for “\(q)”", systemImage: "magnifyingglass", keys: ["⏎"]) { model in
      model.closeThread()
      model.searchText = q
    }
    return filtered + [search]
  }

  var body: some View {
    ZStack(alignment: .top) {
      Color.black.opacity(0.12)
        .ignoresSafeArea()
        .onTapGesture { model.isPaletteOpen = false }

      VStack(spacing: 0) {
        HStack(spacing: 12) {
          Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(Theme.tertiary)
          TextField("Type a command or search", text: $query)
            .textFieldStyle(.plain)
            .font(.system(size: 16, weight: .medium))
            .focused($focused)
            .onSubmit { run(selection) }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.escape) { model.isPaletteOpen = false; return .handled }
          KeyCap(label: "esc")
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        Divider().overlay(Theme.hairline)

        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
              Button { run(index) } label: {
                HStack(spacing: 12) {
                  Image(systemName: command.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(hex: 0x3F3F46))
                    .frame(width: 30, height: 30)
                    .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
                  Text(command.title).font(.system(size: 14, weight: .medium))
                  Spacer()
                  HStack(spacing: 4) { ForEach(command.keys, id: \.self) { KeyCap(label: $0) } }
                }
                .padding(.horizontal, 10)
                .frame(height: 44)
                .background(index == selection ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .onHover { if $0 { selection = index } }
            }
          }
          .padding(10)
        }
        .frame(maxHeight: 380)
        .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 16) {
          Text("↑↓ to move")
          Text("⏎ to run")
          Spacer()
          Text("Type anything to search")
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
      .padding(.top, 110)
    }
    .onAppear { focused = true }
    .onChange(of: query) { selection = 0 }
  }

  private func move(_ delta: Int) {
    selection = max(0, min(matches.count - 1, selection + delta))
  }

  private func run(_ index: Int) {
    let list = matches
    guard list.indices.contains(index) else { return }
    let command = list[index]
    model.isPaletteOpen = false
    Task { await command.run(model) }
  }
}

struct SnoozePickerView: View {
  @Environment(AppModel.self) private var model
  @FocusState private var focused: Bool

  var body: some View {
    ZStack {
      Color.black.opacity(0.12).ignoresSafeArea().onTapGesture { model.isSnoozePickerOpen = false }
      VStack(alignment: .leading, spacing: 2) {
        Text("Snooze until")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Theme.tertiary)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
        ForEach(SnoozeOption.allCases) { option in
          Button {
            Task { await model.snooze(until: option.date(), label: option.title.lowercased()) }
          } label: {
            HStack(spacing: 12) {
              Text(option.title).font(.system(size: 14, weight: .medium))
              Spacer()
              Text(option.detail()).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
              KeyCap(label: option.shortcut)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .padding(10)
      .frame(width: 360)
      .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
      .focusable()
      .focused($focused)
      .focusEffectDisabled()
      .onKeyPress { press in
        if press.key == .escape { model.isSnoozePickerOpen = false; return .handled }
        guard let n = Int(press.characters), (1...SnoozeOption.allCases.count).contains(n) else { return .ignored }
        let option = SnoozeOption.allCases[n - 1]
        Task { await model.snooze(until: option.date(), label: option.title.lowercased()) }
        return .handled
      }
      .onAppear { focused = true }
    }
  }
}
